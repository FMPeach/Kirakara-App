import 'ime_composition.dart';
import 'ime_mode.dart';

abstract class ImeEngine {
  ImeMode get mode;
  ImeComposition get composition;

  Future<void> activate();
  Future<void> deactivate();

  Future<ImeComposition> inputKey(String key);
  Future<ImeComposition> backspace();
  Future<ImeComposition> clear();
  Future<ImeComposition> nextPage();
  Future<ImeComposition> previousPage();

  Future<ImeCommitResult> commitCandidate(int index);
  Future<ImeCommitResult> commitRaw();
}

abstract class HandwritingImeEngine implements ImeEngine {
  Future<ImeComposition> beginStroke(double x, double y);
  Future<ImeComposition> appendStrokePoint(double x, double y);
  Future<ImeComposition> endStroke();
  Future<ImeComposition> recognize();
}

class ImeCommitResult {
  const ImeCommitResult({
    required this.text,
    required this.composition,
  });

  final String text;
  final ImeComposition composition;
}
