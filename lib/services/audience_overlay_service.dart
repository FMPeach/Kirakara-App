import 'dart:async';
import 'package:flutter/foundation.dart';

import '../domain/audience_overlay_options.dart';

import 'audience_hud_ffi.dart';
import 'lan_server.dart';
import 'settings_service.dart';
import 'queue_service.dart';

/// Event-driven publication, independent of the media position poller.
class AudienceOverlayService {
  AudienceOverlayService(
      {required this.settings,
      required this.lan,
      required this.sink,
      required this.queue}) {
    settings.addListener(_sync);
    lan.qrImages.addListener(_sync);
    queue.addListener(_sync);
    sink?.onLanChanged = _networkChanged;
    _sync();
  }
  final SettingsService settings;
  final LanServer lan;
  final AudienceHudSink? sink;
  final QueueService queue;
  AudienceOverlayOptions? _lastOptions;
  String? _lastNetwork;
  List<AudienceQueueEntry>? _lastQueue;
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
    final entries = queue.items
        .where((item) => !queue.isFailed(item.id))
        .take(4)
        .map((item) =>
            (title: item.song.title, artist: item.song.artist?.name ?? ''))
        .toList(growable: false);
    if (_lastOptions == options &&
        _lastNetwork == network &&
        listEquals(_lastQueue, entries)) {
      return;
    }
    _lastOptions = options;
    _lastNetwork = network;
    _lastQueue = entries;
    sink?.setState(options, network, entries);
  }

  void dispose() {
    _disposed = true;
    settings.removeListener(_sync);
    lan.qrImages.removeListener(_sync);
    queue.removeListener(_sync);
    sink?.onLanChanged = null;
  }
}
