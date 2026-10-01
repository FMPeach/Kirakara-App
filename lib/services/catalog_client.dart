import '../domain/song.dart';

abstract class CatalogClient {
  Future<List<Song>> fetchUpdatedSongs({DateTime? since});
  Future<void> syncSongAssets(String songId);
}
