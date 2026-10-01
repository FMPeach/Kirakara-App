/// Kirakara Catalog API v1 — 端点集合
///
/// 用法：
/// ```dart
/// final base = Uri.parse('http://localhost:7391');
/// final artistsUrl = base.resolveUri(CatalogUrls.artists);
/// ```
class CatalogUrls {
  CatalogUrls._();

  // ── 相对路径 ──────────────────────────────────────────────────

  static final artists = Uri.parse('/api/catalog/artists');
  static final songs = Uri.parse('/api/catalog/songs');
  static final categories = Uri.parse('/api/catalog/categories');
  static final rankings = Uri.parse('/api/catalog/rankings');

  /// 分类筛选排行榜
  static Uri rankingsForCategory(String categoryId) =>
      Uri.parse('/api/catalog/rankings?category=$categoryId');

  // ── 静态资源 ──────────────────────────────────────────────────

  /// 歌曲媒体目录前缀，/media/songs/{songId}/
  static String songMediaDir(String songId) => '/media/songs/$songId';

  /// 歌手头像，/media/artists/{artistId}/avatar.jpg
  static String artistAvatar(String artistId) =>
      '/media/artists/$artistId/avatar.jpg';
}
