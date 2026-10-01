import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/ime/engines/mozc_ime_engine.dart';
import 'package:kirakara_app/ime/engines/rime_ime_engine.dart';
import 'package:kirakara_app/ime/ime_controller.dart';
import 'package:kirakara_app/ime/ime_mode.dart';
import 'package:kirakara_app/ime/native/ime_native_bridge.dart';
import 'package:kirakara_app/ime/search_query_controller.dart';

void main() {
  test('IME controller separates composition from committed search text',
      () async {
    final search = SearchQueryController();
    final ime = ImeController(
      searchQueryController: search,
      engines: {
        ImeMode.pinyin: RimeImeEngine(
          bridge: const _ControllerTestImeBridge({'lv': '绿'}),
        ),
        ImeMode.japaneseRomaji: MozcImeEngine(
          bridge: const _ControllerTestImeBridge({'zankoku': '残酷'}),
        ),
      },
    );
    addTearDown(ime.dispose);
    addTearDown(search.dispose);

    await ime.handleKeyboardKey('A');
    expect(search.text, 'A');
    expect(ime.composition.rawInput, isEmpty);

    await ime.setMode(ImeMode.pinyin);
    await ime.handleKeyboardKey('L');
    await ime.handleKeyboardKey('V');

    expect(search.text, 'A');
    expect(ime.composition.rawInput, 'lv');
    expect(ime.composition.candidates.map((c) => c.text), contains('绿'));

    await ime.commitCandidate(0);
    expect(search.text, 'A绿');
    expect(ime.composition.rawInput, isEmpty);

    await ime.handleKeyboardKey('退格');
    expect(search.text, 'A');

    await ime.handleKeyboardKey('清空');
    expect(search.text, isEmpty);

    await ime.setMode(ImeMode.numeric);
    for (final key in ['1', '0', '0', '7']) {
      await ime.handleKeyboardKey(key);
    }
    expect(search.text, '1007');
    expect(ime.composition.rawInput, isEmpty);

    await ime.handleKeyboardKey('退格');
    expect(search.text, '100');
    await ime.handleKeyboardKey('清空');
    expect(search.text, isEmpty);

    await ime.setMode(ImeMode.japaneseRomaji);
    for (final key in ['Z', 'A', 'N', 'K', 'O', 'K', 'U']) {
      await ime.handleKeyboardKey(key);
    }
    expect(
      ime.composition.candidates.map((c) => c.text),
      contains('残酷'),
    );

    await ime.handleKeyboardKey('空格');
    expect(search.text, '残酷');
    expect(ime.composition.rawInput, isEmpty);
  });
}

class _ControllerTestImeBridge implements NativeImeBridge {
  const _ControllerTestImeBridge(this.conversions);

  final Map<String, String> conversions;

  @override
  String get engineName => 'test';

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

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
    final candidate = conversions[rawInput];
    return NativeImeResult(
      rawInput: rawInput,
      preedit: rawInput,
      candidates:
          candidate == null ? const [] : [NativeImeCandidate(text: candidate)],
    );
  }

  @override
  Future<NativeImeResult> clear(String sessionId) async {
    return const NativeImeResult(
      rawInput: '',
      preedit: '',
      candidates: [],
    );
  }
}
