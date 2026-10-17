import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/chunk_helper_launcher.dart';
import 'package:kirakara_app/ui/controller/widgets/chunk_helper_button.dart';
import 'package:path/path.dart' as path;

void main() {
  test(
      'launches only the bundled executable, retaining spaces and dependencies',
      () async {
    final root = await Directory.systemTemp.createTemp('Kirakara 纯K助手 ');
    addTearDown(() => root.delete(recursive: true));
    final toolDirectory =
        Directory(path.join(root.path, 'tools', 'ChunKHelper'));
    await toolDirectory.create(recursive: true);
    final executable = File(path.join(toolDirectory.path, 'ChunK Helper.exe'));
    await executable.writeAsBytes([77, 90]);
    var calls = 0;
    final launcher = ChunKHelperLauncher(
      applicationDirectory: root.path,
      isWindows: true,
      processStarter: (exe, directory) async {
        calls++;
        expect(exe, executable.path);
        expect(directory, toolDirectory.path);
      },
    );
    expect(calls, 0);
    await launcher.launch();
    expect(calls, 1);
  });

  test('missing tool gives a useful error without shell or path fallback',
      () async {
    final root =
        await Directory.systemTemp.createTemp('Kirakara helper missing ');
    addTearDown(() => root.delete(recursive: true));
    var started = false;
    final launcher = ChunKHelperLauncher(
      applicationDirectory: root.path,
      isWindows: true,
      processStarter: (_, __) async {
        started = true;
      },
    );
    await expectLater(
        launcher.launch(), throwsA(isA<ChunKHelperLaunchException>()));
    expect(started, isFalse);
  });

  testWidgets(
      'button launches on click, prevents duplicate pending clicks, then prompts refresh',
      (tester) async {
    final completed = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChunKHelperButton(
      onLaunch: () {
        calls++;
        return completed.future;
      },
    ))));
    expect(calls, 0);
    await tester.tap(find.text('纯K助手'));
    await tester.pump();
    expect(calls, 1);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('chunk-helper-button')))
            .onPressed,
        isNull);
    completed.complete();
    await tester.pumpAndSettle();
    expect(find.text('纯K助手已启动，连接房台后请点击刷新设备。'), findsOneWidget);
  });

  testWidgets('launch error stays in the dialog instead of crashing the App',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChunKHelperButton(
      onLaunch: () async => throw const ChunKHelperLaunchException('测试缺失工具'),
    ))));
    await tester.tap(find.text('纯K助手'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试缺失工具'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
