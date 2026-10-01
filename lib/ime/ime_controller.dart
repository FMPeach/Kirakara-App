import 'package:flutter/foundation.dart';

import 'engines/english_ime_engine.dart';
import 'engines/mozc_ime_engine.dart';
import 'engines/numeric_ime_engine.dart';
import 'engines/rime_ime_engine.dart';
import 'engines/zinnia_handwriting_engine.dart';
import 'handwriting_stroke.dart';
import 'ime_composition.dart';
import 'ime_engine.dart';
import 'ime_mode.dart';
import 'search_query_controller.dart';

class ImeController extends ChangeNotifier {
  ImeController({
    required SearchQueryController searchQueryController,
    Map<ImeMode, ImeEngine>? engines,
  })  : _searchQueryController = searchQueryController,
        _engines = {
          ImeMode.english: EnglishImeEngine(),
          ImeMode.numeric: NumericImeEngine(),
          ImeMode.pinyin: RimeImeEngine(),
          ImeMode.japaneseRomaji: MozcImeEngine(),
          ImeMode.handwriting: ZinniaHandwritingEngine(),
          ...?engines,
        } {
    _activeEngine = _engines[ImeMode.english]!;
    _composition = ImeComposition.empty(ImeMode.english);
  }

  final SearchQueryController _searchQueryController;
  final Map<ImeMode, ImeEngine> _engines;

  late ImeEngine _activeEngine;
  late ImeComposition _composition;
  int _handwritingClearRevision = 0;

  ImeMode get mode => _activeEngine.mode;
  ImeComposition get composition => _composition;
  int get handwritingClearRevision => _handwritingClearRevision;

  Future<void> setMode(ImeMode mode) async {
    if (_activeEngine.mode == mode) {
      return;
    }
    await _activeEngine.deactivate();
    _activeEngine = _engines[mode]!;
    await _activeEngine.activate();
    _composition = await _activeEngine.clear();
    if (mode == ImeMode.handwriting) {
      _handwritingClearRevision += 1;
    }
    notifyListeners();
  }

  Future<void> handleKeyboardKey(String key) async {
    switch (key) {
      case '退格':
        await backspace();
      case '清空':
        await clearAll();
      case '空格':
        await space();
      case '搜索':
        await commitRaw();
      default:
        await inputKey(key);
    }
  }

  Future<void> inputKey(String key) async {
    if (key.isEmpty) {
      return;
    }
    if (mode == ImeMode.english || mode == ImeMode.numeric) {
      _composition = await _activeEngine.inputKey(key);
      final result = await _activeEngine.commitRaw();
      _searchQueryController.appendText(result.text);
      _composition = result.composition;
    } else {
      _composition = await _activeEngine.inputKey(key);
    }
    notifyListeners();
  }

  Future<void> backspace() async {
    if (_composition.rawInput.isNotEmpty) {
      _composition = await _activeEngine.backspace();
    } else {
      _searchQueryController.backspace();
    }
    notifyListeners();
  }

  Future<void> backspaceSearchText() async {
    _searchQueryController.backspace();
    notifyListeners();
  }

  Future<void> clearAll() async {
    _composition = await _activeEngine.clear();
    _searchQueryController.clear();
    _clearHandwritingPadIfActive();
    notifyListeners();
  }

  Future<void> clearComposition() async {
    _composition = await _activeEngine.clear();
    _clearHandwritingPadIfActive();
    notifyListeners();
  }

  Future<void> space() async {
    if (mode == ImeMode.english ||
        mode == ImeMode.numeric ||
        _composition.rawInput.isEmpty) {
      _searchQueryController.appendText(' ');
      notifyListeners();
      return;
    }
    if (_composition.candidates.isNotEmpty) {
      await commitCandidate(0);
      return;
    }
    await commitRaw();
  }

  Future<void> nextPage() async {
    _composition = await _activeEngine.nextPage();
    notifyListeners();
  }

  Future<void> previousPage() async {
    _composition = await _activeEngine.previousPage();
    notifyListeners();
  }

  Future<void> commitCandidate(int index) async {
    final shouldClearHandwritingPad = mode == ImeMode.handwriting;
    final result = await _activeEngine.commitCandidate(index);
    _searchQueryController.appendText(result.text);
    _composition = result.composition;
    if (shouldClearHandwritingPad) {
      _handwritingClearRevision += 1;
    }
    notifyListeners();
  }

  Future<void> commitRaw() async {
    if (_composition.rawInput.isEmpty) {
      return;
    }
    final shouldClearHandwritingPad = mode == ImeMode.handwriting;
    final result = await _activeEngine.commitRaw();
    _searchQueryController.appendText(result.text);
    _composition = result.composition;
    if (shouldClearHandwritingPad) {
      _handwritingClearRevision += 1;
    }
    notifyListeners();
  }

  Future<void> recognizeHandwritingStrokes(List<ImeStroke> strokes) async {
    if (_activeEngine is! HandwritingImeEngine) {
      return;
    }
    final handwritingEngine = _activeEngine as HandwritingImeEngine;
    _composition = await handwritingEngine.clear();
    for (final stroke in strokes) {
      if (stroke.isEmpty) {
        continue;
      }
      final first = stroke.first;
      _composition = await handwritingEngine.beginStroke(first.x, first.y);
      for (final point in stroke.skip(1)) {
        _composition =
            await handwritingEngine.appendStrokePoint(point.x, point.y);
      }
      _composition = await handwritingEngine.endStroke();
    }
    _composition = await handwritingEngine.recognize();
    notifyListeners();
  }

  void _clearHandwritingPadIfActive() {
    if (mode == ImeMode.handwriting) {
      _handwritingClearRevision += 1;
    }
  }
}
