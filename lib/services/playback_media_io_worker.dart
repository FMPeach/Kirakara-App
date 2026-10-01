import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import 'media_stream_pump.dart';

enum MediaIoWorkerAttemptStatus { finished, preempted, failed }

class MediaIoWorkerProgress {
  const MediaIoWorkerProgress({
    required this.totalLength,
    required this.downloadedBytes,
    required this.persistedBytes,
    required this.available,
  });

  final int? totalLength;
  final int downloadedBytes;
  final int persistedBytes;
  final bool available;
}

class MediaIoWorkerAttemptResult {
  const MediaIoWorkerAttemptResult({
    required this.status,
    required this.actualLength,
    required this.totalLength,
    required this.receivedChunks,
    required this.receivedBytes,
    required this.writeCalls,
    required this.writtenBytes,
    required this.peakBufferedBytes,
    this.statusCode,
    this.errorMessage,
  });

  final MediaIoWorkerAttemptStatus status;
  final int actualLength;
  final int? totalLength;
  final int receivedChunks;
  final int receivedBytes;
  final int writeCalls;
  final int writtenBytes;
  final int peakBufferedBytes;
  final int? statusCode;
  final String? errorMessage;
}

class MediaIoWorkerServerMetrics {
  const MediaIoWorkerServerMetrics({
    this.remoteProxyStreams = 0,
    this.remoteProxyBytes = 0,
    this.completedFileStreams = 0,
    this.completedFileBytes = 0,
    this.progressiveFlushes = 0,
    this.progressiveBytes = 0,
  });

  final int remoteProxyStreams;
  final int remoteProxyBytes;
  final int completedFileStreams;
  final int completedFileBytes;
  final int progressiveFlushes;
  final int progressiveBytes;
}

class MediaIoWorkerDownload {
  MediaIoWorkerDownload._({
    required this.result,
    required void Function() cancel,
  }) : _cancel = cancel;

  final Future<MediaIoWorkerAttemptResult> result;
  final void Function() _cancel;

  void cancel() => _cancel();
}

/// Main-isolate facade for a long-lived media I/O isolate.
///
/// Only commands and low-rate progress snapshots cross the isolate boundary;
/// downloaded media bytes stay in the worker from socket to file/server.
class PlaybackMediaIoWorker {
  PlaybackMediaIoWorker({this.onServerMetrics});

  final void Function(MediaIoWorkerServerMetrics metrics)? onServerMetrics;

  ReceivePort? _events;
  StreamSubscription<dynamic>? _eventSubscription;
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _starting;
  Completer<SendPort>? _ready;
  int _nextId = 1;
  bool _disposed = false;
  final Map<int, _PendingDownload> _downloads = {};
  final Map<int, Completer<dynamic>> _requests = {};
  Completer<void>? _stopped;

  Future<MediaIoWorkerDownload> startDownload({
    required String url,
    required String localPath,
    required Map<String, String> headers,
    required int readyBytes,
    required bool isVideo,
    required void Function(MediaIoWorkerProgress progress) onProgress,
  }) async {
    await _ensureStarted();
    if (_disposed) throw StateError('Media I/O worker is disposed');
    final id = _nextId++;
    final completer = Completer<MediaIoWorkerAttemptResult>();
    _downloads[id] = _PendingDownload(
      completer: completer,
      onProgress: onProgress,
    );
    _commands!.send({
      'type': 'download',
      'id': id,
      'url': url,
      'localPath': localPath,
      'headers': headers,
      'readyBytes': readyBytes,
      'isVideo': isVideo,
    });
    return MediaIoWorkerDownload._(
      result: completer.future,
      cancel: () => _commands?.send({'type': 'cancel', 'id': id}),
    );
  }

  Future<int> ensureServer() async {
    final response = await _request('ensureServer') as Map<Object?, Object?>;
    return response['port']! as int;
  }

  Future<void> registerStreamAsset({
    required String token,
    required String localPath,
    required String url,
    required Map<String, String> headers,
  }) async {
    await _request(
      'registerAsset',
      payload: {
        'token': token,
        'localPath': localPath,
        'url': url,
        'headers': headers,
      },
    );
  }

  void updateStreamAssetState({
    required String localPath,
    required int? totalLength,
    required int persistedBytes,
    required bool producerActive,
  }) {
    unawaited(() async {
      await _ensureStarted();
      if (_disposed) return;
      _commands!.send({
        'type': 'updateAssetState',
        'localPath': localPath,
        'totalLength': totalLength,
        'persistedBytes': persistedBytes,
        'producerActive': producerActive,
      });
    }());
  }

  Future<dynamic> _request(
    String type, {
    Map<String, Object?> payload = const {},
  }) async {
    await _ensureStarted();
    if (_disposed) throw StateError('Media I/O worker is disposed');
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _requests[id] = completer;
    _commands!.send({'type': type, 'requestId': id, ...payload});
    return completer.future;
  }

  Future<void> _ensureStarted() {
    final existing = _starting;
    if (existing != null) return existing;
    final future = _start();
    _starting = future;
    return future;
  }

  Future<void> _start() async {
    if (_disposed) throw StateError('Media I/O worker is disposed');
    final events = ReceivePort('kirakara_media_io_events');
    _events = events;
    final ready = Completer<SendPort>();
    _ready = ready;
    _eventSubscription = events.listen(_handleEvent);
    _isolate = await Isolate.spawn<SendPort>(
      _playbackMediaIoWorkerEntry,
      events.sendPort,
      debugName: 'kirakara_media_io',
      errorsAreFatal: true,
    );
    _commands = await ready.future;
  }

  void _handleEvent(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'];
    if (type == 'ready') {
      final port = raw['port'];
      if (port is SendPort && !(_ready?.isCompleted ?? true)) {
        _ready!.complete(port);
      }
      return;
    }
    if (type == 'response') {
      final id = raw['requestId'];
      if (id is! int) return;
      final completer = _requests.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = raw['error'];
      if (error != null) {
        completer.completeError(StateError('$error'));
      } else {
        completer.complete(raw['value']);
      }
      return;
    }
    if (type == 'progress') {
      final id = raw['id'];
      if (id is! int) return;
      _downloads[id]?.onProgress(
        MediaIoWorkerProgress(
          totalLength: raw['totalLength'] as int?,
          downloadedBytes: raw['downloadedBytes']! as int,
          persistedBytes: raw['persistedBytes']! as int,
          available: raw['available']! as bool,
        ),
      );
      return;
    }
    if (type == 'downloadDone') {
      final id = raw['id'];
      if (id is! int) return;
      final pending = _downloads.remove(id);
      if (pending == null || pending.completer.isCompleted) return;
      pending.completer.complete(
        MediaIoWorkerAttemptResult(
          status: MediaIoWorkerAttemptStatus.values.byName(
            raw['status']! as String,
          ),
          actualLength: raw['actualLength']! as int,
          totalLength: raw['totalLength'] as int?,
          receivedChunks: raw['receivedChunks']! as int,
          receivedBytes: raw['receivedBytes']! as int,
          writeCalls: raw['writeCalls']! as int,
          writtenBytes: raw['writtenBytes']! as int,
          peakBufferedBytes: raw['peakBufferedBytes']! as int,
          statusCode: raw['statusCode'] as int?,
          errorMessage: raw['errorMessage'] as String?,
        ),
      );
      return;
    }
    if (type == 'serverMetrics') {
      onServerMetrics?.call(
        MediaIoWorkerServerMetrics(
          remoteProxyStreams: raw['remoteProxyStreams'] as int? ?? 0,
          remoteProxyBytes: raw['remoteProxyBytes'] as int? ?? 0,
          completedFileStreams: raw['completedFileStreams'] as int? ?? 0,
          completedFileBytes: raw['completedFileBytes'] as int? ?? 0,
          progressiveFlushes: raw['progressiveFlushes'] as int? ?? 0,
          progressiveBytes: raw['progressiveBytes'] as int? ?? 0,
        ),
      );
      return;
    }
    if (type == 'stopped') {
      final stopped = _stopped;
      if (stopped != null && !stopped.isCompleted) stopped.complete();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
    for (final pending in _downloads.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError('Media I/O worker stopped'));
      }
    }
    _downloads.clear();
    for (final pending in _requests.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Media I/O worker stopped'));
      }
    }
    _requests.clear();
    final commands = _commands;
    if (commands != null) {
      final stopped = _stopped = Completer<void>();
      commands.send({'type': 'shutdown'});
      try {
        await stopped.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Immediate isolate termination below is the final shutdown guard.
      }
    }
    await _eventSubscription?.cancel();
    _events?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _commands = null;
    _isolate = null;
  }
}

class _PendingDownload {
  const _PendingDownload({
    required this.completer,
    required this.onProgress,
  });

  final Completer<MediaIoWorkerAttemptResult> completer;
  final void Function(MediaIoWorkerProgress progress) onProgress;
}

@pragma('vm:entry-point')
void _playbackMediaIoWorkerEntry(SendPort mainPort) {
  final commands = ReceivePort('kirakara_media_io_commands');
  final runtime = _MediaIoWorkerRuntime(mainPort);
  mainPort.send({'type': 'ready', 'port': commands.sendPort});
  commands.listen(runtime.handleCommand);
}

class _MediaIoWorkerRuntime {
  _MediaIoWorkerRuntime(this.mainPort);

  final SendPort mainPort;
  final http.Client client = http.Client();
  final Map<int, _WorkerDownloadTask> downloads = {};
  final Map<String, _WorkerStreamAsset> streamAssets = {};
  final Map<String, _WorkerDownloadState> downloadStates = {};
  HttpServer? streamServer;
  bool shuttingDown = false;

  void handleCommand(dynamic raw) {
    if (raw is! Map || shuttingDown) return;
    switch (raw['type']) {
      case 'download':
        _startDownload(raw);
      case 'cancel':
        final id = raw['id'];
        if (id is int) downloads[id]?.cancel();
      case 'ensureServer':
        unawaited(_respond(raw, _ensureServer));
      case 'registerAsset':
        unawaited(_respond(raw, () async {
          final token = raw['token']! as String;
          final localPath = raw['localPath']! as String;
          streamAssets[token] = _WorkerStreamAsset(
            localPath: localPath,
            url: raw['url']! as String,
            headers: Map<String, String>.from(raw['headers']! as Map),
          );
          downloadStates.putIfAbsent(localPath, _WorkerDownloadState.new);
          return null;
        }));
      case 'updateAssetState':
        final localPath = raw['localPath'];
        if (localPath is String) {
          final state =
              downloadStates.putIfAbsent(localPath, _WorkerDownloadState.new);
          state
            ..totalLength = raw['totalLength'] as int?
            ..persistedBytes = raw['persistedBytes'] as int? ?? 0;
          final producerActive = raw['producerActive'];
          if (producerActive is bool) {
            state.producerActive = producerActive;
          }
        }
      case 'shutdown':
        unawaited(_shutdown().whenComplete(() {
          mainPort.send({'type': 'stopped'});
          Isolate.exit();
        }));
    }
  }

  void _startDownload(Map<dynamic, dynamic> raw) {
    final id = raw['id']! as int;
    late final _WorkerDownloadTask task;
    task = _WorkerDownloadTask(
      id: id,
      mainPort: mainPort,
      client: client,
      url: raw['url']! as String,
      localPath: raw['localPath']! as String,
      headers: Map<String, String>.from(raw['headers']! as Map),
      readyBytes: raw['readyBytes']! as int,
      isVideo: raw['isVideo']! as bool,
      sharedState: downloadStates.putIfAbsent(
          raw['localPath']! as String, _WorkerDownloadState.new),
    );
    downloads[id] = task;
    unawaited(task.run().whenComplete(() => downloads.remove(id)));
  }

  Future<void> _respond(
    Map<dynamic, dynamic> command,
    FutureOr<dynamic> Function() action,
  ) async {
    final requestId = command['requestId'];
    if (requestId is! int) return;
    try {
      final value = await action();
      mainPort.send({
        'type': 'response',
        'requestId': requestId,
        'value': value,
      });
    } catch (error) {
      mainPort.send({
        'type': 'response',
        'requestId': requestId,
        'error': '$error',
      });
    }
  }

  Future<Map<String, Object?>> _ensureServer() async {
    final existing = streamServer;
    if (existing != null) return {'port': existing.port};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    streamServer = server;
    server.listen(_handleStreamRequest);
    return {'port': server.port};
  }

  Future<void> _handleStreamRequest(HttpRequest request) async {
    var remoteProxyStreams = 0;
    var remoteProxyBytes = 0;
    var completedFileStreams = 0;
    var completedFileBytes = 0;
    var progressiveFlushes = 0;
    var progressiveBytes = 0;
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
      final asset = streamAssets[request.uri.pathSegments[1]];
      if (asset == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
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
        final proxy = await _proxyRemoteRange(
          request: request,
          asset: asset,
          rangeHeader: rangeHeader,
        );
        remoteProxyStreams = proxy.streams;
        remoteProxyBytes = proxy.bytes;
        return;
      }
      final contentLength = range.end - range.start + 1;
      request.response.statusCode =
          range.partial ? HttpStatus.partialContent : HttpStatus.ok;
      request.response.headers.contentType =
          ContentType.parse(_contentTypeFor(asset.url));
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
      final localFile = File(asset.localPath);
      if (await localFile.exists()) {
        completedFileStreams = 1;
        completedFileBytes = contentLength;
        await request.response.addStream(
          localFile.openRead(range.start, range.end + 1),
        );
        await request.response.close();
        return;
      }
      final partFile = File('${asset.localPath}.part');
      if (!await partFile.exists()) {
        await request.response.close();
        return;
      }
      final result = await _writeProgressiveRange(
        response: request.response,
        source: partFile,
        localPath: asset.localPath,
        start: range.start,
        end: range.end,
      );
      progressiveFlushes = result.flushes;
      progressiveBytes = result.bytes;
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    } finally {
      if (remoteProxyStreams != 0 ||
          completedFileStreams != 0 ||
          progressiveFlushes != 0) {
        mainPort.send({
          'type': 'serverMetrics',
          'remoteProxyStreams': remoteProxyStreams,
          'remoteProxyBytes': remoteProxyBytes,
          'completedFileStreams': completedFileStreams,
          'completedFileBytes': completedFileBytes,
          'progressiveFlushes': progressiveFlushes,
          'progressiveBytes': progressiveBytes,
        });
      }
    }
  }

  ({int start, int end, bool partial})? _parseRequestRange(
    String header,
    int size,
  ) {
    if (!header.startsWith('bytes=') || size <= 0) return null;
    var spec = header.substring('bytes='.length);
    final comma = spec.indexOf(',');
    if (comma >= 0) spec = spec.substring(0, comma);
    spec = spec.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
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
      return (start: start, end: end.clamp(start, size - 1), partial: true);
    } on FormatException {
      return null;
    }
  }

  Future<int?> _waitForTotalLength(_WorkerStreamAsset asset) async {
    final localFile = File(asset.localPath);
    if (await localFile.exists()) return localFile.length();
    final state = downloadStates[asset.localPath];
    for (var i = 0; i < 200; i++) {
      final known = state?.totalLength;
      if (known != null && known > 0) return known;
      if (await localFile.exists()) return localFile.length();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return null;
  }

  Future<bool> _shouldProxyRemote(
    _WorkerStreamAsset asset,
    int rangeStart,
  ) async {
    if (await File(asset.localPath).exists()) return false;
    final part = File('${asset.localPath}.part');
    final available = await part.exists() ? await part.length() : 0;
    const maxWaitAheadBytes = 512 * 1024;
    return rangeStart > available + maxWaitAheadBytes;
  }

  Future<({int streams, int bytes})> _proxyRemoteRange({
    required HttpRequest request,
    required _WorkerStreamAsset asset,
    required String? rangeHeader,
  }) async {
    final remoteRequest = http.Request('GET', Uri.parse(asset.url));
    remoteRequest.headers.addAll(asset.headers);
    if (rangeHeader != null) {
      remoteRequest.headers[HttpHeaders.rangeHeader] = rangeHeader;
    }
    final remoteResponse = await client.send(remoteRequest);
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
      return (streams: 1, bytes: contentLength ?? 0);
    }
    await request.response.addStream(remoteResponse.stream);
    await request.response.close();
    return (streams: 1, bytes: contentLength ?? 0);
  }

  Future<({int flushes, int bytes})> _writeProgressiveRange({
    required HttpResponse response,
    required File source,
    required String localPath,
    required int start,
    required int end,
  }) async {
    final raf = await source.open();
    var flushes = 0;
    var bytes = 0;
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
          final producerActive =
              downloadStates[localPath]?.producerActive ?? false;
          if (!producerActive &&
              DateTime.now().difference(lastGrowthAt) >= noGrowthTimeout) {
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
        await response.flush();
        flushes++;
        bytes += chunk.length;
        remaining -= chunk.length;
        readPosition += chunk.length;
      }
      await response.flush();
      flushes++;
    } finally {
      await raf.close();
    }
    await response.close();
    return (flushes: flushes, bytes: bytes);
  }

  String _contentTypeFor(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.mp4')) return 'video/mp4';
    if (path.endsWith('.m4v')) return 'video/x-m4v';
    if (path.endsWith('.webm')) return 'video/webm';
    if (path.endsWith('.mov')) return 'video/quicktime';
    return 'application/octet-stream';
  }

  Future<void> _shutdown() async {
    if (shuttingDown) return;
    shuttingDown = true;
    for (final download in downloads.values.toList(growable: false)) {
      download.cancel();
    }
    await Future.wait(
      downloads.values.map((download) => download.done),
      eagerError: false,
    );
    await streamServer?.close(force: true);
    client.close();
  }
}

class _WorkerDownloadTask {
  _WorkerDownloadTask({
    required this.id,
    required this.mainPort,
    required this.client,
    required this.url,
    required this.localPath,
    required this.headers,
    required this.readyBytes,
    required this.isVideo,
    required this.sharedState,
  });

  static const _progressInterval = Duration(milliseconds: 200);

  final int id;
  final SendPort mainPort;
  final http.Client client;
  final String url;
  final String localPath;
  final Map<String, String> headers;
  final int readyBytes;
  final bool isVideo;
  final _WorkerDownloadState sharedState;
  final Completer<void> _done = Completer<void>();
  MediaStreamPump? _pump;
  Timer? _progressTimer;
  int _downloadedBytes = 0;
  int _persistedBytes = 0;
  int? _totalLength;
  bool _available = false;
  bool _cancelled = false;
  int _receivedChunks = 0;
  int _receivedBytes = 0;
  int _writeCalls = 0;
  int _writtenBytes = 0;
  int _bufferedBytes = 0;
  int _peakBufferedBytes = 0;

  Future<void> get done => _done.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _pump?.cancel();
  }

  Future<void> run() async {
    var status = MediaIoWorkerAttemptStatus.failed;
    var actualLength = 0;
    int? statusCode;
    String? errorMessage;
    sharedState.producerActive = true;
    try {
      final localFile = File(localPath);
      final partFile = File('$localPath.part');
      await localFile.parent.create(recursive: true);
      var existingBytes = await partFile.exists() ? await partFile.length() : 0;
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(headers);
      if (existingBytes > 0) {
        request.headers[HttpHeaders.rangeHeader] = 'bytes=$existingBytes-';
      }
      final response = await client.send(request);
      statusCode = response.statusCode;
      if (_cancelled) {
        await response.stream.listen((_) {}).cancel();
        status = MediaIoWorkerAttemptStatus.preempted;
        return;
      }
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await response.stream.drain<void>();
        if (existingBytes > 0) {
          actualLength = existingBytes;
          _totalLength = existingBytes;
          _downloadedBytes = existingBytes;
          _persistedBytes = existingBytes;
          _available = true;
          sharedState
            ..totalLength = existingBytes
            ..persistedBytes = existingBytes;
          _sendProgress(force: true);
          status = MediaIoWorkerAttemptStatus.finished;
        } else {
          errorMessage = '服务器拒绝了空文件续传请求';
        }
        return;
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        await response.stream.drain<void>();
        errorMessage = '服务器返回 HTTP ${response.statusCode}';
        return;
      }
      final append =
          response.statusCode == HttpStatus.partialContent && existingBytes > 0;
      if (!append) existingBytes = 0;
      _totalLength = _expectedLength(response, existingBytes);
      _downloadedBytes = existingBytes;
      _persistedBytes = existingBytes;
      sharedState
        ..totalLength = _totalLength
        ..persistedBytes = existingBytes;
      _available = existingBytes >= _readyThreshold();
      _sendProgress(force: true);

      final writer = await partFile.open(
        mode: append ? FileMode.append : FileMode.write,
      );
      try {
        final pump = MediaStreamPump(
          stream: response.stream,
          writer: writer,
          onReceived: (length) {
            _receivedChunks++;
            _receivedBytes += length;
            _downloadedBytes += length;
            _scheduleProgress();
          },
          onPersisted: (length) {
            _writeCalls++;
            _writtenBytes += length;
            _persistedBytes += length;
            sharedState.persistedBytes = _persistedBytes;
            final becameAvailable =
                !_available && _persistedBytes >= _readyThreshold();
            if (becameAvailable) _available = true;
            if (becameAvailable) {
              _sendProgress(force: true);
            } else {
              _scheduleProgress();
            }
          },
          onBufferedBytesChanged: (delta) {
            _bufferedBytes += delta;
            if (_bufferedBytes > _peakBufferedBytes) {
              _peakBufferedBytes = _bufferedBytes;
            }
          },
        );
        _pump = pump;
        if (_cancelled) pump.cancel();
        final pumpResult = await pump.run();
        status = pumpResult == MediaStreamPumpResult.cancelled
            ? MediaIoWorkerAttemptStatus.preempted
            : MediaIoWorkerAttemptStatus.finished;
      } finally {
        _pump = null;
        await writer.close();
      }
      actualLength = await partFile.length();
      final expectedLength = _expectedLength(response, existingBytes);
      if (status == MediaIoWorkerAttemptStatus.finished &&
          expectedLength != null &&
          actualLength < expectedLength) {
        status = MediaIoWorkerAttemptStatus.failed;
        errorMessage = '下载提前结束：$actualLength/$expectedLength bytes';
      }
      if (status == MediaIoWorkerAttemptStatus.finished) {
        _totalLength = actualLength;
        _downloadedBytes = actualLength;
        _persistedBytes = actualLength;
        _available = true;
        sharedState
          ..totalLength = actualLength
          ..persistedBytes = actualLength;
      }
    } catch (error) {
      status = _cancelled
          ? MediaIoWorkerAttemptStatus.preempted
          : MediaIoWorkerAttemptStatus.failed;
      errorMessage = '下载连接失败：$error';
      try {
        final part = File('$localPath.part');
        if (await part.exists()) actualLength = await part.length();
      } catch (_) {}
    } finally {
      sharedState.producerActive = false;
      _progressTimer?.cancel();
      _progressTimer = null;
      _sendProgress(force: true);
      mainPort.send({
        'type': 'downloadDone',
        'id': id,
        'status': status.name,
        'actualLength': actualLength,
        'totalLength': _totalLength,
        'receivedChunks': _receivedChunks,
        'receivedBytes': _receivedBytes,
        'writeCalls': _writeCalls,
        'writtenBytes': _writtenBytes,
        'peakBufferedBytes': _peakBufferedBytes,
        'statusCode': statusCode,
        'errorMessage': errorMessage,
      });
      if (!_done.isCompleted) _done.complete();
    }
  }

  void _scheduleProgress() {
    _progressTimer ??= Timer(_progressInterval, () {
      _progressTimer = null;
      _sendProgress(force: true);
    });
  }

  void _sendProgress({required bool force}) {
    if (!force) return;
    mainPort.send({
      'type': 'progress',
      'id': id,
      'totalLength': _totalLength,
      'downloadedBytes': _downloadedBytes,
      'persistedBytes': _persistedBytes,
      'available': _available,
    });
  }

  int _readyThreshold() {
    if (!isVideo) return 1;
    final total = _totalLength;
    if (total != null && total > 0 && total < readyBytes) return total;
    return readyBytes;
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
}

class _WorkerDownloadState {
  int? totalLength;
  int persistedBytes = 0;
  bool producerActive = false;
}

class _WorkerStreamAsset {
  const _WorkerStreamAsset({
    required this.localPath,
    required this.url,
    required this.headers,
  });

  final String localPath;
  final String url;
  final Map<String, String> headers;
}
