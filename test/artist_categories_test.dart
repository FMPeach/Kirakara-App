import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/data/catalog/catalog_models.dart';
import 'package:kirakara_app/data/local_db/local_database.dart';
import 'package:kirakara_app/services/bilibili_account_service.dart';
import 'package:kirakara_app/services/search_service.dart';
import 'package:kirakara_app/ui/browse/browse_mode.dart';
import 'package:kirakara_app/ui/screens/browse_screen.dart';
import 'package:kirakara_app/ui/theme/kirakara_theme.dart';
import 'package:kirakara_app/ui/widgets/kira_design_canvas.dart';

const _catalog = CatalogManifest(
  artists: [
    CatalogArtist(
        id: 'dual', name: '兼任创作者', type: 'solo', categoryIds: ['5', '6']),
    CatalogArtist(id: 'male', name: '单分类男歌手', type: 'solo', categoryIds: ['5']),
    CatalogArtist(
        id: 'producer', name: '单分类P主', type: 'creator', categoryIds: ['6']),
    CatalogArtist(
        id: 'punctuation', name: '标点分类歌手', type: 'solo', categoryIds: ['7']),
    CatalogArtist(id: 'uncategorized', name: '未分类歌手', type: 'solo'),
  ],
  categories: [
    CatalogCategory(id: '5', type: 'artist', name: '日本男歌手', order: 0),
    CatalogCategory(id: '6', type: 'artist', name: '日本VOCALOID P主', order: 1),
    CatalogCategory(id: '7', type: 'artist', name: '日本, 独立', order: 2),
  ],
);

Widget _page(WidgetTester tester, SearchService search) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final directory = Directory.systemTemp.createTempSync('kirakara_artist_');
  final account = BilibiliAccountService(
    sessionFilePath: '${directory.path}/unused-session.json',
  );
  addTearDown(() {
    account.dispose();
    directory.deleteSync(recursive: true);
  });
  return MaterialApp(
    theme: buildKirakaraTheme(),
    home: Scaffold(
      body: KiraDesignCanvas(
        child: BrowseScreen(
          searchService: search,
          bilibiliAccountService: account,
          initialMode: BrowseMode.artists,
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
  setUp(() {
    database = LocalDatabase(dbPath: ':memory:')..open();
    database.replaceAll(_catalog);
    search = SearchService(db: database);
  });
  tearDown(() => database.close());

  test('a multi-category artist belongs to each individual category', () {
    expect(search.searchArtists('', category: '日本男歌手').map((a) => a.id),
        ['dual', 'male']);
    expect(search.searchArtists('', category: '日本VOCALOID P主').map((a) => a.id),
        ['dual', 'producer']);
    expect(search.artists.where((a) => a.id == 'dual'), hasLength(1));
    expect(search.artists.singleWhere((a) => a.id == 'dual').type, 'solo');
  });

  test('artist text search is intersected with category membership', () {
    expect(search.searchArtists('VOCALOID', category: '日本男歌手').map((a) => a.id),
        ['dual']);
    expect(
        search.searchArtists('兼任', category: '日本VOCALOID P主').map((a) => a.id),
        ['dual']);
    expect(search.searchArtists('单分类男歌手', category: '日本VOCALOID P主'), isEmpty);
  });

  test('commas inside a category name are not interpreted as separators', () {
    expect(search.searchArtists('', category: '日本, 独立').map((a) => a.id),
        ['punctuation']);
    expect(search.searchArtists('', category: '日本'), isEmpty);
  });

  test('uncategorized artists stay in all but not in a named category', () {
    expect(
        search.searchArtists('').map((a) => a.id), contains('uncategorized'));
    expect(search.searchArtists('', category: '日本男歌手').map((a) => a.id),
        isNot(contains('uncategorized')));
  });

  test('catalog refresh invalidates cached artist memberships', () {
    search.artists;
    database.db.execute(
        "DELETE FROM artist_categories WHERE artist_id='dual' AND category_id='6'");
    search.invalidateCache();
    expect(search.searchArtists('', category: '日本VOCALOID P主').map((a) => a.id),
        ['producer']);
    expect(search.searchArtists('', category: '日本男歌手').map((a) => a.id),
        ['dual', 'male']);
  });

  testWidgets('artist rail lists independent categories and filters both ways',
      (tester) async {
    await tester.pumpWidget(_page(tester, search));
    expect(find.text('日本男歌手, 日本VOCALOID P主'), findsNothing);
    expect(find.text('日本男歌手'), findsOneWidget);
    expect(find.text('日本VOCALOID P主'), findsOneWidget);
    expect(find.text('兼任创作者'), findsOneWidget);

    await tester.tap(find.text('日本男歌手'));
    await tester.pump();
    expect(find.text('兼任创作者'), findsOneWidget);
    expect(find.text('单分类男歌手'), findsOneWidget);
    expect(find.text('单分类P主'), findsNothing);

    await tester.tap(find.text('日本VOCALOID P主'));
    await tester.pump();
    expect(find.text('兼任创作者'), findsOneWidget);
    expect(find.text('单分类P主'), findsOneWidget);
    expect(find.text('单分类男歌手'), findsNothing);
    await tester.enterText(find.byType(TextField), '兼任');
    await tester.pump();
    expect(find.text('兼任创作者'), findsOneWidget);
    expect(find.text('单分类P主'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed active artist category falls back to all',
      (tester) async {
    await tester.pumpWidget(_page(tester, search));
    final state = tester.state(find.byType(BrowseScreen));
    await tester.tap(find.text('日本VOCALOID P主'));
    await tester.pump();
    database.db.execute("DELETE FROM artist_categories WHERE category_id='6'");
    database.db.execute("DELETE FROM categories WHERE id='6'");
    search.invalidateCache();
    // Rebuild the page while retaining its BrowseScreen state and selection.
    await tester.pumpWidget(_page(tester, search));
    expect(tester.state(find.byType(BrowseScreen)), same(state));
    expect(find.text('日本VOCALOID P主'), findsNothing);
    expect(find.text('兼任创作者'), findsOneWidget);
    expect(find.text('未分类歌手'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
