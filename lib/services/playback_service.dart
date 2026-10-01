import 'package:flutter/foundation.dart';

import '../domain/playback_state.dart';
import '../domain/queue_item.dart';
import '../domain/song.dart';
import 'queue_service.dart';

class PlaybackService extends ChangeNotifier {
  PlaybackService({
    required QueueService queueService,
    QueueItem? initialItem,
  })  : _queueService = queueService,
        _state = PlaybackState.initial(currentItem: initialItem);

  final QueueService _queueService;
  PlaybackState _state;
  int _directSequence = 0;
  int _replayRevision = 0;

  PlaybackState get state => _state;
  int get replayRevision => _replayRevision;

  void disposeService() {}

  void play() {
    _setState(_state.copyWith(mode: PlaybackMode.playing));
  }

  void pause() {
    _setState(_state.copyWith(mode: PlaybackMode.paused));
  }

  void togglePlayPause() {
    _state.isPlaying ? pause() : play();
  }

  void replay() {
    _replayRevision++;
    _setState(
      _state.copyWith(
        position: Duration.zero,
        mode: PlaybackMode.playing,
      ),
    );
  }

  bool syncEnginePosition(Duration position) {
    if (_state.currentSong == null) return false;
    final safePosition = position < Duration.zero ? Duration.zero : position;
    final diffMs = (_state.position - safePosition).inMilliseconds.abs();
    if (diffMs < 250) return false;

    // Engine position is sampled for playback coordination only. Nothing in
    // the controller renders this value, so broadcasting it would rebuild the
    // entire 1080p controller (including the external Stage texture) several
    // times per second for no visible change.
    _setState(_state.copyWith(position: safePosition), notify: false);
    return true;
  }

  void next() {
    final nextItem = _queueService.takeNext();
    if (nextItem == null) {
      _setState(
        _state.copyWith(
          mode: PlaybackMode.paused,
          position: Duration.zero,
          clearCurrentItem: true,
          clearUpNext: true,
        ),
      );
      return;
    }

    final upNext = _peekNextQueueItem();
    _setState(
      _state.copyWith(
        mode: PlaybackMode.playing,
        position: Duration.zero,
        currentItem: nextItem,
        upNext: upNext,
        clearUpNext: upNext == null,
      ),
    );
  }

  void setCurrent(QueueItem item, {bool startPlaying = true}) {
    final upNext = _peekNextQueueItem();
    _setState(
      _state.copyWith(
        currentItem: item,
        mode: startPlaying ? PlaybackMode.playing : PlaybackMode.paused,
        position: Duration.zero,
        upNext: upNext,
        clearUpNext: upNext == null,
      ),
    );
  }

  void setCurrentSong(
    Song song, {
    bool startPlaying = true,
    String requestedBy = '本机',
  }) {
    setCurrent(
      QueueItem(
        id: 'direct-${++_directSequence}',
        song: song,
        requestedBy: requestedBy,
        addedAt: DateTime.now(),
      ),
      startPlaying: startPlaying,
    );
  }

  void setCurrentFromQueue(QueueItem item, {bool startPlaying = true}) {
    _queueService.remove(item.id);
    setCurrent(item, startPlaying: startPlaying);
  }

  void failCurrent(String error) {
    final item = _state.currentItem;
    if (item == null) return;
    _queueService.retainFailed(item, error);
    next();
  }

  void setKey(int key) {
    _setState(_state.copyWith(key: key.clamp(-6, 6).toInt()));
  }

  void transposeBy(int delta) {
    setKey(_state.key + delta);
  }

  void setVolume(int volume) {
    _setState(_state.copyWith(volume: volume.clamp(0, 100).toInt()));
  }

  void changeVolumeBy(int delta) {
    setVolume(_state.volume + delta);
  }

  void toggleAudioTrack() {
    final nextMode = _state.audioTrackMode == AudioTrackMode.vocal
        ? AudioTrackMode.accompaniment
        : AudioTrackMode.vocal;
    _setState(_state.copyWith(audioTrackMode: nextMode));
  }

  void refreshUpNext() {
    final upNext = _peekNextQueueItem();
    _setState(_state.copyWith(upNext: upNext, clearUpNext: upNext == null));
  }

  void _setState(PlaybackState nextState, {bool notify = true}) {
    _state = nextState;
    if (notify) notifyListeners();
  }

  QueueItem? _peekNextQueueItem() {
    return _queueService.nextPlayableItem;
  }
}
