const int defaultImeCandidatePageSize = 25;

class NativeImeCandidate {
  const NativeImeCandidate({
    required this.text,
    this.annotation,
    this.score,
  });

  final String text;
  final String? annotation;
  final double? score;
}

class NativeImeResult {
  const NativeImeResult({
    required this.rawInput,
    required this.preedit,
    required this.candidates,
    this.pageIndex = 0,
    this.hasPreviousPage = false,
    this.hasNextPage = false,
  });

  final String rawInput;
  final String preedit;
  final List<NativeImeCandidate> candidates;
  final int pageIndex;
  final bool hasPreviousPage;
  final bool hasNextPage;
}

abstract class NativeImeBridge {
  String get engineName;
  bool get isAvailable;
  String? get unavailableReason;

  Future<void> activateSession(String sessionId);
  Future<void> deactivateSession(String sessionId);

  Future<NativeImeResult> compose({
    required String sessionId,
    required String rawInput,
    required int pageIndex,
  });

  Future<NativeImeResult> clear(String sessionId);
}

class UnavailableNativeImeBridge implements NativeImeBridge {
  const UnavailableNativeImeBridge({
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
  Future<NativeImeResult> compose({
    required String sessionId,
    required String rawInput,
    required int pageIndex,
  }) async {
    throw StateError('$engineName native bridge is unavailable: $reason');
  }

  @override
  Future<NativeImeResult> clear(String sessionId) async {
    throw StateError('$engineName native bridge is unavailable: $reason');
  }
}
