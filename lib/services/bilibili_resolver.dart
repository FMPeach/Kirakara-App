import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/artist.dart';
import '../domain/media_asset.dart';
import '../domain/song.dart';
import 'bilibili_quality.dart';

// ── Result types ──────────────────────────────────────────────────

class BilibiliPageInfo {
  const BilibiliPageInfo({
    required this.cid,
    required this.title,
    required this.page,
    required this.duration,
  });

  final int cid;
  final String title; // 分P标题
  final int page; // 分P序号 (1-indexed)
  final int duration; // 秒
}

class BilibiliResolveResult {
  const BilibiliResolveResult({
    required this.song,
    required this.bvid,
    required this.cid,
    required this.quality,
    required this.qualityDesc,
    required this.pages,
    required this.selectedPage,
    required this.ownerName,
    required this.ownerMid,
    required this.coverUrl,
    this.playCount,
    this.danmakuCount,
  });

  final Song song;
  final String bvid;
  final int cid;
  final int quality;
  final String qualityDesc;
  final List<BilibiliPageInfo> pages;
  final int selectedPage;
  final String ownerName;
  final int ownerMid;
  final String coverUrl;
  final int? playCount;
  final int? danmakuCount;
}

class BilibiliPageResolveResult {
  const BilibiliPageResolveResult({
    required this.song,
    required this.quality,
    required this.qualityDesc,
  });

  final Song song;
  final int quality;
  final String qualityDesc;
}

class BilibiliResolveError {
  const BilibiliResolveError({required this.code, required this.message});

  final String code; // 'network' | 'not_found' | 'no_stream' | 'parse'
  final String message;
}

// ── Constants ─────────────────────────────────────────────────────

const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const _referer = 'https://www.bilibili.com';

const _mediaHeaders = <String, String>{
  'User-Agent': _userAgent,
  'Referer': _referer,
};

// ── AV → BV ──────────────────────────────────────────────────────

const _bvTable = 'fZodR9XQDSUm21yCkr6zBqiveYah8bt7xsWpVLHdJAjKFGnME';
const _bvS = [11, 10, 3, 8, 4, 6];
const _bvXor = 177451812;
const _bvAdd = 8728348608;

String avToBv(int av) {
  var x = (av ^ _bvXor) + _bvAdd;
  final r = List<String>.filled(12, '');
  for (var i = 0; i < 6; i++) {
    r[_bvS[i]] = _bvTable[x % 58];
    x ~/= 58;
  }
  return 'BV1${r[2]}${r[3]}${r[4]}${r[5]}${r[6]}${r[7]}${r[8]}${r[9]}${r[10]}${r[11]}';
}

// ── HTTP helpers ──────────────────────────────────────────────────

Future<_HttpResult> _get(Uri uri, {Map<String, String>? headers}) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Referer', _referer);
    headers?.forEach((k, v) => request.headers.set(k, v));
    final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
    final body = await response.transform(utf8.decoder).join();
    client.close();
    return _HttpResult(response.statusCode, body);
  } catch (e) {
    return _HttpResult(-1, '');
  }
}

Future<_HttpResult> _getRedirect(Uri uri) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', _userAgent);
    request.followRedirects = false;
    final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
    final location = response.headers.value('location');
    client.close();
    return _HttpResult(
      response.statusCode,
      location ?? '',
    );
  } catch (e) {
    return _HttpResult(-1, '');
  }
}

class _HttpResult {
  const _HttpResult(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

Map<String, String>? _cookieHeaders(String? cookieHeader) {
  final normalized = cookieHeader?.trim() ?? '';
  if (normalized.isEmpty) return null;
  return <String, String>{'Cookie': normalized};
}

/// Builds playurl parameters without letting guest preview mode cap a signed-in
/// account's premium DASH ladder at 1080P.
Map<String, String> buildBilibiliPlayUrlParameters({
  required int cid,
  required int preferredQuality,
  required bool authenticated,
}) {
  final qn = normalizeBilibiliQualityQn(preferredQuality);
  final wants240p = qn == 6;
  return <String, String>{
    'cid': cid.toString(),
    'fnval': wants240p ? '1' : (qn >= 120 ? '144' : '16'),
    'fnver': '0',
    'qn': qn.toString(),
    'fourk': qn >= 120 ? '1' : '0',
    if (!authenticated) 'try_look': '1',
    if (wants240p) 'platform': 'html5',
  };
}

({String videoUrl, String? audioUrl, int quality, String qualityDesc})
    _selectPlaybackStreams(
  Map<String, dynamic> data, {
  required int preferredQuality,
}) {
  final normalizedPreference = normalizeBilibiliQualityQn(preferredQuality);
  final dash = data['dash'] as Map<String, dynamic>?;
  if (dash != null) {
    final videos = (dash['video'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((stream) => selectBilibiliStreamUrl(stream) != null)
        .where((stream) {
      final id = (stream['id'] as num?)?.toInt();
      return id != null && bilibiliAllowedQualityQns.contains(id);
    }).toList();
    final audios = (dash['audio'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((stream) => selectBilibiliStreamUrl(stream) != null)
        .toList();
    if (videos.isNotEmpty && audios.isNotEmpty) {
      final reportedQuality = (data['quality'] as num?)?.toInt() ?? 0;
      final qualityLimit =
          reportedQuality > 0 && reportedQuality < normalizedPreference
              ? reportedQuality
              : normalizedPreference;
      final atOrBelowPreference = videos.where((stream) {
        final id = (stream['id'] as num?)?.toInt() ?? 0;
        return id <= qualityLimit;
      }).toList();
      var qualityCandidates =
          atOrBelowPreference.isNotEmpty ? atOrBelowPreference : videos;
      var compatibleVideos = qualityCandidates
          .where((stream) => (stream['codecid'] as num?)?.toInt() == 7)
          .toList();
      if (compatibleVideos.isEmpty) compatibleVideos = qualityCandidates;
      final candidates = compatibleVideos;
      candidates.sort(_compareDashStreams);
      audios.sort(_compareDashStreams);
      final video = candidates.first;
      final audio = audios.first;
      final quality = (video['id'] as num?)?.toInt() ?? reportedQuality;
      return (
        videoUrl: selectBilibiliStreamUrl(video)!,
        audioUrl: selectBilibiliStreamUrl(audio),
        quality: quality,
        qualityDesc: bilibiliQualityLabel(quality),
      );
    }
  }

  final durl = data['durl'] as List<dynamic>?;
  if (durl != null && durl.isNotEmpty) {
    final first = durl.first as Map<String, dynamic>;
    final url = first['url'] as String?;
    if (url != null && url.isNotEmpty) {
      final quality = (data['quality'] as num?)?.toInt() ?? 0;
      return (
        videoUrl: url,
        audioUrl: null,
        quality: quality,
        qualityDesc: bilibiliQualityLabel(quality),
      );
    }
  }

  throw const BilibiliResolveError(
    code: 'no_stream',
    message: '未获取到可播放的 DASH 或 MP4 流地址',
  );
}

/// Selects a Bilibili DASH URL while avoiding MCDN when a regular CDN mirror
/// is available. Some networks can resolve MCDN URLs but fail during TLS or
/// transfer setup, while the matching backup URL remains healthy.
String? selectBilibiliStreamUrl(Map<String, dynamic> stream) {
  final candidates = <String>[];

  void addCandidate(dynamic value) {
    if (value is String && value.isNotEmpty && !candidates.contains(value)) {
      candidates.add(value);
    }
  }

  addCandidate(stream['baseUrl']);
  addCandidate(stream['base_url']);
  addCandidate(stream['url']);
  final backups = stream['backupUrl'] ?? stream['backup_url'];
  if (backups is List) {
    for (final value in backups) {
      addCandidate(value);
    }
  }

  if (candidates.isEmpty) return null;
  for (final candidate in candidates) {
    final host = Uri.tryParse(candidate)?.host.toLowerCase() ?? '';
    final isMcdn =
        host == 'mcdn.bilivideo.cn' || host.endsWith('.mcdn.bilivideo.cn');
    if (!isMcdn) return candidate;
  }
  return candidates.first;
}

int _compareDashStreams(Map<String, dynamic> a, Map<String, dynamic> b) {
  final aId = (a['id'] as num?)?.toInt() ?? 0;
  final bId = (b['id'] as num?)?.toInt() ?? 0;
  final byId = bId.compareTo(aId);
  if (byId != 0) return byId;
  final aBandwidth = (a['bandwidth'] as num?)?.toInt() ?? 0;
  final bBandwidth = (b['bandwidth'] as num?)?.toInt() ?? 0;
  return bBandwidth.compareTo(aBandwidth);
}

List<MediaAsset> _streamAssets({
  required String videoId,
  required int cid,
  required int page,
  required String videoUrl,
  required String? audioUrl,
}) =>
    [
      MediaAsset(
        id: 'bili-$videoId-video-$cid-$page',
        type: MediaAssetType.video,
        uri: Uri.parse(videoUrl),
        headers: _mediaHeaders,
      ),
      if (audioUrl != null)
        MediaAsset(
          id: 'bili-$videoId-audio-$cid-$page',
          type: MediaAssetType.vocal,
          uri: Uri.parse(audioUrl),
          headers: _mediaHeaders,
        ),
    ];

// ── Public API ────────────────────────────────────────────────────

/// 解析 B站链接或 BV/AV 号，返回可播放的 Song 对象。
///
/// 支持格式：完整链接、短链 b23.tv、纯 BV 号、纯 AV 号。
Future<BilibiliResolveResult> resolveBilibiliUrl(
  String input, {
  int preferredQuality = defaultBilibiliQualityQn,
  String? cookieHeader,
}) async {
  final normalizedQuality = normalizeBilibiliQualityQn(preferredQuality);
  final authHeaders = _cookieHeaders(cookieHeader);
  // 1. Resolve short links
  var url = input.trim();
  if (url.contains('b23.tv')) {
    final result = await _getRedirect(Uri.parse(url));
    if (result.statusCode == 301 || result.statusCode == 302) {
      url = result.body;
    } else {
      throw BilibiliResolveError(
        code: 'network',
        message: '短链解析失败，请检查链接',
      );
    }
  }

  // 2. Extract BV/AV — prefer passing aid directly for AV numbers
  String? bvid;
  int? aid;
  final bvMatch = RegExp(r'BV[a-zA-Z0-9]{10}').firstMatch(url);
  if (bvMatch != null) {
    bvid = bvMatch.group(0)!;
  } else {
    final avMatch = RegExp(r'av(\d+)', caseSensitive: false).firstMatch(url);
    if (avMatch != null) {
      aid = int.tryParse(avMatch.group(1)!);
    } else {
      final rawNum = RegExp(r'\d+').firstMatch(url);
      if (rawNum != null && !url.contains('http')) {
        aid = int.tryParse(rawNum.group(0)!);
      }
    }
    if (aid == null) {
      throw BilibiliResolveError(
        code: 'parse',
        message: '无法识别 BV/AV 号，请检查链接格式',
      );
    }
  }

  // 3. Extract page parameter
  int page = 1;
  final pageMatch = RegExp(r'[?&]p=(\d+)').firstMatch(url);
  if (pageMatch != null) {
    page = int.tryParse(pageMatch.group(1)!) ?? 1;
    if (page < 1) page = 1;
  }

  // 4. View API — get video metadata (supports both bvid and aid)
  final viewParams = <String, String>{};
  if (bvid != null) {
    viewParams['bvid'] = bvid;
  } else {
    viewParams['aid'] = aid.toString();
  }
  final viewUri = Uri.parse('https://api.bilibili.com/x/web-interface/view')
      .replace(queryParameters: viewParams);
  final viewResult = await _get(viewUri, headers: authHeaders);
  if (viewResult.statusCode != 200 || viewResult.body.isEmpty) {
    throw BilibiliResolveError(
      code: 'network',
      message: '获取视频信息失败（网络错误）',
    );
  }

  Map<String, dynamic> viewData;
  try {
    viewData = json.decode(viewResult.body) as Map<String, dynamic>;
  } catch (_) {
    throw BilibiliResolveError(
      code: 'parse',
      message: '解析视频信息失败',
    );
  }

  if (viewData['code'] != 0) {
    final msg = viewData['message'] as String? ?? '未知错误';
    if (viewData['code'] == -404) {
      throw BilibiliResolveError(code: 'not_found', message: '视频不存在：$msg');
    }
    throw BilibiliResolveError(code: 'parse', message: '获取视频信息失败：$msg');
  }

  final data = viewData['data'] as Map<String, dynamic>;
  // B站 View API 响应始终包含 bvid，即使请求用的是 aid
  bvid = data['bvid'] as String?;
  final title = data['title'] as String? ?? '未知标题';
  final durationSec = (data['duration'] as num?)?.toInt() ?? 0;
  final owner = data['owner'] as Map<String, dynamic>?;
  final ownerName = owner?['name'] as String? ?? '未知UP主';
  final ownerMid = (owner?['mid'] as num?)?.toInt() ?? 0;
  final coverUrl = (data['pic'] as String?) ?? '';
  final stat = data['stat'] as Map<String, dynamic>?;
  final playCount = (stat?['view'] as num?)?.toInt();
  final danmakuCount = (stat?['danmaku'] as num?)?.toInt();

  final pages = data['pages'] as List<dynamic>? ?? [];
  if (pages.isEmpty) {
    throw BilibiliResolveError(code: 'parse', message: '视频无分P数据');
  }

  // Build page info list
  final pageInfos = <BilibiliPageInfo>[];
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i] as Map<String, dynamic>;
    pageInfos.add(BilibiliPageInfo(
      cid: (p['cid'] as num?)?.toInt() ?? 0,
      title: p['part'] as String? ?? 'P${i + 1}',
      page: i + 1,
      duration: (p['duration'] as num?)?.toInt() ?? 0,
    ));
  }

  // Find target page (1-indexed)
  int idx = page - 1;
  if (idx >= pages.length) idx = 0;
  final targetPage = pages[idx] as Map<String, dynamic>;
  final cid = (targetPage['cid'] as num?)?.toInt() ?? 0;
  if (cid == 0) {
    throw BilibiliResolveError(code: 'parse', message: '获取视频 CID 失败');
  }

  // 5. Playurl API — get stream URL
  final playParams = buildBilibiliPlayUrlParameters(
    cid: cid,
    preferredQuality: normalizedQuality,
    authenticated: authHeaders != null,
  );
  if (bvid != null) {
    playParams['bvid'] = bvid;
  } else {
    playParams['aid'] = aid.toString();
  }
  final playUri =
      Uri.parse('https://api.bilibili.com/x/player/playurl').replace(
    queryParameters: playParams,
  );
  final playResult = await _get(playUri, headers: authHeaders);
  if (playResult.statusCode != 200 || playResult.body.isEmpty) {
    throw BilibiliResolveError(
      code: 'network',
      message: '获取播放地址失败（网络错误）',
    );
  }

  Map<String, dynamic> playData;
  try {
    playData = json.decode(playResult.body) as Map<String, dynamic>;
  } catch (_) {
    throw BilibiliResolveError(code: 'parse', message: '解析播放地址失败');
  }

  if (playData['code'] != 0) {
    final msg = playData['message'] as String? ?? '';
    // Try WBI endpoint as fallback hint
    if (msg.contains('wbi') ||
        playData['data'] is Map &&
            (playData['data'] as Map).containsKey('v_voucher')) {
      throw BilibiliResolveError(
        code: 'no_stream',
        message: '该视频需要 WBI 签名，当前版本暂不支持。请尝试其他视频。',
      );
    }
    throw BilibiliResolveError(code: 'no_stream', message: '获取播放地址失败：$msg');
  }

  final playResultData = playData['data'] as Map<String, dynamic>;
  final streams = _selectPlaybackStreams(
    playResultData,
    preferredQuality: normalizedQuality,
  );

  // 6. Construct Song
  final videoId = bvid ?? 'av$aid';
  final song = Song(
    id: 'bili-$videoId-$cid',
    title: title,
    category: '外链',
    artist: Artist(id: 'bili-$ownerMid', name: ownerName),
    duration: Duration(seconds: durationSec),
    isExternal: true,
    videoMasterClock: streams.audioUrl != null,
    assets: _streamAssets(
      videoId: videoId,
      cid: cid,
      page: page,
      videoUrl: streams.videoUrl,
      audioUrl: streams.audioUrl,
    ),
  );

  return BilibiliResolveResult(
    song: song,
    bvid: videoId,
    cid: cid,
    quality: streams.quality,
    qualityDesc: streams.qualityDesc,
    pages: pageInfos,
    selectedPage: page,
    ownerName: ownerName,
    ownerMid: ownerMid,
    coverUrl: coverUrl,
    playCount: playCount,
    danmakuCount: danmakuCount,
  );
}

/// 为指定分P获取可播放的 Song 对象（复用已有的 bvid 和 page info）。
/// 不重新请求 View API，只请求 Playurl API。
Future<BilibiliPageResolveResult> resolveBilibiliPage({
  required String bvid,
  required BilibiliPageInfo pageInfo,
  required String ownerName,
  required int ownerMid,
  required String mainTitle,
  int preferredQuality = defaultBilibiliQualityQn,
  String? cookieHeader,
}) async {
  final normalizedQuality = normalizeBilibiliQualityQn(preferredQuality);
  final authHeaders = _cookieHeaders(cookieHeader);
  final queryParameters = buildBilibiliPlayUrlParameters(
    cid: pageInfo.cid,
    preferredQuality: normalizedQuality,
    authenticated: authHeaders != null,
  )..['bvid'] = bvid;
  final playUri =
      Uri.parse('https://api.bilibili.com/x/player/playurl').replace(
    queryParameters: queryParameters,
  );
  final playResult = await _get(
    playUri,
    headers: authHeaders,
  );
  if (playResult.statusCode != 200 || playResult.body.isEmpty) {
    throw BilibiliResolveError(
      code: 'network',
      message: '获取播放地址失败（网络错误）',
    );
  }

  Map<String, dynamic> playData;
  try {
    playData = json.decode(playResult.body) as Map<String, dynamic>;
  } catch (_) {
    throw BilibiliResolveError(code: 'parse', message: '解析播放地址失败');
  }

  if (playData['code'] != 0) {
    throw BilibiliResolveError(
      code: 'no_stream',
      message: '获取播放地址失败：${playData['message'] ?? ''}',
    );
  }

  final playResultData = playData['data'] as Map<String, dynamic>;
  final streams = _selectPlaybackStreams(
    playResultData,
    preferredQuality: normalizedQuality,
  );

  final song = Song(
    id: 'bili-$bvid-${pageInfo.cid}',
    title: mainTitle,
    category: '外链',
    artist: Artist(id: 'bili-$ownerMid', name: ownerName),
    duration: Duration(seconds: pageInfo.duration),
    isExternal: true,
    videoMasterClock: streams.audioUrl != null,
    assets: _streamAssets(
      videoId: bvid,
      cid: pageInfo.cid,
      page: pageInfo.page,
      videoUrl: streams.videoUrl,
      audioUrl: streams.audioUrl,
    ),
  );
  return BilibiliPageResolveResult(
    song: song,
    quality: streams.quality,
    qualityDesc: streams.qualityDesc,
  );
}
