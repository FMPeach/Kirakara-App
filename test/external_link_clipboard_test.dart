import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/data/local_db/local_database.dart';
import 'package:kirakara_app/services/bilibili_account_service.dart';
import 'package:kirakara_app/services/clipboard_service.dart';
import 'package:kirakara_app/services/search_service.dart';
import 'package:kirakara_app/ui/browse/browse_mode.dart';
import 'package:kirakara_app/ui/screens/browse_screen.dart';
import 'package:kirakara_app/ui/theme/kirakara_theme.dart';
import 'package:kirakara_app/ui/widgets/kira_design_canvas.dart';

class _FakeClipboardService extends ClipboardService {
  const _FakeClipboardService(this.text);

  final String? text;

  @override
  Future<String?> readText() async => text;
}

void main() {
  testWidgets('explicit paste extracts only the Bilibili external-link field',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory =
        Directory.systemTemp.createTempSync('kirakara_clipboard_widget_');
    final account = BilibiliAccountService(
      sessionFilePath:
          '${directory.path}${Platform.pathSeparator}bilibili_session.json',
    );
    final database = LocalDatabase(dbPath: ':memory:')..open();
    final search = SearchService(db: database);
    addTearDown(() {
      account.dispose();
      database.close();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildKirakaraTheme(),
        home: Scaffold(
          body: KiraDesignCanvas(
            child: BrowseScreen(
              searchService: search,
              bilibiliAccountService: account,
              clipboardService: const _FakeClipboardService(
                '来自浏览器的标题\r\n'
                'https://www.bilibili.com/video/'
                'BV1xx411c7mD/?p=2\r\n更多说明',
              ),
              initialMode: BrowseMode.externalLink,
              onExit: () {},
              onAddSong: (_) {},
              onBumpSong: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('bilibili-paste-button')));
    await tester.pump();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('bilibili-external-link-field')),
    );
    const expected = 'https://www.bilibili.com/video/BV1xx411c7mD/?p=2';
    expect(field.controller?.text, expected);
    expect(field.controller?.selection.baseOffset, expected.length);
    expect(field.focusNode?.hasFocus, isTrue);
    expect(find.text('粘贴'), findsOneWidget);

    tester.testTextInput.enterText('$expected 中文');
    await tester.pump();
    expect(field.controller?.text, '$expected 中文');
    expect(field.focusNode?.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}
