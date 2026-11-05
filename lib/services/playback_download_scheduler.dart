import 'dart:async';
import 'dart:convert';

import '../domain/song.dart';

/// 为当前首、下一首和后续缓存分别调度。后排补位按五秒间隔逐首放行。
class PlaybackDownloadScheduler {
  PlaybackDownloadScheduler({
    required Future<void> Function(Song) download,
    required bool Function(Song) isCached,
    required void Function(String, int) setPriority,
    required void Function(Song, Object) onFailure,
  })  : _download = download,
        _isCached = isCached,
        _setPriority = setPriority,
        _onFailure = onFailure;

  static const refillDelay = Duration(seconds: 5);

  final Future<void> Function(Song) _download;
  final bool Function(Song) _isCached;
  final void Function(String, int) _setPriority;
  final void Function(Song, Object) _onFailure;
  final Map<String, _DownloadJob> _jobs = {};
  List<String> _queuedKeys = const [];
  String? _activeKey;
  int _lookahead = 3;
  Timer? _refillTimer;
  bool _disposed = false;

  // 同一组资源的重复点播共用下载，版本和地址参与任务身份。
  static String identityOf(Song song) => jsonEncode([
        song.id,
        for (final asset in song.assets)
          [asset.id, asset.type.name, asset.version, asset.uri.toString()],
      ]);

  void update({
    required Iterable<Song> queuedSongs,
    required Song? activeSong,
    required int lookahead,
  }) {
    if (_disposed) return;
    _lookahead = lookahead.clamp(1, 3).toInt();
    _activeKey = activeSong == null ? null : identityOf(activeSong);
    final queued = <String, Song>{};
    for (final song in queuedSongs) {
      queued.putIfAbsent(identityOf(song), () => song);
    }
    _queuedKeys = queued.keys.toList(growable: false);
    final wanted = {...queued};
    if (activeSong != null) wanted[_activeKey!] = activeSong;
    _jobs.removeWhere((key, job) =>
        !wanted.containsKey(key) && job.state != _DownloadJobState.running);
    for (final entry in wanted.entries) {
      final job = _jobs.putIfAbsent(
        entry.key,
        () => _DownloadJob(
            entry.value,
            _isCached(entry.value)
                ? _DownloadJobState.complete
                : _DownloadJobState.waiting),
      );
      job.song = entry.value;
    }
    _updatePriorities();

    // 起播和真正下一首的准备始终绕过后台冷却；只复用资源下载，不预载后排。
    final active = _jobs[_activeKey];
    if (active != null) _start(active);
    if (_queuedKeys.isNotEmpty) _start(_jobs[_queuedKeys.first]!);
    _scheduleRefill();
  }

  void _updatePriorities() {
    final priorities = <String, int>{};
    final ranks = {
      for (var i = 0; i < _queuedKeys.length; i++) _queuedKeys[i]: i + 1,
    };
    for (final entry in _jobs.entries) {
      final priority = entry.key == _activeKey
          ? 0
          : ranks[entry.key]?.clamp(1, 3).toInt() ?? 4;
      final id = entry.value.song.id;
      final previous = priorities[id];
      if (previous == null || priority < previous) priorities[id] = priority;
    }
    for (final entry in priorities.entries) {
      _setPriority(entry.key, entry.value);
    }
  }

  int get _queuedRunning => _jobs.entries
      .where((entry) =>
          entry.key != _activeKey &&
          entry.value.state == _DownloadJobState.running)
      .length;

  _DownloadJob? get _nextWaiting {
    for (final key in _queuedKeys) {
      if (key == _activeKey) continue;
      final job = _jobs[key]!;
      if (job.state == _DownloadJobState.waiting) return job;
    }
    return null;
  }

  void _scheduleRefill() {
    if (_disposed || _queuedRunning >= _lookahead || _nextWaiting == null) {
      _refillTimer?.cancel();
      _refillTimer = null;
      return;
    }
    _refillTimer ??= Timer(refillDelay, () {
      _refillTimer = null;
      if (_disposed) return;
      // 已缓存项不消耗一轮冷却；一次只启动一首真正需要下载的歌曲。
      while (_queuedRunning < _lookahead) {
        final job = _nextWaiting;
        if (job == null) break;
        if (_isCached(job.song)) {
          job.state = _DownloadJobState.complete;
          continue;
        }
        _start(job);
        break;
      }
      _scheduleRefill();
    });
  }

  void _start(_DownloadJob job) {
    if (job.state != _DownloadJobState.waiting) return;
    job.state = _DownloadJobState.running;
    unawaited(Future<void>.sync(() => _download(job.song)).then(
      (_) => _settled(job, null),
      onError: (Object error, StackTrace _) => _settled(job, error),
    ));
  }

  void _settled(_DownloadJob job, Object? error) {
    if (_disposed) return;
    job.state =
        error == null ? _DownloadJobState.complete : _DownloadJobState.failed;
    if (error != null) _onFailure(job.song, error);
    // 每次完整结束后重新留足五秒。已有下载继续运行，完成事件合并到此计时器。
    _refillTimer?.cancel();
    _refillTimer = null;
    _scheduleRefill();
  }

  void dispose() {
    _disposed = true;
    _refillTimer?.cancel();
    _refillTimer = null;
    _jobs.clear();
    _queuedKeys = const [];
  }
}

enum _DownloadJobState { waiting, running, complete, failed }

class _DownloadJob {
  _DownloadJob(this.song, this.state);

  Song song;
  _DownloadJobState state;
}
