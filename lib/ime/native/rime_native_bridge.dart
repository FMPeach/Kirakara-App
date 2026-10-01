import 'package:flutter/services.dart';

import 'ime_native_bridge.dart';

class RimeNativeBridgeProbe {
  const RimeNativeBridgeProbe({
    this.channel = const MethodChannel('kirakara/ime'),
  });

  final MethodChannel channel;

  NativeImeBridge probe() {
    return RimeNativeBridge(channel: channel);
  }
}

class RimeNativeBridge implements NativeImeBridge {
  const RimeNativeBridge({
    required this.channel,
    this.schema = 'luna_pinyin_simp',
    this.pageSize = defaultImeCandidatePageSize,
  });

  final MethodChannel channel;
  final String schema;
  final int pageSize;

  @override
  String get engineName => 'rime';

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<void> activateSession(String sessionId) async {
    final result = await _invokeMap('rime.activate', {
      'sessionId': sessionId,
      'schema': schema,
    });
    _throwIfNativeError(result);
  }

  @override
  Future<void> deactivateSession(String sessionId) async {
    await channel.invokeMethod<bool>('rime.deactivate', {
      'sessionId': sessionId,
    });
  }

  @override
  Future<NativeImeResult> compose({
    required String sessionId,
    required String rawInput,
    required int pageIndex,
  }) async {
    final result = await _invokeMap('rime.compose', {
      'sessionId': sessionId,
      'rawInput': rawInput,
      'pageIndex': pageIndex,
      'pageSize': pageSize,
    });
    _throwIfNativeError(result);
    return _fromNativeMap(result);
  }

  @override
  Future<NativeImeResult> clear(String sessionId) async {
    final result = await _invokeMap('rime.clear', {
      'sessionId': sessionId,
    });
    _throwIfNativeError(result);
    return _fromNativeMap(result);
  }

  Future<Map<Object?, Object?>> _invokeMap(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final result = await channel.invokeMethod<Object?>(method, arguments);
    if (result is Map<Object?, Object?>) {
      return result;
    }
    throw StateError('Unexpected Rime bridge response for $method: $result');
  }

  void _throwIfNativeError(Map<Object?, Object?> result) {
    if (result['ok'] == false) {
      throw StateError(
        (result['error'] as String?) ?? 'Unknown Rime bridge error',
      );
    }
  }

  NativeImeResult _fromNativeMap(Map<Object?, Object?> result) {
    final rawInput = (result['rawInput'] as String?) ?? '';
    final preedit = (result['preedit'] as String?) ?? rawInput;
    final candidatesRaw = result['candidates'];
    final candidates = <NativeImeCandidate>[];
    if (candidatesRaw is List<Object?>) {
      for (final item in candidatesRaw) {
        if (item is Map<Object?, Object?>) {
          candidates.add(
            NativeImeCandidate(
              text: (item['text'] as String?) ?? '',
              annotation: item['annotation'] as String?,
            ),
          );
        }
      }
    }
    return NativeImeResult(
      rawInput: rawInput,
      preedit: preedit,
      candidates: candidates,
      pageIndex: (result['pageIndex'] as int?) ?? 0,
      hasPreviousPage: (result['hasPreviousPage'] as bool?) ?? false,
      hasNextPage: (result['hasNextPage'] as bool?) ?? false,
    );
  }
}
