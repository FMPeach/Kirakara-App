import 'dart:async';

import 'audience_hud_ffi.dart';
import 'lan_server.dart';
import 'settings_service.dart';

/// Event-driven publication, independent of the media position poller.
class AudienceOverlayService {
  AudienceOverlayService(
      {required this.settings, required this.lan, required this.sink}) {
    settings.addListener(_sync);
    lan.qrImages.addListener(_sync);
    sink?.onLanChanged = _networkChanged;
    _sync();
  }
  final SettingsService settings;
  final LanServer lan;
  final AudienceHudSink? sink;
  String? _lastState;
  bool _disposed = false;
  void _networkChanged() {
    if (!_disposed) unawaited(lan.refreshAddress());
  }

  void _sync() {
    if (_disposed) return;
    final qr = lan.qrImages.image;
    sink?.setImage(qr);
    final options = settings.audienceOverlay;
    final network = lan.qrImages.endpoint?.authority ?? '';
    final identity =
        '${options.qrEnabled}/${options.queueEnabled}/${options.announcementEnabled}/$network';
    if (_lastState == identity) return;
    _lastState = identity;
    sink?.setState(options, network, const []);
  }

  void dispose() {
    _disposed = true;
    settings.removeListener(_sync);
    lan.qrImages.removeListener(_sync);
    sink?.onLanChanged = null;
  }
}
