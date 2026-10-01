import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/ime/engines/rime_ime_engine.dart';
import 'package:kirakara_app/ime/native/ime_native_bridge.dart';
import 'package:kirakara_app/ime/native/rime_native_bridge.dart';

void main() {
  test('Rime bridge requests the shared 25 candidate page size', () {
    const bridge = RimeNativeBridge(channel: MethodChannel('test/rime'));

    expect(bridge.pageSize, defaultImeCandidatePageSize);
    expect(bridge.pageSize, 25);
  });

  test('Rime engine exposes native failure without fake candidates', () async {
    final engine = RimeImeEngine(
      bridge: const UnavailableNativeImeBridge(
        engineName: 'rime',
        reason: 'test unavailable bridge',
      ),
    );

    expect(engine.isNativeAvailable, isFalse);
    await engine.inputKey('L');
    final composition = await engine.inputKey('V');

    expect(composition.rawInput, 'lv');
    expect(composition.candidates, isEmpty);
    expect(composition.errorMessage, contains('拼音输入法不可用'));
    expect(composition.errorMessage, contains('test unavailable bridge'));

    final commit = await engine.commitRaw();
    expect(commit.text, 'lv');
  });

  test('Rime engine maps native bridge candidates into composition', () async {
    final engine = RimeImeEngine(bridge: _FakeRimeBridge());

    expect(engine.isNativeAvailable, isTrue);
    await engine.inputKey('L');
    final composition = await engine.inputKey('V');

    expect(composition.rawInput, 'lv');
    expect(composition.preedit, 'lv');
    expect(composition.candidates.single.text, '旅');

    final commit = await engine.commitCandidate(0);
    expect(commit.text, '旅');
    expect(commit.composition.rawInput, isEmpty);
  });
}

class _FakeRimeBridge implements NativeImeBridge {
  @override
  String get engineName => 'rime';

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
    return NativeImeResult(
      rawInput: rawInput,
      preedit: rawInput,
      candidates: [
        NativeImeCandidate(text: rawInput == 'lv' ? '旅' : rawInput),
      ],
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
