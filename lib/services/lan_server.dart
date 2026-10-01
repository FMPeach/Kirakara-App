import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/queue_item.dart';
import '../domain/song.dart';
import 'bilibili_account_service.dart';
import 'bilibili_resolver.dart';
import 'lan_address_resolver.dart';
import 'playback_service.dart';
import 'queue_service.dart';
import 'search_service.dart';

class LanServer {
  LanServer({
    required QueueService queueService,
    required SearchService searchService,
    required PlaybackService playbackService,
    required BilibiliAccountService bilibiliAccountService,
    InternetAddress? bindAddress,
  })  : _queueService = queueService,
        _searchService = searchService,
        _playbackService = playbackService,
        _bilibiliAccountService = bilibiliAccountService,
        _bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  final QueueService _queueService;
  final SearchService _searchService;
  final PlaybackService _playbackService;
  final BilibiliAccountService _bilibiliAccountService;
  final InternetAddress _bindAddress;
  HttpServer? _server;
  String? _lanIp;

  bool get isRunning => _server != null;
  Uri? get localUri {
    if (_server == null || _lanIp == null) return null;
    return Uri.parse('http://$_lanIp:${_server!.port}');
  }

  Future<void> start({int port = 7391}) async {
    if (_server != null) return;
    _lanIp = _bindAddress.address == InternetAddress.anyIPv4.address
        ? await LanAddressResolver.detectIpv4()
        : _bindAddress.address;
    _server = await HttpServer.bind(_bindAddress, port);
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _lanIp = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // CORS
    request.response.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    final method = request.method;

    // ── Static HTML ──────────────────────────────────────────
    if (method == 'GET' && (path == '/' || path == '/index.html')) {
      await _serveFile(request, 'html/mobile-request.html', 'text/html; charset=utf-8');
      return;
    }
    if (method == 'GET' && path.startsWith('/static/')) {
      await _serveStatic(request, path);
      return;
    }

    // ── API ──────────────────────────────────────────────────
    try {
      await _handleApi(request, method, path);
    } catch (e) {
      _json(request, 500, {'error': 'internal', 'detail': e.toString()});
    }
  }

  Future<void> _handleApi(HttpRequest request, String method, String path) async {
    // GET /api/cover?url= — 代理封面图片（绕过 B站 referer 限制）
    if (method == 'GET' && path == '/api/cover') {
      await _proxyCover(request);
      return;
    }

    // GET /api/featured — 推荐歌曲
    if (method == 'GET' && path == '/api/featured') {
      final songs = _searchService.featuredSongs;
      _json(request, 200, songs.map(_songToJson).toList());
      return;
    }

    // GET /api/search?q=
    if (method == 'GET' && path == '/api/search') {
      final query = request.uri.queryParameters['q'] ?? '';
      final songs = await _searchService.search(query);
      _json(request, 200, songs.map(_songToJson).toList());
      return;
    }

    // GET /api/queue — 当前队列
    if (method == 'GET' && path == '/api/queue') {
      final current = _playbackService.state.currentItem;
      final items = _queueService.items;
      _json(request, 200, {
        'current': current != null ? _queueItemToJson(current) : null,
        'upcoming': items.map(_queueItemToJson).toList(),
        'isPlaying': _playbackService.state.isPlaying,
      });
      return;
    }

    // POST /api/queue — 加入队列
    if (method == 'POST' && path == '/api/queue') {
      final body = await utf8.decoder.bind(request).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final songId = payload['songId'] as String?;
      final matches = _searchService.featuredSongs.where(
        (candidate) => candidate.id == songId,
      );
      final song = matches.isEmpty ? null : matches.first;
      if (song == null) {
        _json(request, 404, {'error': 'song_not_found'});
      } else {
        final item = _queueService.addSong(song, requestedBy: '手机点歌');
        _onQueueChanged();
        _json(request, 200, {'queueId': item.id});
      }
      return;
    }

    // DELETE /api/queue/:id — 移除
    if (method == 'DELETE' && path.startsWith('/api/queue/')) {
      final id = path.substring('/api/queue/'.length);
      _queueService.remove(id);
      _onQueueChanged();
      _json(request, 200, {'ok': true});
      return;
    }

    // POST /api/queue/bump/:id — 顶歌
    if (method == 'POST' && path.startsWith('/api/queue/bump/')) {
      final id = path.substring('/api/queue/bump/'.length);
      _queueService.bumpItemToNext(id);
      _onQueueChanged();
      _json(request, 200, {'ok': true});
      return;
    }

    // POST /api/resolve — 外链解析（B站链接/BV号）
    if (method == 'POST' && path == '/api/resolve') {
      await _handleResolve(request);
      return;
    }

    // POST /api/playback/play
    if (method == 'POST' && path == '/api/playback/play') {
      _playbackService.play();
      _json(request, 200, {'ok': true});
      return;
    }

    // POST /api/playback/pause
    if (method == 'POST' && path == '/api/playback/pause') {
      _playbackService.pause();
      _json(request, 200, {'ok': true});
      return;
    }

    // POST /api/playback/next
    if (method == 'POST' && path == '/api/playback/next') {
      _playbackService.next();
      _json(request, 200, {'ok': true});
      return;
    }

    // POST /api/playback/track — 原唱/伴奏切换
    if (method == 'POST' && path == '/api/playback/track') {
      _playbackService.toggleAudioTrack();
      _json(request, 200, {
        'ok': true,
        'track': _playbackService.state.audioTrackMode.name,
      });
      return;
    }

    // POST /api/playback/volume — 设置音量
    if (method == 'POST' && path == '/api/playback/volume') {
      final body = await utf8.decoder.bind(request).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final vol = (payload['volume'] as num?)?.toInt() ?? 72;
      _playbackService.setVolume(vol);
      _json(request, 200, {'ok': true, 'volume': _playbackService.state.volume});
      return;
    }

    // POST /api/playback/key — 调整变调（key）
    if (method == 'POST' && path == '/api/playback/key') {
      final body = await utf8.decoder.bind(request).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final delta = (payload['delta'] as num?)?.toInt() ?? 0;
      final absolute = payload['key'] as num?;
      if (absolute != null) {
        _playbackService.setKey(absolute.toInt());
      } else if (delta != 0) {
        _playbackService.transposeBy(delta);
      }
      _json(request, 200, {'ok': true, 'key': _playbackService.state.key});
      return;
    }

    // GET /api/playback — 播放状态
    if (method == 'GET' && path == '/api/playback') {
      final state = _playbackService.state;
      _json(request, 200, {
        'isPlaying': state.isPlaying,
        'volume': state.volume,
        'key': state.key,
        'track': state.audioTrackMode.name,
        'currentSong': state.currentSong != null ? {
          'id': state.currentSong!.id,
          'title': state.currentSong!.title,
          'artist': state.currentSong!.artist?.name ?? '',
        } : null,
      });
      return;
    }

    _json(request, 404, {'error': 'not_found'});
  }

  // ── static files ───────────────────────────────────────────

  Future<void> _serveFile(HttpRequest request, String assetPath, String contentType) async {
    try {
      String content;
      // Prefer Flutter asset bundle (works in release builds where the
      // file system path relative to CWD does not exist).
      try {
        content = await rootBundle.loadString(assetPath);
      } catch (_) {
        // Fallback: read from file system (dev mode).
        final file = File(assetPath);
        if (!await file.exists()) {
          request.response.statusCode = 404;
          request.response.write('Not found');
          await request.response.close();
          return;
        }
        content = await file.readAsString();
      }
      request.response.headers.contentType = ContentType.parse(contentType);
      request.response.write(content);
      await request.response.close();
    } catch (_) {
      request.response.statusCode = 500;
      await request.response.close();
    }
  }

  Future<void> _serveStatic(HttpRequest request, String path) async {
    final relativePath = path.substring(1); // remove leading /
    final ext = path.split('.').last;
    final mime = _mimeType(ext);
    await _serveFile(request, relativePath, mime);
  }

  String _mimeType(String ext) {
    switch (ext) {
      case 'html': return 'text/html; charset=utf-8';
      case 'css': return 'text/css; charset=utf-8';
      case 'js': return 'application/javascript; charset=utf-8';
      case 'json': return 'application/json';
      case 'png': return 'image/png';
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'svg': return 'image/svg+xml';
      case 'woff2': return 'font/woff2';
      default: return 'application/octet-stream';
    }
  }

  // ── queue sync ────────────────────────────────────────────

  /// Called after any API that mutates the queue.  Refreshes the
  /// up-next preview and auto-starts playback when the player is idle.
  void _onQueueChanged() {
    _playbackService.refreshUpNext();
    final state = _playbackService.state;
    // Auto-start: nothing playing now, but queue has songs ready.
    if (state.currentSong == null && _queueService.items.isNotEmpty) {
      _playbackService.next();
    }
  }

  // ── resolve ──────────────────────────────────────────────

  Future<void> _handleResolve(HttpRequest request) async {
    await _bilibiliAccountService.load();
    final body = await utf8.decoder.bind(request).join();
    final payload = jsonDecode(body) as Map<String, dynamic>;
    final url = payload['url'] as String?;
    final page = (payload['page'] as num?)?.toInt();
    if (url == null || url.trim().isEmpty) {
      _json(request, 400, {'error': 'empty_url'});
      return;
    }
    try {
      // 指定分P → 直接加入队列
      if (page != null && page > 0) {
        // 用之前缓存的结果或重新解析
        final result = await resolveBilibiliUrl(
          url.trim(),
          preferredQuality: _bilibiliAccountService.preferredQualityQn,
          cookieHeader: _bilibiliAccountService.cookieHeader,
        );
        final pageInfo = result.pages.firstWhere(
          (p) => p.page == page,
          orElse: () => result.pages.first,
        );
        final pageResult = await resolveBilibiliPage(
          bvid: result.bvid,
          pageInfo: pageInfo,
          ownerName: result.ownerName,
          ownerMid: result.ownerMid,
          mainTitle: result.song.title,
          preferredQuality: _bilibiliAccountService.preferredQualityQn,
          cookieHeader: _bilibiliAccountService.cookieHeader,
        );
        final song = pageResult.song;
        final item = _queueService.addSong(song, requestedBy: '手机点歌');
        _onQueueChanged();
        _json(request, 200, {
          'queueId': item.id,
          'title': song.title,
          'added': true,
        });
        return;
      }
      // 第一步：返回预览信息供用户确认
      final result = await resolveBilibiliUrl(
        url.trim(),
        preferredQuality: _bilibiliAccountService.preferredQualityQn,
        cookieHeader: _bilibiliAccountService.cookieHeader,
      );
      _json(request, 200, {
        'title': result.song.title,
        'bvid': result.bvid,
        'ownerName': result.ownerName,
        'coverUrl': result.coverUrl,
        'quality': result.quality,
        'qualityDesc': result.qualityDesc,
        'selectedPage': result.selectedPage,
        'pages': result.pages.map((p) => {
          'page': p.page,
          'title': p.title,
          'duration': p.duration,
        }).toList(),
        'added': false,
      });
    } on BilibiliResolveError catch (e) {
      _json(request, 422, {'error': e.code, 'message': e.message});
    } catch (e) {
      _json(request, 500, {'error': 'resolve_failed', 'message': e.toString()});
    }
  }

  Future<void> _proxyCover(HttpRequest request) async {
    final url = request.uri.queryParameters['url'];
    if (url == null || url.isEmpty) {
      _json(request, 400, {'error': 'missing_url'});
      return;
    }
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
      req.headers.set('Referer', 'https://www.bilibili.com');
      final res = await req.close().timeout(const Duration(seconds: 10));
      request.response.statusCode = res.statusCode;
      request.response.headers.contentType = res.headers.contentType;
      await request.response.addStream(res);
      await request.response.close();
      client.close();
    } catch (_) {
      request.response.statusCode = 502;
      await request.response.close();
    }
  }

  void _json(HttpRequest request, int status, Object? data) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    request.response.close();
  }

  Map<String, Object?> _songToJson(Song song) {
    return {
      'id': song.id,
      'title': song.title,
      'artist': song.artist?.name ?? '未知',
      'category': song.category,
      'code': song.code,
    };
  }

  Map<String, Object?> _queueItemToJson(QueueItem item) {
    return {
      'id': item.id,
      'songId': item.song.id,
      'title': item.song.title,
      'artist': item.song.artist?.name ?? '未知',
      'requestedBy': item.requestedBy,
    };
  }
}
