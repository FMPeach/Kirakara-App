import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 设置持久化 — 便携版：所有设置写入 exe 目录旁 settings/settings.json，
/// 不依赖 %APPDATA% / SharedPreferences。
class SettingsService extends ChangeNotifier {
  SettingsService({
    required String initialCacheDirectoryPath,
    required String settingsFilePath,
  })  : _cacheDirectoryPath = initialCacheDirectoryPath,
        _settingsFilePath = settingsFilePath;

  static const _customAnnouncementKey = 'custom_announcement';
  static const _prefetchLookaheadKey = 'prefetch_lookahead';
  static const _cacheDirectoryKey = 'cache_directory';
  static const _dlnaDeepSearchKey = 'dlna_deep_search_enabled';

  final String _settingsFilePath;
  bool _disposed = false;
  String _customAnnouncement = '';
  int _prefetchLookahead = 3;
  String _cacheDirectoryPath;
  bool _dlnaDeepSearchEnabled = false;

  String get customAnnouncement => _customAnnouncement;
  int get prefetchLookahead => _prefetchLookahead;
  String get cacheDirectoryPath => _cacheDirectoryPath;
  bool get dlnaDeepSearchEnabled => _dlnaDeepSearchEnabled;

  // ── settings/settings.json 读写 ────────────────────────────────

  File get _settingsFile => File(_settingsFilePath);

  void _write() {
    try {
      _settingsFile.parent.createSync(recursive: true);
      _settingsFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          _customAnnouncementKey: _customAnnouncement,
          _prefetchLookaheadKey: _prefetchLookahead,
          _cacheDirectoryKey: _cacheDirectoryPath,
          _dlnaDeepSearchKey: _dlnaDeepSearchEnabled,
        }),
        flush: true,
      );
    } on FileSystemException {
      // 便携目录只读时静默失败，保留内存态
    }
  }

  Map<String, Object?>? _read() {
    try {
      if (!_settingsFile.existsSync()) return null;
      final decoded = jsonDecode(_settingsFile.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } on Exception {
      return null;
    }
  }

  /// 解析缓存目录：优先 settings.json 中的用户选择，其次默认路径。
  static Future<String> resolveCacheDirectory(
      String defaultPath, String settingsFilePath) async {
    var saved = '';
    try {
      final file = File(settingsFilePath);
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) {
          final value = decoded[_cacheDirectoryKey];
          if (value is String) saved = value.trim();
        }
      }
    } on Exception {
      saved = '';
    }
    final selected = saved.isEmpty ? defaultPath : saved;
    try {
      final directory = Directory(selected).absolute;
      directory.createSync(recursive: true);
      return directory.path;
    } on FileSystemException {
      final fallback = Directory(defaultPath).absolute;
      fallback.createSync(recursive: true);
      return fallback.path;
    }
  }

  Future<void> load() async {
    final stored = _read() ?? <String, Object?>{};
    _customAnnouncement =
        (stored[_customAnnouncementKey] as String?)?.trim() ?? '';
    _prefetchLookahead = ((stored[_prefetchLookaheadKey] as num?)?.toInt() ?? 3)
        .clamp(1, 3)
        .toInt();
    final cacheDirectory =
        (stored[_cacheDirectoryKey] as String?)?.trim() ?? '';
    if (cacheDirectory.isNotEmpty) {
      _cacheDirectoryPath = cacheDirectory;
    }
    _dlnaDeepSearchEnabled = stored[_dlnaDeepSearchKey] == true;
    if (!_disposed) notifyListeners();
  }

  Future<void> setCustomAnnouncement(String value) async {
    final normalized = value.trim();
    if (_customAnnouncement == normalized) return;
    _customAnnouncement = normalized;
    if (!_disposed) notifyListeners();
    _write();
  }

  Future<void> setPrefetchLookahead(int value) async {
    final normalized = value.clamp(1, 3).toInt();
    if (_prefetchLookahead == normalized) return;
    _prefetchLookahead = normalized;
    if (!_disposed) notifyListeners();
    _write();
  }

  Future<void> setCacheDirectoryPath(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty || _cacheDirectoryPath == normalized) return;
    _cacheDirectoryPath = normalized;
    if (!_disposed) notifyListeners();
    _write();
  }

  Future<void> setDlnaDeepSearchEnabled(bool value) async {
    if (_dlnaDeepSearchEnabled == value) return;
    _dlnaDeepSearchEnabled = value;
    if (!_disposed) notifyListeners();
    _write();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
