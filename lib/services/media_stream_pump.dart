import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

enum MediaStreamPumpResult { completed, cancelled }

/// Writes one byte stream to a file using bounded, timer-backed batches.
///
/// The source subscription is paused only while a file write is outstanding.
/// This bounds memory without adding a bandwidth cap or an artificial delay.
class MediaStreamPump {
  MediaStreamPump({
    required this.stream,
    required this.writer,
    this.onReceived,
    this.onPersisted,
    this.onBufferedBytesChanged,
    this.writeBatchBytes = 1024 * 1024,
    this.flushInterval = const Duration(milliseconds: 75),
  })  : assert(writeBatchBytes > 0),
        assert(flushInterval > Duration.zero);

  final Stream<List<int>> stream;
  final RandomAccessFile writer;
  final void Function(int length)? onReceived;
  final void Function(int length)? onPersisted;
  final void Function(int delta)? onBufferedBytesChanged;
  final int writeBatchBytes;
  final Duration flushInterval;

  final Completer<MediaStreamPumpResult> _done =
      Completer<MediaStreamPumpResult>();
  final List<Uint8List> _pending = <Uint8List>[];
  StreamSubscription<List<int>>? _subscription;
  Timer? _flushTimer;
  Future<void>? _activeWrite;
  int _pendingBytes = 0;
  bool _subscriptionPaused = false;
  bool _finishing = false;
  bool _cancelled = false;
  bool _started = false;

  Future<MediaStreamPumpResult> run() {
    if (_started) return _done.future;
    _started = true;
    if (_cancelled) {
      _finish();
      return _done.future;
    }
    final subscription = stream.listen(
      _onData,
      onError: _onStreamError,
      onDone: _onStreamDone,
      cancelOnError: false,
    );
    _subscription = subscription;
    // A synchronous source can complete while listen() is still returning.
    if (_finishing) {
      unawaited(subscription.cancel());
    } else if (_pendingBytes >= writeBatchBytes) {
      _startWrite();
    }
    return _done.future;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _finish();
  }

  void _onData(List<int> chunk) {
    if (_finishing || chunk.isEmpty) return;
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _pending.add(bytes);
    _pendingBytes += bytes.length;
    onBufferedBytesChanged?.call(bytes.length);
    onReceived?.call(bytes.length);
    if (_pendingBytes >= writeBatchBytes) {
      _startWrite();
    } else {
      _flushTimer ??= Timer(flushInterval, _startWrite);
    }
  }

  void _startWrite() {
    if (_finishing || _pendingBytes == 0 || _activeWrite != null) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    final subscription = _subscription;
    if (subscription != null && !_subscriptionPaused) {
      _subscriptionPaused = true;
      subscription.pause();
    }
    final batch = _takePending();
    final write = _writeBatch(batch);
    _activeWrite = write;
    unawaited(
      write.then(
        (_) {
          if (identical(_activeWrite, write)) _activeWrite = null;
          if (_finishing) return;
          if (_pendingBytes >= writeBatchBytes) {
            _startWrite();
            return;
          }
          if (_subscriptionPaused) {
            _subscriptionPaused = false;
            _subscription?.resume();
          }
          if (_pendingBytes > 0) {
            _flushTimer ??= Timer(flushInterval, _startWrite);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_activeWrite, write)) _activeWrite = null;
          _finish(error: error, stackTrace: stackTrace);
        },
      ),
    );
  }

  Uint8List _takePending() {
    assert(_pendingBytes > 0);
    final length = _pendingBytes;
    final Uint8List result;
    if (_pending.length == 1) {
      result = _pending.single;
    } else {
      result = Uint8List(length);
      var offset = 0;
      for (final chunk in _pending) {
        result.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
    }
    _pending.clear();
    _pendingBytes = 0;
    return result;
  }

  Future<void> _writeBatch(Uint8List batch) async {
    try {
      await writer.writeFrom(batch);
      onPersisted?.call(batch.length);
    } finally {
      onBufferedBytesChanged?.call(-batch.length);
    }
  }

  void _onStreamDone() => _finish();

  void _onStreamError(Object error, StackTrace stackTrace) =>
      _finish(error: error, stackTrace: stackTrace);

  void _finish({Object? error, StackTrace? stackTrace}) {
    if (_finishing) return;
    _finishing = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    unawaited(_finishAsync(error: error, stackTrace: stackTrace));
  }

  Future<void> _finishAsync({Object? error, StackTrace? stackTrace}) async {
    Object? failure = error;
    StackTrace? failureStack = stackTrace;
    try {
      final cancellation = _subscription?.cancel();
      if (_cancelled) {
        // Real HTTP subscriptions may keep their cancellation Future pending
        // until the remote response ends. Delivery stops when cancel() is
        // called, so do not let transport cleanup block priority preemption.
        if (cancellation != null) {
          unawaited(cancellation.catchError((Object _) {}));
        }
      } else if (cancellation != null) {
        await cancellation;
      }
      final activeWrite = _activeWrite;
      if (activeWrite != null) await activeWrite;
      if (_pendingBytes > 0) {
        await _writeBatch(_takePending());
      }
    } catch (caught, caughtStack) {
      failure ??= caught;
      failureStack ??= caughtStack;
    }

    if (failure != null) {
      if (!_done.isCompleted) {
        _done.completeError(failure, failureStack ?? StackTrace.current);
      }
      return;
    }
    if (!_done.isCompleted) {
      _done.complete(
        _cancelled
            ? MediaStreamPumpResult.cancelled
            : MediaStreamPumpResult.completed,
      );
    }
  }
}
