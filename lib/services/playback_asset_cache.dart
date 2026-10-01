import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../domain/media_asset.dart';
import '../domain/song.dart';
import 'media_stream_pump.dart';
import 'playback_media_io_worker.dart';
import 'windows_native_media_io.dart';

/// 播放周期缓存 — 下载歌曲媒体文件到本地临时目录。
///
/// 切歌或 App 退出时调用 [clear] 清理。
class PlaybackAssetCache extends ChangeNotifier {
  PlaybackAssetCache({
    required String baseUrl,
    Directory? cacheDir,
    Directory? cacheRoot,
    http.Client? httpClient,
    http.Client? mediaHttpClient,
    Duration retryDelay = const Duration(milliseconds: 500),
    int maxAutomaticRetries = 5,
    int videoReadyBytes = 512 * 1024,
    bool enableNativeMediaIo = true,
    bool debugMediaIo = false,
  })  : assert(cacheDir == null || cacheRoot == null),
        assert(maxAutomaticRetries >= 0),
        assert(videoReadyBytes > 0),
        _baseUri = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
        _cacheDir = cacheDir ?? _createSessionCacheDirectory(cacheRoot),
        _http = httpClient ?? http.Client(),
        _mediaHttp = mediaHttpClient ?? http.Client(),
        _retryDelay = retryDelay,
        _maxAutomaticRetries = maxAutomaticRetries,
        _videoReadyBytes = videoReadyBytes {
    if (httpClient == null && mediaHttpClient == null) {
      _mediaIoWorker = PlaybackMediaIoWorker(
        onServerMetrics: _ioMetrics.addWorkerServerMetrics,
      );
      if (Platform.isWindows && enableNativeMediaIo) {
        _nativeMediaIo = WindowsNativeMediaIo(debugLogging: debugMediaIo);
      }
    }
  }

  static Directory _createSessionCacheDirectory(Directory? cacheRoot) {
    final root = cacheRoot ??
        Directory(p.join(Directory.systemTemp.path, 'Kirakara_Cache'));
    final directory = Directory(
      p.join(root.path, 'session_$pid'),
    );
    // A PID can be reused after an abnormal exit. The Windows runner also
    // removes abandoned session directories, but clearing our own path here
    // keeps this constructor safe on every platform.
    if (directory.existsSync()) {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // If another resource is still releasing, creation below can reuse the
        // directory and the runner will perform the final cleanup on exit.
      }
    }
    directory.createSync(recursive: true);
    _writeSessionMarker(directory);
    return directory;
  }

  static void _writeSessionMarker(Directory directory) {
    try {
      File(
        p.join(
          Directory.systemTemp.path,
          'kirakara_cache_session_$pid.path',
        ),
      ).writeAsStringSync(directory.absolute.path, flush: true);
    } on FileSystemException {
      // Dart cleanup still runs; the Windows runner marker is an extra guard.
    }
  }

  static void _deleteSessionMarker() {
    try {
      final marker = File(
        p.join(
          Directory.systemTemp.path,
          'kirakara_cache_session_$pid.path',
        ),
      );
      if (marker.existsSync()) marker.deleteSync();
    } on FileSystemException {
      // The native runner also removes the marker after engine shutdown.
    }
  }

  final Uri _baseUri;
  final Directory _cacheDir;
  final http.Client _http;
  final http.Client _mediaHttp;
  final Duration _retryDelay;
  final int _maxAutomaticRetries;
  final int _videoReadyBytes;
  final Map<String, Future<void>> _downloads = {};
  final Map<String, MediaAsset> _streamAssets = {};
  final Map<String, _DownloadState> _downloadStates = {};
  final Map<String, int> _songPriorities = {};
  final _AsyncPreemptivePermitPool _downloadConnectionPool =
      _AsyncPreemptivePermitPool(15);
  final _PlaybackAssetIoMetrics _ioMetrics = _PlaybackAssetIoMetrics();
  PlaybackMediaIoWorker? _mediaIoWorker;
  WindowsNativeMediaIo? _nativeMediaIo;
  int? _workerStreamPort;
  Future<int>? _workerStreamServerFuture;
  HttpServer? _streamServer;
  Future<HttpServer>? _streamServerFuture;
  bool _disposed = false;

  String get cacheDirectoryPath => _cacheDir.path;

  /// Current-process counters for diagnosing media I/O overhead.
  ///
  /// The snapshot is never persisted and contains no URLs, cookies, headers,
  /// account data, or file names. Reading it does not notify listeners.
  PlaybackAssetIoDiagnostics get ioDiagnostics => _ioMetrics.snapshot();

  /// Emits one explicitly requested diagnostics sample in debug builds.
  void debugLogIoDiagnostics() {
    assert(() {
      debugPrint('[playback-io] $ioDiagnostics');
      return true;
    }());
  }

  Future<int> cacheSizeBytes() async {
    if (!await _cacheDir.exists()) return 0;
    var total = 0;
    await for (final entity in _cacheDir.list(recursive: true)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // A progressive file may be moving from .part while we inspect it.
        }
      }
    }
    return total;
  }

  /// 确保歌曲全部 assets 完整下载。完成后回填 [MediaAsset.cachedPath] 和
  /// [song.lyricProject.cachedPath]。
  Future<void> ensureSongAssets(Song song) async {
    _songPriorities.putIfAbsent(song.id, () => 0);
    await Future.wait(
      song.assets
          .where(_isPlaybackAsset)
          .map((asset) => _ensureOne(song.id, asset)),
    );
    for (final cover in song.assets.where(_isOptionalAsset)) {
      _startBackgroundDownload(song.id, cover, required: false);
    }
    _syncLyricProject(song);
  }

  /// 播放前准备：KRL 等小资源和音频完整缓存；视频同时启动后台渐进缓存。
  ///
  /// 当前 Show 音频链路仍需要先拿到完整音频再解码，因此 vocal/inst 仍然
  /// 会被等待。视频只有在尚未完整落盘时才注册本机渐进缓存入口。
  Future<void> ensurePlaybackAssets(
    Song song, {
    bool awaitAudio = true,
  }) async {
    _songPriorities.putIfAbsent(song.id, () => 0);
    final blocking = <Future<void>>[];
    final videos = <MediaAsset>[];
    for (final asset in song.assets) {
      if (_isOptionalAsset(asset)) {
        _startBackgroundDownload(song.id, asset, required: false);
        continue;
      }
      if (!_isPlaybackAsset(asset)) continue;
      if (asset.type == MediaAssetType.video) {
        videos.add(asset);
        final availability = _downloadStateFor(asset).whenAvailable;
        _startBackgroundDownload(song.id, asset, background: true);
        blocking.add(availability);
      } else if (_isAudio(asset.type)) {
        final task = _ensureOne(song.id, asset);
        if (awaitAudio) {
          blocking.add(task);
        } else {
          unawaited(task);
        }
      } else {
        blocking.add(_ensureOne(song.id, asset));
      }
    }
    final streamVideos = videos
        .where((asset) => existingLocalPathFor(asset) == null)
        .toList(growable: false);
    if (streamVideos.isNotEmpty) {
      await _ensureStreamServer();
      await Future.wait(streamVideos.map(_prepareStreamAsset));
    }
    await Future.wait(blocking);
    _syncLyricProject(song);
  }

  /// 队列预热用：歌词、原唱、伴奏和视频都并发启动下载，调用方不等待。
  ///
  /// 这个方法不等待音频完成，专门给“队列里后续歌曲”提前占坑。播放真正
  /// 落到这首歌时，[ensurePlaybackAssets] 会复用同一个下载任务并等待
  /// 音频/KRL 等必要资源完整落盘。
  void prefetchPlaybackAssets(Song song) {
    _songPriorities.putIfAbsent(song.id, () => 2);
    final videos = <MediaAsset>[];
    for (final asset in song.assets) {
      if (!_isPlaybackAsset(asset) && !_isOptionalAsset(asset)) continue;
      if (asset.type == MediaAssetType.video) {
        videos.add(asset);
      }
      _startBackgroundDownload(
        song.id,
        asset,
        background: true,
        required: _isPlaybackAsset(asset),
      );
    }
    final streamVideos = videos
        .where((asset) => existingLocalPathFor(asset) == null)
        .toList(growable: false);
    if (streamVideos.isNotEmpty) {
      unawaited(_ensureStreamServer().then(
        (_) => Future.wait(streamVideos.map(_prepareStreamAsset)),
      ));
    }
  }

  /// 队列预热用：所有资源并发启动下载，调用方不等待。
  void prefetchSongAssets(Song song) {
    prefetchPlaybackAssets(song);
  }

  /// 设置歌曲下载优先级：0=当前播放，1=standby，数值越大越靠后。
  ///
  /// 只要 15 连接池尚未占满，不同歌曲及其全部资源都会同时请求、持续拉取
  /// 并写盘。池满后优先级才参与排队；提权会抢占最新、最低优先级连接，
  /// 被抢占资源保留 `.part` 并稍后 Range 续传。
  void setSongPriority(String songId, int priority) {
    _songPriorities[songId] = priority < 0 ? 0 : priority;
    _downloadConnectionPool.prioritiesChanged();
  }

  void validateRequiredPlaybackAssets(Song song) {
    final availableTypes = song.assets.map((asset) => asset.type).toSet();
    final requiredTypes = song.isExternal
        ? const [MediaAssetType.video]
        : const [
            MediaAssetType.video,
            MediaAssetType.vocal,
            MediaAssetType.accompaniment,
            MediaAssetType.lyric,
          ];
    final missing = requiredTypes
        .where((type) => !availableTypes.contains(type))
        .map(_assetTypeLabel)
        .toList(growable: false);
    if (missing.isEmpty) return;
    throw PlaybackAssetDownloadException(
      songId: song.id,
      message: '缺少播放必需资源：${missing.join('、')}',
    );
  }

  void resetFailuresForSong(Song song) {
    for (final asset in song.assets) {
      _downloadStateFor(asset).resetFailure();
    }
    _notifyProgressListeners();
  }

  /// 歌曲所有已知 asset 是否已完整缓存。
  bool isSongFullyCached(Song song) {
    final playbackAssets = song.assets.where(_isPlaybackAsset).toList();
    if (playbackAssets.isEmpty) return true;
    for (final asset in playbackAssets) {
      final local = existingLocalPathFor(asset);
      if (local == null) return false;
    }
    // 没有正在进行的下载
    final inProgress = _downloads.keys.any(
      (key) => playbackAssets.any((asset) => key.startsWith('${asset.id}|')),
    );
    return !inProgress;
  }

  /// 歌曲级聚合下载进度。
  ({int total, int downloaded, bool complete}) songProgress(Song song) {
    var total = 0;
    var downloaded = 0;
    var complete = true;
    for (final asset in song.assets.where(_isPlaybackAsset)) {
      final p = _progressForAsset(asset);
      if (p.totalBytes != null) total += p.totalBytes!;
      downloaded += p.downloadedBytes;
      if (!p.isComplete) complete = false;
    }
    return (total: total, downloaded: downloaded, complete: complete);
  }

  /// 播放时优先返回完整缓存/本地文件；没有完整缓存时返回可流式读取的 HTTP URL。
  /// 视频统一走本地流服务器（即使已完整缓存），避免 MF 引擎直接读文件时
  /// 的文件系统瓶颈和缓冲不足问题。
  String? playbackPathFor(MediaAsset asset) {
    if (asset.type == MediaAssetType.video) {
      final streamUrl = _localStreamUrlFor(asset);
      if (streamUrl != null) return streamUrl;
      return _remoteUrlFor(asset);
    }
    final local = existingLocalPathFor(asset);
    if (local != null) return local;
    return _remoteUrlFor(asset);
  }

  /// 只返回已经完整存在的本地文件。音频和 KRL 当前需要走这里。
  String? existingLocalPathFor(MediaAsset asset) {
    final cached = asset.cachedPath;
    if (cached != null && cached.isNotEmpty && File(cached).existsSync()) {
      return cached;
    }
    if (asset.uri.isScheme('file')) {
      final path = asset.uri.toFilePath(windows: Platform.isWindows);
      return File(path).existsSync() ? path : null;
    }
    final local = _localPathFor(asset);
    if (File(local).existsSync()) {
      asset.cachedPath = local;
      return local;
    }
    return null;
  }

  PlaybackAssetProgress progressForSong(Song song) {
    var totalBytes = 0;
    var downloadedBytes = 0;
    var knownAssets = 0;
    var completeAssets = 0;
    var failedAssets = 0;
    var bytesPerSecond = 0.0;
    String? errorMessage;

    final assets = song.assets.where(_isPlaybackAsset).toList(growable: false);
    for (final asset in assets) {
      final progress = _progressForAsset(asset);
      if (progress.totalBytes != null && progress.totalBytes! > 0) {
        totalBytes += progress.totalBytes!;
        knownAssets++;
      }
      downloadedBytes += progress.downloadedBytes;
      bytesPerSecond += progress.bytesPerSecond;
      if (progress.isComplete) completeAssets++;
      if (progress.isFailed) {
        failedAssets++;
        errorMessage ??= progress.errorMessage;
      }
    }

    return PlaybackAssetProgress(
      totalBytes: totalBytes,
      downloadedBytes: totalBytes > 0
          ? downloadedBytes.clamp(0, totalBytes).toInt()
          : downloadedBytes,
      bytesPerSecond: bytesPerSecond,
      knownAssets: knownAssets,
      completeAssets: completeAssets,
      assetCount: assets.length,
      failedAssets: failedAssets,
      errorMessage: errorMessage,
    );
  }

  void _syncLyricProject(Song song) {
    final lp = song.lyricProject;
    if (lp != null) {
      for (final a in song.assets) {
        if (a.type == MediaAssetType.lyric && a.cachedPath != null) {
          lp.cachedPath = a.cachedPath;
          break;
        }
      }
    }
  }

  Future<void> _ensureOne(
    String songId,
    MediaAsset asset, {
    bool background = false,
    bool required = true,
  }) {
    final state = _downloadStateFor(asset);
    final previousError = state.error;
    if (previousError != null) return Future<void>.error(previousError);

    // 已有有效本地文件，跳过
    if (asset.cachedPath != null && asset.cachedPath!.isNotEmpty) {
      final f = File(asset.cachedPath!);
      if (f.existsSync()) {
        state.markAvailable();
        return Future.value();
      }
    }

    // A completed progressive video can remain as `.part` while Media
    // Foundation still has the file open. Treat it as a finished cache entry
    // and retry the cosmetic rename without issuing another HTTP request.
    final completedPart = _completedPartFor(asset);
    if (completedPart != null) {
      return _promoteCompletedPart(asset, completedPart);
    }

    // 本地 file:// 无需下载
    if (asset.uri.isScheme('file')) {
      final path = asset.uri.toFilePath(windows: Platform.isWindows);
      if (File(path).existsSync()) {
        asset.cachedPath = path;
        state.markAvailable();
        return Future.value();
      }
      return _failWithoutDownload(
        state,
        PlaybackAssetDownloadException(
          songId: songId,
          assetType: asset.type,
          message: '本地播放资源不存在：$path',
        ),
      );
    }

    final url = _remoteUrlFor(asset);
    if (url == null) {
      return _failWithoutDownload(
        state,
        PlaybackAssetDownloadException(
          songId: songId,
          assetType: asset.type,
          message: '播放资源地址无效',
        ),
      );
    }

    final localPath = _localPathFor(asset);
    final key = '${asset.id}|${asset.type.name}|${asset.version}|$url';
    final active = _downloads[key];
    if (active != null) {
      return active.then((_) => _hydrateCachedAsset(asset, localPath));
    }

    late final Future<void> future;
    future = _ensureOneDownload(
      songId: songId,
      url: url,
      localPath: localPath,
      asset: asset,
      client: background ? _mediaHttp : _http,
      required: required,
    ).whenComplete(() {
      if (identical(_downloads[key], future)) {
        _downloads.remove(key);
      }
    });
    _downloads[key] = future;
    return future;
  }

  Future<void> _ensureOneDownload({
    required String songId,
    required String url,
    required String localPath,
    required MediaAsset asset,
    required http.Client client,
    required bool required,
  }) async {
    if (await _hydrateCachedAsset(asset, localPath)) return;

    var retries = 0;
    while (!_disposed) {
      var retryAfterFailure = false;
      final connectionLease = await _downloadConnectionPool.acquire(
        priority: () => _songPriorities[songId] ?? 2,
      );
      _ioMetrics.connectionOpened();
      try {
        if (_disposed) return;
        if (await _hydrateCachedAsset(asset, localPath)) return;
        _downloadStateFor(asset).lastError = null;
        final result = await _downloadToCache(
          url,
          localPath,
          asset,
          client: client,
          connectionLease: connectionLease,
        );
        if (result == _DownloadAttemptResult.finished) return;
        if (result == _DownloadAttemptResult.failed) {
          retryAfterFailure = true;
          final state = _downloadStateFor(asset);
          final error = state.lastError ??
              PlaybackAssetDownloadException(
                songId: songId,
                assetType: asset.type,
                message: '下载失败',
              );
          if (retries >= (required ? _maxAutomaticRetries : 0)) {
            state.markFailed(error);
            _notifyProgressListeners();
            throw error;
          }
          retries++;
        }
      } finally {
        _ioMetrics.connectionClosed();
        connectionLease.release();
      }
      if (retryAfterFailure) {
        await Future<void>.delayed(_retryDelay);
      } else {
        // Preemption does not consume a retry. Preserve `.part` and re-enter
        // the priority queue immediately for an HTTP Range continuation.
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  void _startBackgroundDownload(
    String songId,
    MediaAsset asset, {
    bool background = false,
    bool required = true,
  }) {
    unawaited(
      _ensureOne(
        songId,
        asset,
        background: background,
        required: required,
      ).catchError((Object _) {}),
    );
  }

  Future<void> _failWithoutDownload(
    _DownloadState state,
    PlaybackAssetDownloadException error,
  ) {
    state.markFailed(error);
    _notifyProgressListeners();
    return Future<void>.error(error);
  }

  Future<bool> _hydrateCachedAsset(
    MediaAsset asset,
    String localPath,
  ) async {
    final localFile = File(localPath);
    if (!await localFile.exists()) return false;
    asset.cachedPath = localPath;
    final state = _downloadStateFor(asset);
    state.totalLength = await localFile.length();
    state.downloadedBytes = state.totalLength ?? 0;
    state.persistedBytes = state.downloadedBytes;
    state.complete = true;
    state.markAvailable();
    return true;
  }

  String? _remoteUrlFor(MediaAsset asset) {
    if (asset.uri.isScheme('http') || asset.uri.isScheme('https')) {
      return asset.uri.toString();
    }
    if (asset.uri.hasScheme) return null;
    return _baseUri.resolveUri(asset.uri).toString();
  }

  String _localPathFor(MediaAsset asset) {
    final ext = p.extension(asset.uri.path).isEmpty
        ? '.bin'
        : p.extension(asset.uri.path);
    final safeId = asset.id.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]+'), '_');
    return p.join(
      _cacheDir.path,
      '${safeId}_${asset.type.name}_v${asset.version}$ext',
    );
  }

  Future<_DownloadAttemptResult> _downloadToCache(
    String url,
    String localPath,
    MediaAsset asset, {
    required http.Client client,
    required _PreemptiblePermitLease connectionLease,
  }) async {
    final native = _nativeMediaIo;
    if (native != null && await native.isAvailable()) {
      final nativeResult = await _downloadToCacheNative(
        native: native,
        url: url,
        localPath: localPath,
        asset: asset,
        connectionLease: connectionLease,
      );
      if (nativeResult != null) return nativeResult;
    }
    final worker = _mediaIoWorker;
    if (worker != null) {
      return _downloadToCacheInWorker(
        worker: worker,
        url: url,
        localPath: localPath,
        asset: asset,
        connectionLease: connectionLease,
      );
    }
    try {
      if (connectionLease.preemptRequested) {
        return _DownloadAttemptResult.preempted;
      }
      final localFile = File(localPath);
      final partFile = File('$localPath.part');
      final state = _downloadStateFor(asset);
      await localFile.parent.create(recursive: true);

      var existingBytes = await partFile.exists() ? await partFile.length() : 0;
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(asset.headers);
      if (existingBytes > 0) {
        request.headers[HttpHeaders.rangeHeader] = 'bytes=$existingBytes-';
      }

      final response = await client.send(request);
      if (connectionLease.preemptRequested) {
        await response.stream.listen((_) {}).cancel();
        return _DownloadAttemptResult.preempted;
      }
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await response.stream.drain<void>();
        if (existingBytes > 0) {
          state.complete = true;
          state.totalLength = existingBytes;
          state.downloadedBytes = state.totalLength ?? 0;
          state.persistedBytes = state.downloadedBytes;
          state.markAvailable();
          _notifyProgressListeners();
          await _promoteCompletedPart(asset, partFile);
          return _DownloadAttemptResult.finished;
        }
        state.lastError = PlaybackAssetDownloadException(
          assetType: asset.type,
          statusCode: response.statusCode,
          message: '服务器拒绝了空文件续传请求',
        );
        return _DownloadAttemptResult.failed;
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        await response.stream.drain<void>();
        state.lastError = PlaybackAssetDownloadException(
          assetType: asset.type,
          statusCode: response.statusCode,
          message: '服务器返回 HTTP ${response.statusCode}',
        );
        return _DownloadAttemptResult.failed;
      }

      state.lastError = null;

      final append =
          response.statusCode == HttpStatus.partialContent && existingBytes > 0;
      if (!append) {
        existingBytes = 0;
      }

      state.totalLength = _expectedLength(response, existingBytes);
      state.downloadedBytes = existingBytes;
      state.persistedBytes = existingBytes;
      state.complete = false;
      state.markSample(existingBytes);
      if (existingBytes >= _readyThresholdFor(asset, state.totalLength)) {
        state.markAvailable();
      }
      _notifyProgressListeners();

      final writer = await partFile.open(
        mode: append ? FileMode.append : FileMode.write,
      );
      late final MediaStreamPumpResult pumpResult;
      try {
        final pump = MediaStreamPump(
          stream: response.stream,
          writer: writer,
          onReceived: (length) {
            _ioMetrics.receivedChunk(length);
            state.downloadedBytes += length;
          },
          onPersisted: (length) {
            _ioMetrics.writeCompleted(length);
            state.persistedBytes += length;
            state.markSample(state.persistedBytes);
            if (!state.available &&
                state.persistedBytes >=
                    _readyThresholdFor(asset, state.totalLength)) {
              state.markAvailable();
            }
            _notifyProgressListeners();
          },
          onBufferedBytesChanged: _ioMetrics.bufferedBytesChanged,
        );
        _ioMetrics.preemptionHandlerRegistered();
        connectionLease.setPreemptHandler(() {
          _ioMetrics.preemptionRequested();
          pump.cancel();
        });
        if (connectionLease.preemptRequested) pump.cancel();
        pumpResult = await pump.run();
        connectionLease.clearPreemptHandler();
      } finally {
        connectionLease.clearPreemptHandler();
        await writer.close();
      }
      if (pumpResult == MediaStreamPumpResult.cancelled) {
        return _DownloadAttemptResult.preempted;
      }

      final expectedLength = _expectedLength(response, existingBytes);
      final actualLength = await partFile.length();
      if (expectedLength == null || actualLength >= expectedLength) {
        // Completion is defined by bytes on disk, not by whether Windows lets
        // us rename a file that MF is currently reading. Mark it complete
        // first so the queue cannot get stuck at 100% or download it twice.
        state.complete = true;
        state.totalLength = actualLength;
        state.downloadedBytes = actualLength;
        state.persistedBytes = actualLength;
        state.markAvailable();
        state.markSample(actualLength);
        _notifyProgressListeners();
        await _promoteCompletedPart(asset, partFile);
        return _DownloadAttemptResult.finished;
      }
      state.lastError = PlaybackAssetDownloadException(
        assetType: asset.type,
        message: '下载提前结束：$actualLength/$expectedLength bytes',
      );
      return _DownloadAttemptResult.failed;
    } catch (error) {
      _downloadStateFor(asset).lastError = PlaybackAssetDownloadException(
        assetType: asset.type,
        message: '下载连接失败：$error',
      );
      return connectionLease.preemptRequested
          ? _DownloadAttemptResult.preempted
          : _DownloadAttemptResult.failed;
    }
  }

  Future<_DownloadAttemptResult?> _downloadToCacheNative({
    required WindowsNativeMediaIo native,
    required String url,
    required String localPath,
    required MediaAsset asset,
    required _PreemptiblePermitLease connectionLease,
  }) async {
    final state = _downloadStateFor(asset);
    if (connectionLease.preemptRequested) {
      return _DownloadAttemptResult.preempted;
    }
    final operation = await native.startDownload(
      url: url,
      localPath: localPath,
      headers: asset.headers,
      readyBytes: _videoReadyBytes,
      isVideo: asset.type == MediaAssetType.video,
      onProgress: (progress) {
        _applyIoProgress(state, progress);
        if (asset.type == MediaAssetType.video) {
          _mediaIoWorker?.updateStreamAssetState(
            localPath: localPath,
            totalLength: progress.totalLength,
            persistedBytes: progress.persistedBytes,
            producerActive: true,
          );
        }
      },
    );
    if (operation == null) return null;
    _mediaIoWorker?.updateStreamAssetState(
      localPath: localPath,
      totalLength: state.totalLength,
      persistedBytes: state.persistedBytes,
      producerActive: true,
    );
    try {
      _ioMetrics.preemptionHandlerRegistered();
      connectionLease.setPreemptHandler(() {
        _ioMetrics.preemptionRequested();
        operation.cancel();
      });
      if (connectionLease.preemptRequested) operation.cancel();
      final result = await operation.result;
      _ioMetrics.addWorkerDownloadResult(result);
      return _applyIoResult(
        result: result,
        state: state,
        localPath: localPath,
        asset: asset,
      );
    } catch (error) {
      state.lastError = PlaybackAssetDownloadException(
        assetType: asset.type,
        message: 'Windows 原生下载连接失败：$error',
      );
      return _DownloadAttemptResult.failed;
    } finally {
      connectionLease.clearPreemptHandler();
      _mediaIoWorker?.updateStreamAssetState(
        localPath: localPath,
        totalLength: state.totalLength,
        persistedBytes: state.persistedBytes,
        producerActive: false,
      );
    }
  }

  Future<_DownloadAttemptResult> _downloadToCacheInWorker({
    required PlaybackMediaIoWorker worker,
    required String url,
    required String localPath,
    required MediaAsset asset,
    required _PreemptiblePermitLease connectionLease,
  }) async {
    final state = _downloadStateFor(asset);
    try {
      if (connectionLease.preemptRequested) {
        return _DownloadAttemptResult.preempted;
      }
      state.lastError = null;
      state.complete = false;
      final operation = await worker.startDownload(
        url: url,
        localPath: localPath,
        headers: asset.headers,
        readyBytes: _videoReadyBytes,
        isVideo: asset.type == MediaAssetType.video,
        onProgress: (progress) {
          _applyIoProgress(state, progress);
        },
      );
      _ioMetrics.preemptionHandlerRegistered();
      connectionLease.setPreemptHandler(() {
        _ioMetrics.preemptionRequested();
        operation.cancel();
      });
      if (connectionLease.preemptRequested) operation.cancel();
      final result = await operation.result;
      connectionLease.clearPreemptHandler();
      _ioMetrics.addWorkerDownloadResult(result);
      return _applyIoResult(
        result: result,
        state: state,
        localPath: localPath,
        asset: asset,
      );
    } catch (error) {
      state.lastError = PlaybackAssetDownloadException(
        assetType: asset.type,
        message: '下载连接失败：$error',
      );
      return connectionLease.preemptRequested
          ? _DownloadAttemptResult.preempted
          : _DownloadAttemptResult.failed;
    } finally {
      connectionLease.clearPreemptHandler();
    }
  }

  void _applyIoProgress(
    _DownloadState state,
    MediaIoWorkerProgress progress,
  ) {
    state.totalLength = progress.totalLength;
    state.downloadedBytes = progress.downloadedBytes;
    state.persistedBytes = progress.persistedBytes;
    state.markSample(progress.persistedBytes);
    if (progress.available) state.markAvailable();
    _notifyProgressListeners();
  }

  Future<_DownloadAttemptResult> _applyIoResult({
    required MediaIoWorkerAttemptResult result,
    required _DownloadState state,
    required String localPath,
    required MediaAsset asset,
  }) async {
    switch (result.status) {
      case MediaIoWorkerAttemptStatus.preempted:
        return _DownloadAttemptResult.preempted;
      case MediaIoWorkerAttemptStatus.failed:
        state.lastError = PlaybackAssetDownloadException(
          assetType: asset.type,
          statusCode: result.statusCode,
          message: result.errorMessage ?? '下载失败',
        );
        return _DownloadAttemptResult.failed;
      case MediaIoWorkerAttemptStatus.finished:
        final actualLength = result.actualLength;
        if (actualLength <= 0) {
          state.lastError = PlaybackAssetDownloadException(
            assetType: asset.type,
            message: '下载完成但文件为空',
          );
          return _DownloadAttemptResult.failed;
        }
        state.complete = true;
        state.totalLength = actualLength;
        state.downloadedBytes = actualLength;
        state.persistedBytes = actualLength;
        state.markAvailable();
        state.markSample(actualLength);
        _notifyProgressListeners();
        _mediaIoWorker?.updateStreamAssetState(
          localPath: localPath,
          totalLength: actualLength,
          persistedBytes: actualLength,
          producerActive: false,
        );
        await _promoteCompletedPart(asset, File('$localPath.part'));
        return _DownloadAttemptResult.finished;
    }
  }

  Future<void> _ensureStreamServer() async {
    final worker = _mediaIoWorker;
    if (worker != null) {
      final pending = _workerStreamServerFuture ??= worker.ensureServer();
      _workerStreamPort = await pending;
      return;
    }
    final server = _streamServer;
    if (server != null) return;
    final pending = _streamServerFuture;
    if (pending != null) {
      await pending;
      return;
    }

    final future = HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((s) {
      _streamServer = s;
      s.listen(_handleStreamRequest);
      return s;
    });
    _streamServerFuture = future;
    await future;
  }

  String? _localStreamUrlFor(MediaAsset asset) {
    final port =
        _mediaIoWorker != null ? _workerStreamPort : _streamServer?.port;
    if (port == null) return null;
    final token = _registerStreamAsset(asset);
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: port,
      pathSegments: ['cache', token],
    ).toString();
  }

  String _registerStreamAsset(MediaAsset asset) {
    final token = Uri.encodeComponent(
      '${asset.id}_${asset.type.name}_v${asset.version}',
    );
    _streamAssets[token] = asset;
    return token;
  }

  Future<void> _prepareStreamAsset(MediaAsset asset) async {
    final token = _registerStreamAsset(asset);
    final worker = _mediaIoWorker;
    if (worker == null) return;
    final url = _remoteUrlFor(asset);
    if (url == null) return;
    await worker.registerStreamAsset(
      token: token,
      localPath: _localPathFor(asset),
      url: url,
      headers: asset.headers,
    );
    final state = _downloadStateFor(asset);
    worker.updateStreamAssetState(
      localPath: _localPathFor(asset),
      totalLength: state.totalLength,
      persistedBytes: state.persistedBytes,
      producerActive: !state.complete && !state.failed,
    );
  }

  Future<void> _handleStreamRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      if (request.uri.pathSegments.length != 2 ||
          request.uri.pathSegments.first != 'cache') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final token = request.uri.pathSegments[1];
      final asset = _streamAssets[token];
      if (asset == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      // 不在此触发下载——视频下载由 ensurePlaybackAssets 统一管理

      final totalLength = await _waitForTotalLength(asset);
      if (totalLength == null || totalLength <= 0) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.headers.set(HttpHeaders.retryAfterHeader, '1');
        await request.response.close();
        return;
      }

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final range = rangeHeader == null
          ? (start: 0, end: totalLength - 1, partial: false)
          : _parseRequestRange(rangeHeader, totalLength);
      if (range == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */$totalLength');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        await request.response.close();
        return;
      }

      if (await _shouldProxyRemote(asset, range.start)) {
        await _proxyRemoteRange(
          request: request,
          asset: asset,
          rangeHeader: rangeHeader,
        );
        return;
      }

      final contentLength = range.end - range.start + 1;
      final contentType = _contentTypeFor(asset.uri.path);
      request.response.statusCode =
          range.partial ? HttpStatus.partialContent : HttpStatus.ok;
      request.response.headers.contentType = ContentType.parse(contentType);
      request.response.headers.contentLength = contentLength;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (range.partial) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$totalLength',
        );
      }

      if (request.method == 'HEAD') {
        await request.response.close();
        return;
      }

      await _writeCachedRange(
        response: request.response,
        asset: asset,
        start: range.start,
        end: range.end,
      );
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  ({int start, int end, bool partial})? _parseRequestRange(
    String header,
    int size,
  ) {
    final parsed = _parseRange(header, size);
    if (parsed == null) return null;
    return (start: parsed.start, end: parsed.end, partial: true);
  }

  ({int start, int end})? _parseRange(String header, int size) {
    if (!header.startsWith('bytes=') || size <= 0) return null;
    var spec = header.substring('bytes='.length);
    final comma = spec.indexOf(',');
    if (comma >= 0) spec = spec.substring(0, comma);
    spec = spec.trim();
    if (!spec.contains('-')) return null;
    final dash = spec.indexOf('-');
    final startText = spec.substring(0, dash);
    final endText = spec.substring(dash + 1);
    try {
      final int start;
      final int end;
      if (startText.isEmpty) {
        final suffix = int.parse(endText);
        if (suffix <= 0) return null;
        start = (size - suffix).clamp(0, size - 1);
        end = size - 1;
      } else {
        start = int.parse(startText);
        end = endText.isEmpty ? size - 1 : int.parse(endText);
      }
      if (start < 0 || start >= size || end < start) return null;
      return (start: start, end: end.clamp(start, size - 1));
    } on FormatException {
      return null;
    }
  }

  Future<int?> _waitForTotalLength(MediaAsset asset) async {
    final localFile = File(_localPathFor(asset));
    if (await localFile.exists()) return localFile.length();

    final state = _downloadStateFor(asset);
    for (var i = 0; i < 200; i++) {
      final known = state.totalLength;
      if (known != null && known > 0) return known;
      if (await localFile.exists()) return localFile.length();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return null;
  }

  Future<bool> _shouldProxyRemote(MediaAsset asset, int rangeStart) async {
    if (await File(_localPathFor(asset)).exists()) return false;
    final available = await _availableCachedBytes(asset);
    // MF may request MP4 tail metadata before the sequential download reaches
    // it. Do not block the local cache server for those far-ahead reads.
    const maxWaitAheadBytes = 512 * 1024;
    return rangeStart > available + maxWaitAheadBytes;
  }

  Future<int> _availableCachedBytes(MediaAsset asset) async {
    final file = await _readableFileFor(asset);
    return file == null ? 0 : file.length();
  }

  Future<void> _proxyRemoteRange({
    required HttpRequest request,
    required MediaAsset asset,
    required String? rangeHeader,
  }) async {
    final url = _remoteUrlFor(asset);
    if (url == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    final remoteRequest = http.Request('GET', Uri.parse(url));
    remoteRequest.headers.addAll(asset.headers);
    if (rangeHeader != null) {
      remoteRequest.headers[HttpHeaders.rangeHeader] = rangeHeader;
    }

    http.StreamedResponse? remoteResponse;
    try {
      remoteResponse = await _mediaHttp.send(remoteRequest);
      request.response.statusCode = remoteResponse.statusCode;
      final contentType = remoteResponse.headers[HttpHeaders.contentTypeHeader];
      if (contentType != null) {
        request.response.headers.contentType = ContentType.parse(contentType);
      }
      final contentLength = remoteResponse.contentLength;
      if (contentLength != null && contentLength >= 0) {
        request.response.headers.contentLength = contentLength;
      }
      for (final header in const [
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentRangeHeader,
      ]) {
        final value = remoteResponse.headers[header];
        if (value != null) request.response.headers.set(header, value);
      }

      if (request.method == 'HEAD') {
        await request.response.close();
        return;
      }

      _ioMetrics.remoteProxyOpened(contentLength);
      await request.response.addStream(remoteResponse.stream);
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _writeCachedRange({
    required HttpResponse response,
    required MediaAsset asset,
    required int start,
    required int end,
  }) async {
    final source = await _readableFileFor(asset);
    if (source == null) {
      await response.close();
      return;
    }

    final completedPath = _localPathFor(asset);
    if (source.path == completedPath) {
      _ioMetrics.completedFileStreamOpened(end - start + 1);
      await response.addStream(source.openRead(start, end + 1));
      await response.close();
      return;
    }

    final raf = await source.open();
    try {
      await raf.setPosition(start);
      var remaining = end - start + 1;
      var readPosition = start;
      var lastGrowthAt = DateTime.now();
      const chunkSize = 256 * 1024;
      const noGrowthTimeout = Duration(seconds: 5);
      while (remaining > 0) {
        final currentLen = await source.length();
        final available = (currentLen - readPosition).clamp(0, remaining);
        if (available <= 0) {
          // Do not pin SourceReader forever when the producer stalls. Bytes
          // already on disk have been flushed to the client; after five
          // seconds close this truncated response so MF can reconnect.
          if (DateTime.now().difference(lastGrowthAt) >= noGrowthTimeout) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        lastGrowthAt = DateTime.now();
        final toRead = available > chunkSize ? chunkSize : available;
        final chunk = await raf.read(toRead);
        if (chunk.isEmpty) break;
        response.add(chunk);
        // 读到多少就立刻推给下游（MF SourceReader）。不刷新的话，响应会在
        // 缓冲区里停留到整段写完，渐进读取会退化成“等整条下载完才出字节”。
        await response.flush();
        _ioMetrics.progressiveFlush(chunk.length);
        remaining -= chunk.length;
        readPosition += chunk.length;
      }
      await response.flush();
      _ioMetrics.progressiveFinalFlush();
    } finally {
      await raf.close();
    }
    await response.close();
  }

  Future<File?> _readableFileFor(MediaAsset asset) async {
    final localFile = File(_localPathFor(asset));
    if (await localFile.exists()) return localFile;
    final partFile = File('${_localPathFor(asset)}.part');
    if (await partFile.exists()) return partFile;
    return null;
  }

  int? _expectedLength(http.StreamedResponse response, int existingBytes) {
    final contentRange = response.headers[HttpHeaders.contentRangeHeader];
    if (contentRange != null) {
      final match = RegExp(r'bytes\s+\d+-\d+/(\d+)', caseSensitive: false)
          .firstMatch(contentRange);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    final contentLength = response.contentLength;
    if (contentLength == null || contentLength < 0) return null;
    return existingBytes + contentLength;
  }

  int _readyThresholdFor(MediaAsset asset, int? totalLength) {
    if (asset.type != MediaAssetType.video) return 1;
    final total = totalLength;
    if (total != null && total > 0 && total < _videoReadyBytes) return total;
    return _videoReadyBytes;
  }

  _DownloadState _downloadStateFor(MediaAsset asset) =>
      _downloadStates.putIfAbsent(_localPathFor(asset), _DownloadState.new);

  File? _completedPartFor(MediaAsset asset) {
    final state = _downloadStateFor(asset);
    if (!state.complete) return null;
    final partFile = File('${_localPathFor(asset)}.part');
    if (!partFile.existsSync()) return null;
    final length = partFile.lengthSync();
    final expected = state.totalLength;
    if (length <= 0 || (expected != null && length < expected)) return null;
    return partFile;
  }

  Future<void> _promoteCompletedPart(
    MediaAsset asset,
    File partFile,
  ) async {
    final localPath = _localPathFor(asset);
    final localFile = File(localPath);
    try {
      if (await localFile.exists()) {
        asset.cachedPath = localPath;
        return;
      }
      await partFile.rename(localPath);
      asset.cachedPath = localPath;
    } on FileSystemException {
      // The loopback stream may still be serving this file to MF. The `.part`
      // already contains the complete resource and remains the readable source
      // until a later ensure call can promote it.
    }
  }

  _AssetProgress _progressForAsset(MediaAsset asset) {
    if (asset.uri.isScheme('file')) {
      final path = asset.uri.toFilePath(windows: Platform.isWindows);
      final file = File(path);
      final length = file.existsSync() ? file.lengthSync() : 0;
      return _AssetProgress(
        totalBytes: length,
        downloadedBytes: length,
        bytesPerSecond: 0,
        isComplete: length > 0,
        isFailed: length <= 0,
        errorMessage: length <= 0 ? '本地文件不存在' : null,
      );
    }

    final localFile = File(_localPathFor(asset));
    if (localFile.existsSync()) {
      final length = localFile.lengthSync();
      return _AssetProgress(
        totalBytes: length,
        downloadedBytes: length,
        bytesPerSecond: 0,
        isComplete: true,
        isFailed: false,
      );
    }

    final state = _downloadStateFor(asset);
    // 活动下载的每个数据块都会更新 downloadedBytes，因此无需在每次 UI 重建
    // 里做同步 stat；只有本会话尚无字节状态时（例如遗留的 .part）才查磁盘。
    var downloaded = state.downloadedBytes;
    if (downloaded <= 0) {
      final partFile = File('${_localPathFor(asset)}.part');
      if (partFile.existsSync()) downloaded = partFile.lengthSync();
    }
    return _AssetProgress(
      totalBytes: state.totalLength,
      downloadedBytes: downloaded,
      bytesPerSecond: state.bytesPerSecond,
      isComplete: state.complete && !state.failed,
      isFailed: state.failed,
      errorMessage: state.error?.toString(),
    );
  }

  String _contentTypeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.mp4':
        return 'video/mp4';
      case '.m4v':
        return 'video/x-m4v';
      case '.webm':
        return 'video/webm';
      case '.mov':
        return 'video/quicktime';
      default:
        return 'application/octet-stream';
    }
  }

  bool _isAudio(MediaAssetType type) =>
      type == MediaAssetType.vocal || type == MediaAssetType.accompaniment;

  bool _isPlaybackAsset(MediaAsset asset) => asset.type != MediaAssetType.cover;

  bool _isOptionalAsset(MediaAsset asset) => asset.type == MediaAssetType.cover;

  static String _assetTypeLabel(MediaAssetType type) => switch (type) {
        MediaAssetType.video => '视频',
        MediaAssetType.vocal => '原唱',
        MediaAssetType.accompaniment => '伴奏',
        MediaAssetType.lyric => 'KRL',
        MediaAssetType.cover => '封面',
      };

  /// 进度通知合并窗口。下载池最多允许 15 条响应流同时写盘，逐块直发会以
  /// 数百赫兹的节奏重建监听 UI（点歌列表对话框），并连带触发同步文件查询。
  static const _progressNotifyInterval = Duration(milliseconds: 120);
  DateTime? _lastProgressNotifyAt;
  Timer? _progressNotifyTimer;

  void _notifyProgressListeners() {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _lastProgressNotifyAt;
    if (last == null || now.difference(last) >= _progressNotifyInterval) {
      _lastProgressNotifyAt = now;
      notifyListeners();
      return;
    }
    _progressNotifyTimer ??= Timer(_progressNotifyInterval, () {
      _progressNotifyTimer = null;
      if (_disposed) return;
      _lastProgressNotifyAt = DateTime.now();
      notifyListeners();
    });
  }

  /// 清理所有缓存文件。
  void clear() {
    var deleted = !_cacheDir.existsSync();
    try {
      if (_cacheDir.existsSync()) {
        _cacheDir.deleteSync(recursive: true);
      }
      deleted = !_cacheDir.existsSync();
    } catch (_) {}
    // Native decoders can still own media handles while the Flutter widget
    // tree is shutting down. Keep the marker in that case so the Windows
    // runner can retry after the engine has been destroyed.
    if (deleted) {
      _deleteSessionMarker();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _progressNotifyTimer?.cancel();
    _progressNotifyTimer = null;
    _downloadConnectionPool.dispose();
    _http.close();
    _mediaHttp.close();
    unawaited(_mediaIoWorker?.dispose());
    _mediaIoWorker = null;
    _nativeMediaIo?.dispose();
    _nativeMediaIo = null;
    unawaited(_streamServer?.close(force: true));
    _streamServer = null;
    super.dispose();
  }
}

/// Immutable, process-local media I/O counters.
class PlaybackAssetIoDiagnostics {
  const PlaybackAssetIoDiagnostics({
    required this.receivedChunks,
    required this.receivedBytes,
    required this.writeCalls,
    required this.writtenBytes,
    required this.preemptionHandlers,
    required this.preemptions,
    required this.bufferedBytes,
    required this.peakBufferedBytes,
    required this.activeConnections,
    required this.peakActiveConnections,
    required this.remoteProxyStreams,
    required this.remoteProxyBytes,
    required this.completedFileStreams,
    required this.completedFileBytes,
    required this.progressiveFlushes,
    required this.progressiveBytes,
  });

  final int receivedChunks;
  final int receivedBytes;
  final int writeCalls;
  final int writtenBytes;
  final int preemptionHandlers;
  final int preemptions;
  final int bufferedBytes;
  final int peakBufferedBytes;
  final int activeConnections;
  final int peakActiveConnections;
  final int remoteProxyStreams;
  final int remoteProxyBytes;
  final int completedFileStreams;
  final int completedFileBytes;
  final int progressiveFlushes;
  final int progressiveBytes;

  @override
  String toString() => 'received=$receivedBytes/$receivedChunks '
      'writes=$writtenBytes/$writeCalls '
      'buffered=$bufferedBytes peakBuffered=$peakBufferedBytes '
      'connections=$activeConnections peakConnections=$peakActiveConnections '
      'preemptions=$preemptions handlers=$preemptionHandlers '
      'proxy=$remoteProxyBytes/$remoteProxyStreams '
      'fileStream=$completedFileBytes/$completedFileStreams '
      'progressive=$progressiveBytes/$progressiveFlushes';
}

class _PlaybackAssetIoMetrics {
  int receivedChunks = 0;
  int receivedBytes = 0;
  int writeCalls = 0;
  int writtenBytes = 0;
  int preemptionHandlers = 0;
  int preemptions = 0;
  int bufferedBytes = 0;
  int peakBufferedBytes = 0;
  int activeConnections = 0;
  int peakActiveConnections = 0;
  int remoteProxyStreams = 0;
  int remoteProxyBytes = 0;
  int completedFileStreams = 0;
  int completedFileBytes = 0;
  int progressiveFlushes = 0;
  int progressiveBytes = 0;

  void receivedChunk(int length) {
    receivedChunks++;
    receivedBytes += length;
  }

  void writeCompleted(int length) {
    writeCalls++;
    writtenBytes += length;
  }

  void preemptionHandlerRegistered() => preemptionHandlers++;
  void preemptionRequested() => preemptions++;

  void bufferedBytesChanged(int delta) {
    bufferedBytes += delta;
    if (bufferedBytes > peakBufferedBytes) peakBufferedBytes = bufferedBytes;
    assert(bufferedBytes >= 0);
  }

  void connectionOpened() {
    activeConnections++;
    if (activeConnections > peakActiveConnections) {
      peakActiveConnections = activeConnections;
    }
  }

  void connectionClosed() {
    activeConnections--;
    assert(activeConnections >= 0);
  }

  void remoteProxyOpened(int? length) {
    remoteProxyStreams++;
    if (length != null && length > 0) remoteProxyBytes += length;
  }

  void completedFileStreamOpened(int length) {
    completedFileStreams++;
    completedFileBytes += length;
  }

  void progressiveFlush(int length) {
    progressiveFlushes++;
    progressiveBytes += length;
  }

  void progressiveFinalFlush() => progressiveFlushes++;

  void addWorkerDownloadResult(MediaIoWorkerAttemptResult result) {
    receivedChunks += result.receivedChunks;
    receivedBytes += result.receivedBytes;
    writeCalls += result.writeCalls;
    writtenBytes += result.writtenBytes;
    if (result.peakBufferedBytes > peakBufferedBytes) {
      peakBufferedBytes = result.peakBufferedBytes;
    }
  }

  void addWorkerServerMetrics(MediaIoWorkerServerMetrics metrics) {
    remoteProxyStreams += metrics.remoteProxyStreams;
    remoteProxyBytes += metrics.remoteProxyBytes;
    completedFileStreams += metrics.completedFileStreams;
    completedFileBytes += metrics.completedFileBytes;
    progressiveFlushes += metrics.progressiveFlushes;
    progressiveBytes += metrics.progressiveBytes;
  }

  PlaybackAssetIoDiagnostics snapshot() => PlaybackAssetIoDiagnostics(
        receivedChunks: receivedChunks,
        receivedBytes: receivedBytes,
        writeCalls: writeCalls,
        writtenBytes: writtenBytes,
        preemptionHandlers: preemptionHandlers,
        preemptions: preemptions,
        bufferedBytes: bufferedBytes,
        peakBufferedBytes: peakBufferedBytes,
        activeConnections: activeConnections,
        peakActiveConnections: peakActiveConnections,
        remoteProxyStreams: remoteProxyStreams,
        remoteProxyBytes: remoteProxyBytes,
        completedFileStreams: completedFileStreams,
        completedFileBytes: completedFileBytes,
        progressiveFlushes: progressiveFlushes,
        progressiveBytes: progressiveBytes,
      );
}

class _DownloadState {
  int? totalLength;
  int downloadedBytes = 0;
  int persistedBytes = 0;
  double bytesPerSecond = 0;
  bool complete = false;
  bool available = false;
  Object? lastError;
  Object? error;
  Completer<void>? _availability;
  int _lastSampleBytes = 0;
  DateTime? _lastSampleAt;

  bool get failed => error != null;

  Future<void> get whenAvailable {
    if (available) return Future.value();
    final failure = error;
    if (failure != null) return Future<void>.error(failure);
    return (_availability ??= Completer<void>()).future;
  }

  void markAvailable() {
    available = true;
    error = null;
    lastError = null;
    final availability = _availability;
    if (availability != null && !availability.isCompleted) {
      availability.complete();
    }
  }

  void markFailed(Object failure) {
    complete = false;
    bytesPerSecond = 0;
    error = failure;
    lastError = failure;
    final availability = _availability;
    if (availability != null && !availability.isCompleted) {
      availability.completeError(failure);
    }
  }

  void resetFailure() {
    error = null;
    lastError = null;
    if (!available) _availability = null;
  }

  void markSample(int bytes) {
    final now = DateTime.now();
    final lastAt = _lastSampleAt;
    if (lastAt != null) {
      final elapsed = now.difference(lastAt).inMilliseconds;
      final delta = bytes - _lastSampleBytes;
      if (elapsed >= 250 && delta >= 0) {
        bytesPerSecond = delta * 1000 / elapsed;
        _lastSampleAt = now;
        _lastSampleBytes = bytes;
      }
      return;
    }
    _lastSampleAt = now;
    _lastSampleBytes = bytes;
  }
}

enum _DownloadAttemptResult { finished, preempted, failed }

/// 全资源并发池。正常最多允许 15 条响应流同时拉取并写盘。
///
/// 如果池已满而更高优先级任务正在等待，最新、最低优先级的活动连接会收到
/// 抢占信号。下载循环随即取消响应流并保留 `.part`，重新排队后通过 Range
/// 继续拉取。
class _AsyncPreemptivePermitPool {
  _AsyncPreemptivePermitPool(this._limit);

  final int _limit;
  final List<_PreemptivePermitRequest> _waiters = [];
  final Set<_PreemptiblePermitLease> _active = {};
  int _sequence = 0;
  bool _disposed = false;

  Future<_PreemptiblePermitLease> acquire({
    required int Function() priority,
  }) {
    if (_disposed) {
      return Future.value(_PreemptiblePermitLease.cancelled(priority));
    }
    final request = _PreemptivePermitRequest(
      priority: priority,
      sequence: _sequence++,
    );
    _waiters.add(request);
    _schedule();
    return request.completer.future;
  }

  void prioritiesChanged() => _schedule();

  void _schedule() {
    if (_disposed) return;
    _sortWaiters();

    while (_active.length < _limit && _waiters.isNotEmpty) {
      final request = _waiters.removeAt(0);
      late final _PreemptiblePermitLease lease;
      lease = _PreemptiblePermitLease(
        priority: request.priority,
        sequence: request.sequence,
        onRelease: () {
          if (_active.remove(lease)) _schedule();
        },
      );
      _active.add(lease);
      request.completer.complete(lease);
    }

    if (_waiters.isEmpty || _active.length < _limit) return;
    _requestPreemptions();
  }

  void _sortWaiters() {
    _waiters.sort((a, b) {
      final byPriority = a.priority().compareTo(b.priority());
      return byPriority != 0 ? byPriority : a.sequence.compareTo(b.sequence);
    });
  }

  void _requestPreemptions() {
    final pendingPreemptions =
        _active.where((lease) => lease.preemptRequested).length;
    if (pendingPreemptions >= _waiters.length) return;

    final candidates = _active
        .where((lease) => !lease.preemptRequested)
        .toList(growable: false)
      ..sort((a, b) {
        final byPriority = b.priority().compareTo(a.priority());
        return byPriority != 0 ? byPriority : b.sequence.compareTo(a.sequence);
      });
    final unmatchedWaiters = _waiters.skip(pendingPreemptions).toList();
    final count = candidates.length < unmatchedWaiters.length
        ? candidates.length
        : unmatchedWaiters.length;
    for (var i = 0; i < count; i++) {
      final waiter = unmatchedWaiters[i];
      final active = candidates[i];
      if (waiter.priority() >= active.priority()) break;
      active.requestPreempt();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final lease in _active) {
      lease.requestPreempt();
    }
    for (final request in _waiters) {
      if (!request.completer.isCompleted) {
        request.completer.complete(
          _PreemptiblePermitLease.cancelled(request.priority),
        );
      }
    }
    _waiters.clear();
  }
}

class _PreemptivePermitRequest {
  _PreemptivePermitRequest({
    required this.priority,
    required this.sequence,
  });

  final int Function() priority;
  final int sequence;
  final Completer<_PreemptiblePermitLease> completer =
      Completer<_PreemptiblePermitLease>();
}

class _PreemptiblePermitLease {
  _PreemptiblePermitLease({
    required this.priority,
    required this.sequence,
    required void Function() onRelease,
  }) : _onRelease = onRelease;

  _PreemptiblePermitLease.cancelled(this.priority)
      : sequence = -1,
        _onRelease = _noop,
        _preemptRequested = true;

  final int Function() priority;
  final int sequence;
  final void Function() _onRelease;
  void Function()? _preemptHandler;
  bool _preemptRequested = false;
  bool _released = false;

  bool get preemptRequested => _preemptRequested;

  void setPreemptHandler(void Function() handler) {
    assert(_preemptHandler == null);
    _preemptHandler = handler;
    if (_preemptRequested) handler();
  }

  void clearPreemptHandler() => _preemptHandler = null;

  void requestPreempt() {
    if (_preemptRequested) return;
    _preemptRequested = true;
    _preemptHandler?.call();
  }

  void release() {
    if (_released) return;
    _released = true;
    _preemptHandler = null;
    _onRelease();
  }

  static void _noop() {}
}

class PlaybackAssetProgress {
  const PlaybackAssetProgress({
    required this.totalBytes,
    required this.downloadedBytes,
    required this.bytesPerSecond,
    required this.knownAssets,
    required this.completeAssets,
    required this.assetCount,
    required this.failedAssets,
    this.errorMessage,
  });

  final int totalBytes;
  final int downloadedBytes;
  final double bytesPerSecond;
  final int knownAssets;
  final int completeAssets;
  final int assetCount;
  final int failedAssets;
  final String? errorMessage;

  double? get fraction =>
      totalBytes <= 0 ? null : (downloadedBytes / totalBytes).clamp(0.0, 1.0);

  bool get hasFailed => failedAssets > 0;
  bool get isComplete =>
      !hasFailed && assetCount > 0 && completeAssets >= assetCount;
}

class _AssetProgress {
  const _AssetProgress({
    required this.totalBytes,
    required this.downloadedBytes,
    required this.bytesPerSecond,
    required this.isComplete,
    this.isFailed = false,
    this.errorMessage,
  });

  final int? totalBytes;
  final int downloadedBytes;
  final double bytesPerSecond;
  final bool isComplete;
  final bool isFailed;
  final String? errorMessage;
}

class PlaybackAssetDownloadException implements Exception {
  const PlaybackAssetDownloadException({
    this.songId,
    this.assetType,
    this.statusCode,
    required this.message,
  });

  final String? songId;
  final MediaAssetType? assetType;
  final int? statusCode;
  final String message;

  @override
  String toString() {
    final type = assetType == null
        ? ''
        : '${PlaybackAssetCache._assetTypeLabel(assetType!)}：';
    return '$type$message';
  }
}
