import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'dlna/dlna_control_point.dart';
import 'dlna/dlna_device.dart';
import 'dlna/dlna_discovery_service.dart';
import 'kirakara_show_service.dart';
import 'lan_address_resolver.dart';

enum CastState {
  idle,
  searching,
  casting,
}

class CastService extends ChangeNotifier {
  CastService({
    DlnaDiscoveryService? discoveryService,
    DlnaControlPoint? controlPoint,
    Duration receiverMonitorInterval = const Duration(seconds: 2),
    int receiverFailureThreshold = 3,
    int receiverStoppedThreshold = 2,
  })  : _discoveryService = discoveryService ??
            DlnaDiscoveryService(logger: (message) => debugPrint(message)),
        _controlPoint = controlPoint ?? const DlnaControlPoint(),
        _receiverMonitorInterval = receiverMonitorInterval,
        _receiverFailureThreshold = receiverFailureThreshold,
        _receiverStoppedThreshold = receiverStoppedThreshold {
    assert(receiverMonitorInterval > Duration.zero);
    assert(receiverFailureThreshold > 0);
    assert(receiverStoppedThreshold > 0);
  }

  final DlnaDiscoveryService _discoveryService;
  final DlnaControlPoint _controlPoint;
  final Duration _receiverMonitorInterval;
  final int _receiverFailureThreshold;
  final int _receiverStoppedThreshold;

  bool _isEnabled = false;
  bool _isDiscovering = false;
  CastState _state = CastState.idle;
  List<DlnaDevice> _devices = const [];
  List<DlnaDevice> _manualDevices = const [];
  DlnaDevice? _activeDevice;
  String? _targetName;
  KirakaraShowService? _activeShowService;
  String? _mpegTsUrl;
  String? _lastError;
  int _discoveryGeneration = 0;
  int _sessionGeneration = 0;
  Timer? _receiverMonitor;
  bool _receiverPollInFlight = false;
  int _receiverPollFailures = 0;
  int _receiverStoppedPolls = 0;

  bool get isEnabled => _isEnabled;
  bool get isDiscovering => _isDiscovering;
  CastState get state => _state;
  List<DlnaDevice> get devices => List.unmodifiable(_devices);
  DlnaDevice? get activeDevice => _activeDevice;
  String? get targetName => _targetName;
  bool get isCasting => _state == CastState.casting;
  String? get mpegTsUrl => _mpegTsUrl;
  String? get lastError => _lastError;

  Future<void> enableCastMode({bool includePureK = false}) async {
    if (!_isEnabled) {
      _isEnabled = true;
      _lastError = null;
      _devices = DlnaDiscoveryService.deduplicateDevices(_manualDevices);
      notifyListeners();
    }
    await refreshDevices(includePureK: includePureK);
  }

  Future<void> disableCastMode({
    KirakaraShowService? showService,
  }) async {
    _isEnabled = false;
    _discoveryGeneration++;
    _isDiscovering = false;
    await stopCast(showService: showService);
    _devices = const [];
    notifyListeners();
  }

  Future<void> refreshDevices({bool includePureK = false}) async {
    if (!_isEnabled || _isDiscovering) return;
    final generation = ++_discoveryGeneration;
    _isDiscovering = true;
    _lastError = null;
    notifyListeners();
    final ssdpDevices = <DlnaDevice>[];
    final pureKDevices = <DlnaDevice>[];
    final errors = <Object>[];

    Future<void> discoverSsdp() async {
      try {
        ssdpDevices.addAll(await _discoveryService.discover());
      } catch (error) {
        errors.add(error);
        debugPrint('DLNA SSDP discovery failed: $error');
      }
    }

    Future<void> discoverPureK() async {
      try {
        pureKDevices.addAll(
          await _discoveryService.discoverPureKRenderers(),
        );
      } catch (error) {
        errors.add(error);
        debugPrint('Pure K HTTP discovery failed: $error');
      }
    }

    try {
      await Future.wait([
        discoverSsdp(),
        if (includePureK) discoverPureK(),
      ]);
      if (!_isEnabled || generation != _discoveryGeneration) return;
      _devices = DlnaDiscoveryService.deduplicateDevices([
        ...ssdpDevices,
        ...pureKDevices,
        ..._manualDevices,
      ]);
      final requestedSources = includePureK ? 2 : 1;
      if (errors.length == requestedSources) {
        _lastError = errors.map((error) => error.toString()).join('\n');
      }
    } finally {
      if (_isEnabled && generation == _discoveryGeneration) {
        _isDiscovering = false;
        notifyListeners();
      }
    }
  }

  Future<DlnaDevice> addManualRenderer(String address) async {
    _isEnabled = true;
    _lastError = null;
    notifyListeners();
    try {
      final device = await _discoveryService.resolveManualRenderer(address);
      _manualDevices = DlnaDiscoveryService.deduplicateDevices([
        ..._manualDevices,
        device,
      ]);
      _devices = DlnaDiscoveryService.deduplicateDevices([
        ..._devices,
        ..._manualDevices,
      ]);
      notifyListeners();
      return device;
    } catch (error) {
      _lastError = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> connectToDevice(
    DlnaDevice device,
    KirakaraShowService showService,
  ) async {
    if (_state == CastState.searching) return;
    if (_activeDevice?.id == device.id && isCasting) {
      await stopCast(showService: showService);
      return;
    }

    _isEnabled = true;
    await stopCast(showService: showService);
    final generation = ++_sessionGeneration;
    _activeDevice = device;
    _targetName = device.friendlyName;
    _mpegTsUrl = null;
    _lastError = null;
    _state = CastState.searching;
    notifyListeners();

    try {
      final startWatch = Stopwatch()..start();
      final streamUri = _startNativeStream(
        showService,
        localAddress: device.localAddress,
      );
      debugPrint('[cast-timing] startCastStream '
          '${startWatch.elapsedMilliseconds}ms');
      _activeShowService = showService;
      _mpegTsUrl = streamUri.toString();

      startWatch.reset();
      await _controlPoint.setTransportUriAndPlay(
        device,
        streamUri,
        title: 'Kira Karaoke',
      );
      debugPrint('[cast-timing] dlna setTransportUriAndPlay '
          '${startWatch.elapsedMilliseconds}ms');
      if (generation != _sessionGeneration) return;
      _state = CastState.casting;
      _startReceiverMonitor(device, generation);
      notifyListeners();
    } catch (error) {
      if (generation != _sessionGeneration) return;
      showService.stopCastStream();
      _activeShowService = null;
      _activeDevice = null;
      _targetName = null;
      _mpegTsUrl = null;
      _state = CastState.idle;
      _lastError = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// Keeps the existing raw stream test available for development tools.
  Future<void> startMpegTsDebugStream(
    KirakaraShowService showService,
  ) async {
    _isEnabled = true;
    await stopCast(showService: showService);
    _state = CastState.searching;
    _targetName = 'VLC 测试输出';
    _lastError = null;
    notifyListeners();
    try {
      final lanIp = await LanAddressResolver.detectIpv4();
      if (lanIp == null) {
        throw StateError('未找到可用的实体局域网 IPv4，请检查 Wi-Fi 或网线连接');
      }
      final streamUri = _startNativeStream(
        showService,
        localAddress: lanIp,
      );
      _activeShowService = showService;
      _mpegTsUrl = streamUri.toString();
      _state = CastState.casting;
      notifyListeners();
    } catch (error) {
      showService.stopCastStream();
      _activeShowService = null;
      _targetName = null;
      _mpegTsUrl = null;
      _state = CastState.idle;
      _lastError = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> stopCast({KirakaraShowService? showService}) async {
    _sessionGeneration++;
    _cancelReceiverMonitor();
    final stopWatch = Stopwatch()..start();
    final device = _activeDevice;
    if (device != null) {
      try {
        await _controlPoint.stop(device).timeout(const Duration(seconds: 3));
      } catch (_) {
        // The renderer may already be offline; local cleanup must still run.
      }
    }
    (showService ?? _activeShowService)?.stopCastStream();
    debugPrint('[cast-timing] stopCast ${stopWatch.elapsedMilliseconds}ms');
    _activeShowService = null;
    _activeDevice = null;
    _targetName = null;
    _mpegTsUrl = null;
    _lastError = null;
    _state = CastState.idle;
    notifyListeners();
  }

  Uri _startNativeStream(
    KirakaraShowService showService, {
    required String localAddress,
  }) {
    final started = showService.startCastStream(0);
    final port = started ? showService.castStreamPort : 0;
    if (!started || port == 0) {
      showService.stopCastStream();
      throw StateError('当前设备无法启动投屏编码或局域网输出服务');
    }
    return Uri.parse('http://$localAddress:$port/cast/stage.ts');
  }

  void _startReceiverMonitor(DlnaDevice device, int generation) {
    _cancelReceiverMonitor();
    _receiverPollFailures = 0;
    _receiverStoppedPolls = 0;
    _receiverMonitor = Timer.periodic(
      _receiverMonitorInterval,
      (_) => unawaited(_pollReceiver(device, generation)),
    );
  }

  Future<void> _pollReceiver(DlnaDevice device, int generation) async {
    if (_receiverPollInFlight ||
        generation != _sessionGeneration ||
        _state != CastState.casting ||
        _activeDevice?.id != device.id) {
      return;
    }
    _receiverPollInFlight = true;
    try {
      final transportState = await _controlPoint.getTransportState(device);
      if (generation != _sessionGeneration || _activeDevice?.id != device.id) {
        return;
      }
      _receiverPollFailures = 0;
      if (transportState == DlnaTransportState.stopped ||
          transportState == DlnaTransportState.noMedia) {
        _receiverStoppedPolls++;
        if (_receiverStoppedPolls >= _receiverStoppedThreshold) {
          _finishRemoteDisconnect(generation, '投屏设备已断开连接');
        }
      } else {
        _receiverStoppedPolls = 0;
      }
    } catch (error) {
      if (generation != _sessionGeneration || _activeDevice?.id != device.id) {
        return;
      }
      if (error is! SocketException &&
          error is! TimeoutException &&
          error is! HttpException) {
        // Some older renderers can play a URI but reject GetTransportInfo.
        // Disable monitoring instead of tearing down a working stream.
        _cancelReceiverMonitor();
        debugPrint('DLNA receiver monitoring is unavailable: $error');
        return;
      }
      _receiverStoppedPolls = 0;
      _receiverPollFailures++;
      if (_receiverPollFailures >= _receiverFailureThreshold) {
        _finishRemoteDisconnect(generation, '无法连接投屏设备，投屏已断开');
      }
    } finally {
      _receiverPollInFlight = false;
    }
  }

  void _finishRemoteDisconnect(int generation, String message) {
    if (generation != _sessionGeneration) return;
    _sessionGeneration++;
    _cancelReceiverMonitor();
    _activeShowService?.stopCastStream();
    _activeShowService = null;
    _activeDevice = null;
    _targetName = null;
    _mpegTsUrl = null;
    _state = CastState.idle;
    _lastError = message;
    notifyListeners();
  }

  void _cancelReceiverMonitor() {
    _receiverMonitor?.cancel();
    _receiverMonitor = null;
    _receiverPollFailures = 0;
    _receiverStoppedPolls = 0;
  }

  @override
  void dispose() {
    _discoveryGeneration++;
    _sessionGeneration++;
    _cancelReceiverMonitor();
    _activeShowService?.stopCastStream();
    _activeShowService = null;
    super.dispose();
  }
}
