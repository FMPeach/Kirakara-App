import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/media_asset.dart';
import '../domain/playback_state.dart';
import '../domain/queue_item.dart';
import '../domain/song.dart';
import '../domain/stage_overlay_state.dart';
import 'kirakara_show_ffi.dart';
import 'playback_asset_cache.dart';
import 'playback_service.dart';
import 'playback_slot.dart';
import 'playback_slot_manager.dart';

class KirakaraShowService extends ChangeNotifier {
  KirakaraShowService({
    required PlaybackService playbackService,
    PlaybackAssetCache? assetCache,
    PlaybackSlotManager? slotManager,
  })  : _playbackService = playbackService,
        _assetCache = assetCache,
        _slotManager = slotManager;

  final PlaybackService _playbackService;
  final PlaybackAssetCache? _assetCache;
  final PlaybackSlotManager? _slotManager;
  KirakaraShowFFI? _ffi;
  String? _loadedSongId;
  String? _loadedItemId;
  String? _preparingItemId;
  AudioTrackMode? _loadedAudioTrackMode;
  bool? _lastPlaying;
  int? _lastVolume;
  int? _lastKey;
  String? _lastCompletedItemId;
  String? _seamlessTransitionItemId;
  bool _sawEngineProgressForItem = false;
  bool _started = false;
  bool _applyingEnginePosition = false;
  int _lastReplayRevision = 0;
  int _prepareGeneration = 0;
  Future<bool>? _activeNativeLoad;
  bool _showNeedsAsyncWake = true;
  String? _nativePreparedSongId;
  int? _nativePreparedSlotGeneration;
  Duration _enginePosition = Duration.zero;
  Duration _engineDuration = Duration.zero;
  bool _isBuffering = false;
  bool _isShowLoading = false;
  int? _showLoadingGeneration;

  /// The engine's render surface dimensions.
  int get engineWidth => _ffi?.width ?? 0;
  int get engineHeight => _ffi?.height ?? 0;
  Duration get enginePosition => _enginePosition;
  Duration get engineDuration => _engineDuration;
  bool get isBuffering => _isBuffering;
  bool get isLoading => _isShowLoading;
  int get nativeHandleAddress => _ffi?.nativeHandleAddress ?? 0;

  /// Call this once after the engine DLL is available.
  void start() {
    if (_started) return;
    _started = true;
    try {
      _ffi = KirakaraShowFFI();
    } catch (e) {
      debugPrint('KirakaraShowService: failed to load engine DLL: $e');
      return;
    }
    _playbackService.addListener(_syncWithPlayback);
    _slotManager?.addListener(_syncPreparedSlot);
    _syncWithPlayback();
    _syncPreparedSlot();
    _startFramePoller();
  }

  @override
  Future<void> dispose() async {
    if (_started) {
      _playbackService.removeListener(_syncWithPlayback);
      _slotManager?.removeListener(_syncPreparedSlot);
      _framePoller?.cancel();
      _started = false;
    }
    _prepareGeneration++;
    final activeLoad = _activeNativeLoad;
    if (activeLoad != null) {
      try {
        await activeLoad;
      } catch (_) {
        // The engine is being torn down; a failed in-flight load is inert.
      }
    }
    _ffi?.dispose();
    _ffi = null;
    super.dispose();
  }

  void _syncPreparedSlot() {
    final ffi = _ffi;
    final slot = _slotManager?.standbySlot;
    if (ffi == null || slot == null || !slot.isReady) return;
    if (_nativePreparedSongId == slot.songId &&
        _nativePreparedSlotGeneration == slot.generation) {
      return;
    }
    final song = slot.song;
    final videoPath = slot.videoPath;
    if (song == null || videoPath == null) return;
    if (!song.isExternal && slot.krlPath == null) return;

    final accepted = ffi.prepareNext(
      videoPath,
      lyricPath: song.isExternal ? null : slot.krlPath,
      vocalPath: slot.vocalPath,
      accompanimentPath: slot.instPath,
      videoMasterClock: song.videoMasterClock,
    );
    if (accepted) {
      _nativePreparedSongId = slot.songId;
      _nativePreparedSlotGeneration = slot.generation;
    }
  }

  // ── Playback sync ──────────────────────────────────────────────

  void _syncWithPlayback() {
    if (_applyingEnginePosition) return;
    final ffi = _ffi;
    if (ffi == null) return;

    final state = _playbackService.state;
    _syncVolume(ffi, state);
    _syncKey(ffi, state);
    final item = state.currentItem;

    if (item == null) {
      _prepareGeneration++;
      _showNeedsAsyncWake = true;
      _seamlessTransitionItemId = null;
      ffi.stop();
      _loadedSongId = null;
      _loadedItemId = null;
      _preparingItemId = null;
      _loadedAudioTrackMode = null;
      _lastPlaying = null;
      _lastKey = null;
      _lastCompletedItemId = null;
      _sawEngineProgressForItem = false;
      _lastReplayRevision = _playbackService.replayRevision;
      _enginePosition = Duration.zero;
      _engineDuration = Duration.zero;
      _setShowLoading(false);
      _setBuffering(false);
      return;
    }

    if (_loadedItemId != item.id || _loadedSongId != item.song.id) {
      // A replay requested while the item is still loading is naturally
      // satisfied by that initial load, which already starts at its title.
      _lastReplayRevision = _playbackService.replayRevision;
      _trySlotSwapOrPrepare(item);
      return;
    }

    _syncAudioTrack(ffi, state);
    if (_lastReplayRevision != _playbackService.replayRevision) {
      _lastReplayRevision = _playbackService.replayRevision;
      _replayCurrentProgram(ffi);
      return;
    }
    final justLoaded = _lastPlaying == null;
    if (!justLoaded) {
      _syncRequestedPosition(ffi, state);
    }

    // Sync play/pause
    if (_lastPlaying == state.isPlaying) return;
    if (state.isPlaying) {
      ffi.play();
    } else {
      ffi.pause();
    }
    _lastPlaying = state.isPlaying;
  }

  /// 热路径：尝试 slot swap；失败则走异步下载 + 加载。
  void _trySlotSwapOrPrepare(QueueItem item) {
    final seamlessTransition = _seamlessTransitionItemId == item.id;
    _seamlessTransitionItemId = null;
    final slot = _slotManager?.consumeStandby(item.song.id);
    if (slot != null) {
      final generation = ++_prepareGeneration;
      _preparingItemId = item.id;
      unawaited(_loadFromSlot(
        slot,
        item,
        generation: generation,
        seamlessTransition: seamlessTransition,
      ));
      return;
    }

    if (_preparingItemId == item.id) return;
    final generation = ++_prepareGeneration;
    _preparingItemId = item.id;

    // The first program has no previously rendered Stage frame to retain.
    // Publish the loading state before cache preparation starts so Flutter can
    // keep its opaque-black guard over the transparent compositor hole for the
    // whole startup interval, not only for the final synchronous Show load.
    if (_showNeedsAsyncWake) {
      _beginShowLoading(generation);
    }

    if (seamlessTransition) {
      _ffi?.pause();
    } else {
      _ffi?.stop();
    }
    _loadedSongId = null;
    _loadedItemId = null;
    _sawEngineProgressForItem = false;
    _lastCompletedItemId = null;
    _lastPlaying = null;
    _enginePosition = Duration.zero;
    _engineDuration = Duration.zero;
    _setBuffering(true);

    _slotManager?.createFallbackActive(item.song.id, item.song);
    _prepareAndLoadAsync(
      item,
      generation,
      seamlessTransition: seamlessTransition,
    );
  }

  /// 从已预热 slot 提交原生加载。不调用 stop，避免歌词闪回第一帧。
  Future<void> _loadFromSlot(
    PlaybackSlot slot,
    QueueItem item, {
    required int generation,
    required bool seamlessTransition,
  }) async {
    final ffi = _ffi;
    if (ffi == null || !slot.isReady || slot.videoPath == null) {
      _finishShowLoading(item.id, generation);
      return;
    }

    // 外部歌曲允许 krlPath 为 null
    final isExternal = item.song.isExternal;
    if (!isExternal && slot.krlPath == null) {
      _finishShowLoading(item.id, generation);
      return;
    }

    _loadedSongId = null;
    _loadedItemId = null;

    final showLoading = _showNeedsAsyncWake || _activeNativeLoad != null;
    if (showLoading) {
      _beginShowLoading(generation);
    }
    if (!_isCurrentPreparation(item, generation)) {
      _finishShowLoading(item.id, generation);
      return;
    }

    final loaded = await _runNativeLoad(
      ffi,
      generation: generation,
      videoPath: slot.videoPath!,
      lyricPath: isExternal ? null : slot.krlPath,
      vocalPath: slot.vocalPath,
      accompanimentPath: slot.instPath,
      videoMasterClock: item.song.videoMasterClock,
      seamlessTransition: seamlessTransition,
    );
    if (!_isCurrentPreparation(item, generation)) {
      _finishShowLoading(item.id, generation);
      return;
    }
    if (!loaded) {
      _failCurrentPreparation(
        item,
        generation,
        '播放资源无法载入',
      );
      return;
    }

    _loadedSongId = item.song.id;
    _loadedItemId = item.id;
    _loadedAudioTrackMode = slot.vocalPath == null && slot.instPath != null
        ? AudioTrackMode.accompaniment
        : AudioTrackMode.vocal;
    _lastPlaying = null;
    _lastCompletedItemId = null;
    _sawEngineProgressForItem = false;
    _enginePosition = Duration.zero;
    _engineDuration = Duration.zero;
    _finishShowLoading(item.id, generation);

    _slotManager?.onPlaybackStarted();
    _syncWithPlayback();
  }

  /// 异步下载 + 加载（慢路径，仅 standby 未命中时用）。
  Future<void> _prepareAndLoadAsync(
    QueueItem item,
    int generation, {
    required bool seamlessTransition,
  }) async {
    try {
      final isExternal = item.song.isExternal;

      // 外链 DASH 同样进入播放周期缓存：视频渐进，音频完整落盘。
      if (_assetCache != null) {
        _assetCache.validateRequiredPlaybackAssets(item.song);
        await _assetCache.ensurePlaybackAssets(item.song);
      }
      if (!_isCurrentPreparation(item, generation)) return;

      final ffi = _ffi;
      if (ffi == null) return;

      final videoPath = _pathFor(item.song, MediaAssetType.video);
      if (videoPath == null) {
        throw PlaybackAssetDownloadException(
          songId: item.song.id,
          assetType: MediaAssetType.video,
          message: '视频不可用',
        );
      }
      if (!_isCurrentPreparation(item, generation)) return;

      // 外部歌曲不需要歌词，也不做 existsSync 检查（视频是 HTTP URL）
      final String? lyricPath;
      if (isExternal) {
        lyricPath = null;
      } else {
        lyricPath = item.song.lyricProject?.cachedPath ??
            _pathFor(item.song, MediaAssetType.lyric);
        if (lyricPath == null) {
          throw PlaybackAssetDownloadException(
            songId: item.song.id,
            assetType: MediaAssetType.lyric,
            message: 'KRL 不可用',
          );
        }
        if ((!_isHttpPath(videoPath) && !File(videoPath).existsSync()) ||
            !File(lyricPath).existsSync()) {
          throw PlaybackAssetDownloadException(
            songId: item.song.id,
            message: '视频或 KRL 缓存文件不存在',
          );
        }
      }

      final vocalPath = _existingPathFor(item.song, MediaAssetType.vocal);
      final accompanimentPath =
          _existingPathFor(item.song, MediaAssetType.accompaniment);
      if (!isExternal && (vocalPath == null || accompanimentPath == null)) {
        throw PlaybackAssetDownloadException(
          songId: item.song.id,
          message: '原唱或伴奏不可用',
        );
      }
      if (!_isCurrentPreparation(item, generation)) return;

      _beginShowLoading(generation);
      if (!_isCurrentPreparation(item, generation)) return;

      final loaded = await _runNativeLoad(
        ffi,
        generation: generation,
        videoPath: videoPath,
        lyricPath: lyricPath,
        vocalPath: vocalPath,
        accompanimentPath: accompanimentPath,
        videoMasterClock: item.song.videoMasterClock,
        seamlessTransition: seamlessTransition,
      );
      if (!_isCurrentPreparation(item, generation)) {
        _finishShowLoading(item.id, generation);
        return;
      }
      if (!loaded) {
        throw PlaybackAssetDownloadException(
          songId: item.song.id,
          message: '播放资源无法载入',
        );
      }

      _loadedSongId = item.song.id;
      _loadedItemId = item.id;
      if (_preparingItemId == item.id && generation == _prepareGeneration) {
        _preparingItemId = null;
      }
      _loadedAudioTrackMode = vocalPath == null && accompanimentPath != null
          ? AudioTrackMode.accompaniment
          : AudioTrackMode.vocal;
      _lastPlaying = null;
      _enginePosition = Duration.zero;
      _engineDuration = Duration.zero;
      _finishShowLoading(item.id, generation);

      _slotManager?.onPlaybackStarted();
      _syncWithPlayback();
    } on PlaybackAssetDownloadException catch (error) {
      if (_isCurrentPreparation(item, generation)) {
        debugPrint(
          'KirakaraShowService: skipping failed song ${item.song.id}: $error',
        );
        _finishShowLoading(item.id, generation);
        _playbackService.failCurrent(error.toString());
      }
    } finally {
      if (_preparingItemId == item.id && generation == _prepareGeneration) {
        _preparingItemId = null;
      }
      if (_showLoadingGeneration == generation &&
          (_loadedItemId != item.id || !_isCurrentItem(item))) {
        _setShowLoading(false);
      }
    }
  }

  bool _isCurrentPreparation(QueueItem item, int generation) {
    return generation == _prepareGeneration &&
        _preparingItemId == item.id &&
        _playbackService.state.currentItem?.id == item.id;
  }

  void _syncAudioTrack(KirakaraShowFFI ffi, PlaybackState state) {
    if (_loadedAudioTrackMode != state.audioTrackMode) {
      final changed = ffi.setAudioTrack(_trackIndex(state.audioTrackMode));
      if (changed) {
        _loadedAudioTrackMode = state.audioTrackMode;
      }
    }
  }

  // ── Frame polling ──────────────────────────────────────────────

  Timer? _framePoller;

  void _startFramePoller() {
    _framePoller = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => _pollFrame(),
    );
  }

  void _pollFrame() {
    final ffi = _ffi;
    if (ffi == null) return;

    final pos = ffi.position;
    final duration = ffi.duration;
    final engineState = ffi.state;
    _setBuffering(_preparingItemId != null || ffi.isBuffering);
    if (pos.isFinite && pos >= 0) {
      _enginePosition = Duration(milliseconds: (pos * 1000).round());
    }
    if (duration.isFinite && duration > 0) {
      _engineDuration = Duration(milliseconds: (duration * 1000).round());
    }

    final state = _playbackService.state;
    final itemId = state.currentItem?.id;
    final songId = state.currentItem?.song.id;
    final loadedCurrentItem =
        itemId != null && itemId == _loadedItemId && songId == _loadedSongId;
    if (!loadedCurrentItem || _preparingItemId != null) {
      return;
    }
    if (state.isPlaying &&
        songId != null &&
        (engineState == 1 ||
            _enginePosition > const Duration(milliseconds: 1000))) {
      _sawEngineProgressForItem = true;
    }
    if (_shouldAdvanceAfterEngineEnd(
      state: state,
      songId: songId,
      engineState: engineState,
    )) {
      _advanceAfterEngineEnd();
      return;
    }

    if (pos.isFinite) {
      final beforeItemId = _playbackService.state.currentItem?.id;
      _applyingEnginePosition = true;
      final bool changed;
      try {
        changed = _playbackService.syncEnginePosition(
          Duration(milliseconds: (pos * 1000).round()),
        );
      } finally {
        _applyingEnginePosition = false;
      }
      final afterItemId = _playbackService.state.currentItem?.id;
      if (changed && beforeItemId != afterItemId) {
        _syncWithPlayback();
      }
    }
  }

  void setStageWindowVisible(bool visible) {
    _ffi?.setStageVisible(visible);
  }

  void setStageWindowRect({
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    _ffi?.setStageWindowRect(
      x: x,
      y: y,
      width: width,
      height: height,
    );
  }

  bool startCastStream(int port) {
    return _ffi?.startCastStream(port) ?? false;
  }

  int get castStreamPort => _ffi?.castStreamPort ?? 0;

  void stopCastStream() {
    _ffi?.stopCastStream();
  }

  bool setStageOverlayState(StageOverlayState state) {
    return _ffi?.setStageOverlayState(state) ?? false;
  }

  void setAudioClockOffset(Duration offset) {
    final seconds = offset.inMicroseconds / Duration.microsecondsPerSecond;
    _ffi?.setAudioClockOffset(seconds);
  }

  void _setBuffering(bool value) {
    if (_isBuffering == value) return;
    _isBuffering = value;
    notifyListeners();
  }

  void _beginShowLoading(int generation) {
    _showLoadingGeneration = generation;
    _setShowLoading(true);
  }

  Future<bool> _runNativeLoad(
    KirakaraShowFFI ffi, {
    required int generation,
    required String videoPath,
    String? lyricPath,
    String? vocalPath,
    String? accompanimentPath,
    required bool videoMasterClock,
    required bool seamlessTransition,
  }) async {
    // Show's load ABI is synchronous. Even a native-prepared hot transition
    // can briefly wait for MediaEngine/physical-Stage handoff, so every load
    // stays on this helper isolate. This also prevents a cross-thread
    // SendMessage/callback cycle from blocking Flutter's UI event loop.
    while (true) {
      final active = _activeNativeLoad;
      if (active == null) break;
      try {
        await active;
      } catch (_) {
        // A failed older request must not prevent the newest song from loading.
      }
    }
    if (generation != _prepareGeneration || !_started) return false;

    final load = ffi.loadOffUiIsolate(
      videoPath,
      lyricPath: lyricPath,
      vocalPath: vocalPath,
      accompanimentPath: accompanimentPath,
      videoMasterClock: videoMasterClock,
      seamlessTransition: seamlessTransition,
    );
    _activeNativeLoad = load;
    try {
      final loaded = await load;
      if (loaded && _playbackService.state.currentItem != null) {
        _showNeedsAsyncWake = false;
      }
      return loaded;
    } catch (error) {
      debugPrint('KirakaraShowService: native load failed: $error');
      return false;
    } finally {
      if (identical(_activeNativeLoad, load)) {
        _activeNativeLoad = null;
      }
    }
  }

  void _finishShowLoading(String itemId, int generation) {
    if (_preparingItemId == itemId && generation == _prepareGeneration) {
      _preparingItemId = null;
    }
    if (_showLoadingGeneration == generation) {
      _setShowLoading(false);
    }
  }

  void _failCurrentPreparation(
    QueueItem item,
    int generation,
    String error,
  ) {
    if (!_isCurrentPreparation(item, generation)) return;
    _finishShowLoading(item.id, generation);
    _playbackService.failCurrent(error);
  }

  void _setShowLoading(bool value) {
    if (_isShowLoading == value) return;
    _isShowLoading = value;
    if (!value) _showLoadingGeneration = null;
    notifyListeners();
  }

  bool _isCurrentItem(QueueItem item) =>
      _playbackService.state.currentItem?.id == item.id;

  // ── Helpers ────────────────────────────────────────────────────

  String? _pathFor(Song song, MediaAssetType type) {
    for (final asset in song.assets) {
      if (asset.type != type) continue;
      final cached = _assetCache?.playbackPathFor(asset);
      if (cached != null) return cached;
      if (asset.cachedPath != null && asset.cachedPath!.isNotEmpty) {
        return asset.cachedPath;
      }
      // HTTP(S) URL 直接返回（外部歌曲流媒体，不走本地文件）
      if (asset.uri.isScheme('http') || asset.uri.isScheme('https')) {
        return asset.uri.toString();
      }
      if (asset.uri.isScheme('file')) {
        return asset.uri.toFilePath(windows: Platform.isWindows);
      }
    }
    return null;
  }

  String? _existingPathFor(Song song, MediaAssetType type) {
    final path = _pathFor(song, type);
    if (path == null || !File(path).existsSync()) return null;
    return path;
  }

  bool _isHttpPath(String path) =>
      path.startsWith('http://') || path.startsWith('https://');

  int _trackIndex(AudioTrackMode mode) {
    return mode == AudioTrackMode.accompaniment ? 1 : 0;
  }

  void _syncVolume(KirakaraShowFFI ffi, PlaybackState state) {
    final volume = state.volume.clamp(0, 100).toInt();
    if (_lastVolume == volume) return;
    ffi.setVolume(volume);
    _lastVolume = volume;
  }

  void _syncKey(KirakaraShowFFI ffi, PlaybackState state) {
    final key = state.key.clamp(-6, 6).toInt();
    if (_lastKey == key) return;
    ffi.setKeySemitones(key);
    _lastKey = key;
  }

  void _replayCurrentProgram(KirakaraShowFFI ffi) {
    // New title-aware engines restart the whole program, including the
    // negative title timeline. Older DLLs lack this optional export and keep
    // their established media-zero behavior.
    if (!ffi.replay()) {
      ffi.seek(0.0);
      ffi.play();
    }
    _enginePosition = Duration.zero;
    _lastCompletedItemId = null;
    _sawEngineProgressForItem = false;
    _lastPlaying = true;
  }

  void _syncRequestedPosition(
    KirakaraShowFFI ffi,
    PlaybackState state,
  ) {
    if (state.currentSong == null) return;

    final rawPosition = ffi.position;
    if (!rawPosition.isFinite || rawPosition < 0) return;

    final enginePosition = Duration(
      milliseconds: (rawPosition * 1000).round(),
    );
    final requestedPosition =
        state.position < Duration.zero ? Duration.zero : state.position;
    final diffMs = (requestedPosition - enginePosition).inMilliseconds.abs();
    if (diffMs < 500) return;

    ffi.seek(requestedPosition.inMilliseconds / 1000.0);
    _enginePosition = requestedPosition;
    _lastCompletedItemId = null;
    _sawEngineProgressForItem = false;
  }

  bool _shouldAdvanceAfterEngineEnd({
    required PlaybackState state,
    required String? songId,
    required int engineState,
  }) {
    if (!state.isPlaying || songId == null || songId != _loadedSongId) {
      return false;
    }
    final itemId = state.currentItem?.id;
    if (_lastCompletedItemId == itemId) return false;

    const stopped = 3;
    if (engineState == stopped && _sawEngineProgressForItem) return true;

    if (_engineDuration <= Duration.zero) return false;
    if (_enginePosition < const Duration(seconds: 1)) return false;
    return _enginePosition >= _engineDuration;
  }

  void _advanceAfterEngineEnd() {
    _lastCompletedItemId = _playbackService.state.currentItem?.id;
    _applyingEnginePosition = true;
    try {
      _playbackService.next();
      _seamlessTransitionItemId = _playbackService.state.currentItem?.id;
    } finally {
      _applyingEnginePosition = false;
    }
    _syncWithPlayback();
  }
}
