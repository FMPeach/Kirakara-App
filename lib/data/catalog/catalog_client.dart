import 'dart:async';

import 'package:http/http.dart' as http;

import '../../domain/song.dart';
import '../../services/catalog_client.dart';
import 'catalog_endpoint_selector.dart';
import 'catalog_models.dart';
import 'catalog_urls.dart';

/// 通过 HTTP 从 catalog 服务器拉取索引。
///
/// 当前阶段返回解析后的 [CatalogManifest]，后续接入 SQLite 后会直接写入
/// 本地数据库并返回更新计数。
class HttpCatalogClient implements CatalogClient {
  HttpCatalogClient({
    required Uri baseUrl,
    CatalogEndpointSelector? endpointSelector,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 10),
  })  : _baseUrl = baseUrl,
        _endpointSelector = endpointSelector,
        _http = httpClient ?? http.Client();

  final Uri _baseUrl;
  final CatalogEndpointSelector? _endpointSelector;
  final http.Client _http;
  final Duration requestTimeout;

  /// 拉取全量 manifest。
  Future<CatalogManifest> fetchManifest() async {
    final selector = _endpointSelector;
    final baseUrl = selector == null ? _baseUrl : await selector.resolve();
    try {
      return await _fetchManifestFrom(baseUrl);
    } on Object {
      if (selector == null) rethrow;
      final fallback = await selector.tryFallbackAfter(baseUrl);
      if (fallback == null) rethrow;
      return _fetchManifestFrom(fallback);
    }
  }

  Future<CatalogManifest> _fetchManifestFrom(Uri baseUrl) async {
    final results = await Future.wait([
      _getBody(baseUrl.resolveUri(CatalogUrls.artists)),
      _getBody(baseUrl.resolveUri(CatalogUrls.songs)),
      _getBody(baseUrl.resolveUri(CatalogUrls.categories)),
      _getBody(baseUrl.resolveUri(CatalogUrls.rankings)),
    ]);

    return CatalogManifest.fromRawJsonBodies(
      artistsBody: results[0],
      songsBody: results[1],
      categoriesBody: results[2],
      rankingsBody: results[3],
    );
  }

  // ── CatalogClient interface ───────────────────────────────────

  @override
  Future<List<Song>> fetchUpdatedSongs({DateTime? since}) async {
    // 暂不实现增量，全量拉取后由上层调用方决定如何转换成 Song 列表。
    // 当前启动同步使用 fetchManifest，增量接口后续再接入。
    return const [];
  }

  @override
  Future<void> syncSongAssets(String songId) async {
    // PlaybackAssetCache 阶段再实现。
  }

  // ── helpers ───────────────────────────────────────────────────

  Future<String> _getBody(Uri uri) async {
    // 加随机数破缓存
    final url = uri.replace(queryParameters: {
      ...uri.queryParameters,
      'r': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    final response = await _http.get(url).timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw HttpException('GET $url → ${response.statusCode}');
    }
    return response.body;
  }

  void dispose() {
    _http.close();
  }
}

class HttpException implements Exception {
  const HttpException(this.message);
  final String message;

  @override
  String toString() => 'HttpException: $message';
}
