import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/settings_service.dart';

void main() {
  test('DLNA deep search defaults off and persists explicit changes', () async {
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

    final initial = SettingsService(
      initialCacheDirectoryPath: directory.path,
      settingsFilePath: settingsPath,
    );
    await initial.load();
    expect(initial.dlnaDeepSearchEnabled, isFalse);

    await initial.setDlnaDeepSearchEnabled(true);
    final stored = jsonDecode(File(settingsPath).readAsStringSync()) as Map;
    expect(stored['dlna_deep_search_enabled'], isTrue);
    initial.dispose();

    final reloaded = SettingsService(
      initialCacheDirectoryPath: directory.path,
      settingsFilePath: settingsPath,
    );
    await reloaded.load();
    expect(reloaded.dlnaDeepSearchEnabled, isTrue);
    reloaded.dispose();
  });
}
