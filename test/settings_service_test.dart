import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/settings_service.dart';
import 'package:kirakara_app/domain/audience_overlay_options.dart';
import 'package:path/path.dart' as p;

void main() {
  group('cache directory fallback', () {
    late Directory sandbox;
    late String settingsPath;
    late List<String> defaults;
    const locations = ['D drive', 'C drive', 'app directory', 'user Temp'];

    setUp(() {
      final directory =
          Directory.systemTemp.createTempSync('kirakara_cache_test_');
      addTearDown(() => directory.deleteSync(recursive: true));
      sandbox = directory;
      settingsPath = p.join(sandbox.path, 'settings.json');
      defaults = [
        for (var i = 0; i < locations.length; i++)
          p.join(sandbox.path, 'location-$i', 'Kirakara_Cache'),
      ];
    });

    void blockDirectory(String path) {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not a directory');
    }

    Future<String> resolve() => SettingsService.resolveCacheDirectory(
          settingsFilePath: settingsPath,
          defaultPaths: defaults,
        );

    for (var failures = 0; failures < locations.length; failures++) {
      test('uses ${locations[failures]} after $failures failed locations',
          () async {
        defaults.take(failures).forEach(blockDirectory);
        expect(await resolve(), defaults[failures]);
        expect(Directory(defaults[failures]).listSync(), isEmpty);
        for (final path in defaults.skip(failures + 1)) {
          expect(Directory(path).existsSync(), isFalse);
        }
      });
    }

    test('tries an available user preference before the defaults', () async {
      final preferred = p.join(sandbox.path, 'custom');
      File(settingsPath)
          .writeAsStringSync(jsonEncode({'cache_directory': preferred}));
      expect(await resolve(), preferred);
      expect(Directory(defaults.first).existsSync(), isFalse);
    });

    test('keeps the resolved path without overwriting a failed preference',
        () async {
      final preferred = p.join(sandbox.path, 'unavailable-custom');
      blockDirectory(preferred);
      blockDirectory(defaults.first);
      File(settingsPath)
          .writeAsStringSync(jsonEncode({'cache_directory': preferred}));
      final resolved = await resolve();
      expect(resolved, defaults[1]);
      final settings = SettingsService(
        initialCacheDirectoryPath: resolved,
        settingsFilePath: settingsPath,
      );
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.cacheDirectoryPath, resolved);
      await settings.setCustomAnnouncement('test');
      expect(
          jsonDecode(File(settingsPath).readAsStringSync())['cache_directory'],
          preferred);
      File(preferred).deleteSync();
      expect(await resolve(), preferred);
    });

    test('does not save an automatic fallback as a user preference', () async {
      defaults.take(2).forEach(blockDirectory);
      final resolved = await resolve();
      final settings = SettingsService(
        initialCacheDirectoryPath: resolved,
        settingsFilePath: settingsPath,
      );
      addTearDown(settings.dispose);
      await settings.load();
      await settings.setPrefetchLookahead(2);
      expect(jsonDecode(File(settingsPath).readAsStringSync()),
          isNot(contains('cache_directory')));
      await settings.setCacheDirectoryPath(resolved);
      expect(
          jsonDecode(File(settingsPath).readAsStringSync())['cache_directory'],
          resolved);
    });

    test('reports failure when no location can be used', () async {
      defaults.forEach(blockDirectory);
      await expectLater(resolve(), throwsA(isA<FileSystemException>()));
    });
  });

  test(
      'audience overlay settings persist independently and migrate old settings',
      () async {
    final directory =
        Directory.systemTemp.createTempSync('kirakara_overlay_settings_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/settings.json';
    File(path).writeAsStringSync('{"custom_announcement":"hello"}');
    final settings = SettingsService(
        initialCacheDirectoryPath: directory.path, settingsFilePath: path);
    await settings.load();
    expect(settings.audienceOverlay, const AudienceOverlayOptions());
    const options = AudienceOverlayOptions(
        qrEnabled: false, queueEnabled: true, announcementEnabled: true);
    await settings.setAudienceOverlay(options);
    settings.dispose();
    final restored = SettingsService(
        initialCacheDirectoryPath: directory.path, settingsFilePath: path);
    await restored.load();
    expect(restored.audienceOverlay, options);
    expect(restored.customAnnouncement, 'hello');
    restored.dispose();
  });
  test('obsolete DLNA deep search setting is ignored', () async {
    final directory = Directory.systemTemp.createTempSync(
      'kirakara_settings_test',
    );
    addTearDown(() {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Test cleanup is best-effort.
      }
    });
    final settingsPath =
        '${directory.path}${Platform.pathSeparator}settings.json';

    File(settingsPath).writeAsStringSync(
      '{"dlna_deep_search_enabled":true}',
    );
    final settings = SettingsService(
      initialCacheDirectoryPath: directory.path,
      settingsFilePath: settingsPath,
    );
    await settings.load();
    await settings.setCustomAnnouncement('测试');
    expect(
      File(settingsPath).readAsStringSync(),
      isNot(contains('dlna_deep_search_enabled')),
    );
    settings.dispose();
  });
}
