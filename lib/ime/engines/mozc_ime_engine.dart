import '../ime_candidate.dart';
import '../ime_composition.dart';
import '../ime_engine.dart';
import '../ime_mode.dart';
import '../native/ime_native_bridge.dart';
import '../native/mozc_native_bridge.dart';

class MozcImeEngine implements ImeEngine {
  MozcImeEngine({
    NativeImeBridge? bridge,
    this.sessionId = 'kirakara-mozc-session',
  }) : _bridge = bridge ?? const MozcNativeBridgeProbe().probe();

  final NativeImeBridge _bridge;
  final String sessionId;

  String _rawInput = '';
  int _pageIndex = 0;
  bool _nativeFailed = false;
  String? _nativeError;
  ImeComposition _composition = ImeComposition.empty(ImeMode.japaneseRomaji);

  @override
  ImeMode get mode => ImeMode.japaneseRomaji;

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
    _rawInput = '$_rawInput${key.toLowerCase()}';
    _pageIndex = 0;
    if (!isNativeAvailable) {
      _composition = _failureComposition();
      return _composition;
    }
    try {
      _composition = await _composeNative();
    } on Object catch (error) {
      _recordNativeFailure(error);
    }
    return _composition;
  }

  @override
  Future<ImeComposition> backspace() async {
    if (_rawInput.isNotEmpty) {
      _rawInput = _rawInput.substring(0, _rawInput.length - 1);
    }
    _pageIndex = 0;
    if (!isNativeAvailable) {
      _composition = _failureComposition();
      return _composition;
    }
    try {
      _composition = _rawInput.isEmpty
          ? ImeComposition.empty(mode)
          : await _composeNative();
    } on Object catch (error) {
      _recordNativeFailure(error);
    }
    return _composition;
  }

  @override
  Future<ImeComposition> clear() async {
    _rawInput = '';
    _pageIndex = 0;
    if (!isNativeAvailable) {
      _composition = _failureComposition();
      return _composition;
    }
    try {
      final result = await _bridge.clear(sessionId);
      _composition = _fromNative(result);
    } on Object catch (error) {
      _recordNativeFailure(error);
    }
    return _composition;
  }

  @override
  Future<ImeComposition> nextPage() async {
    if (!isNativeAvailable) {
      _composition = _failureComposition();
      return _composition;
    }
    if (_composition.hasNextPage) {
      _pageIndex += 1;
      try {
        _composition = await _composeNative();
      } on Object catch (error) {
        _recordNativeFailure(error);
      }
    }
    return _composition;
  }

  @override
  Future<ImeComposition> previousPage() async {
    if (!isNativeAvailable) {
      _composition = _failureComposition();
      return _composition;
    }
    if (_pageIndex > 0) {
      _pageIndex -= 1;
      try {
        _composition = await _composeNative();
      } on Object catch (error) {
        _recordNativeFailure(error);
      }
    }
    return _composition;
  }

  @override
  Future<ImeCommitResult> commitCandidate(int index) async {
    final candidates = _composition.candidates;
    final text = index >= 0 && index < candidates.length
        ? candidates[index].text
        : _rawInput;
    await clear();
    return ImeCommitResult(text: text, composition: _composition);
  }

  @override
  Future<ImeCommitResult> commitRaw() async {
    final text = _rawInput;
    await clear();
    return ImeCommitResult(text: text, composition: _composition);
  }

  Future<ImeComposition> _composeNative() async {
    final result = await _bridge.compose(
      sessionId: sessionId,
      rawInput: _rawInput,
      pageIndex: _pageIndex,
    );
    return _fromNative(result);
  }

  void _recordNativeFailure(Object error) {
    _nativeFailed = true;
    _nativeError = error.toString();
    _composition = _failureComposition();
  }

  ImeComposition _failureComposition() {
    final reason = nativeUnavailableReason ?? '未知错误';
    return ImeComposition(
      mode: mode,
      rawInput: _rawInput,
      preedit: _rawInput,
      candidates: const [],
      errorMessage: '日语输入法不可用：$reason',
    );
  }

  ImeComposition _fromNative(NativeImeResult result) {
    return ImeComposition(
      mode: mode,
      rawInput: result.rawInput,
      preedit: result.preedit,
      candidates: [
        for (final candidate in result.candidates)
          ImeCandidate(
            text: candidate.text,
            annotation: candidate.annotation,
            score: candidate.score,
          ),
      ],
      pageIndex: result.pageIndex,
      hasPreviousPage: result.hasPreviousPage,
      hasNextPage: result.hasNextPage,
    );
  }
}
