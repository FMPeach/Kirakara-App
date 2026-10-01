import 'queue_item.dart';
import 'song.dart';

enum PlaybackMode {
  stopped,
  playing,
  paused,
}

enum AudioTrackMode {
  vocal,
  accompaniment,
}

class PlaybackState {
  const PlaybackState({
    required this.mode,
    required this.volume,
    required this.key,
    required this.audioTrackMode,
    required this.position,
    this.currentItem,
    this.upNext,
  });

  factory PlaybackState.initial({QueueItem? currentItem, QueueItem? upNext}) {
    return PlaybackState(
      mode: PlaybackMode.paused,
      volume: 72,
      key: 0,
      audioTrackMode: AudioTrackMode.vocal,
      position: Duration.zero,
      currentItem: currentItem,
      upNext: upNext,
    );
  }

  final PlaybackMode mode;
  final int volume;
  final int key;
  final AudioTrackMode audioTrackMode;
  final Duration position;
  final QueueItem? currentItem;
  final QueueItem? upNext;

  Song? get currentSong => currentItem?.song;

  bool get isPlaying => mode == PlaybackMode.playing;

  PlaybackState copyWith({
    PlaybackMode? mode,
    int? volume,
    int? key,
    AudioTrackMode? audioTrackMode,
    Duration? position,
    QueueItem? currentItem,
    QueueItem? upNext,
    bool clearCurrentItem = false,
    bool clearUpNext = false,
  }) {
    return PlaybackState(
      mode: mode ?? this.mode,
      volume: volume ?? this.volume,
      key: key ?? this.key,
      audioTrackMode: audioTrackMode ?? this.audioTrackMode,
      position: position ?? this.position,
      currentItem: clearCurrentItem ? null : currentItem ?? this.currentItem,
      upNext: clearUpNext ? null : upNext ?? this.upNext,
    );
  }
}
