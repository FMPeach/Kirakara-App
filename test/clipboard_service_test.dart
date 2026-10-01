import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/bilibili_clipboard_input.dart';
import 'package:kirakara_app/services/clipboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClipboardService', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('uses the standard Flutter text clipboard API', () async {
      MethodCall? observedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        observedCall = call;
        return <String, Object?>{'text': 'Kirakara 剪贴板 🙂'};
      });

      final text = await const ClipboardService().readText();

      expect(observedCall?.method, 'Clipboard.getData');
      expect(observedCall?.arguments, Clipboard.kTextPlain);
      expect(text, 'Kirakara 剪贴板 🙂');
    });

    test('returns null for an empty or unsupported text clipboard', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);

      expect(await const ClipboardService().readText(), isNull);
    });

    test('maps the Engine size limit without exposing clipboard content',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (_) async {
        throw PlatformException(
          code: 'Clipboard error',
          message: 'Clipboard text is too large',
          details: 111,
        );
      });

      await expectLater(
        const ClipboardService().readText(),
        throwsA(
          isA<ClipboardReadException>().having(
            (error) => error.failure,
            'failure',
            ClipboardReadFailure.tooLarge,
          ),
        ),
      );
    });
  });

  group('Bilibili clipboard input extraction', () {
    test('prefers a complete video URL and preserves its page query', () {
      expect(
        extractBilibiliClipboardInput(
          '分享给你：\r\n  https://www.bilibili.com/video/'
          'BV1xx411c7mD/?p=3&spm_id_from=333.1007  \r\n标题',
        ),
        'https://www.bilibili.com/video/'
        'BV1xx411c7mD/?p=3&spm_id_from=333.1007',
      );
    });

    test('accepts short links and removes surrounding punctuation', () {
      expect(
        extractBilibiliClipboardInput('短链【https://b23.tv/AbCd123】'),
        'https://b23.tv/AbCd123',
      );
    });

    test('extracts BV and AV ids from multiline share text', () {
      expect(
        extractBilibiliClipboardInput('标题\n bv1xx411c7mD \nUP主'),
        'BV1xx411c7mD',
      );
      expect(
        extractBilibiliClipboardInput('标题\r\nAV170001\r\nUP主'),
        'av170001',
      );
    });

    test('skips unrelated URL while extracting an embedded supported id', () {
      expect(
        extractBilibiliClipboardInput('https://example.com/video/BV1xx411c7mD'),
        'BV1xx411c7mD',
      );
      expect(extractBilibiliClipboardInput('170001'), isNull);
      expect(
        extractBilibiliClipboardInput(
          List<String>.filled(
            maxBilibiliClipboardInputCodeUnits + 1,
            'x',
          ).join(),
        ),
        isNull,
      );
    });
  });
}
