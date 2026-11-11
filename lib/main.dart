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
    // 缓存路径在下方独立选择，不依赖这里能否写入。
  }
  final settingsFilePath = p.join(settingsDir, 'settings.json');
  final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
  final cacheDirectories = Platform.isWindows
      ? [
          r'D:\Kirakara_Cache',
          r'C:\Kirakara_Cache',
          p.join(exeDir, 'Kirakara_Cache'),
          p.join(
            localAppData == null || localAppData.isEmpty
                ? Directory.systemTemp.path
                : p.join(localAppData, 'Temp'),
            'Kirakara_Cache',
          ),
        ]
      : [p.join((await getTemporaryDirectory()).path, 'Kirakara_Cache')];
  final String cacheDirectory;
  try {
    cacheDirectory = await SettingsService.resolveCacheDirectory(
      settingsFilePath: settingsFilePath,
      defaultPaths: cacheDirectories,
    );
  } on FileSystemException catch (error) {
    debugPrint('Kirakara: unable to create a cache directory: $error');
    runApp(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('无法创建缓存目录，请检查磁盘空间和目录权限。'),
        ),
      ),
    ));
    return;
  }
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
