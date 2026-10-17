import 'dart:io';

import 'package:path/path.dart' as path;

typedef ChunKHelperProcessStarter = Future<void> Function(
    String executable, String workingDirectory);

class ChunKHelperLauncher {
  const ChunKHelperLauncher({
    this.applicationDirectory,
    this.processStarter = _startProcess,
    this.isWindows,
  });

  final String? applicationDirectory;
  final ChunKHelperProcessStarter processStarter;
  final bool? isWindows;

  Future<void> launch() async {
    if (!(isWindows ?? Platform.isWindows)) {
      throw const ChunKHelperLaunchException('纯K助手目前仅支持 Windows。');
    }
    final directory = path.join(
      applicationDirectory ?? path.dirname(Platform.resolvedExecutable),
      'tools',
      'ChunKHelper',
    );
    final executable = path.join(directory, 'ChunK Helper.exe');
    if (!await File(executable).exists()) {
      throw const ChunKHelperLaunchException(
        '未找到纯K助手，请将助手发布目录放到 App 的 tools/ChunKHelper 下。',
      );
    }
    try {
      await processStarter(executable, directory);
    } on ProcessException {
      throw const ChunKHelperLaunchException('纯K助手启动失败，请检查工具文件是否完整。');
    }
  }

  static Future<void> _startProcess(
      String executable, String workingDirectory) async {
    await Process.start(
      executable,
      const [],
      workingDirectory: workingDirectory,
      runInShell: false,
      mode: ProcessStartMode.detached,
    );
  }
}

class ChunKHelperLaunchException implements Exception {
  const ChunKHelperLaunchException(this.message);
  final String message;
  @override
  String toString() => message;
}
