import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/ime/engines/zinnia_handwriting_engine.dart';
import 'package:kirakara_app/ime/ime_controller.dart';
import 'package:kirakara_app/ime/ime_mode.dart';
import 'package:kirakara_app/ime/native/zinnia_native_bridge.dart';
import 'package:kirakara_app/ime/search_query_controller.dart';
import 'package:kirakara_app/ui/theme/kirakara_theme.dart';
import 'package:kirakara_app/ui/input/handwriting_pad.dart';
import 'package:kirakara_app/ui/input/karaoke_input_panel.dart';

void main() {
  testWidgets('touch keyboard unfocuses hardware IME text field',
      (tester) async {
    tester.view.physicalSize = const Size(640, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final search = SearchQueryController();
    final ime = ImeController(
      searchQueryController: search,
      engines: {
        ImeMode.handwriting: ZinniaHandwritingEngine(
          bridge: const UnavailableNativeHandwritingBridge(
            engineName: 'zinnia',
            reason: 'widget test',
          ),
        ),
      },
    );
    final focusNode = FocusNode(debugLabel: 'test-search');
    addTearDown(ime.dispose);
    addTearDown(search.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildKirakaraTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 488,
            height: 760,
            child: KaraokeInputPanel(
              activeTab: '歌名',
              placeholder: '搜索歌名、歌手、编号',
              controller: search.textController,
              searchFocusNode: focusNode,
              imeController: ime,
              onTab: (_) {},
              onSearch: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isFalse);
    expect(search.text, 'A');

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '残酷');
    await tester.pump();
    expect(search.text, '残酷');
  });

  testWidgets('handwriting native failure appears in the candidate bar',
      (tester) async {
    tester.view.physicalSize = const Size(640, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final search = SearchQueryController();
    final ime = ImeController(
      searchQueryController: search,
      engines: {
        ImeMode.handwriting: ZinniaHandwritingEngine(
          bridge: const UnavailableNativeHandwritingBridge(
            engineName: 'zinnia',
            reason: 'widget test',
          ),
        ),
      },
    );
    final focusNode = FocusNode(debugLabel: 'test-handwriting-search');
    addTearDown(ime.dispose);
    addTearDown(search.dispose);
    addTearDown(focusNode.dispose);

    await ime.setMode(ImeMode.handwriting);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKirakaraTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 488,
            height: 760,
            child: KaraokeInputPanel(
              activeTab: '歌名',
              placeholder: '搜索歌名、歌手、编号',
              controller: search.textController,
              searchFocusNode: focusNode,
              imeController: ime,
              onTab: (_) {},
              onSearch: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byType(HandwritingPad), findsOneWidget);
    expect(find.textContaining('手写识别不可用'), findsOneWidget);

    await tester.drag(find.byType(HandwritingPad), const Offset(80, 80));
    await tester.pumpAndSettle();

    expect(find.textContaining('手写识别不可用'), findsOneWidget);
    expect(find.text('1 残'), findsNothing);
    expect(search.text, isEmpty);

    await tester.tap(find.text('撤销一笔'));
    await tester.pumpAndSettle();
    expect(find.textContaining('手写识别不可用'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.textContaining('手写识别不可用'), findsOneWidget);
  });

  testWidgets('numeric mode shows a dial pad for song numbers', (tester) async {
    tester.view.physicalSize = const Size(640, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final search = SearchQueryController();
    final ime = ImeController(searchQueryController: search);
    final focusNode = FocusNode(debugLabel: 'test-numeric-search');
    addTearDown(ime.dispose);
    addTearDown(search.dispose);
    addTearDown(focusNode.dispose);

    await ime.setMode(ImeMode.numeric);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildKirakaraTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 488,
            height: 760,
            child: KaraokeInputPanel(
              activeTab: '歌名',
              placeholder: '搜索歌名、歌手、编号',
              controller: search.textController,
              searchFocusNode: focusNode,
              imeController: ime,
              onTab: (_) {},
              onSearch: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('数字'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.text('1'));
    await tester.tap(find.text('0'));
    await tester.tap(find.text('0'));
    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();

    expect(search.text, '1007');
    expect(tester.takeException(), isNull);
  });
}
