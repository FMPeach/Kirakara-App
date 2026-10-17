import 'dart:io';

import 'package:flutter/services.dart';

typedef DlnaSystemDeviceAdded = void Function(Uri location, String? usn);
typedef DlnaSystemDeviceRemoved = void Function(String usn);

abstract interface class DlnaSystemDiscovery {
  Future<bool> start({
    required DlnaSystemDeviceAdded onDeviceAdded,
    required DlnaSystemDeviceRemoved onDeviceRemoved,
  });

  Future<void> stop();
}

/// Receives UPnP device events from Windows' own SSDP service.
///
/// Windows normally owns UDP 1900 through SSDPSRV. A second Dart socket may
/// bind successfully with SO_REUSEADDR but is not guaranteed to receive a
/// directed NOTIFY. The native runner therefore subscribes to the system UPnP
/// device finder and forwards only the description URL and UDN. Description
/// loading and MediaRenderer validation stay in the shared Dart code.
class WindowsUpnpDiscoveryBridge implements DlnaSystemDiscovery {
  WindowsUpnpDiscoveryBridge({
    MethodChannel channel = const MethodChannel('kirakara/dlna_discovery'),
  }) : _channel = channel;

  final MethodChannel _channel;
  DlnaSystemDeviceAdded? _onDeviceAdded;
  DlnaSystemDeviceRemoved? _onDeviceRemoved;
  bool _active = false;

  static Future<String?> resolveLocalAddress(Uri location) async {
    if (!Platform.isWindows) return null;
    try {
      return await const MethodChannel('kirakara/dlna_discovery')
          .invokeMethod<String>('resolveLocalAddress', {'host': location.host});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> start({
    required DlnaSystemDeviceAdded onDeviceAdded,
    required DlnaSystemDeviceRemoved onDeviceRemoved,
  }) async {
    if (!Platform.isWindows) return false;
    await stop();
    _onDeviceAdded = onDeviceAdded;
    _onDeviceRemoved = onDeviceRemoved;
    _active = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    try {
      final started =
          await _channel.invokeMethod<bool>('startDiscovery') ?? false;
      if (!started) {
        _active = false;
        _onDeviceAdded = null;
        _onDeviceRemoved = null;
      }
      return started;
    } on MissingPluginException {
      _active = false;
      _onDeviceAdded = null;
      _onDeviceRemoved = null;
      return false;
    } on PlatformException {
      _active = false;
      _onDeviceAdded = null;
      _onDeviceRemoved = null;
      return false;
    }
  }

  @override
  Future<void> stop() async {
    final wasActive = _active;
    _active = false;
    _onDeviceAdded = null;
    _onDeviceRemoved = null;
    if (!Platform.isWindows || !wasActive) return;
    try {
      await _channel.invokeMethod<void>('stopDiscovery');
    } on MissingPluginException {
      // Unit tests and non-Windows embedders do not register the native bridge.
    } on PlatformException {
      // Discovery is best effort; the Dart sockets remain available.
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (!_active) return;
    final arguments = call.arguments;
    if (arguments is! Map) return;

    switch (call.method) {
      case 'onDeviceAdded':
        final locationText = arguments['location'];
        if (locationText is! String) return;
        final location = Uri.tryParse(locationText);
        if (location == null) return;
        final usnValue = arguments['usn'];
        _onDeviceAdded?.call(
          location,
          usnValue is String && usnValue.trim().isNotEmpty ? usnValue : null,
        );
      case 'onDeviceRemoved':
        final usn = arguments['usn'];
        if (usn is String && usn.trim().isNotEmpty) {
          _onDeviceRemoved?.call(usn);
        }
    }
  }
}
