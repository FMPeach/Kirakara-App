import '../domain/media_asset.dart';

class CacheService {
  Future<String?> cachedPathFor(MediaAsset asset) async {
    return asset.cachedPath;
  }

  Future<void> warmSongAssets(String songId) async {
    // Reserved for media, cover, and KRL prefetch.
  }
}
