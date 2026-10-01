import '../ime_composition.dart';
import '../ime_engine.dart';
import '../ime_mode.dart';

class EnglishImeEngine implements ImeEngine {
  ImeComposition _composition = ImeComposition.empty(ImeMode.english);

  @override
  ImeMode get mode => ImeMode.english;

  @override
  ImeComposition get composition => _composition;

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {
    await clear();
  }

  @override
  Future<ImeComposition> inputKey(String key) async {
    _composition = ImeComposition(
      mode: mode,
      rawInput: key,
      preedit: key,
      candidates: const [],
    );
    return _composition;
  }

  @override
  Future<ImeComposition> backspace() async {
    return clear();
  }

  @override
  Future<ImeComposition> clear() async {
    _composition = ImeComposition.empty(mode);
    return _composition;
  }

  @override
  Future<ImeComposition> nextPage() async => _composition;

  @override
  Future<ImeComposition> previousPage() async => _composition;

  @override
  Future<ImeCommitResult> commitCandidate(int index) async {
    return commitRaw();
  }

  @override
  Future<ImeCommitResult> commitRaw() async {
    final text = _composition.rawInput;
    await clear();
    return ImeCommitResult(text: text, composition: _composition);
  }
}
