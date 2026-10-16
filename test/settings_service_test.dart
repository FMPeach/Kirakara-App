import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/settings_service.dart';

void main() {
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
