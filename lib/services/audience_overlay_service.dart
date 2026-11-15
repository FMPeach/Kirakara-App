import 'dart:async';
import 'package:flutter/foundation.dart';

import '../domain/audience_overlay_options.dart';
import '../domain/playback_state.dart';
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
  int _lastActionSequence = 0;
  int _publishedActionSequence = 0;
  AudienceOverlayOptions? _lastOptions;
  String? _lastNetwork;
  bool? _lastWifi;
  List<AudienceQueueEntry>? _lastQueue;
  AudienceQueueEntry? _lastCurrent;
  bool _disposed = false;

  void _onPlaybackChanged() {
    if (!identical(_observedItem, playback.state.currentItem)) _sync();
    final event = playback.actionEvent;
    if (event != null && event.sequence > _lastActionSequence) {
      _lastActionSequence = event.sequence;
      if (settings.audienceOverlay.actionEnabled) _publishAction(event.action);
    }
  }

  void _publishAction(PlaybackAction action) {
    sink?.notifyPlaybackAction((
      action: action,
      sequence: ++_publishedActionSequence,
    ));
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
    final previousOptions = _lastOptions;
    _lastOptions = options;
    if (previousOptions?.actionEnabled != options.actionEnabled) {
      if (!options.actionEnabled) {
        if (previousOptions != null) _publishAction(PlaybackAction.none);
      } else if (playback.state.currentItem != null &&
          playback.state.mode == PlaybackMode.paused) {
        _publishAction(PlaybackAction.pause);
      }
    }
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
    // The action switch is handled above, independently of the QR/list card.
    if (previousOptions?.qrEnabled == options.qrEnabled &&
        previousOptions?.queueEnabled == options.queueEnabled &&
        previousOptions?.announcementEnabled == options.announcementEnabled &&
        _lastNetwork == network &&
        _lastWifi == wifi &&
        _lastCurrent == current &&
        listEquals(_lastQueue, entries)) {
      return;
    }
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
