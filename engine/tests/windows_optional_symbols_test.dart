// Copyright 2026 Kirakara contributors. SPDX-License-Identifier: MIT
import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/targets/common.dart';
import 'package:flutter_tools/src/build_system/targets/windows.dart';
import 'package:process/process.dart';
import 'package:test/test.dart';

({Environment environment, FileSystem fs, String source}) fixture(
  BuildMode mode, {
  required bool local,
}) {
  final fs = MemoryFileSystem.test(style: FileSystemStyle.windows);
  final artifacts = local
      ? Artifacts.testLocalEngine(
          localEngine: 'host_${mode.cliName}_kirakara',
          localEngineHost: 'host_${mode.cliName}_kirakara',
          fileSystem: fs,
        )
      : Artifacts.test(fileSystem: fs);
  final environment = Environment.test(
    fs.currentDirectory,
    artifacts: artifacts,
    processManager: const LocalProcessManager(),
    fileSystem: fs,
    logger: BufferLogger.test(),
    defines: <String, String>{kBuildMode: mode.cliName},
  );
  environment.buildDir.createSync(recursive: true);
  final source = artifacts.getArtifactPath(
    Artifact.windowsDesktopPath,
    platform: TargetPlatform.windows_x64,
    mode: mode,
  );
  for (final name in <String>[
    'flutter_windows.dll',
    'flutter_windows.dll.exp',
    'flutter_windows.dll.lib',
    'flutter_export.h',
    'flutter_messenger.h',
    'flutter_plugin_registrar.h',
    'flutter_texture_registrar.h',
    'flutter_windows.h',
  ]) {
    fs.file(fs.path.join(source, name)).createSync(recursive: true);
  }
  fs
      .file(artifacts.getArtifactPath(Artifact.icuData,
          platform: TargetPlatform.windows_x64))
      .createSync(recursive: true);
  fs
      .file(fs.path.join(
          artifacts.getArtifactPath(
            Artifact.windowsCppClientWrapper,
            platform: TargetPlatform.windows_x64,
            mode: mode,
          ),
          'wrapper.cc'))
      .createSync(recursive: true);
  return (environment: environment, fs: fs, source: source);
}

void main() {
  for (final mode in <BuildMode>[
    BuildMode.debug,
    BuildMode.profile,
    BuildMode.release
  ]) {
    test('${mode.cliName} local-engine accepts missing optional PDB', () async {
      final f = fixture(mode, local: true);
      await const UnpackWindows(TargetPlatform.windows_x64)
          .build(f.environment);
      expect(
          f.fs
              .file(r'C:\windows\flutter\ephemeral\flutter_windows.dll')
              .existsSync(),
          isTrue);
      expect(
          f.fs
              .file(r'C:\windows\flutter\ephemeral\flutter_windows.dll.pdb')
              .existsSync(),
          isFalse);
    });
    test('${mode.cliName} stock engine still rejects missing PDB', () async {
      final f = fixture(mode, local: false);
      await expectLater(
          const UnpackWindows(TargetPlatform.windows_x64).build(f.environment),
          throwsA(isA<Exception>()));
    });
  }
  test('local-engine still copies an available real PDB', () async {
    final f = fixture(BuildMode.debug, local: true);
    f.fs
        .file(f.fs.path.join(f.source, 'flutter_windows.dll.pdb'))
        .writeAsStringSync('symbols');
    await const UnpackWindows(TargetPlatform.windows_x64).build(f.environment);
    expect(
        f.fs
            .file(r'C:\windows\flutter\ephemeral\flutter_windows.dll.pdb')
            .readAsStringSync(),
        'symbols');
  });
  test('local-engine still rejects missing EXP', () async {
    final f = fixture(BuildMode.debug, local: true);
    f.fs.file(f.fs.path.join(f.source, 'flutter_windows.dll.exp')).deleteSync();
    await expectLater(
        const UnpackWindows(TargetPlatform.windows_x64).build(f.environment),
        throwsA(isA<Exception>()));
  });
  test('local-engine rejects a directory pretending to be a PDB', () async {
    final f = fixture(BuildMode.debug, local: true);
    f.fs
        .directory(f.fs.path.join(f.source, 'flutter_windows.dll.pdb'))
        .createSync();
    await expectLater(
        const UnpackWindows(TargetPlatform.windows_x64).build(f.environment),
        throwsA(isA<Exception>()));
  });
  test('local-engine rejects a link pretending to be a PDB', () async {
    final f = fixture(BuildMode.debug, local: true);
    f.fs
        .link(f.fs.path.join(f.source, 'flutter_windows.dll.pdb'))
        .createSync('flutter_windows.dll');
    await expectLater(
        const UnpackWindows(TargetPlatform.windows_x64).build(f.environment),
        throwsA(isA<Exception>()));
  });
}
