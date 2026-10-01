import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'bilibili_quality.dart';

enum BilibiliQrLoginState {
  idle,
  loading,
  waiting,
  scanned,
  expired,
  error,
  loggedIn,
}

class BilibiliAccountProfile {
  const BilibiliAccountProfile({
    required this.name,
    required this.faceUrl,
    required this.signature,
  });

  final String name;
  final String faceUrl;
  final String signature;
}

/// Owns the optional Bilibili web session used by external-link resolving.
///
/// QR polling is deliberately opt-in: [startLoginFlow] is called only while
/// the account rail is visible, and [stopQrPolling] is called when it leaves
/// the widget tree. Cookies, QR credentials and profile data remain in memory
/// only; the settings file stores the non-sensitive quality preference.
class BilibiliAccountService extends ChangeNotifier {
  BilibiliAccountService({required String sessionFilePath})
      : _sessionFile = File(sessionFilePath);

  static const _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';
  static const _referer = 'https://www.bilibili.com/';
  static const _qrGenerateUrl =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate';
  static const _qrPollUrl =
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll';
  static const _profileUrl = 'https://api.bilibili.com/x/space/myinfo';
  static const _logoutUrl = 'https://passport.bilibili.com/login/exit/v2';

  final File _sessionFile;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  final Map<String, String> _cookies = <String, String>{};

  Future<void>? _loadFuture;
  Timer? _pollTimer;
  bool _polling = false;
  bool _disposed = false;
  int _qrGeneration = 0;
  String? _qrcodeKey;

  BilibiliAccountProfile? _profile;
  String? _qrUrl;
  String _statusMessage = '使用哔哩哔哩扫码登录';
  BilibiliQrLoginState _qrState = BilibiliQrLoginState.idle;
  int _preferredQualityQn = defaultBilibiliQualityQn;

  BilibiliAccountProfile? get profile => _profile;
  bool get isLoggedIn => _profile != null && _cookies.isNotEmpty;
  String? get qrUrl => _qrUrl;
  String get statusMessage => _statusMessage;
  BilibiliQrLoginState get qrState => _qrState;
  int get preferredQualityQn => _preferredQualityQn;

  String? get cookieHeader {
    if (_cookies.isEmpty) return null;
    return _cookies.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    try {
      if (await _sessionFile.exists()) {
        final decoded = jsonDecode(await _sessionFile.readAsString());
        if (decoded is Map) {
          _preferredQualityQn = normalizeBilibiliQualityQn(
            (decoded['preferred_quality_qn'] as num?)?.toInt(),
          );
        }
      }
    } on Exception {
      // Keep defaults when the preferences file cannot be read.
    }

    // Rewrite legacy session files immediately so cookies and profile data
    // persisted by older builds are removed from disk.
    _writePreferences();
    _setQrState(
      BilibiliQrLoginState.idle,
      '使用哔哩哔哩扫码登录',
    );
  }

  Future<void> startLoginFlow() async {
    await load();
    if (_disposed || isLoggedIn) return;
    if (_qrcodeKey != null &&
        _qrUrl != null &&
        _qrState != BilibiliQrLoginState.expired) {
      _startQrPolling();
      return;
    }
    await refreshLoginQr();
  }

  Future<void> refreshLoginQr() async {
    await load();
    if (_disposed || isLoggedIn) return;
    final generation = ++_qrGeneration;
    stopQrPolling();
    _qrUrl = null;
    _qrcodeKey = null;
    _setQrState(BilibiliQrLoginState.loading, '正在获取登录二维码…');

    try {
      final response = await _getJson(Uri.parse(_qrGenerateUrl));
      if (generation != _qrGeneration || _disposed) return;
      final code = (response['code'] as num?)?.toInt();
      final data = response['data'];
      if (code != 0 || data is! Map) {
        throw const FormatException('二维码接口返回异常');
      }
      final url = data['url'];
      final key = data['qrcode_key'];
      if (url is! String || url.isEmpty || key is! String || key.isEmpty) {
        throw const FormatException('二维码数据不完整');
      }
      _qrUrl = url;
      _qrcodeKey = key;
      _setQrState(BilibiliQrLoginState.waiting, '请使用哔哩哔哩客户端扫码');
      _startQrPolling();
    } on Exception {
      if (generation == _qrGeneration && !_disposed) {
        _qrUrl = null;
        _qrcodeKey = null;
        _setQrState(BilibiliQrLoginState.error, '二维码获取失败，请刷新重试');
      }
    }
  }

  void _startQrPolling() {
    if (_pollTimer != null || _qrcodeKey == null || isLoggedIn || _disposed) {
      return;
    }
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollLoginQr());
    });
    unawaited(_pollLoginQr());
  }

  void stopQrPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollLoginQr() async {
    final key = _qrcodeKey;
    if (_polling || key == null || _disposed || isLoggedIn) return;
    final generation = _qrGeneration;
    _polling = true;
    try {
      final uri = Uri.parse(_qrPollUrl).replace(
        queryParameters: <String, String>{'qrcode_key': key},
      );
      final result = await _requestJson(uri);
      if (generation != _qrGeneration || key != _qrcodeKey || _disposed) {
        return;
      }
      final data = result.body['data'];
      if (data is! Map) return;
      final status = (data['code'] as num?)?.toInt();
      switch (status) {
        case 0:
          _mergeCookies(result.cookies);
          _mergeCookiesFromUrl(data['url']);
          if (_cookies.isEmpty) {
            _setQrState(BilibiliQrLoginState.error, '登录成功，但未取得会话信息');
            stopQrPolling();
            return;
          }
          stopQrPolling();
          final loaded = await _refreshProfile();
          if (!loaded) {
            _cookies.clear();
            _setQrState(BilibiliQrLoginState.error, '登录状态验证失败，请刷新重试');
            return;
          }
          _qrGeneration++;
          _qrUrl = null;
          _qrcodeKey = null;
          _setQrState(BilibiliQrLoginState.loggedIn, '已登录');
          return;
        case 86038:
          stopQrPolling();
          _setQrState(BilibiliQrLoginState.expired, '二维码已过期，请刷新');
          return;
        case 86090:
          _setQrState(BilibiliQrLoginState.scanned, '已扫码，请在手机上确认');
          return;
        case 86101:
          _setQrState(BilibiliQrLoginState.waiting, '请使用哔哩哔哩客户端扫码');
          return;
        default:
          return;
      }
    } on Exception {
      if (generation == _qrGeneration && !_disposed) {
        _setQrState(BilibiliQrLoginState.error, '登录状态检查失败，请刷新重试');
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> setPreferredQualityQn(int qn) async {
    final normalized = normalizeBilibiliQualityQn(qn);
    if (_preferredQualityQn == normalized) return;
    _preferredQualityQn = normalized;
    _notify();
    _writePreferences();
  }

  Future<void> logout() async {
    await load();
    _qrGeneration++;
    stopQrPolling();
    final csrf = _cookies['bili_jct'];
    if (_cookies.isNotEmpty && csrf != null && csrf.isNotEmpty) {
      try {
        final request = await _client.postUrl(Uri.parse(_logoutUrl));
        _setCommonHeaders(request);
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        request.headers.set(HttpHeaders.cookieHeader, cookieHeader!);
        request.write('biliCSRF=${Uri.encodeQueryComponent(csrf)}');
        final response = await request.close().timeout(
              const Duration(seconds: 10),
            );
        await response.drain<void>();
      } on Exception {
        // Local logout must still succeed when the remote endpoint is offline.
      }
    }
    _cookies.clear();
    _profile = null;
    _qrUrl = null;
    _qrcodeKey = null;
    _setQrState(BilibiliQrLoginState.idle, '使用哔哩哔哩扫码登录');
  }

  Future<bool> _refreshProfile() async {
    try {
      final response = await _getJson(
        Uri.parse(_profileUrl),
        includeCookies: true,
      );
      final code = (response['code'] as num?)?.toInt();
      final data = response['data'];
      if (code != 0 || data is! Map) {
        return false;
      }
      final name = data['name'];
      if (name is! String || name.trim().isEmpty) return false;
      _profile = BilibiliAccountProfile(
        name: name.trim(),
        faceUrl: (data['face'] as String?)?.trim() ?? '',
        signature: (data['sign'] as String?)?.trim() ?? '',
      );
      return true;
    } on Exception {
      // Keep the in-memory profile during transient network failures.
      return _profile != null && _cookies.isNotEmpty;
    }
  }

  Future<Map<String, dynamic>> _getJson(
    Uri uri, {
    bool includeCookies = false,
  }) async {
    final result = await _requestJson(uri, includeCookies: includeCookies);
    return result.body;
  }

  Future<({Map<String, dynamic> body, List<Cookie> cookies})> _requestJson(
    Uri uri, {
    bool includeCookies = false,
  }) async {
    final request = await _client.getUrl(uri);
    _setCommonHeaders(request);
    if (includeCookies && cookieHeader != null) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader!);
    }
    final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected JSON response');
    }
    return (body: decoded, cookies: response.cookies);
  }

  void _setCommonHeaders(HttpClientRequest request) {
    request.headers
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..set(HttpHeaders.refererHeader, _referer)
      ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
  }

  void _mergeCookies(List<Cookie> cookies) {
    for (final cookie in cookies) {
      if (cookie.name.isNotEmpty && cookie.value.isNotEmpty) {
        _cookies[cookie.name] = cookie.value;
      }
    }
  }

  void _mergeCookiesFromUrl(Object? value) {
    if (value is! String || value.isEmpty) return;
    final uri = Uri.tryParse(value);
    if (uri == null) return;
    const sessionKeys = <String>{
      'DedeUserID',
      'DedeUserID__ckMd5',
      'SESSDATA',
      'bili_jct',
      'sid',
    };
    for (final entry in uri.queryParameters.entries) {
      if (sessionKeys.contains(entry.key) && entry.value.isNotEmpty) {
        _cookies[entry.key] = entry.value;
      }
    }
  }

  void _setQrState(BilibiliQrLoginState state, String message) {
    _qrState = state;
    _statusMessage = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _writePreferences() {
    try {
      _sessionFile.parent.createSync(recursive: true);
      _sessionFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'preferred_quality_qn': _preferredQualityQn,
        }),
        flush: true,
      );
    } on FileSystemException {
      // Portable directory may be read-only; keep the in-memory session.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _qrGeneration++;
    stopQrPolling();
    _cookies.clear();
    _profile = null;
    _qrUrl = null;
    _qrcodeKey = null;
    _client.close(force: true);
    super.dispose();
  }
}
