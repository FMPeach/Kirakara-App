import '../handwriting_stroke.dart';
import '../ime_candidate.dart';
import '../ime_composition.dart';
import '../ime_engine.dart';
import '../ime_mode.dart';
import '../native/ime_native_bridge.dart';
import '../native/zinnia_native_bridge.dart';

class ZinniaHandwritingEngine implements HandwritingImeEngine {
  ZinniaHandwritingEngine({
    NativeHandwritingBridge? bridge,
    this.sessionId = 'kirakara-zinnia-session',
  }) : _bridge = bridge ?? const ZinniaNativeBridgeProbe().probe();

  final NativeHandwritingBridge _bridge;
  final String sessionId;

  final List<ImeStroke> _strokes = [];
  ImeStroke? _activeStroke;
  bool _nativeFailed = false;
  String? _nativeError;
  ImeComposition _composition = ImeComposition.empty(ImeMode.handwriting);

  @override
  ImeMode get mode => ImeMode.handwriting;

  @override
  ImeComposition get composition => _composition;

  bool get isNativeAvailable => _bridge.isAvailable && !_nativeFailed;
  String? get nativeUnavailableReason =>
      _nativeError ?? _bridge.unavailableReason;

  @override
  Future<void> activate() async {
    if (!_bridge.isAvailable) {
      _composition = _failureComposition();
      return;
    }
    try {
      await _bridge.activateSession(sessionId);
    } on Object catch (error) {
      _recordNativeFailure(error);
    }
  }

  @override
  Future<void> deactivate() async {
    if (isNativeAvailable) {
      try {
        await _bridge.deactivateSession(sessionId);
      } on Object catch (error) {
        _recordNativeFailure(error);
      }
    }
  }

  @override
  Future<ImeComposition> inputKey(String key) async {
    _composition = isNativeAvailable
        ? _strokeComposition(candidates: const [])
        : _failureComposition();
    return _composition;
  }

  @override
  Future<ImeComposition> beginStroke(double x, double y) async {
    _activeStroke = [ImeStrokePoint(x: x, y: y)];
    _composition = _strokeComposition(candidates: const []);
    return _composition;
  }

  @override
  Future<ImeComposition> appendStrokePoint(double x, double y) async {
    _activeStroke?.add(ImeStrokePoint(x: x, y: y));
    _composition = _strokeComposition(candidates: const []);
    return _composition;
  }

  @override
  Future<ImeComposition> endStroke() async {
    final stroke = _activeStroke;
    if (stroke != null && stroke.isNotEmpty) {
      _strokes.add(stroke);
    }
    _activeStroke = null;
    _composition = _strokeComposition(candidates: const []);
    return _composition;
  }

  @override
  Future<ImeComposition> recognize() async {
    if (!isNativeAvailable) {
      _composition = _failureComposition();
      return _composition;
    }
    if (_strokes.isEmpty) {
      _composition = ImeComposition.empty(mode);
      return _composition;
    }
    late final List<NativeImeCandidate> candidates;
    try {
      candidates = await _bridge.recognize(
        sessionId: sessionId,
        strokes: _strokes,
      );
    } on Object catch (error) {
      _recordNativeFailure(error);
      return _composition;
    }
    _composition = _strokeComposition(
      candidates: [
        for (final candidate in candidates)
          ImeCandidate(
            text: candidate.text,
            annotation: candidate.annotation,
            score: candidate.score,
          ),
      ],
    );
    return _composition;
  }

  @override
  Future<ImeComposition> backspace() async {
    if (_strokes.isNotEmpty) {
      _strokes.removeLast();
    }
    _activeStroke = null;
    _composition = _strokeComposition(candidates: const []);
    return _composition;
  }

  @override
  Future<ImeComposition> clear() async {
    _strokes.clear();
    _activeStroke = null;
    if (!isNativeAvailable) {
      _composition = _failureComposition();
      return _composition;
    }
    _composition = ImeComposition.empty(mode);
    return _composition;
  }

  @override
  Future<ImeComposition> nextPage() async => _composition;

  @override
  Future<ImeComposition> previousPage() async => _composition;

  @override
  Future<ImeCommitResult> commitCandidate(int index) async {
    final candidates = _composition.candidates;
    if (index < 0 || index >= candidates.length) {
      return commitRaw();
    }
    final text = candidates[index].text;
    await clear();
    return ImeCommitResult(text: text, composition: _composition);
  }

  @override
  Future<ImeCommitResult> commitRaw() async {
    final text = _composition.rawInput;
    await clear();
    return ImeCommitResult(text: text, composition: _composition);
  }

  ImeComposition _strokeComposition({
    required List<ImeCandidate> candidates,
    String? errorMessage,
  }) {
    final count = _strokes.length + (_activeStroke == null ? 0 : 1);
    final rawInput = count == 0 ? '' : '$count 笔';
    return ImeComposition(
      mode: mode,
      rawInput: rawInput,
      preedit: rawInput,
      candidates: candidates,
      errorMessage: errorMessage,
    );
  }

  void _recordNativeFailure(Object error) {
    _nativeFailed = true;
    _nativeError = error.toString();
    _composition = _failureComposition();
  }

  ImeComposition _failureComposition() {
    final reason = nativeUnavailableReason ?? '未知错误';
    return _strokeComposition(
      candidates: const [],
      errorMessage: '手写识别不可用：$reason',
    );
  }
}
