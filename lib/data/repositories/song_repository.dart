import '../../domain/song.dart';
import '../../services/search_service.dart';

class SongRepository {
  SongRepository({
    required SearchService searchService,
  }) : _searchService = searchService;

  final SearchService _searchService;

  Future<List<Song>> searchLocal(String query) {
    return _searchService.search(query);
  }

  Future<List<Song>> featuredLocal() async {
    return _searchService.featuredSongs;
  }
}
