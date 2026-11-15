import 'package:flutter/foundation.dart';

import '../domain/playback_state.dart';
import '../domain/queue_item.dart';
import '../domain/song.dart';
import 'queue_service.dart';

enum PlaybackAction {
  none(0),
  play(1),
  pause(2),
  replay(3),
  skip(4),
  vocal(5),
  accompaniment(6),
  volumeUp(7),
  volumeDown(8);

  const PlaybackAction(this.hostCode);
  final int hostCode;
}

typedef PlaybackActionEvent = ({PlaybackAction action, int sequence});

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
  PlaybackActionEvent? _actionEvent;

  PlaybackState get state => _state;
  int get replayRevision => _replayRevision;
  PlaybackActionEvent? get actionEvent => _actionEvent;

  void disposeService() {}

  void play() {
    _setState(_state.copyWith(mode: PlaybackMode.playing),
        action: _state.currentItem != null && !_state.isPlaying
            ? PlaybackAction.play
            : null);
  }

  void pause() {
    _setState(_state.copyWith(mode: PlaybackMode.paused),
        action: _state.currentItem != null && _state.isPlaying
            ? PlaybackAction.pause
            : null);
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
      action: _state.currentItem != null ? PlaybackAction.replay : null,
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

  void next({bool requestedByUser = false}) {
    final hadCurrent = _state.currentItem != null;
    final nextItem = _queueService.takeNext();
    final action = requestedByUser && (hadCurrent || nextItem != null)
        ? PlaybackAction.skip
        : null;
    if (nextItem == null) {
      _setState(
        _state.copyWith(
          mode: PlaybackMode.paused,
          key: 0,
          position: Duration.zero,
          clearCurrentItem: true,
          clearUpNext: true,
        ),
        action: action,
      );
      return;
    }

    final upNext = _peekNextQueueItem();
    _setState(
      _state.copyWith(
        mode: PlaybackMode.playing,
        key: 0,
        position: Duration.zero,
        currentItem: nextItem,
        upNext: upNext,
        clearUpNext: upNext == null,
      ),
      action: action,
    );
  }

  void setCurrent(QueueItem item, {bool startPlaying = true}) {
    final upNext = _peekNextQueueItem();
    _setState(
      _state.copyWith(
        currentItem: item,
        key: 0,
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

  void setVolume(int volume, {bool requestedByUser = false}) {
    final nextVolume = volume.clamp(0, 100).toInt();
    final action = requestedByUser && nextVolume != _state.volume
        ? (nextVolume > _state.volume
            ? PlaybackAction.volumeUp
            : PlaybackAction.volumeDown)
        : null;
    _setState(_state.copyWith(volume: nextVolume), action: action);
  }

  void changeVolumeBy(int delta) {
    setVolume(_state.volume + delta, requestedByUser: true);
  }

  void toggleAudioTrack() {
    final nextMode = _state.audioTrackMode == AudioTrackMode.vocal
        ? AudioTrackMode.accompaniment
        : AudioTrackMode.vocal;
    final song = _state.currentSong;
    // External links already represent a single selected part and have no
    // alternate audio track for Show to switch to.
    _setState(
      _state.copyWith(audioTrackMode: nextMode),
      action: song != null && !song.isExternalSong
          ? (nextMode == AudioTrackMode.vocal
              ? PlaybackAction.vocal
              : PlaybackAction.accompaniment)
          : null,
    );
  }

  void refreshUpNext() {
    final upNext = _peekNextQueueItem();
    _setState(_state.copyWith(upNext: upNext, clearUpNext: upNext == null));
  }

  void _setState(PlaybackState nextState,
      {bool notify = true, PlaybackAction? action}) {
    // An internal departure from a paused item also clears the pause beneath
    // a temporary audio indicator.
    final previousItem = _state.currentItem;
    if (action == null &&
        previousItem != null &&
        _state.mode == PlaybackMode.paused &&
        (nextState.mode != PlaybackMode.paused ||
            previousItem.id != nextState.currentItem?.id)) {
      action = PlaybackAction.none;
    }
    if (action != null) {
      _actionEvent = (
        action: action,
        sequence: (_actionEvent?.sequence ?? 0) + 1,
      );
    }
    _state = nextState;
    if (notify) notifyListeners();
  }

  QueueItem? _peekNextQueueItem() {
    return _queueService.nextPlayableItem;
  }
}
