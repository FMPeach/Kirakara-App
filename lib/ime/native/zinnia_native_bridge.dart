import 'package:flutter/services.dart';

import '../handwriting_stroke.dart';
import 'ime_native_bridge.dart';

abstract class NativeHandwritingBridge {
  String get engineName;
  bool get isAvailable;
  String? get unavailableReason;

  Future<void> activateSession(String sessionId);
  Future<void> deactivateSession(String sessionId);
  Future<List<NativeImeCandidate>> recognize({
    required String sessionId,
    required List<ImeStroke> strokes,
  });
}

class UnavailableNativeHandwritingBridge implements NativeHandwritingBridge {
  const UnavailableNativeHandwritingBridge({
    required this.engineName,
    required this.reason,
  });

  final String reason;

  @override
  final String engineName;

  @override
  bool get isAvailable => false;

  @override
  String? get unavailableReason => reason;

  @override
  Future<void> activateSession(String sessionId) async {}

  @override
  Future<void> deactivateSession(String sessionId) async {}

  @override
  Future<List<NativeImeCandidate>> recognize({
    required String sessionId,
    required List<ImeStroke> strokes,
  }) async {
    throw StateError('$engineName native bridge is unavailable: $reason');
  }
}

class ZinniaNativeBridgeProbe {
  const ZinniaNativeBridgeProbe({
    this.channel = const MethodChannel('kirakara/ime'),
  });

  final MethodChannel channel;

  NativeHandwritingBridge probe() {
    return ZinniaNativeBridge(channel: channel);
  }
}

class ZinniaNativeBridge implements NativeHandwritingBridge {
  const ZinniaNativeBridge({
    required this.channel,
  });

  final MethodChannel channel;

  @override
  String get engineName => 'zinnia';

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<void> activateSession(String sessionId) async {
    final result = await _invokeMap('zinnia.activate', {
      'sessionId': sessionId,
    });
    _throwIfNativeError(result);
  }

  @override
  Future<void> deactivateSession(String sessionId) async {
    await channel.invokeMethod<bool>('zinnia.deactivate', {
      'sessionId': sessionId,
    });
  }

  @override
  Future<List<NativeImeCandidate>> recognize({
    required String sessionId,
    required List<ImeStroke> strokes,
  }) async {
    final result = await _invokeMap('zinnia.recognize', {
      'sessionId': sessionId,
      'strokes': _serializeStrokes(strokes),
      'nbest': 10,
    });
    _throwIfNativeError(result);
    return _candidatesFromNativeMap(result);
  }

  Future<Map<Object?, Object?>> _invokeMap(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final result = await channel.invokeMethod<Object?>(method, arguments);
    if (result is Map<Object?, Object?>) {
      return result;
    }
    throw StateError('Unexpected Zinnia bridge response for $method: $result');
  }

  void _throwIfNativeError(Map<Object?, Object?> result) {
    if (result['ok'] == false) {
      throw StateError(
        (result['error'] as String?) ?? 'Unknown Zinnia bridge error',
      );
    }
  }

  List<List<Map<String, double>>> _serializeStrokes(List<ImeStroke> strokes) {
    return [
      for (final stroke in strokes)
        [
          for (final point in stroke) {'x': point.x, 'y': point.y},
        ],
    ];
  }

  List<NativeImeCandidate> _candidatesFromNativeMap(
    Map<Object?, Object?> result,
  ) {
    final candidates = <NativeImeCandidate>[];
    final candidatesRaw = result['candidates'];
    if (candidatesRaw is List<Object?>) {
      for (final item in candidatesRaw) {
        if (item is Map<Object?, Object?>) {
          candidates.add(
            NativeImeCandidate(
              text: (item['text'] as String?) ?? '',
              annotation: item['annotation'] as String?,
              score: item['score'] as double?,
            ),
          );
        }
      }
    }
    return candidates;
  }
}
