import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/media_asset.dart';
import '../domain/queue_item.dart';
import '../domain/song.dart';
import 'playback_asset_cache.dart';
import 'playback_slot.dart';
import 'queue_service.dart';

/// 准无缝切歌架构的核心。
///
/// 保持 active + standby 两个 [PlaybackSlot]。
/// 切歌热路径只做 slot swap；下载、DB 查询、KRL 解析均在后台准备。
class PlaybackSlotManager extends ChangeNotifier {
  PlaybackSlotManager({
    required QueueService queueService,
    PlaybackAssetCache? assetCache,
    VoidCallback? onQueueAvailabilityChanged,
  })  : _queueService = queueService,
        _assetCache = assetCache,
        _onQueueAvailabilityChanged = onQueueAvailabilityChanged {
    _queueService.addListener(_onQueueChanged);
  }

  final QueueService _queueService;
  final PlaybackAssetCache? _assetCache;
  final VoidCallback? _onQueueAvailabilityChanged;
  int _prefetchLookahead = 3;
  final Set<String> _prefetchedSongIds = {};

  PlaybackSlot? _activeSlot;
  PlaybackSlot? _standbySlot;
  int _prepGeneration = 0;
  bool _queueRefreshScheduled = false;
  bool _disposed = false;

  // ── 暴露给 UI ─────────────────────────────────────────────────

  /// 下一首的准备状态。
  SlotState get upNextState => _standbySlot?.state ?? SlotState.empty;

  /// 已准备的下一首 songId。
  String? get preparedSongId =>
      _standbySlot?.isReady == true ? _standbySlot?.songId : null;

  /// 最近一次准备失败的信息。
  String? get lastPreparationError =>
      _standbySlot?.state == SlotState.failed ? _standbySlot?.error : null;

  PlaybackSlot? get activeSlot => _activeSlot;
  PlaybackSlot? get standbySlot => _standbySlot;

  int get prefetchLookahead => _prefetchLookahead;

  void setPrefetchLookahead(int value) {
    final normalized = value.clamp(1, 3).toInt();
    if (_prefetchLookahead == normalized) return;
    _prefetchLookahead = normalized;
    _maybePrepareNext();
    notifyListeners();
  }

  // ── 生命周期 ──────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _queueService.removeListener(_onQueueChanged);
    super.dispose();
  }

  // ── 队列变化 ──────────────────────────────────────────────────

  void _onQueueChanged() {
    // QueueService.takeNext() notifies synchronously before PlaybackService
    // publishes the newly-current item. Replacing standby in this callback
    // destroys the exact prepared slot that the following playback
    // notification is about to consume, forcing every natural transition
    // through the slow load path. Coalesce queue churn until the current call
    // stack has completed; consumeStandby then wins, and its own microtask
    // prepares the following song.
    if (_queueRefreshScheduled) return;
    _queueRefreshScheduled = true;
    scheduleMicrotask(() {
      _queueRefreshScheduled = false;
      if (!_disposed) _maybePrepareNext();
    });
  }

  /// 在 active 开始播放后调用，启动 standby 预热。
  void onPlaybackStarted() {
    _maybePrepareNext();
  }

  void _maybePrepareNext() {
    _prefetchQueuedItems();
    final nextItem = _peekNextQueueItem();
    if (nextItem == null) {
      // 队列空了，清 standby
      if (_standbySlot != null && _standbySlot!.songId != _activeSlot?.songId) {
        _standbySlot = null;
        notifyListeners();
      }
      return;
    }

    final nextId = nextItem.song.id;
    // 如果 standby 已经是同一首且 ready/preparing，不重复准备
    if (_standbySlot != null &&
        _standbySlot!.songId == nextId &&
        (_standbySlot!.isReady || _standbySlot!.state == SlotState.preparing)) {
      return;
    }

    _prepareStandby(nextItem);
  }

  void _prefetchQueuedItems() {
    final cache = _assetCache;
    if (cache == null) return;

    final items = _queueService.items
        .where((item) => !_queueService.isFailed(item.id))
        .toList(growable: false);
    final limit =
        items.length < _prefetchLookahead ? items.length : _prefetchLookahead;
    final nextPrefetchedIds = <String>{
      for (var i = 0; i < limit; i++) items[i].song.id,
    };
    for (final songId in _prefetchedSongIds.difference(nextPrefetchedIds)) {
      if (songId != _activeSlot?.songId) {
        cache.setSongPriority(songId, 4);
      }
    }
    for (var i = 0; i < limit; i++) {
      final song = items[i].song;
      // priority: 0=active, 1=standby, 2+i=queue
      final priority = (i + 1).clamp(1, 3);
      cache.setSongPriority(song.id, priority);
      cache.prefetchPlaybackAssets(song);
    }
    _prefetchedSongIds
      ..clear()
      ..addAll(nextPrefetchedIds);
  }

  // ── 准备 standby ──────────────────────────────────────────────

  Future<void> _prepareStandby(QueueItem item) async {
    final gen = ++_prepGeneration;
    final isExternal = item.song.isExternal;
    final slot = PlaybackSlot(songId: item.song.id)
      ..state = SlotState.preparing
      ..generation = gen
      ..song = item.song
      ..priority = 1; // standby = 1

    final previousStandbyId = _standbySlot?.songId;
    if (previousStandbyId != null &&
        previousStandbyId != item.song.id &&
        previousStandbyId != _activeSlot?.songId) {
      _assetCache?.setSongPriority(previousStandbyId, 4);
    }
    _standbySlot = slot;
    notifyListeners();

    try {
      // 1) 普通曲目和外链 DASH 都进入本次运行周期缓存。
      if (_assetCache != null) {
        _assetCache.validateRequiredPlaybackAssets(item.song);
        _assetCache.setSongPriority(item.song.id, 1);
        // 进度轮询
        unawaited(_pollSlotProgress(slot, gen));
        await _assetCache.ensurePlaybackAssets(item.song);
      }
      if (_isStale(gen)) return;

      // 标记下载完成
      slot.downloadComplete = true;
      slot.downloadedBytes = slot.downloadTotal;
      notifyListeners();

      // 2) 收集本地路径
      slot.videoPath = _pathFor(item.song, MediaAssetType.video);
      slot.vocalPath = _existingPathFor(item.song, MediaAssetType.vocal);
      slot.instPath = _existingPathFor(item.song, MediaAssetType.accompaniment);
      slot.krlPath = isExternal
          ? null
          : (item.song.lyricProject?.cachedPath ??
              _existingPathFor(item.song, MediaAssetType.lyric));

      // 外部歌曲只需 videoPath；普通歌曲需要 video + krl
      if (slot.videoPath == null || (!isExternal && slot.krlPath == null)) {
        slot.state = SlotState.failed;
        slot.error = isExternal ? 'missing video URL' : 'missing media or KRL';
        notifyListeners();
        return;
      }

      if (_isStale(gen)) return;

      slot.state = SlotState.ready;
      notifyListeners();
      debugPrint('PlaybackSlotManager: standby ready for ${item.song.title}');
    } catch (e) {
      if (_isStale(gen)) return;
      slot.state = SlotState.failed;
      slot.error = e.toString();
      notifyListeners();
      _queueService.markFailed(item.id, slot.error!);
      _onQueueAvailabilityChanged?.call();
    }
  }

  // ── 切歌：promote standby → active ────────────────────────────

  /// 切歌热路径。如果 standby ready 且匹配，直接返回准备好的 slot。
  /// 否则返回 null，调用方走 fallback 慢路径。
  PlaybackSlot? consumeStandby(String nextSongId) {
    final standby = _standbySlot;
    if (standby == null) return null;
    if (!standby.isReady) return null;
    if (standby.songId != nextSongId) return null;

    final previousActiveId = _activeSlot?.songId;
    if (previousActiveId != null && previousActiveId != nextSongId) {
      _assetCache?.setSongPriority(previousActiveId, 4);
    }
    _activeSlot = standby;
    _activeSlot!.priority = 0;
    _assetCache?.setSongPriority(_activeSlot!.songId, 0);
    _standbySlot = null;
    notifyListeners();

    // 异步准备新的下一首
    Future.microtask(_maybePrepareNext);

    return _activeSlot;
  }

  // ── fallback：同步创建临时 active slot ─────────────────────────

  /// 当 standby 未就绪时，创建一个标记为 empty 的 active slot。
  /// 调用方之后需要走完整下载+加载流程。
  PlaybackSlot createFallbackActive(String songId, Song song) {
    final previousActiveId = _activeSlot?.songId;
    if (previousActiveId != null && previousActiveId != songId) {
      _assetCache?.setSongPriority(previousActiveId, 4);
    }
    _activeSlot = PlaybackSlot(songId: songId)
      ..song = song
      ..state = SlotState.empty
      ..priority = 0;
    _assetCache?.setSongPriority(songId, 0);
    _standbySlot = null;
    notifyListeners();
    return _activeSlot!;
  }

  // ── helpers ───────────────────────────────────────────────────

  QueueItem? _peekNextQueueItem() {
    return _queueService.nextPlayableItem;
  }

  String? _pathFor(Song song, MediaAssetType type) {
    for (final asset in song.assets) {
      if (asset.type != type) continue;
      final cached = _assetCache?.playbackPathFor(asset);
      if (cached != null) return cached;
      if (asset.cachedPath != null && asset.cachedPath!.isNotEmpty) {
        return asset.cachedPath;
      }
      // HTTP(S) URL 直接返回（外部歌曲流媒体）
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
    for (final asset in song.assets) {
      if (asset.type != type) continue;
      final cached = _assetCache?.existingLocalPathFor(asset);
      if (cached != null) return cached;
      final path = _pathFor(song, type);
      if (path == null || !File(path).existsSync()) return null;
      return path;
    }
    return null;
  }

  bool _isStale(int generation) =>
      generation != _prepGeneration || _standbySlot?.generation != generation;

  Future<void> _pollSlotProgress(PlaybackSlot slot, int generation) async {
    final cache = _assetCache;
    if (cache == null || slot.song == null) return;
    while (!_isStale(generation) && slot.state == SlotState.preparing) {
      await Future.delayed(const Duration(milliseconds: 200));
      final song = slot.song!;
      final progress = cache.songProgress(song);
      slot.downloadTotal = progress.total;
      slot.downloadedBytes = progress.downloaded;
      slot.downloadComplete = progress.complete;
      if (slot.downloadTotal > 0 || slot.downloadedBytes > 0) {
        notifyListeners();
      }
    }
  }
}
