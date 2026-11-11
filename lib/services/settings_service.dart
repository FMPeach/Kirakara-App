import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/audience_overlay_options.dart';

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

  final String _settingsFilePath;
  bool _disposed = false;
  String _customAnnouncement = '';
  int _prefetchLookahead = 3;
  String _cacheDirectoryPath;
  String? _cacheDirectoryPreference;
  AudienceOverlayOptions _audienceOverlay = const AudienceOverlayOptions();

  String get customAnnouncement => _customAnnouncement;
  int get prefetchLookahead => _prefetchLookahead;
  String get cacheDirectoryPath => _cacheDirectoryPath;
  AudienceOverlayOptions get audienceOverlay => _audienceOverlay;

  // ── settings/settings.json 读写 ────────────────────────────────

  File get _settingsFile => File(_settingsFilePath);

  void _write() {
    try {
      _settingsFile.parent.createSync(recursive: true);
      _settingsFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          _customAnnouncementKey: _customAnnouncement,
          _prefetchLookaheadKey: _prefetchLookahead,
          if (_cacheDirectoryPreference != null)
            _cacheDirectoryKey: _cacheDirectoryPreference,
          'audience_overlay': {
            'qr_enabled': _audienceOverlay.qrEnabled,
            'queue_enabled': _audienceOverlay.queueEnabled,
            'announcement_enabled': _audienceOverlay.announcementEnabled,
          },
        }),
        flush: true,
      );
    } on FileSystemException {
      // 便携目录只读时静默失败，保留内存态
    }
  }

  static Map<String, Object?>? _readSettings(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } on Exception {
      return null;
    }
  }

  static String? _cachePreference(Map<String, Object?>? stored) {
    final value = stored?[_cacheDirectoryKey];
    if (value is! String) return null;
    final path = value.trim();
    return path.isEmpty ? null : path;
  }

  /// 先试用户选择的目录，再按顺序尝试默认目录。
  static Future<String> resolveCacheDirectory({
    required String settingsFilePath,
    required Iterable<String> defaultPaths,
  }) async {
    final saved = _cachePreference(_readSettings(settingsFilePath));
    FileSystemException? lastError;
    for (final path in <String>{if (saved != null) saved, ...defaultPaths}) {
      try {
        final directory = Directory(path).absolute;
        await directory.create(recursive: true);
        // 播放缓存需要在这里创建会话子目录，目录存在不等于有写权限。
        final probe = await directory.createTemp('.kirakara-write-check-');
        await probe.delete();
        return directory.path;
      } on FileSystemException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const FileSystemException('No usable cache directory');
  }

  Future<void> load() async {
    final stored = _readSettings(_settingsFilePath) ?? <String, Object?>{};
    final overlay = stored['audience_overlay'];
    if (overlay is Map) {
      _audienceOverlay = AudienceOverlayOptions(
        qrEnabled: overlay['qr_enabled'] is bool
            ? overlay['qr_enabled'] as bool
            : true,
        queueEnabled: overlay['queue_enabled'] is bool
            ? overlay['queue_enabled'] as bool
            : true,
        announcementEnabled: overlay['announcement_enabled'] is bool
            ? overlay['announcement_enabled'] as bool
            : false,
      );
    }
    _customAnnouncement =
        (stored[_customAnnouncementKey] as String?)?.trim() ?? '';
    _prefetchLookahead = ((stored[_prefetchLookaheadKey] as num?)?.toInt() ?? 3)
        .clamp(1, 3)
        .toInt();
    // 启动时已选好可用目录；保留偏好供下次启动，不覆盖本次回退结果。
    _cacheDirectoryPreference = _cachePreference(stored);
    if (!_disposed) notifyListeners();
  }

  Future<void> setCustomAnnouncement(String value) async {
    final normalized = value.trim();
    if (_customAnnouncement == normalized) return;
    _customAnnouncement = normalized;
    if (!_disposed) notifyListeners();
    _write();
  }

  Future<void> setAudienceOverlay(AudienceOverlayOptions value) async {
    if (_audienceOverlay == value) return;
    _audienceOverlay = value;
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
    if (normalized.isEmpty ||
        (_cacheDirectoryPreference == normalized &&
            _cacheDirectoryPath == normalized)) {
      return;
    }
    _cacheDirectoryPreference = normalized;
    _cacheDirectoryPath = normalized;
    if (!_disposed) notifyListeners();
    _write();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
