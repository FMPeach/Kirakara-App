import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/ime/engines/zinnia_handwriting_engine.dart';
import 'package:kirakara_app/ime/handwriting_stroke.dart';
import 'package:kirakara_app/ime/native/ime_native_bridge.dart';
import 'package:kirakara_app/ime/native/zinnia_native_bridge.dart';

void main() {
  test('Zinnia handwriting engine exposes native recognition failure',
      () async {
    final engine = ZinniaHandwritingEngine(
      bridge: const UnavailableNativeHandwritingBridge(
        engineName: 'zinnia',
        reason: 'test',
      ),
    );

    expect(engine.isNativeAvailable, isFalse);
    await engine.beginStroke(0, 0);
    await engine.appendStrokePoint(24, 36);
    await engine.endStroke();
    final composition = await engine.recognize();

    expect(composition.rawInput, '1 笔');
    expect(composition.candidates, isEmpty);
    expect(composition.errorMessage, contains('手写识别不可用'));
    expect(composition.errorMessage, contains('test'));
  });

  test('Zinnia handwriting engine maps native candidates', () async {
    final engine = ZinniaHandwritingEngine(bridge: _FakeZinniaBridge());

    expect(engine.isNativeAvailable, isTrue);
    await engine.beginStroke(0, 0);
    await engine.appendStrokePoint(24, 36);
    await engine.endStroke();
    final composition = await engine.recognize();

    expect(composition.candidates.single.text, '星');

    final commit = await engine.commitCandidate(0);
    expect(commit.text, '星');
    expect(commit.composition.rawInput, isEmpty);
  });
}

class _FakeZinniaBridge implements NativeHandwritingBridge {
  @override
  String get engineName => 'zinnia';

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<void> activateSession(String sessionId) async {}

  @override
  Future<void> deactivateSession(String sessionId) async {}

  @override
  Future<List<NativeImeCandidate>> recognize({
    required String sessionId,
    required List<ImeStroke> strokes,
  }) async {
    return const [
      NativeImeCandidate(text: '星', annotation: 'zinnia'),
    ];
  }
}
