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
    CatalogArtist(id: '1', name: '有歌歌手', type: 'solo'),
    CatalogArtist(id: '2', name: '空歌手', type: 'solo'),
    CatalogArtist(id: '3', name: '', type: 'other'),
    CatalogArtist(id: '4', name: '其他歌手', type: 'solo'),
  ],
  categories: [
    CatalogCategory(id: '101', type: 'artist', name: '同名分类'),
    CatalogCategory(id: '102', type: 'song', name: '歌曲分类'),
    CatalogCategory(id: '103', type: 'song', name: '空分类'),
    CatalogCategory(id: '104', type: 'song', name: '同名分类'),
  ],
  songs: [
    CatalogSong(
      id: '10001',
      title: '范围内旧歌',
      artistLine: '有歌歌手',
      artistRefs: [CatalogArtistRef(id: '1', role: 'vocal')],
      categoryIds: ['102'],
    ),
    CatalogSong(
      id: '10002',
      title: '无关歌曲',
      artistLine: '其他歌手',
      artistRefs: [CatalogArtistRef(id: '4', role: 'vocal')],
    ),
    CatalogSong(
      id: '10003',
      title: '范围内新歌',
      artistLine: '有歌歌手',
      artistRefs: [CatalogArtistRef(id: '1', role: 'vocal')],
      categoryIds: ['102', '104'],
    ),
  ],
);

const _ranking = CatalogRanking(
  categoryId: null,
  name: '测试榜单',
  entries: [
    CatalogRankingEntry(rank: 1, songId: '10001'),
    CatalogRankingEntry(rank: 2, songId: '10003'),
    CatalogRankingEntry(rank: 3, songId: '99999'),
  ],
);

Widget _page(
  SearchService search,
  BilibiliAccountService account,
  BrowseMode mode, {
  VoidCallback? onExit,
}) {
  return MaterialApp(
    theme: buildKirakaraTheme(),
    home: Scaffold(
      body: KiraDesignCanvas(
        child: BrowseScreen(
          searchService: search,
          bilibiliAccountService: account,
          initialMode: mode,
          onExit: onExit ?? () {},
          onAddSong: (_) {},
          onBumpSong: (_) {},
        ),
      ),
    ),
  );
}

void _prepareView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _expectNoSongs() {
  for (final song in _catalog.songs) {
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == song.title,
      ),
      findsNothing,
    );
  }
}

void main() {
  late LocalDatabase database;
  late SearchService search;
  late BilibiliAccountService account;
  late Directory directory;

  setUp(() {
    database = LocalDatabase(dbPath: ':memory:')..open();
    database.replaceAll(_catalog);
    search = SearchService(db: database);
    directory = Directory.systemTemp.createTempSync('kirakara_empty_catalog_');
    account = BilibiliAccountService(
      sessionFilePath: '${directory.path}/unused-session.json',
    );
  });

  tearDown(() async {
    account.dispose();
    await database.close();
    directory.deleteSync(recursive: true);
  });

  test('空歌手和已移除歌手保持空结果，包括命中其他歌曲的搜索', () {
    final emptyArtist = search.artists.singleWhere((a) => a.id == '2');
    for (final query in ['', '无关歌曲']) {
      expect(search.songsForArtist(emptyArtist, query: query), isEmpty);
    }
    database.db.execute("DELETE FROM artists WHERE id = '2'");
    search.invalidateCache();
    expect(search.songsForArtist(emptyArtist), isEmpty);
    expect(search.featuredSongs, hasLength(3));
  });

  test('空分类和不存在的分类保持空结果，包括命中其他歌曲的搜索', () {
    for (final name in ['空分类', '不存在的分类']) {
      for (final query in ['', '无关歌曲']) {
        expect(
          search.songsForCategory(
            CategorySummary(name: name, note: ''),
            query: query,
          ),
          isEmpty,
        );
      }
    }
  });

  test('有内容的歌手和分类维持范围和排序，同名歌手分类不干扰歌曲分类', () {
    final artist = search.artists.singleWhere((a) => a.id == '1');
    const category = CategorySummary(name: '歌曲分类', note: '');
    expect(search.songsForArtist(artist).map((s) => s.id), ['10003', '10001']);
    expect(
        search.songsForCategory(category).map((s) => s.id), ['10003', '10001']);
    expect(search.songsForArtist(artist, query: '无关歌曲'), isEmpty);
    expect(search.songsForCategory(category, query: '无关歌曲'), isEmpty);
    expect(
      search
          .songsForCategory(const CategorySummary(name: '同名分类', note: ''))
          .map((s) => s.id),
      ['10003'],
    );
    expect(search.searchSongs('', source: const []), isEmpty);
    expect(search.searchSongs('无关歌曲', source: const []), isEmpty);
  });

  test('榜单为空或仅引用缺失歌曲时保持空，已有排名顺序不变', () {
    expect(search.rankings, isEmpty);
    expect(
      search
          .songsForRanking(const CatalogRanking(categoryId: null, name: '空榜')),
      isEmpty,
    );
    expect(
        search.songsForRanking(_ranking).map((s) => s.id), ['10001', '10003']);
    expect(
      search.songsForRanking(const CatalogRanking(
        categoryId: null,
        name: '缺失歌曲榜',
        entries: [CatalogRankingEntry(rank: 1, songId: '99999')],
      )),
      isEmpty,
    );
  });

  test('全量同步可以清空并恢复歌曲、歌手、分类和榜单缓存', () {
    search.featuredSongs;
    search.artists;
    search.categories;
    database.replaceAll(CatalogManifest.fromRawJsonBodies(
      artistsBody: '[]',
      songsBody: '[]',
      categoriesBody: '{"items":[]}',
      rankingsBody: '[]',
    ));
    search.invalidateCache();
    expect(search.featuredSongs, isEmpty);
    expect(search.searchSongs('无关歌曲'), isEmpty);
    expect(search.artists, isEmpty);
    expect(search.categories, isEmpty);
    expect(search.rankings, isEmpty);
    database.replaceAll(_catalog);
    search.invalidateCache();
    expect(search.featuredSongs, hasLength(3));
    expect(search.artists, hasLength(4));
    expect(search.categories, hasLength(3));
  });

  test('空名称和空关联的占位数据可以正常读取', () {
    database.replaceAll(CatalogManifest.fromRawJsonBodies(
      artistsBody: '[{"id":"5","name":null}]',
      songsBody: '[{"id":"10004","title":null,"artistLine":null}]',
      categoriesBody: '{"items":[{"id":"105","name":null}]}',
      rankingsBody: '[{"name":"待统计","entries":[]}]',
    ));
    search.invalidateCache();
    expect(search.featuredSongs.single.title, isEmpty);
    expect(search.artists.single.name, isEmpty);
    expect(search.songsForArtist(search.artists.single), isEmpty);
    expect(search.categories.single.name, isEmpty);
    expect(search.songsForCategory(search.categories.single), isEmpty);
    expect(search.rankings, isEmpty);
  });

  testWidgets('空排行榜显示空状态，不显示曲库歌曲且可以返回', (tester) async {
    _prepareView(tester);
    var exited = false;
    await tester.pumpWidget(_page(search, account, BrowseMode.ranking,
        onExit: () => exited = true));
    expect(find.text('暂无排行数据'), findsOneWidget);
    _expectNoSongs();
    await tester.tap(find.text('返回'));
    expect(exited, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('榜单清空后移除旧歌曲，再同步后恢复排名内容', (tester) async {
    _prepareView(tester);
    void updateRankings(List<CatalogRanking> rankings) {
      database.replaceAll(CatalogManifest(
        artists: _catalog.artists,
        categories: _catalog.categories,
        songs: _catalog.songs,
        rankings: rankings,
      ));
      search.invalidateCache();
    }

    updateRankings([_ranking]);
    await tester.pumpWidget(_page(search, account, BrowseMode.ranking));
    final state = tester.state(find.byType(BrowseScreen));
    expect(find.text('范围内旧歌'), findsOneWidget);
    expect(find.text('无关歌曲'), findsNothing);
    updateRankings(const []);
    await tester.pumpWidget(_page(search, account, BrowseMode.ranking));
    expect(tester.state(find.byType(BrowseScreen)), same(state));
    expect(find.text('暂无排行数据'), findsOneWidget);
    _expectNoSongs();
    updateRankings([_ranking]);
    await tester.pumpWidget(_page(search, account, BrowseMode.ranking));
    expect(find.text('范围内旧歌'), findsOneWidget);
    expect(find.text('范围内新歌'), findsOneWidget);
    expect(find.text('暂无排行数据'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空歌手详情及其搜索保持为空', (tester) async {
    _prepareView(tester);
    await tester.pumpWidget(_page(search, account, BrowseMode.artists));
    await tester.tap(find.text('空歌手'));
    await tester.pump();
    expect(find.text('该歌手暂无歌曲'), findsOneWidget);
    _expectNoSongs();
    await tester.enterText(find.byType(TextField), '无关歌曲');
    await tester.pump();
    _expectNoSongs();
    expect(find.text('共 0 首歌曲'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pump();
    expect(find.text('有歌歌手'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌手详情在关联歌曲移除和恢复后更新，不回填其他歌曲', (tester) async {
    _prepareView(tester);
    await tester.pumpWidget(_page(search, account, BrowseMode.artists));
    await tester.tap(find.text('有歌歌手'));
    await tester.pump();
    expect(find.text('范围内新歌'), findsOneWidget);
    database.db.execute("DELETE FROM song_artists WHERE artist_id = '1'");
    search.invalidateCache();
    await tester.pumpWidget(_page(search, account, BrowseMode.artists));
    expect(find.text('该歌手暂无歌曲'), findsOneWidget);
    _expectNoSongs();
    database.replaceAll(_catalog);
    search.invalidateCache();
    await tester.pumpWidget(_page(search, account, BrowseMode.artists));
    expect(find.text('范围内新歌'), findsOneWidget);
    expect(find.text('无关歌曲'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [BrowseMode.categories, BrowseMode.songs]) {
    testWidgets('$mode 空分类及其搜索保持为空', (tester) async {
      _prepareView(tester);
      await tester.pumpWidget(_page(search, account, mode));
      await tester.tap(find.text('空分类').first);
      await tester.pump();
      expect(find.text('该分类暂无歌曲'), findsOneWidget);
      _expectNoSongs();
      await tester.enterText(find.byType(TextField), '无关歌曲');
      await tester.pump();
      expect(find.text('没有找到匹配歌曲'), findsOneWidget);
      _expectNoSongs();
      expect(tester.takeException(), isNull);
    });

    testWidgets('$mode 当前分类保留占位，歌曲移除后清空并可恢复', (tester) async {
      _prepareView(tester);
      await tester.pumpWidget(_page(search, account, mode));
      await tester.tap(find.text('歌曲分类').first);
      await tester.pump();
      expect(find.text('范围内新歌'), findsOneWidget);
      database.db
          .execute("DELETE FROM song_categories WHERE category_id = '102'");
      search.invalidateCache();
      await tester.pumpWidget(_page(search, account, mode));
      expect(find.text('该分类暂无歌曲'), findsOneWidget);
      _expectNoSongs();
      database.replaceAll(_catalog);
      search.invalidateCache();
      await tester.pumpWidget(_page(search, account, mode));
      expect(find.text('范围内新歌'), findsOneWidget);
      expect(find.text('无关歌曲'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('未选择歌手的详情保持为空，不擅自选择曲库第一位歌手', (tester) async {
    _prepareView(tester);
    await tester.pumpWidget(_page(search, account, BrowseMode.artistDetail));
    expect(find.text('暂无歌手'), findsWidgets);
    _expectNoSongs();
    expect(tester.takeException(), isNull);
  });

  testWidgets('空歌手名使用占位头像，仍可进入空详情', (tester) async {
    _prepareView(tester);
    await tester.pumpWidget(_page(search, account, BrowseMode.artists));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('?'));
    await tester.pump();
    expect(find.text('共 0 首歌曲'), findsOneWidget);
    _expectNoSongs();
    expect(tester.takeException(), isNull);
  });

  for (final entry in {
    BrowseMode.songs: '暂无歌曲',
    BrowseMode.artists: '没有匹配歌手',
    BrowseMode.categories: '暂无歌曲分类',
    BrowseMode.ranking: '暂无排行数据',
    BrowseMode.artistDetail: '暂无歌手',
  }.entries) {
    testWidgets('${entry.key} 全空曲库仍可浏览和返回', (tester) async {
      _prepareView(tester);
      database.replaceAll(const CatalogManifest());
      search.invalidateCache();
      await tester.pumpWidget(_page(search, account, entry.key));
      expect(find.text(entry.value), findsWidgets);
      expect(find.text('返回'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
