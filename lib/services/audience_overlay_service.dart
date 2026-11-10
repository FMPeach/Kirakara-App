import 'dart:async';
import 'package:flutter/foundation.dart';

import '../domain/audience_overlay_options.dart';
import '../domain/queue_item.dart';

import 'audience_hud_ffi.dart';
import 'lan_server.dart';
import 'playback_service.dart';
import 'settings_service.dart';
import 'queue_service.dart';

/// Event-driven publication, independent of the media position poller.
class AudienceOverlayService {
  AudienceOverlayService(
      {required this.settings,
      required this.lan,
      required this.sink,
      required this.queue,
      required this.playback}) {
    settings.addListener(_sync);
    lan.qrImages.addListener(_sync);
    queue.addListener(_sync);
    playback.addListener(_onPlaybackChanged);
    sink?.onLanChanged = _networkChanged;
    _sync();
  }
  final SettingsService settings;
  final LanServer lan;
  final AudienceHudSink? sink;
  final QueueService queue;
  final PlaybackService playback;
  QueueItem? _observedItem;
  AudienceOverlayOptions? _lastOptions;
  String? _lastNetwork;
  bool? _lastWifi;
  List<AudienceQueueEntry>? _lastQueue;
  AudienceQueueEntry? _lastCurrent;
  bool _disposed = false;

  void _onPlaybackChanged() {
    // Volume, pause and position updates do not change the cached card.
    if (identical(_observedItem, playback.state.currentItem)) return;
    _sync();
  }

  void _networkChanged() {
    if (!_disposed) unawaited(_refreshNetwork());
  }

  Future<void> _refreshNetwork() async {
    await lan.refreshAddress();
    // An unchanged address still confirms the image for the new OS event.
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    final qr = lan.qrImages.image;
    sink?.setImage(qr);
    final options = settings.audienceOverlay;
    final network = lan.networkName;
    final wifi = lan.networkIsWifi;
    _observedItem = playback.state.currentItem;
    final song = _observedItem?.song;
    final AudienceQueueEntry? current = song == null
        ? null
        : (title: song.title, artist: song.artist?.name ?? '');
    final entries = queue.items
        .where((item) => !queue.isFailed(item.id))
        .take(4)
        .map((item) =>
            (title: item.song.title, artist: item.song.artist?.name ?? ''))
        .toList(growable: false);
    if (_lastOptions == options &&
        _lastNetwork == network &&
        _lastWifi == wifi &&
        _lastCurrent == current &&
        listEquals(_lastQueue, entries)) {
      return;
    }
    _lastOptions = options;
    _lastNetwork = network;
    _lastWifi = wifi;
    _lastQueue = entries;
    _lastCurrent = current;
    sink?.setState(options, network, entries, wifi: wifi, current: current);
  }

  void dispose() {
    _disposed = true;
    settings.removeListener(_sync);
    lan.qrImages.removeListener(_sync);
    queue.removeListener(_sync);
    playback.removeListener(_onPlaybackChanged);
    sink?.onLanChanged = null;
  }
}
