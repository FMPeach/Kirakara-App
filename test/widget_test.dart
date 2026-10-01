import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/app/kirakara_app.dart';
import 'package:kirakara_app/ui/widgets/kira_design_canvas.dart';

/// 在临时目录预写 settings.json 并返回路径；随 tearDown 自动清理。
String _prepareSettingsFile(String announcement) {
  final dir = Directory.systemTemp.createTempSync('kirakara_widget_test');
  final path = '${dir.path}${Platform.pathSeparator}settings.json';
  File(path).writeAsStringSync(
    jsonEncode({'custom_announcement': announcement}),
    flush: true,
  );
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 测试清理失败可忽略
    }
  });
  return path;
}

void main() {
  testWidgets('Kirakara controller shell renders', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TickerMode(
      enabled: false,
      child: KirakaraApp(databasePath: ':memory:'),
    ));
    await tester.pump();

    final wordmark = find.byWidgetPredicate((widget) {
      return widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName ==
              'assets/branding/wordmark.png' &&
          widget.semanticLabel == 'Kira Karaoke';
    });
    expect(wordmark, findsOneWidget);
    final appIcon = find.byWidgetPredicate((widget) {
      return widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName ==
              'assets/branding/app_icon.png' &&
          widget.semanticLabel == 'Kirakara app icon';
    });
    expect(appIcon, findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.text('投屏'), findsOneWidget);
    expect(find.text('主控'), findsNothing);
    expect(find.text('歌名点歌'), findsOneWidget);
    expect(find.text('点歌列表'), findsOneWidget);
    expect(find.byType(KiraDesignCanvas), findsOneWidget);

    final fixedStage = find.byWidgetPredicate((widget) {
      return widget is SizedBox &&
          widget.width == KiraDesignCanvas.stageSize.width &&
          widget.height == KiraDesignCanvas.stageSize.height;
    });
    expect(fixedStage, findsOneWidget);

    final fittedStage = find.byWidgetPredicate((widget) {
      return widget is FittedBox && widget.fit == BoxFit.contain;
    });
    expect(fittedStage, findsOneWidget);

    await tester.tap(find.text('投屏'));
    await tester.pump();
    expect(find.text('显示输出'), findsOneWidget);
    expect(find.text('双屏异显'), findsOneWidget);
    expect(find.text('无线投屏'), findsOneWidget);
    expect(find.text('深度搜索（慎用）'), findsNothing);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pump();

    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    expect(find.text('报幕文字'), findsOneWidget);
    expect(find.text('深度搜索（慎用）'), findsOneWidget);
    final deepSearchSwitch = tester.widget<Switch>(
      find.byKey(const ValueKey('dlna-deep-search-switch')),
    );
    expect(deepSearchSwitch.value, isFalse);
    expect(find.text('媒体缓存'), findsOneWidget);
    expect(find.text('队列预缓存范围'), findsOneWidget);
  });

  testWidgets('browse pages render inside the controller shell',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const TickerMode(
      enabled: false,
      child: KirakaraApp(databasePath: ':memory:'),
    ));
    await tester.pump();

    await tester.tap(find.text('歌名点歌').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('搜索歌名、歌手、编号'), findsWidgets);
    expect(find.text('搜索范围'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('返回').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('歌手点歌').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('地区与类型'), findsOneWidget);
    if (find.text('没有匹配歌手').evaluate().isNotEmpty) {
      expect(tester.takeException(), isNull);
      return;
    }
    expect(find.text('緑黄色社会'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('緑黄色社会').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('共 2 首歌曲'), findsOneWidget);
    expect(find.text('在歌手内搜索'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('返回').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('分类').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('番剧 OP / ED / 插曲'), findsOneWidget);
    expect(find.text('在当前分类中搜索歌曲、歌手、编号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('external-link page shows the Bilibili account rail',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settingsFile = _prepareSettingsFile('');

    await tester.pumpWidget(
      TickerMode(
        enabled: false,
        child: KirakaraApp(
          databasePath: ':memory:',
          settingsFilePath: settingsFile,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('外链点歌').first);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('登录 Bilibili 账号'), findsOneWidget);
    expect(find.text('刷新二维码'), findsOneWidget);
    expect(
        find.textContaining('https://www.bilibili.com/video'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long ticker keeps a clear gap between repeated runs',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settingsFile = _prepareSettingsFile(
      List.filled(
        10,
        '欢迎使用 Kira Karaoke，请使用手机点歌并留意下一首歌曲',
      ).join('，'),
    );

    await tester.pumpWidget(
      KirakaraApp(databasePath: ':memory:', settingsFilePath: settingsFile),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final leading = find.byKey(const ValueKey('marquee-leading-run'));
    final trailing = find.byKey(const ValueKey('marquee-trailing-run'));
    expect(leading, findsOneWidget);
    expect(trailing, findsOneWidget);

    void expectRunGap() {
      final leadingRect = tester.getRect(leading);
      final trailingRect = tester.getRect(trailing);
      expect(trailingRect.left - leadingRect.right, greaterThanOrEqualTo(95));
    }

    expectRunGap();
    await tester.pump(const Duration(seconds: 12));
    expectRunGap();
    expect(tester.takeException(), isNull);
  });

  testWidgets('near-boundary ticker scrolls before punctuation can overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settingsFile = _prepareSettingsFile('');

    await tester.pumpWidget(TickerMode(
      enabled: false,
      child:
          KirakaraApp(databasePath: ':memory:', settingsFilePath: settingsFile),
    ));
    await tester.pump();

    await tester.tap(find.text('歌名点歌').first);
    await tester.pump(const Duration(milliseconds: 300));

    final viewport = find.byKey(const ValueKey('marquee-viewport'));
    final staticRun = find.byKey(const ValueKey('marquee-static-run'));
    expect(viewport, findsOneWidget);
    expect(staticRun, findsOneWidget);

    final baseWidget = tester.widget<Text>(staticRun);
    final baseText = baseWidget.data!;
    final textContext = tester.element(staticRun);
    final effectiveStyle =
        DefaultTextStyle.of(textContext).style.merge(baseWidget.style);
    final availableWidth = tester.getSize(viewport).width;

    String? boundaryAnnouncement;
    for (var wideCount = 0;
        wideCount <= 100 && boundaryAnnouncement == null;
        wideCount += 1) {
      for (var narrowCount = 0;
          narrowCount <= 110 - wideCount;
          narrowCount += 1) {
        final announcement = 'MyGO!!!!!'
            '${List.filled(wideCount, '歌').join()}'
            '${List.filled(narrowCount, 'i').join()}';
        final ticker = '$announcement  ·  $baseText';
        final painter = TextPainter(
          text: TextSpan(text: ticker, style: effectiveStyle),
          maxLines: 1,
          textDirection: Directionality.of(textContext),
          textScaler: MediaQuery.textScalerOf(textContext),
          locale: Localizations.maybeLocaleOf(textContext),
        )..layout();
        final width = painter.width;
        painter.dispose();
        if (width > availableWidth - 12 && width <= availableWidth) {
          boundaryAnnouncement = announcement;
          break;
        }
      }
    }
    expect(boundaryAnnouncement, isNotNull);
    final announcement = boundaryAnnouncement!;
    expect(announcement.length, lessThanOrEqualTo(120));

    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    final announcementField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '留空则不显示自定义文字',
    );
    expect(announcementField, findsOneWidget);
    await tester.enterText(announcementField, announcement);
    await tester.tap(find.text('应用'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const ValueKey('marquee-leading-run')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('marquee-trailing-run')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('marquee-static-run')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('physical dual-screen hard-cuts the low-motion announcement',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const windowChannel = MethodChannel('kirakara/window');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      return switch (call.method) {
        'getDisplays' => <Object?>[
            <String, Object?>{
              'id': 'controller',
              'name': 'Controller',
              'isPrimary': true,
              'left': 0,
              'top': 0,
              'width': 1920,
              'height': 1080,
            },
            <String, Object?>{
              'id': 'stage',
              'name': 'Stage',
              'isPrimary': false,
              'left': 1920,
              'top': 0,
              'width': 1920,
              'height': 1080,
            },
          ],
        'isControllerFullscreen' => false,
        _ => null,
      };
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(windowChannel, null),
    );

    await tester.pumpWidget(const KirakaraApp(databasePath: ':memory:'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byKey(const ValueKey('low-motion-announcement')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('marquee-viewport')), findsNothing);
    expect(
      find.byKey(const ValueKey('low-motion-fade-switcher')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('low-motion-announcement')),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    expect(find.textContaining('当前播放：'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('下一首：'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
