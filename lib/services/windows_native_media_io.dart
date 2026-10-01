import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'playback_media_io_worker.dart';

class WindowsNativeMediaIo {
  WindowsNativeMediaIo({
    MethodChannel channel = const MethodChannel('kirakara/media_io'),
    this.debugLogging = false,
  }) : _channel = channel;

  static const _pollInterval = Duration(milliseconds: 250);

  final MethodChannel _channel;
  final bool debugLogging;
  final Map<int, _NativeDownload> _downloads = {};
  Future<bool>? _probe;
  Timer? _pollTimer;
  int _nextId = 1;
  bool _polling = false;
  bool _disabled = false;
  bool _disposed = false;

  Future<bool> isAvailable() => _probe ??= _probeOnce();

  Future<bool> _probeOnce() async {
    if (_disabled || _disposed) return false;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('probe');
      return result?['available'] == true && result?['backend'] == 'winhttp';
    } on MissingPluginException {
      _disabled = true;
      return false;
    } on PlatformException {
      _disabled = true;
      return false;
    }
  }

  Future<WindowsNativeMediaIoDownload?> startDownload({
    required String url,
    required String localPath,
    required Map<String, String> headers,
    required int readyBytes,
    required bool isVideo,
    required void Function(MediaIoWorkerProgress progress) onProgress,
  }) async {
    if (!await isAvailable() || _disposed) return null;
    final id = _nextId++;
    try {
      await _channel.invokeMethod<bool>('start', {
        'id': id,
        'url': url,
        'localPath': localPath,
        'headers': headers,
        'initialFlushBytes': isVideo ? readyBytes : 1024 * 1024,
      });
    } on MissingPluginException {
      _disable();
      return null;
    } on PlatformException {
      // A bridge/startup incompatibility is a capability failure. Keep this
      // process clean and immediately use the Dart worker for this attempt.
      _disable();
      return null;
    }
    final completer = Completer<MediaIoWorkerAttemptResult>();
    _downloads[id] = _NativeDownload(
      id: id,
      completer: completer,
      readyBytes: readyBytes,
      isVideo: isVideo,
      onProgress: onProgress,
    );
    _ensurePolling();
    return WindowsNativeMediaIoDownload._(
      result: completer.future,
      cancel: () => _cancel(id),
    );
  }

  void _ensurePolling() {
    if (_pollTimer != null || _downloads.isEmpty || _disposed) return;
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    unawaited(_poll());
  }

  Future<void> _poll() async {
    if (_polling || _downloads.isEmpty || _disposed) return;
    _polling = true;
    try {
      final snapshots = await _channel.invokeListMethod<dynamic>('poll');
      if (snapshots == null) return;
      if (debugLogging) debugPrint('[native-media-io] $snapshots');
      for (final raw in snapshots) {
        if (raw is! Map) continue;
        final id = raw['id'];
        if (id is! int) continue;
        final pending = _downloads[id];
        if (pending == null) continue;
        final totalLength = raw['totalLength'] as int?;
        final downloadedBytes = raw['downloadedBytes'] as int? ?? 0;
        final persistedBytes = raw['persistedBytes'] as int? ?? 0;
        final threshold = pending.isVideo
            ? (totalLength != null &&
                    totalLength > 0 &&
                    totalLength < pending.readyBytes
                ? totalLength
                : pending.readyBytes)
            : 1;
        pending.onProgress(
          MediaIoWorkerProgress(
            totalLength: totalLength,
            downloadedBytes: downloadedBytes,
            persistedBytes: persistedBytes,
            available: persistedBytes >= threshold,
          ),
        );
        final status = raw['status'];
        if (status != 'finished' &&
            status != 'preempted' &&
            status != 'failed') {
          continue;
        }
        _downloads.remove(id);
        final statusCode = raw['statusCode'] as int?;
        pending.completer.complete(
          MediaIoWorkerAttemptResult(
            status: switch (status) {
              'finished' => MediaIoWorkerAttemptStatus.finished,
              'preempted' => MediaIoWorkerAttemptStatus.preempted,
              _ => MediaIoWorkerAttemptStatus.failed,
            },
            actualLength: persistedBytes,
            totalLength: totalLength,
            receivedChunks: raw['readCalls'] as int? ?? 0,
            receivedBytes: raw['receivedBytes'] as int? ?? 0,
            writeCalls: raw['writeCalls'] as int? ?? 0,
            writtenBytes: raw['receivedBytes'] as int? ?? 0,
            peakBufferedBytes: raw['peakBufferedBytes'] as int? ?? 0,
            statusCode:
                statusCode == null || statusCode == 0 ? null : statusCode,
            errorMessage: raw['error'] as String?,
          ),
        );
        unawaited(_channel.invokeMethod<void>('release', {'id': id}));
      }
    } on MissingPluginException {
      _failBackend();
    } on PlatformException {
      _failBackend();
    } finally {
      _polling = false;
      if (_downloads.isEmpty) {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    }
  }

  void _cancel(int id) {
    if (!_downloads.containsKey(id)) return;
    unawaited(_channel.invokeMethod<void>('cancel', {'id': id}).catchError((_) {
      _failBackend();
    }));
  }

  void _disable() {
    _disabled = true;
    _probe = Future<bool>.value(false);
  }

  void _failBackend() {
    _disable();
    final pending = _downloads.values.toList(growable: false);
    for (final id in _downloads.keys) {
      unawaited(_channel.invokeMethod<void>('cancel', {'id': id}).catchError(
        (Object _) {},
      ));
    }
    _downloads.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final download in pending) {
      if (!download.completer.isCompleted) {
        download.completer.completeError(
          PlatformException(
            code: 'native_media_io_lost',
            message: 'Windows native media I/O bridge stopped responding',
          ),
        );
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final id in _downloads.keys.toList(growable: false)) {
      unawaited(_channel.invokeMethod<void>('cancel', {'id': id}));
    }
    _downloads.clear();
  }
}

class WindowsNativeMediaIoDownload {
  WindowsNativeMediaIoDownload._({
    required this.result,
    required void Function() cancel,
  }) : _cancel = cancel;

  final Future<MediaIoWorkerAttemptResult> result;
  final void Function() _cancel;

  void cancel() => _cancel();
}

class _NativeDownload {
  const _NativeDownload({
    required this.id,
    required this.completer,
    required this.readyBytes,
    required this.isVideo,
    required this.onProgress,
  });

  final int id;
  final Completer<MediaIoWorkerAttemptResult> completer;
  final int readyBytes;
  final bool isVideo;
  final void Function(MediaIoWorkerProgress progress) onProgress;
}
