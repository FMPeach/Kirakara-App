import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/ime/engines/mozc_ime_engine.dart';
import 'package:kirakara_app/ime/native/ime_native_bridge.dart';
import 'package:kirakara_app/ime/native/mozc_native_bridge.dart';

void main() {
  test('Mozc bridge requests the shared 25 candidate page size', () {
    const bridge = MozcNativeBridge(executablePath: 'unused');

    expect(bridge.pageSize, defaultImeCandidatePageSize);
    expect(bridge.pageSize, 25);
  });

  test('Mozc engine exposes native failure without fake candidates', () async {
    final engine = MozcImeEngine(
      bridge: const UnavailableNativeImeBridge(
        engineName: 'mozc',
        reason: 'test bridge is intentionally unavailable',
      ),
    );

    expect(engine.isNativeAvailable, isFalse);
    for (final key in ['Z', 'A', 'N', 'K', 'O', 'K', 'U']) {
      await engine.inputKey(key);
    }

    expect(engine.composition.rawInput, 'zankoku');
    expect(engine.composition.candidates, isEmpty);
    expect(engine.composition.errorMessage, contains('日语输入法不可用'));
    expect(
      engine.composition.errorMessage,
      contains('test bridge is intentionally unavailable'),
    );
  });

  test('Mozc engine maps native bridge candidates into composition', () async {
    final engine = MozcImeEngine(bridge: _FakeMozcBridge());

    expect(engine.isNativeAvailable, isTrue);
    for (final key in ['N', 'I', 'H', 'O', 'N', 'G', 'O']) {
      await engine.inputKey(key);
    }

    expect(engine.composition.rawInput, 'nihongo');
    expect(engine.composition.candidates.single.text, '日本語');

    final commit = await engine.commitCandidate(0);
    expect(commit.text, '日本語');
    expect(commit.composition.rawInput, isEmpty);
  });

  final helper = File(
    'third_party/ime/mozc/windows/runtime/kirakara_mozc_bridge.exe',
  );
  test(
    'Mozc helper returns real Japanese candidates without catalog matching',
    () async {
      final bridge = MozcNativeBridge(executablePath: helper.absolute.path);
      final result = await bridge.compose(
        sessionId: 'test-mozc-session',
        rawInput: 'nihongo',
        pageIndex: 0,
      );

      expect(result.rawInput, 'nihongo');
      expect(result.preedit, isNotEmpty);
      expect(result.candidates.map((candidate) => candidate.text),
          contains('日本語'));
      expect(
        result.candidates.map((candidate) => candidate.text),
        isNot(contains('残酷な天使のテーゼ')),
      );
    },
    skip: !Platform.isWindows || !helper.existsSync()
        ? 'Mozc helper runtime is only built on Windows'
        : null,
  );
}

class _FakeMozcBridge implements NativeImeBridge {
  @override
  String get engineName => 'mozc';

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
        NativeImeCandidate(text: rawInput == 'nihongo' ? '日本語' : rawInput),
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
