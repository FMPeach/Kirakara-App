import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/data/local_db/local_database.dart';
import 'package:kirakara_app/services/search_service.dart';

void main() {
  late LocalDatabase database;
  late SearchService search;

  setUp(() {
    database = LocalDatabase(dbPath: ':memory:')..open();
    database.db.execute('''
      INSERT INTO songs (id, title, artist_line) VALUES
        ('10001', '较早歌曲', '较早歌手'),
        ('10003', '最新歌曲', '最新歌手'),
        ('10002', '较新歌曲', '较新歌手')
    ''');
    database.db.execute('''
      INSERT INTO artists (id, name, type) VALUES
        ('1', '较早歌手', 'solo'),
        ('3', '最新歌手', 'solo'),
        ('2', '较新歌手', 'solo')
    ''');
    database.db.execute('''
      INSERT INTO categories (id, type, name, note, ord) VALUES
        ('101', 'song', '较早分类', NULL, 1),
        ('103', 'song', '最新分类', NULL, 3),
        ('102', 'song', '较新分类', NULL, 2)
    ''');
    search = SearchService(db: database);
  });

  tearDown(() => database.close());

  test('歌曲、歌手和分类默认按数字 ID 从新到旧排列', () {
    expect(
      search.featuredSongs.map((song) => song.id),
      ['10003', '10002', '10001'],
    );
    expect(search.artists.map((artist) => artist.id), ['3', '2', '1']);
    expect(
      search.categories.map((category) => category.name),
      ['最新分类', '较新分类', '较早分类'],
    );
  });
}
