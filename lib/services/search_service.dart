import '../data/catalog/catalog_models.dart';
import '../data/local_db/local_database.dart';
import '../domain/artist.dart';
import '../domain/lyric_project.dart';
import '../domain/media_asset.dart';
import '../domain/song.dart';

/// Qu ku sou suo fu wu — cong LocalDatabase (SQLite) du qu.
///
/// Ruo shu ju ku wei kong, hui tui dao nei zhi zui xiao mock shu ju.
class SearchService {
  SearchService({required LocalDatabase db}) : _db = db;

  final LocalDatabase _db;
  List<Song>? _cachedSongs;
  List<ArtistSummary>? _cachedArtists;
  List<CategorySummary>? _cachedCategories;

  /// 服务器下发的枚举展示文案，由 catalog 同步后设置。
  CatalogLabelMaps? labelMaps;

  /// 同步后调用，使缓存失效。
  void invalidateCache() {
    _cachedSongs = null;
    _cachedArtists = null;
    _cachedCategories = null;
  }

  // ── Songs ──────────────────────────────────────────────────────

  List<Song> get featuredSongs => _allSongs();

  List<Song> _allSongs() {
    if (_cachedSongs != null) return _cachedSongs!;

    final rows = _db.selectMaps(
      'SELECT s.id, s.title, s.artist_line, s.primary_artist_id, s.cover_color '
      'FROM songs s ORDER BY s.id',
      ['id', 'title', 'artistLine', 'primaryArtistId', 'coverColor'],
    );
    if (rows.isEmpty) {
      _cachedSongs = const [];
      return _cachedSongs!;
    }

    // 批量获取所有 tags / categories / assets，避免 N+1 查询
    final allTags = <String, List<String>>{};
    for (final t in _db.selectMaps('SELECT song_id, tag FROM song_tags', ['songId', 'tag'])) {
      (allTags[t['songId'] as String] ??= []).add(t['tag'] as String);
    }

    final allCats = <String, String>{};
    for (final c in _db.selectMaps(
      "SELECT sc.song_id, c.name FROM song_categories sc JOIN categories c ON c.id = sc.category_id",
      ['songId', 'name'],
    )) {
      allCats.putIfAbsent(c['songId'] as String, () => c['name'] as String);
    }

    final allAssets = <String, List<Map<String, Object?>>>{};
    for (final a in _db.selectMaps(
      'SELECT song_id, type, uri, version FROM song_assets',
      ['songId', 'type', 'uri', 'version'],
    )) {
      (allAssets[a['songId'] as String] ??= []).add(a);
    }

    _cachedSongs = rows.map((r) {
      final id = r['id'] as String;
      final tags = allTags[id] ?? const [];
      final category = allCats[id] ?? '';
      final assetRows = allAssets[id] ?? const [];

      final assets = assetRows.map((a) {
        return MediaAsset(
          id: '$id-${a['type']}',
          type: _toAssetType(a['type'] as String),
          uri: Uri.parse(a['uri'] as String),
          version: a['version'] as int,
        );
      }).toList();

      final krlRow = assetRows.cast<Map<String, Object?>?>().firstWhere(
        (a) => a?['type'] == 'krl',
        orElse: () => null,
      );
      final lyricProject = krlRow != null
          ? LyricProject(
              id: '$id-krl', songId: id,
              krlUri: Uri.parse(krlRow['uri'] as String),
              version: krlRow['version'] as int,
            )
          : LyricProject(id: '$id-krl', songId: id, krlUri: Uri.parse(''), version: 1);

      final coverStr = r['coverColor'] as String?;
      final coverColor = coverStr != null
          ? int.parse(coverStr, radix: 16) | 0xFF000000
          : 0xffdd3e38;

      return Song(
        id: id, title: r['title'] as String,
        artist: Artist(
          id: r['primaryArtistId'] as String? ?? id,
          name: r['artistLine'] as String,
        ),
        category: category, code: id, tags: tags,
        coverColor: coverColor, assets: assets, lyricProject: lyricProject,
      );
    }).toList();

    return _cachedSongs!;
  }

  Future<List<Song>> search(String query) async {
    return searchSongs(query);
  }

  List<Song> searchSongs(String query, {Iterable<Song>? source}) {
    final pool = source ?? _allSongs();
    if (query.trim().isEmpty) return List.unmodifiable(pool);

    final matchedIds = _db.ftsSearch(query).toSet();
    if (matchedIds.isNotEmpty) {
      return pool.where((s) => matchedIds.contains(s.id)).toList();
    }

    final normalized = query.trim().toLowerCase();
    return pool.where((s) {
      final fields = [
        s.title, s.artist?.name ?? '未知', s.category, s.code ?? '', ...s.tags,
      ].join(' ').toLowerCase();
      return fields.contains(normalized);
    }).toList();
  }

  // ── Artists ────────────────────────────────────────────────────

  List<ArtistSummary> get artists {
    if (_cachedArtists != null) return _cachedArtists!;
    final rows = _db.selectMaps(
      "SELECT a.id, a.name, a.type, a.note, "
      "COALESCE((SELECT GROUP_CONCAT(c.name, ', ') "
      "FROM artist_categories ac JOIN categories c ON c.id = ac.category_id "
      "WHERE ac.artist_id = a.id), '') AS grp "
      "FROM artists a ORDER BY a.id",
      ['id', 'name', 'type', 'note', 'grp'],
    );
    if (rows.isEmpty) {
      _cachedArtists = const [];
      return _cachedArtists!;
    }
    _cachedArtists = rows.map((r) => ArtistSummary(
      id: r['id'] as String,
      name: r['name'] as String,
      type: r['type'] as String,
      group: (r['grp'] as String?) ?? '',
      note: (r['note'] as String?) ?? '',
    )).toList();
    return _cachedArtists!;
  }

  List<ArtistSummary> searchArtists(String query, {String category = '全部'}) {
    final all = artists;
    final q = query.trim().toLowerCase();
    return all.where((a) {
      final catOk = category == '全部' || a.group == category;
      final searchOk = q.isEmpty ||
          [a.name, a.type, a.group, a.note].join(' ').toLowerCase().contains(q);
      return catOk && searchOk;
    }).toList();
  }

  List<Song> songsForArtist(ArtistSummary artist, {String query = ''}) {
    final rows = _db.selectMaps(
      'SELECT song_id FROM song_artists WHERE artist_id = ?', ['songId'], [artist.id],
    );
    final ids = rows.map((r) => r['songId'] as String).toSet();
    if (ids.isEmpty) return searchSongs(query);

    final pool = _allSongs().where((s) => ids.contains(s.id));
    return searchSongs(query, source: pool);
  }

  int songCountForArtist(ArtistSummary artist) {
    final rs = _db.select(
      'SELECT COUNT(*) FROM song_artists WHERE artist_id = ?', [artist.id],
    );
    if (rs.isEmpty) return 0;
    final count = rs.first[0];
    return (count is int) ? count : 0;
  }

  // ── Rankings ──────────────────────────────────────────────────

  /// 服务器下发的榜单定义（按 rank 排序）。空表返回 []。
  List<CatalogRanking> get rankings {
    final rows = _db.selectMaps(
      'SELECT category_id, name, song_id, rank, score, play_count '
      'FROM rankings ORDER BY rank',
      ['categoryId', 'name', 'songId', 'rank', 'score', 'playCount'],
    );
    if (rows.isEmpty) return const [];
    final names = <String, String>{};
    final grouped = <String, List<CatalogRankingEntry>>{};
    for (final r in rows) {
      final key = (r['categoryId'] as String?) ?? '';
      names[key] = r['name'] as String;
      (grouped[key] ??= []).add(CatalogRankingEntry(
        rank: (r['rank'] as num).toInt(),
        songId: r['songId'] as String,
        score: r['score'] as num?,
        playCount: (r['playCount'] as num?)?.toInt(),
      ));
    }
    return grouped.entries.map((e) {
      final list = e.value..sort((a, b) => a.rank.compareTo(b.rank));
      return CatalogRanking(
        categoryId: e.key.isEmpty ? null : e.key,
        name: names[e.key] ?? '',
        entries: list,
      );
    }).toList();
  }

  /// 榜单条目映射为 Song（按 rank 排序，曲库里缺失的跳过）。
  List<Song> songsForRanking(CatalogRanking ranking) {
    final byId = {for (final s in _allSongs()) s.id: s};
    return ranking.entries
        .map((e) => byId[e.songId])
        .whereType<Song>()
        .toList();
  }

  // ── Categories ─────────────────────────────────────────────────

  List<CategorySummary> get categories {
    if (_cachedCategories != null) return _cachedCategories!;
    final rows = _db.selectMaps(
      "SELECT name, note FROM categories WHERE type = 'song' ORDER BY ord",
      ['name', 'note'],
    );
    if (rows.isEmpty) {
      _cachedCategories = const [];
      return _cachedCategories!;
    }
    _cachedCategories = rows.map((r) => CategorySummary(
      name: r['name'] as String,
      note: (r['note'] as String?) ?? '',
    )).toList();
    return _cachedCategories!;
  }

  List<Song> songsForCategory(CategorySummary category, {String query = ''}) {
    final catRows = _db.selectMaps(
      'SELECT id FROM categories WHERE name = ?', ['id'], [category.name],
    );
    if (catRows.isEmpty) return searchSongs(query);

    final catId = catRows.first['id'] as String;
    final songRows = _db.selectMaps(
      'SELECT song_id FROM song_categories WHERE category_id = ?', ['songId'], [catId],
    );
    final ids = songRows.map((r) => r['songId'] as String).toSet();
    if (ids.isEmpty) return searchSongs(query);

    final pool = _allSongs().where((s) => ids.contains(s.id));
    return searchSongs(query, source: pool);
  }

  // ── helpers ───────────────────────────────────────────────────

  static MediaAssetType _toAssetType(String t) {
    return switch (t) {
      'video' => MediaAssetType.video,
      'vocal' => MediaAssetType.vocal,
      'inst'  => MediaAssetType.accompaniment,
      'cover' => MediaAssetType.cover,
      'krl'   => MediaAssetType.lyric,
      _       => MediaAssetType.video,
    };
  }
}

// ── UI view models ───────────────────────────────────────────────

class ArtistSummary {
  const ArtistSummary({
    required this.id,
    required this.name,
    required this.type,
    required this.group,
    required this.note,
  });

  final String id;
  final String name;
  final String type;
  final String group;
  final String note;
}

class CategorySummary {
  const CategorySummary({
    required this.name,
    required this.note,
  });

  final String name;
  final String note;
}
