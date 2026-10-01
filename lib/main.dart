import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/kirakara_app.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final exeDir = p.dirname(Platform.resolvedExecutable);
  // 便携版：数据库与设置统一放到 exe 旁 settings/ 目录。
  final settingsDir = p.join(exeDir, 'settings');
  try {
    Directory(settingsDir).createSync(recursive: true);
  } on FileSystemException {
    // exe 目录只读时回退到临时目录，保证可运行
  }
  final settingsFilePath = p.join(settingsDir, 'settings.json');
  final defaultCacheDirectory = Platform.isWindows
      ? p.join(exeDir, 'Kirakara_Cache')
      : p.join((await getTemporaryDirectory()).path, 'Kirakara_Cache');
  final cacheDirectory = await SettingsService.resolveCacheDirectory(
    defaultCacheDirectory,
    settingsFilePath,
  );
  final smokeLanLoopback = Platform.isWindows &&
      Platform.environment['KIRAKARA_SMOKE_LAN_LOOPBACK'] == '1';
  runApp(
    KirakaraApp(
      databasePath: p.join(settingsDir, 'kirakara_index.db'),
      cacheDirectoryPath: cacheDirectory,
      settingsFilePath: settingsFilePath,
      lanServerBindAddress:
          smokeLanLoopback ? InternetAddress.loopbackIPv4 : null,
    ),
  );
}
