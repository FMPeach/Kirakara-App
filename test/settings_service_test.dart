import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/settings_service.dart';
import 'package:kirakara_app/domain/audience_overlay_options.dart';

void main() {
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
