import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../lan_address_resolver.dart';
import 'dlna_device.dart';
import 'dlna_device_description_parser.dart';
import 'dlna_http_client.dart';

typedef DlnaDescriptionLoader = Future<String> Function(
  Uri location,
  String localAddress,
);
typedef DlnaLocalInterfaceResolver = Future<LanAddressCandidate?> Function();
typedef DlnaDiscoveryLogger = void Function(String message);
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

class DlnaDiscoveryException implements Exception {
  const DlnaDiscoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DlnaDiscoveryService {
  DlnaDiscoveryService({
    DlnaDeviceDescriptionParser parser = const DlnaDeviceDescriptionParser(),
    DlnaDescriptionLoader? descriptionLoader,
    DlnaLocalInterfaceResolver? localInterfaceResolver,
    DlnaUnicastSearch? unicastSearch,
    DlnaDiscoveryLogger? logger,
  })  : _parser = parser,
        _descriptionLoader = descriptionLoader ?? _loadDescription,
        _localInterfaceResolver =
            localInterfaceResolver ?? LanAddressResolver.detectIpv4Candidate,
        _unicastSearch = unicastSearch ?? _searchUnicast,
        _logger = logger ?? _defaultLog;

  static final InternetAddress _multicastAddress =
      InternetAddress('239.255.255.250');
  static const int _ssdpPort = 1900;
  static const List<String> _searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'ssdp:all',
  ];

  static const String multicastSource = 'ssdp-multicast';
  static const String unicastSource = 'ssdp-unicast';
  static const String manualUrlSource = 'manual-url';

  final DlnaDeviceDescriptionParser _parser;
  final DlnaDescriptionLoader _descriptionLoader;
  final DlnaLocalInterfaceResolver _localInterfaceResolver;
  final DlnaUnicastSearch _unicastSearch;
  final DlnaDiscoveryLogger _logger;

  Future<List<DlnaDevice>> discover({
    Duration responseWindow = const Duration(milliseconds: 2600),
  }) async {
    final localInterface = await _requireLocalInterface();
    final socket = await RawDatagramSocket.bind(
      InternetAddress(localInterface.address),
      0,
      reuseAddress: true,
    );
    socket.multicastHops = 4;
    final responses = <Uri, String?>{};
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final response = _parseDatagram(datagram!);
        if (response == null) continue;
        responses.putIfAbsent(response.location, () => response.usn);
      }
    });

    try {
      for (var pass = 0; pass < 2; pass++) {
        for (final target in _searchTargets) {
          socket.send(
            ascii.encode(buildSearchRequest(target)),
            _multicastAddress,
            _ssdpPort,
          );
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }
      await Future<void>.delayed(responseWindow);
    } finally {
      await subscription.cancel();
      socket.close();
    }

    final devices = <DlnaDevice>[];
    await Future.wait(
      responses.entries.map((entry) async {
        try {
          final device = await _loadDevice(
            location: entry.key,
            usn: entry.value,
            localInterface: localInterface,
            source: multicastSource,
          );
          devices.add(device);
        } catch (_) {
          // SSDP commonly returns routers and media servers for ssdp:all.
        }
      }),
    );
    return deduplicateDevices(devices);
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
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
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

  Future<DlnaDevice> _loadDevice({
    required Uri location,
    required LanAddressCandidate localInterface,
    required String source,
    String? usn,
  }) async {
    final description = await _descriptionLoader(
      location,
      localInterface.address,
    );
    final device = _parser.parse(
      description,
      location: location,
      localAddress: localInterface.address,
      usn: usn,
    );
    _logDevice(device, source: source, localInterface: localInterface);
    return device;
  }

  void _logDevice(
    DlnaDevice device, {
    required String source,
    required LanAddressCandidate localInterface,
  }) {
    final discoverySource = switch (source) {
      multicastSource || unicastSource => 'ssdp',
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
    final packet = ascii.decode(datagram.data, allowInvalid: true);
    final headers = parseResponseHeaders(packet);
    final locationText = headers['location'];
    if (locationText == null) return null;
    final location = Uri.tryParse(locationText.trim());
    if (location == null) return null;
    try {
      DlnaHttpClient.validateLanUri(location);
    } catch (_) {
      return null;
    }
    return DlnaSsdpResponse(location: location, usn: headers['usn']);
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

  static Future<String> _loadDescription(
    Uri location,
    String localAddress,
  ) {
    return DlnaHttpClient.getText(
      location,
      localAddress: localAddress,
    );
  }

  static void _defaultLog(String message) =>
      developer.log(message, name: 'kirakara.dlna');
}
