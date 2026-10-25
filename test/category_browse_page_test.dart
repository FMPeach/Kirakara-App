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

Widget _categoryPage(SearchService search, BilibiliAccountService account) {
  return MaterialApp(
    theme: buildKirakaraTheme(),
    home: Scaffold(
      body: KiraDesignCanvas(
        child: BrowseScreen(
          searchService: search,
          bilibiliAccountService: account,
          initialMode: BrowseMode.categories,
          onExit: () {},
          onAddSong: (_) {},
          onBumpSong: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  late LocalDatabase database;
  late SearchService search;
  late BilibiliAccountService account;
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('kirakara_categories_');
    account = BilibiliAccountService(
      sessionFilePath:
          '${directory.path}${Platform.pathSeparator}bilibili_session.json',
    );
    database = LocalDatabase(dbPath: ':memory:')..open();
    search = SearchService(db: database);
    database.db.execute('''
      INSERT INTO categories (id, type, name, note, ord) VALUES
        ('anime', 'song', '动漫', '动画歌曲', 0),
        ('pop', 'song', '流行', '流行歌曲', 1)
    ''');
    database.db.execute('''
      INSERT INTO songs (id, title, artist_line) VALUES
        ('1', '动画测试歌曲', '测试歌手'),
        ('2', '流行测试歌曲', '测试歌手')
    ''');
    database.db.execute('''
      INSERT INTO song_categories (song_id, category_id) VALUES
        ('1', 'anime'), ('2', 'pop')
    ''');
  });

  tearDown(() async {
    account.dispose();
    await database.close();
    directory.deleteSync(recursive: true);
  });

  testWidgets('category fallback, selection and search still work', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_categoryPage(search, account));
    expect(find.text('动画测试歌曲'), findsOneWidget);
    expect(find.text('流行测试歌曲'), findsNothing);

    await tester.tap(find.text('流行').first);
    await tester.pump();
    expect(find.text('流行测试歌曲'), findsOneWidget);
    expect(find.text('动画测试歌曲'), findsNothing);

    await tester.enterText(find.byType(TextField), '没有这首歌');
    await tester.pump();
    expect(find.text('没有找到匹配歌曲'), findsOneWidget);
    expect(find.text('暂无歌曲分类'), findsNothing);
    expect(find.text('返回'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog refresh can remove and restore the active category', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_categoryPage(search, account));
    await tester.tap(find.text('流行').first);
    await tester.pump();
    expect(find.text('流行测试歌曲'), findsOneWidget);

    database.db.execute('DELETE FROM song_categories');
    database.db.execute('DELETE FROM categories');
    search.invalidateCache();
    await tester.pumpWidget(_categoryPage(search, account));
    expect(find.text('暂无歌曲分类'), findsOneWidget);
    expect(find.text('流行测试歌曲'), findsNothing);
    expect(find.text('动画测试歌曲'), findsNothing);
    expect(find.text('返回'), findsOneWidget);
    expect(tester.takeException(), isNull);

    database.db.execute('''
      INSERT INTO categories (id, type, name, note, ord)
      VALUES ('anime', 'song', '动漫', '动画歌曲', 0)
    ''');
    database.db.execute('''
      INSERT INTO song_categories (song_id, category_id) VALUES ('1', 'anime')
    ''');
    search.invalidateCache();
    await tester.pumpWidget(_categoryPage(search, account));
    expect(find.text('动画测试歌曲'), findsOneWidget);
    expect(find.text('暂无歌曲分类'), findsNothing);
    expect(find.text('返回'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
