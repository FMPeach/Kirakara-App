import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _allowClipboardMutation = bool.fromEnvironment(
  'KIRAKARA_ALLOW_CLIPBOARD_MUTATION',
);
const _expectClipboardRetry = bool.fromEnvironment(
  'KIRAKARA_EXPECT_CLIPBOARD_RETRY',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'stock Windows Clipboard API round-trips Unicode text',
    (_) async {
      final previous = await Clipboard.getData(Clipboard.kTextPlain);
      const sample = 'Kirakara 剪贴板基线 🙂\r\n第二行';
      try {
        await Clipboard.setData(const ClipboardData(text: sample));
        final result = await Clipboard.getData(Clipboard.kTextPlain);
        expect(result?.text, sample);
      } finally {
        await Clipboard.setData(ClipboardData(text: previous?.text ?? ''));
      }
    },
    skip: !Platform.isWindows || !_allowClipboardMutation,
  );

  testWidgets(
    'Windows text editing keeps copy cut paste Shift+Insert and context menu',
    (tester) async {
      final previous = await Clipboard.getData(Clipboard.kTextPlain);
      final controller = TextEditingController(text: 'Kirakara 快捷键');
      final focusNode = FocusNode();
      addTearDown(() {
        controller.dispose();
        focusNode.dispose();
      });

      Future<void> chord(
        LogicalKeyboardKey modifier,
        LogicalKeyboardKey key,
      ) async {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextField(
                key: const ValueKey('clipboard-shortcut-field'),
                controller: controller,
                focusNode: focusNode,
              ),
            ),
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('clipboard-shortcut-field')),
        );
        await tester.pump();

        controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: controller.text.length,
        );
        await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyC);
        expect(
          (await Clipboard.getData(Clipboard.kTextPlain))?.text,
          'Kirakara 快捷键',
        );

        await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyX);
        expect(controller.text, isEmpty);
        await chord(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyV);
        expect(controller.text, 'Kirakara 快捷键');

        controller.clear();
        await Clipboard.setData(const ClipboardData(text: 'Shift Insert'));
        await chord(LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.insert);
        expect(controller.text, 'Shift Insert');

        controller.clear();
        await Clipboard.setData(const ClipboardData(text: 'Context Paste'));
        final field = find.byKey(const ValueKey('clipboard-shortcut-field'));
        await tester.tapAt(
          tester.getCenter(field),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        final paste = find.text('Paste');
        expect(paste, findsOneWidget);
        await tester.tap(paste);
        await tester.pumpAndSettle();
        expect(controller.text, 'Context Paste');
        expect(focusNode.hasFocus, isTrue);
      } finally {
        await Clipboard.setData(ClipboardData(text: previous?.text ?? ''));
      }
    },
    skip: !Platform.isWindows || !_allowClipboardMutation,
  );

  testWidgets(
    'custom Windows Clipboard API retries transient ownership asynchronously',
    (_) async {
      final previous = await Clipboard.getData(Clipboard.kTextPlain);
      const sample = 'Kirakara contention probe';
      final temporaryDirectory =
          await Directory.systemTemp.createTemp('kirakara_clipboard_retry_');
      final readyFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}ready.txt',
      );
      Process? holder;
      try {
        await Clipboard.setData(const ClipboardData(text: sample));
        final holderScript = File(
          '${Directory.current.path}${Platform.pathSeparator}tool'
          '${Platform.pathSeparator}windows_clipboard'
          '${Platform.pathSeparator}hold_clipboard.ps1',
        );
        expect(holderScript.existsSync(), isTrue);
        holder = await Process.start(
          'powershell.exe',
          <String>[
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            holderScript.path,
            '-ReadyPath',
            readyFile.path,
            '-DurationMilliseconds',
            '120',
          ],
        );

        final readyDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (
            !readyFile.existsSync() && DateTime.now().isBefore(readyDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(readyFile.existsSync(), isTrue);

        final stopwatch = Stopwatch()..start();
        final result = await Clipboard.getData(Clipboard.kTextPlain);
        stopwatch.stop();
        expect(result?.text, sample);
        expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(50));
        expect(stopwatch.elapsedMilliseconds, lessThan(1000));
        expect(await holder.exitCode, 0);
      } finally {
        holder?.kill();
        await Clipboard.setData(ClipboardData(text: previous?.text ?? ''));
        if (temporaryDirectory.existsSync()) {
          temporaryDirectory.deleteSync(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows ||
        !_allowClipboardMutation ||
        !_expectClipboardRetry,
  );
}
