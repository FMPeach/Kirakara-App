import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../lan_address_resolver.dart';
import 'dlna_device.dart';
import 'dlna_device_description_parser.dart';
import 'dlna_http_client.dart';
import 'windows_upnp_discovery_bridge.dart';

typedef DlnaDescriptionLoader = Future<String> Function(
  Uri location,
  String localAddress,
);
typedef DlnaLocalInterfaceResolver = Future<LanAddressCandidate?> Function();
typedef DlnaLocalInterfacesResolver = Future<List<DlnaDiscoveryInterface>>
    Function();
typedef DlnaDiscoveryLogger = void Function(String message);
typedef DlnaDeviceDiscovered = void Function(DlnaDevice device);
typedef DlnaDeviceRemoved = void Function(String usn);
typedef DlnaTargetAddressResolver = Future<String?> Function(Uri location);
typedef DlnaUnicastSearch = Future<List<DlnaSsdpResponse>> Function(
  InternetAddress targetAddress,
  String localAddress,
  Duration responseWindow,
);

class DlnaSsdpResponse {
  const DlnaSsdpResponse({required this.location, this.usn});

  final Uri location;
  final String? usn;
}

enum DlnaSsdpMessageType {
  searchResponse,
  alive,
  update,
  byebye,
}

class DlnaSsdpMessage {
  const DlnaSsdpMessage({
    required this.type,
    this.location,
    this.usn,
  });

  final DlnaSsdpMessageType type;
  final Uri? location;
  final String? usn;
}

class DlnaDiscoveryInterface {
  const DlnaDiscoveryInterface({
    required this.candidate,
    this.networkInterface,
  });

  final LanAddressCandidate candidate;
  final NetworkInterface? networkInterface;
}

class DlnaDiscoveryException implements Exception {
  const DlnaDiscoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _DlnaDiscoverySession {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

class DlnaDiscoveryService {
  DlnaDiscoveryService({
    DlnaDeviceDescriptionParser parser = const DlnaDeviceDescriptionParser(),
    DlnaDescriptionLoader? descriptionLoader,
    DlnaTargetAddressResolver? targetAddressResolver,
    DlnaLocalInterfaceResolver? localInterfaceResolver,
    DlnaLocalInterfacesResolver? localInterfacesResolver,
    DlnaSystemDiscovery? systemDiscovery,
    DlnaUnicastSearch? unicastSearch,
    DlnaDiscoveryLogger? logger,
  })  : _parser = parser,
        _descriptionLoader = descriptionLoader,
        _targetAddressResolver = targetAddressResolver ??
            WindowsUpnpDiscoveryBridge.resolveLocalAddress,
        _localInterfaceResolver =
            localInterfaceResolver ?? LanAddressResolver.detectIpv4Candidate,
        _localInterfacesResolver = localInterfacesResolver ??
            (localInterfaceResolver == null
                ? _detectDiscoveryInterfaces
                : () async {
                    final candidate = await localInterfaceResolver();
                    return candidate == null
                        ? const []
                        : [DlnaDiscoveryInterface(candidate: candidate)];
                  }),
        _systemDiscovery = systemDiscovery ?? WindowsUpnpDiscoveryBridge(),
        _unicastSearch = unicastSearch ?? _searchUnicast,
        _logger = logger ?? _defaultLog;

  static final InternetAddress _multicastAddress =
      InternetAddress('239.255.255.250');
  static const int _ssdpPort = 1900;
  static const Duration defaultResponseWindow = Duration(seconds: 40);
  static const List<String> _searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'ssdp:all',
  ];

  static const String multicastSource = 'ssdp-multicast';
  static const String notifySource = 'ssdp-notify';
  static const String windowsUpnpSource = 'windows-upnp';
  static const String unicastSource = 'ssdp-unicast';
  static const String manualUrlSource = 'manual-url';

  final DlnaDeviceDescriptionParser _parser;
  final DlnaDescriptionLoader? _descriptionLoader;
  final DlnaTargetAddressResolver _targetAddressResolver;
  final DlnaLocalInterfaceResolver _localInterfaceResolver;
  final DlnaLocalInterfacesResolver _localInterfacesResolver;
  final DlnaSystemDiscovery _systemDiscovery;
  final DlnaUnicastSearch _unicastSearch;
  final DlnaDiscoveryLogger _logger;
  _DlnaDiscoverySession? _activeDiscovery;

  Future<List<DlnaDevice>> discover({
    Duration responseWindow = defaultResponseWindow,
    DlnaDeviceDiscovered? onDevice,
    DlnaDeviceRemoved? onDeviceRemoved,
  }) async {
    if (responseWindow <= Duration.zero) {
      throw ArgumentError.value(
        responseWindow,
        'responseWindow',
        'must be positive',
      );
    }

    cancelDiscovery();
    final session = _DlnaDiscoverySession();
    _activeDiscovery = session;
    final subscriptions = <StreamSubscription<RawSocketEvent>>[];
    final sockets = <RawDatagramSocket>[];
    final searchChannels = <({
      RawDatagramSocket socket,
      DlnaDiscoveryInterface discoveryInterface,
    })>[];
    final devices = <DlnaDevice>[];
    final acceptedKeys = <String>{};
    final departedUdns = <String>{};
    final pendingLoads = <String, Future<void>>{};
    var systemDiscoveryStarted = false;

    late final List<DlnaDiscoveryInterface> discoveryInterfaces;

    void publishDevice(DlnaDevice device) {
      final merged = deduplicateDevices([...devices, device]);
      devices
        ..clear()
        ..addAll(merged);
      onDevice?.call(device);
    }

    void handleByebye(String? usn) {
      final canonical = _canonicalUdn(usn ?? '');
      if (canonical.isEmpty) return;
      departedUdns.add(canonical);
      final removedLocations = devices
          .where((device) => _canonicalUdn(device.udn) == canonical)
          .map((device) => _locationKey(device.location))
          .toList(growable: false);
      devices.removeWhere(
        (device) => _canonicalUdn(device.udn) == canonical,
      );
      acceptedKeys.remove('usn:$canonical');
      for (final location in removedLocations) {
        acceptedKeys.remove('location:$location');
      }
      onDeviceRemoved?.call(usn!);
    }

    void handleMessage(
      DlnaSsdpMessage message, {
      required String source,
      DlnaDiscoveryInterface? preferredInterface,
    }) {
      if (message.type == DlnaSsdpMessageType.byebye) {
        handleByebye(message.usn);
        return;
      }
      final location = message.location;
      if (location == null || session.isCancelled) return;
      final canonicalUsn = _canonicalUdn(message.usn ?? '');
      if (canonicalUsn.isNotEmpty) departedUdns.remove(canonicalUsn);
      final key = canonicalUsn.isNotEmpty
          ? 'usn:$canonicalUsn'
          : 'location:${_locationKey(location)}';
      if (acceptedKeys.contains(key) || pendingLoads.containsKey(key)) return;

      late final Future<void> load;
      load = _loadDeviceAcrossInterfaces(
        location: location,
        usn: message.usn,
        source: source,
        interfaces: discoveryInterfaces,
        preferredInterface: preferredInterface,
      ).then((device) {
        if (session.isCancelled ||
            (canonicalUsn.isNotEmpty && departedUdns.contains(canonicalUsn))) {
          return;
        }
        acceptedKeys.add(key);
        publishDevice(device);
      }).catchError((Object _) {
        // ssdp:all commonly returns non-renderers and stale descriptions.
      }).whenComplete(() {
        pendingLoads.remove(key);
      });
      pendingLoads[key] = load;
    }

    try {
      discoveryInterfaces = await _requireDiscoveryInterfaces();
      if (session.isCancelled) {
        _activeDiscovery = null;
        return const [];
      }

      try {
        systemDiscoveryStarted = await _systemDiscovery.start(
          onDeviceAdded: (location, usn) {
            handleMessage(
              DlnaSsdpMessage(
                type: DlnaSsdpMessageType.alive,
                location: location,
                usn: usn,
              ),
              source: windowsUpnpSource,
            );
          },
          onDeviceRemoved: handleByebye,
        );
        if (!systemDiscoveryStarted) {
          _logger(
            '[dlna-discovery] Windows UPnP listener unavailable; '
            'using direct UDP fallback',
          );
        }
      } catch (error) {
        _logger(
            '[dlna-discovery] Windows UPnP listener unavailable error=$error');
      }

      // Multicast can be shared with the system SSDP service. Reusing UDP 1900
      // does not guarantee a copy of directed unicast: Windows may deliver it
      // only to SSDPSRV, whose device finder may not surface that advertisement.
      try {
        final notifySocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          _ssdpPort,
          reuseAddress: true,
        );
        sockets.add(notifySocket);
        // Winsock applies this option to reception: local UPnP publishers
        // (such as ChunK Helper) must be allowed to reach this listener.
        // This socket exists only for this refresh session; finally closes it.
        // Our own M-SEARCH packets are ignored by the NOTIFY parser below.
        notifySocket.multicastLoopback = true;
        for (final discoveryInterface in discoveryInterfaces) {
          try {
            notifySocket.joinMulticast(
              _multicastAddress,
              discoveryInterface.networkInterface,
            );
          } catch (error) {
            _logger(
              '[dlna-discovery] multicast join failed '
              'interface=${jsonEncode(discoveryInterface.candidate.interfaceName)} '
              'address=${jsonEncode(discoveryInterface.candidate.address)} '
              'error=$error',
            );
          }
        }
        subscriptions.add(
          notifySocket.listen((event) {
            if (event != RawSocketEvent.read) return;
            Datagram? datagram;
            while ((datagram = notifySocket.receive()) != null) {
              final message = _parseSsdpDatagram(datagram!);
              if (message == null ||
                  message.type == DlnaSsdpMessageType.searchResponse) {
                continue;
              }
              handleMessage(message, source: notifySource);
            }
          }),
        );
      } catch (error) {
        _logger(
            '[dlna-discovery] direct UDP 1900 listener unavailable error=$error');
      }

      for (final discoveryInterface in discoveryInterfaces) {
        try {
          final socket = await RawDatagramSocket.bind(
            InternetAddress(discoveryInterface.candidate.address),
            0,
            reuseAddress: true,
          );
          socket.multicastHops = 4;
          sockets.add(socket);
          searchChannels.add((
            socket: socket,
            discoveryInterface: discoveryInterface,
          ));
          subscriptions.add(
            socket.listen((event) {
              if (event != RawSocketEvent.read) return;
              Datagram? datagram;
              while ((datagram = socket.receive()) != null) {
                final message = _parseSsdpDatagram(datagram!);
                if (message == null ||
                    message.type != DlnaSsdpMessageType.searchResponse) {
                  continue;
                }
                handleMessage(
                  message,
                  source: multicastSource,
                  preferredInterface: discoveryInterface,
                );
              }
            }),
          );
        } catch (error) {
          _logger(
            '[dlna-discovery] M-SEARCH socket unavailable '
            'interface=${jsonEncode(discoveryInterface.candidate.interfaceName)} '
            'address=${jsonEncode(discoveryInterface.candidate.address)} '
            'error=$error',
          );
        }
      }

      if (searchChannels.isEmpty && !systemDiscoveryStarted) {
        throw const DlnaDiscoveryException('无法打开 DLNA SSDP 网络端口');
      }

      for (var pass = 0; pass < 2; pass++) {
        for (final target in _searchTargets) {
          final request = ascii.encode(buildSearchRequest(target));
          for (final channel in searchChannels) {
            try {
              channel.socket.send(
                request,
                _multicastAddress,
                _ssdpPort,
              );
            } catch (error) {
              _logger(
                '[dlna-discovery] M-SEARCH send failed '
                'address=${jsonEncode(channel.discoveryInterface.candidate.address)} '
                'error=$error',
              );
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (session.isCancelled) break;
        }
        if (session.isCancelled) break;
      }
      if (!session.isCancelled) {
        await Future.any<void>([
          Future<void>.delayed(responseWindow),
          session.cancelled,
        ]);
      }
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      for (final socket in sockets) {
        socket.close();
      }
      await _systemDiscovery.stop();
      if (identical(_activeDiscovery, session)) _activeDiscovery = null;
    }

    if (!session.isCancelled && pendingLoads.isNotEmpty) {
      await Future.wait(pendingLoads.values.toList(growable: false));
    }
    return deduplicateDevices(devices);
  }

  void cancelDiscovery() {
    _activeDiscovery?.cancel();
  }

  /// Resolves an explicitly supplied renderer URL or IPv4 address.
  ///
  /// A URL is fetched directly. A bare IPv4 address receives a bounded,
  /// directed M-SEARCH; if the renderer does not answer, callers should ask
  /// for its complete description URL instead of scanning arbitrary ports.
  Future<DlnaDevice> resolveManualRenderer(
    String input, {
    Duration responseWindow = const Duration(milliseconds: 1800),
  }) async {
    final value = input.trim();
    if (value.isEmpty) {
      throw const DlnaDiscoveryException('请输入 Renderer IP 或完整 description URL');
    }
    final localInterface = await _requireLocalInterface();

    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) {
      try {
        DlnaHttpClient.validateLanUri(uri);
        return await _loadDevice(
          location: uri,
          localInterface: localInterface,
          source: manualUrlSource,
        );
      } catch (error) {
        throw DlnaDiscoveryException('无法添加该 DLNA description URL：$error');
      }
    }

    final targetAddress = InternetAddress.tryParse(value);
    if (targetAddress == null ||
        targetAddress.type != InternetAddressType.IPv4) {
      throw const DlnaDiscoveryException(
        '格式无效：请输入 IPv4 地址，或以 http:// 开头的完整 description URL',
      );
    }
    try {
      DlnaHttpClient.validateLanUri(
          Uri.parse('http://${targetAddress.address}/'));
    } catch (error) {
      throw DlnaDiscoveryException('Renderer IP 无效：$error');
    }

    final responses = await _unicastSearch(
      targetAddress,
      localInterface.address,
      responseWindow,
    );
    Object? lastError;
    for (final response in responses) {
      try {
        DlnaHttpClient.validateLanUri(response.location);
        return await _loadDevice(
          location: response.location,
          usn: response.usn,
          localInterface: localInterface,
          source: unicastSource,
        );
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) {
      throw DlnaDiscoveryException(
        'Renderer 响应了定向 SSDP，但 description 无法解析：$lastError',
      );
    }
    throw DlnaDiscoveryException(
      'Renderer 未响应定向 SSDP；请改为输入完整 description URL，例如 '
      'http://${targetAddress.address}:端口/description.xml',
    );
  }

  static List<DlnaDevice> deduplicateDevices(Iterable<DlnaDevice> devices) {
    final result = <DlnaDevice>[];
    for (final device in devices) {
      final existing = result.indexWhere(
        (candidate) => _sameRenderer(candidate, device),
      );
      if (existing < 0) {
        result.add(device);
      } else {
        // Later entries win. CastService appends explicit devices after
        // multicast results so a verified manual route remains usable.
        result[existing] = device;
      }
    }
    result.sort(
      (left, right) => left.friendlyName.toLowerCase().compareTo(
            right.friendlyName.toLowerCase(),
          ),
    );
    return result;
  }

  static String buildSearchRequest(
    String searchTarget, {
    String host = '239.255.255.250:1900',
  }) {
    return 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $host\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $searchTarget\r\n'
        'USER-AGENT: Windows/10 UPnP/1.1 Kirakara/0.1\r\n'
        '\r\n';
  }

  static Map<String, String> parseResponseHeaders(String packet) {
    final lines = const LineSplitter().convert(packet);
    if (lines.isEmpty || !lines.first.toUpperCase().contains('200 OK')) {
      return const {};
    }
    return _parseHeaderLines(lines.skip(1));
  }

  static DlnaSsdpMessage? parseSsdpMessage(String packet) {
    final lines = const LineSplitter().convert(packet);
    if (lines.isEmpty) return null;
    final startLine = lines.first.trim().toUpperCase();
    final headers = _parseHeaderLines(lines.skip(1));

    late final DlnaSsdpMessageType type;
    if (startLine.contains('200 OK')) {
      type = DlnaSsdpMessageType.searchResponse;
    } else if (startLine == 'NOTIFY * HTTP/1.1') {
      switch (headers['nts']?.toLowerCase()) {
        case 'ssdp:alive':
          type = DlnaSsdpMessageType.alive;
        case 'ssdp:update':
          type = DlnaSsdpMessageType.update;
        case 'ssdp:byebye':
          type = DlnaSsdpMessageType.byebye;
        default:
          return null;
      }
    } else {
      return null;
    }

    final usnText = headers['usn']?.trim();
    if (type == DlnaSsdpMessageType.byebye) {
      return DlnaSsdpMessage(
        type: type,
        usn: usnText == null || usnText.isEmpty ? null : usnText,
      );
    }

    final locationText = headers['location']?.trim();
    if (locationText == null || locationText.isEmpty) return null;
    final location = Uri.tryParse(locationText);
    if (location == null) return null;
    try {
      DlnaHttpClient.validateLanUri(location);
    } catch (_) {
      return null;
    }
    return DlnaSsdpMessage(
      type: type,
      location: location,
      usn: usnText == null || usnText.isEmpty ? null : usnText,
    );
  }

  static Map<String, String> _parseHeaderLines(Iterable<String> lines) {
    final headers = <String, String>{};
    for (final line in lines) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final name = line.substring(0, separator).trim().toLowerCase();
      final value = line.substring(separator + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) headers[name] = value;
    }
    return headers;
  }

  Future<LanAddressCandidate> _requireLocalInterface() async {
    final localInterface = await _localInterfaceResolver();
    if (localInterface == null) {
      throw const DlnaDiscoveryException(
        '未找到可用的实体局域网 IPv4，请检查 Wi-Fi 或网线连接',
      );
    }
    return localInterface;
  }

  Future<List<DlnaDiscoveryInterface>> _requireDiscoveryInterfaces() async {
    final interfaces = await _localInterfacesResolver();
    if (interfaces.isEmpty) {
      throw const DlnaDiscoveryException(
        '未找到可用的实体局域网 IPv4，请检查 Wi-Fi 或网线连接',
      );
    }
    return interfaces;
  }

  Future<DlnaDevice> _loadDevice({
    required Uri location,
    required LanAddressCandidate localInterface,
    required String source,
    String? usn,
  }) async {
    final loader = _descriptionLoader;
    final String description;
    var sourceInterface = localInterface;
    if (loader != null) {
      description = await loader(location, localInterface.address);
    } else {
      // Discovery's preferred LAN interface need not carry the route to this
      // LOCATION. Ask Windows for its source address instead of binding HTTP
      // and the advertised stream URL to an unrelated physical adapter.
      final address = await _targetAddressResolver(location);
      if (address != null && address != localInterface.address) {
        sourceInterface = await _interfaceForAddress(address);
      }
      description = await DlnaHttpClient.getText(
        location,
        localAddress: sourceInterface.address,
      );
    }
    final device = _parser.parse(
      description,
      location: location,
      localAddress: sourceInterface.address,
      usn: usn,
    );
    _logDevice(device, source: source, localInterface: sourceInterface);
    return device;
  }

  Future<DlnaDevice> _loadDeviceAcrossInterfaces({
    required Uri location,
    required String source,
    required List<DlnaDiscoveryInterface> interfaces,
    DlnaDiscoveryInterface? preferredInterface,
    String? usn,
  }) async {
    final ordered = <DlnaDiscoveryInterface>[
      if (preferredInterface != null) preferredInterface,
      ...interfaces,
    ];
    final triedAddresses = <String>{};
    Object? lastError;
    for (final discoveryInterface in ordered) {
      final localInterface = discoveryInterface.candidate;
      if (!triedAddresses.add(localInterface.address)) continue;
      try {
        return await _loadDevice(
          location: location,
          localInterface: localInterface,
          source: source,
          usn: usn,
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? DlnaDiscoveryException('无法通过可用局域网接口访问 $location');
  }

  void _logDevice(
    DlnaDevice device, {
    required String source,
    required LanAddressCandidate localInterface,
  }) {
    final discoverySource = switch (source) {
      multicastSource ||
      notifySource ||
      windowsUpnpSource ||
      unicastSource =>
        'ssdp',
      _ => source,
    };
    _logger(
      '[dlna-discovery] discoverySource=$discoverySource source=$source '
      'sourceInterface=${jsonEncode('${localInterface.interfaceName} (${localInterface.address})')} '
      'rendererIP=${jsonEncode(device.location.host)} '
      'descriptionURL=${jsonEncode(device.location.toString())} '
      'friendlyName=${jsonEncode(device.friendlyName)} '
      'UDN=${jsonEncode(device.udn)} '
      'manufacturer=${jsonEncode(device.manufacturer)} '
      'modelName=${jsonEncode(device.modelName)} '
      'avTransport=${jsonEncode(device.avTransport.controlUrl.toString())}',
    );
  }

  static bool _sameRenderer(DlnaDevice left, DlnaDevice right) {
    final leftUdn = _canonicalUdn(left.udn);
    final rightUdn = _canonicalUdn(right.udn);
    if (leftUdn.isNotEmpty && rightUdn.isNotEmpty) {
      return leftUdn == rightUdn;
    }
    if (_locationKey(left.location) == _locationKey(right.location)) {
      return true;
    }
    return left.location.host.toLowerCase() ==
        right.location.host.toLowerCase();
  }

  static String _canonicalUdn(String value) =>
      value.trim().split('::').first.toLowerCase();

  static String _locationKey(Uri uri) {
    final normalized = uri.normalizePath();
    final port = normalized.hasPort ? normalized.port : 80;
    final path = normalized.path.isEmpty ? '/' : normalized.path;
    final query = normalized.hasQuery ? '?${normalized.query}' : '';
    return '${normalized.scheme.toLowerCase()}://'
        '${normalized.host.toLowerCase()}:$port$path$query';
  }

  static DlnaSsdpResponse? _parseDatagram(Datagram datagram) {
    final message = _parseSsdpDatagram(datagram);
    if (message == null ||
        message.type != DlnaSsdpMessageType.searchResponse ||
        message.location == null) {
      return null;
    }
    return DlnaSsdpResponse(
      location: message.location!,
      usn: message.usn,
    );
  }

  static DlnaSsdpMessage? _parseSsdpDatagram(Datagram datagram) {
    return parseSsdpMessage(
      ascii.decode(datagram.data, allowInvalid: true),
    );
  }

  static Future<List<DlnaDiscoveryInterface>>
      _detectDiscoveryInterfaces() async {
    try {
      final networkInterfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final candidates = <LanAddressCandidate>[];
      final interfaceByCandidate = <String, NetworkInterface>{};
      for (final networkInterface in networkInterfaces) {
        for (final address in networkInterface.addresses) {
          final candidate = LanAddressCandidate(
            interfaceName: networkInterface.name,
            address: address.address,
          );
          candidates.add(candidate);
          interfaceByCandidate[
                  '${candidate.interfaceName}\u0000${candidate.address}'] =
              networkInterface;
        }
      }
      return LanAddressResolver.selectIpv4Candidates(candidates)
          .map(
            (candidate) => DlnaDiscoveryInterface(
              candidate: candidate,
              networkInterface: interfaceByCandidate[
                  '${candidate.interfaceName}\u0000${candidate.address}'],
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<List<DlnaSsdpResponse>> _searchUnicast(
    InternetAddress targetAddress,
    String localAddress,
    Duration responseWindow,
  ) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress(localAddress),
      0,
      reuseAddress: true,
    );
    final responses = <Uri, DlnaSsdpResponse>{};
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        if (datagram!.address.address != targetAddress.address) continue;
        final response = _parseDatagram(datagram);
        if (response != null) responses[response.location] = response;
      }
    });
    try {
      for (final target in _searchTargets) {
        socket.send(
          ascii.encode(
            buildSearchRequest(
              target,
              host: '${targetAddress.address}:$_ssdpPort',
            ),
          ),
          targetAddress,
          _ssdpPort,
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      await Future<void>.delayed(responseWindow);
    } finally {
      await subscription.cancel();
      socket.close();
    }
    return responses.values.toList();
  }

  static Future<LanAddressCandidate> _interfaceForAddress(
      String address) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final networkInterface in interfaces) {
        if (networkInterface.addresses.any((item) => item.address == address)) {
          return LanAddressCandidate(
            interfaceName: networkInterface.name,
            address: address,
          );
        }
      }
    } catch (_) {
      // Route selection does not depend on adapter display names.
    }
    return LanAddressCandidate(interfaceName: 'OS route', address: address);
  }

  static void _defaultLog(String message) =>
      developer.log(message, name: 'kirakara.dlna');
}
