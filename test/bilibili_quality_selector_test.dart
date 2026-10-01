import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/data/local_db/local_database.dart';
import 'package:kirakara_app/services/bilibili_account_service.dart';
import 'package:kirakara_app/services/search_service.dart';
import 'package:kirakara_app/ui/browse/browse_mode.dart';
import 'package:kirakara_app/ui/screens/browse_screen.dart';
import 'package:kirakara_app/ui/theme/kirakara_theme.dart';
import 'package:kirakara_app/ui/widgets/kira_design_canvas.dart';

class _SignedInAccountService extends BilibiliAccountService {
  _SignedInAccountService(String sessionFilePath)
      : super(sessionFilePath: sessionFilePath);

  int _qualityQn = 116;

  @override
  bool get isLoggedIn => true;

  @override
  BilibiliAccountProfile get profile => const BilibiliAccountProfile(
        name: '测试用户',
        faceUrl: '',
        signature: '测试简介',
      );

  @override
  int get preferredQualityQn => _qualityQn;

  @override
  Future<void> load() async {}

  @override
  Future<void> startLoginFlow() async {}

  @override
  void stopQrPolling() {}

  @override
  Future<void> setPreferredQualityQn(int qn) async {
    _qualityQn = qn;
    notifyListeners();
  }
}

void main() {
  testWidgets('quality popup follows the fitted 1920x1080 canvas scale',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory =
        Directory.systemTemp.createTempSync('kirakara_quality_menu_');
    final account = _SignedInAccountService(
      '${directory.path}${Platform.pathSeparator}session.json',
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
              initialMode: BrowseMode.externalLink,
              onExit: () {},
              onAddSong: (_) {},
              onBumpSong: (_) {},
            ),
          ),
        ),
      ),
    );

    final selector = find.byKey(const ValueKey('bilibili-quality-selector'));
    final fieldRect = tester.getRect(selector);
    await tester.tap(selector);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final button = tester.widget<PopupMenuButton<int>>(selector);
    expect(button.constraints!.maxWidth, closeTo(fieldRect.width, 0.5));
    expect(button.shape, isA<RoundedRectangleBorder>());
    final shape = button.shape! as RoundedRectangleBorder;
    final borderRadius = shape.borderRadius as BorderRadius;
    expect(borderRadius.topLeft.x, closeTo(20 / 3, 0.1));

    final option = find.byKey(const ValueKey('bilibili-quality-option-120'));
    final optionWidget = tester.widget<PopupMenuItem<int>>(option);
    final optionRect = tester.getRect(option);
    expect(optionWidget.height, closeTo(32, 0.1));
    expect(optionRect.width, closeTo(fieldRect.width, 0.5));

    final label = tester.widget<Text>(
      find.descendant(of: option, matching: find.byType(Text)),
    );
    expect(label.data, '4K 超清');
    expect(label.style!.fontFamily, 'Microsoft YaHei UI');
    expect(label.style!.fontSize, closeTo(12, 0.1));
    expect(find.textContaining('QN'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(1270, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });
}
