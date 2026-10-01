import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../catalog/catalog_models.dart';

/// 本地 IndexCache — SQLite 持久存储 catalog 索引。
class LocalDatabase {
  LocalDatabase({String? dbPath}) : _dbPath = dbPath;

  final String? _dbPath;
  Database? _db;
  bool _open = false;

  Database get db {
    final d = _db;
    if (d == null) throw StateError('LocalDatabase not open');
    return d;
  }

  bool get isOpen => _open;

  // ── lifecycle ─────────────────────────────────────────────────

  /// 打开数据库（同步，sqlite3 的 open 是即时操作）。
  void open() {
    if (_open) return;
    final path = _dbPath ?? p.join('.', 'kirakara_index.db');
    _db = sqlite3.open(path);
    _createSchema();
    _open = true;
  }

  Future<void> close() async {
    _db?.dispose();
    _db = null;
    _open = false;
  }

  // ── schema ────────────────────────────────────────────────────

  void _createSchema() {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('''
      CREATE TABLE IF NOT EXISTS artists (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        type        TEXT NOT NULL,
        note        TEXT,
        avatar_uri  TEXT
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS artist_categories (
        artist_id   TEXT NOT NULL REFERENCES artists(id),
        category_id TEXT NOT NULL,
        PRIMARY KEY (artist_id, category_id)
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS songs (
        id                TEXT PRIMARY KEY,
        title             TEXT NOT NULL,
        artist_line       TEXT NOT NULL,
        primary_artist_id TEXT,
        cover_color       TEXT
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS song_categories (
        song_id     TEXT NOT NULL REFERENCES songs(id),
        category_id TEXT NOT NULL,
        PRIMARY KEY (song_id, category_id)
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS song_artists (
        song_id   TEXT NOT NULL REFERENCES songs(id),
        artist_id TEXT NOT NULL,
        role      TEXT NOT NULL,
        display   INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (song_id, artist_id, role)
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS song_credits (
        song_id   TEXT NOT NULL REFERENCES songs(id),
        name      TEXT NOT NULL,
        role      TEXT NOT NULL,
        entity_id TEXT,
        display   INTEGER NOT NULL DEFAULT 0
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS song_tags (
        song_id TEXT NOT NULL REFERENCES songs(id),
        tag     TEXT NOT NULL,
        PRIMARY KEY (song_id, tag)
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS song_search_hints (
        song_id TEXT NOT NULL REFERENCES songs(id),
        value   TEXT NOT NULL,
        PRIMARY KEY (song_id, value)
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS song_assets (
        song_id TEXT NOT NULL REFERENCES songs(id),
        type    TEXT NOT NULL,
        uri     TEXT NOT NULL,
        version INTEGER NOT NULL,
        hash    TEXT NOT NULL,
        size    INTEGER NOT NULL,
        PRIMARY KEY (song_id, type)
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS categories (
        id    TEXT PRIMARY KEY,
        type  TEXT NOT NULL,
        name  TEXT NOT NULL,
        note  TEXT,
        ord   INTEGER
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS rankings (
        category_id TEXT,
        name        TEXT NOT NULL,
        song_id     TEXT NOT NULL REFERENCES songs(id),
        rank        INTEGER NOT NULL,
        score       REAL,
        play_count  INTEGER
      )
    ''');
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS songs_fts USING fts5(
        title,
        artist_line,
        tags,
        search_hints,
        content='',
        tokenize='unicode61'
      )
    ''');
  }

  // ── 全量替换 ─────────────────────────────────────────────────

  /// 事务写入全量 manifest，替换旧索引。
  void replaceAll(CatalogManifest manifest) {
    db.execute('BEGIN');
    try {
      for (final table in _allTables) {
        db.execute('DELETE FROM $table');
      }
      // contentless FTS5 不支持 DELETE，用 DROP + CREATE 清空
      db.execute('DROP TABLE IF EXISTS songs_fts');
      db.execute('''
        CREATE VIRTUAL TABLE songs_fts USING fts5(
          title, artist_line, tags, search_hints,
          content='', tokenize='unicode61'
        )
      ''');

      for (final a in manifest.artists) {
        db.execute(
          'INSERT INTO artists (id, name, type, note, avatar_uri) VALUES (?, ?, ?, ?, ?)',
          [a.id, a.name, a.type, a.note, a.avatarUri],
        );
        for (final cid in a.categoryIds) {
          db.execute(
            'INSERT OR IGNORE INTO artist_categories (artist_id, category_id) VALUES (?, ?)',
            [a.id, cid],
          );
        }
      }

      for (final c in manifest.categories) {
        db.execute(
          'INSERT INTO categories (id, type, name, note, ord) VALUES (?, ?, ?, ?, ?)',
          [c.id, c.type, c.name, c.note, c.order],
        );
      }

      for (final s in manifest.songs) {
        db.execute(
          'INSERT INTO songs (id, title, artist_line, primary_artist_id, cover_color) VALUES (?, ?, ?, ?, ?)',
          [s.id, s.title, s.artistLine, s.primaryArtistId, s.coverColor],
        );
        for (final cid in s.categoryIds) {
          db.execute(
            'INSERT OR IGNORE INTO song_categories (song_id, category_id) VALUES (?, ?)',
            [s.id, cid],
          );
        }
        for (final ref in s.artistRefs) {
          db.execute(
            'INSERT OR IGNORE INTO song_artists (song_id, artist_id, role, display) VALUES (?, ?, ?, ?)',
            [s.id, ref.id, ref.role, ref.display ? 1 : 0],
          );
        }
        for (final cr in s.credits) {
          db.execute(
            'INSERT OR IGNORE INTO song_credits (song_id, name, role, entity_id, display) VALUES (?, ?, ?, ?, ?)',
            [s.id, cr.name, cr.role, cr.entityId, cr.display ? 1 : 0],
          );
        }
        for (final t in s.tags) {
          db.execute(
            'INSERT OR IGNORE INTO song_tags (song_id, tag) VALUES (?, ?)',
            [s.id, t],
          );
        }
        if (s.searchHints != null) {
          for (final h in s.searchHints!) {
            db.execute(
              'INSERT OR IGNORE INTO song_search_hints (song_id, value) VALUES (?, ?)',
              [s.id, h],
            );
          }
        }
        for (final a in s.assets) {
          db.execute(
            'INSERT OR IGNORE INTO song_assets (song_id, type, uri, version, hash, size) VALUES (?, ?, ?, ?, ?, ?)',
            [s.id, a.type, a.uri, a.version, a.hash, a.size],
          );
        }

        // FTS
        db.execute(
          'INSERT INTO songs_fts (rowid, title, artist_line, tags, search_hints) VALUES (?, ?, ?, ?, ?)',
          [_songRowId(s.id), s.title, s.artistLine, s.tags.join(' '), (s.searchHints ?? const []).join(' ')],
        );
      }

      for (final r in manifest.rankings) {
        for (final e in r.entries) {
          db.execute(
            'INSERT INTO rankings (category_id, name, song_id, rank, score, play_count) VALUES (?, ?, ?, ?, ?, ?)',
            [r.categoryId, r.name, e.songId, e.rank, e.score, e.playCount],
          );
        }
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ── query ─────────────────────────────────────────────────────

  ResultSet select(String sql, [List<Object?> params = const []]) =>
      db.select(sql, params);

  /// 执行查询并以 Map 列表返回。需显式传入列名顺序。
  List<Map<String, Object?>> selectMaps(
    String sql,
    List<String> columns, [
    List<Object?> params = const [],
  ]) {
    final rs = db.select(sql, params);
    final rows = <Map<String, Object?>>[];
    for (final row in rs) {
      final map = <String, Object?>{};
      for (var i = 0; i < columns.length && i < row.length; i++) {
        map[columns[i]] = row[i];
      }
      rows.add(map);
    }
    return rows;
  }

  // ── FTS ───────────────────────────────────────────────────────

  /// 返回匹配的 song id 列表。
  List<String> ftsSearch(String query) {
    if (query.trim().isEmpty) return const [];
    try {
      final rs = db.select(
        'SELECT rowid FROM songs_fts WHERE songs_fts MATCH ?',
        [_ftsQuery(query)],
      );
      return rs.map((r) {
        final v = r[0];
        return _songIdFromRowId(v is int ? v : (v as num).toInt());
      }).toList();
    } catch (_) {
      return _fallbackSearch(query);
    }
  }

  List<String> _fallbackSearch(String query) {
    final like = '%${query.replaceAll("'", "''")}%';
    final rs = db.select(
      'SELECT DISTINCT s.id FROM songs s '
      'LEFT JOIN song_tags st ON st.song_id = s.id '
      'LEFT JOIN song_search_hints sh ON sh.song_id = s.id '
      'WHERE s.title LIKE ?1 OR s.artist_line LIKE ?1 '
      'OR st.tag LIKE ?1 OR sh.value LIKE ?1',
      [like],
    );
    return rs.map((r) => r[0] as String).toList();
  }

  // ── private ───────────────────────────────────────────────────

  /// FTS rowid → songId：直接查 songs 表。小数据量足够，大数据量建议加映射表。
  static int _songRowId(String songId) {
    var h = 0;
    for (var i = 0; i < songId.length; i++) {
      h = (h * 31 + songId.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return h;
  }

  String? _songIdForRowId(int rowId) {
    final all = db.select('SELECT id FROM songs');
    for (final row in all) {
      final id = row[0] as String;
      if (_songRowId(id) == rowId) return id;
    }
    return null;
  }

  String _songIdFromRowId(int rowId) {
    return _songIdForRowId(rowId) ?? '';
  }

  String _ftsQuery(String raw) {
    return raw
        .trim()
        .split(RegExp(r'\s+'))
        .map((w) => '"$w"')
        .join(' AND ');
  }

  static const _allTables = [
    'artists', 'artist_categories',
    'songs', 'song_categories', 'song_artists', 'song_credits',
    'song_tags', 'song_search_hints', 'song_assets',
    'categories', 'rankings',
  ];
}
