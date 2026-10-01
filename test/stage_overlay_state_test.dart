import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/stage_overlay_state.dart';
import 'package:kirakara_app/services/kirakara_show_ffi.dart';
import 'package:path/path.dart' as p;

void main() {
  test('disabled overlay state needs no temporary artwork', () {
    const state = StageOverlayState(revision: 0);
    expect(state.isValid, isTrue);
  });

  test('visible overlays require content but decorations stay optional', () {
    const invalid = StageOverlayState(revision: 1, qrVisible: true);
    const valid = StageOverlayState(
      revision: 2,
      qrVisible: true,
      qrPayload: 'http://192.168.1.2:7391',
      announcementVisible: true,
      announcementText: 'Kira Karaoke',
    );
    expect(invalid.isValid, isFalse);
    expect(valid.isValid, isTrue);
  });

  test('asset cache identity requires key and path together', () {
    const missingPath = StageOverlayAsset(
      cacheKey: 'qr-frame',
      localPath: '',
      contentRevision: 1,
    );
    const complete = StageOverlayAsset(
      cacheKey: 'qr-frame',
      localPath: r'D:\cache\qr-frame.png',
      contentRevision: 1,
    );
    expect(missingPath.isValid, isFalse);
    expect(complete.isValid, isTrue);
  });

  final showDll = _findShowHostDll();
  test(
    'Windows FFI transports the versioned overlay struct',
    () {
      final ffi = KirakaraShowFFI(dllPath: showDll!.path);
      try {
        expect(
          ffi.setStageOverlayState(
            const StageOverlayState(
              revision: 42,
              qrVisible: true,
              qrPayload: 'http://192.168.1.2:7391',
              announcementVisible: true,
              announcementText: 'Kira Karaoke',
            ),
          ),
          isTrue,
        );
      } finally {
        ffi.dispose();
      }
    },
    skip: !Platform.isWindows || showDll == null,
  );
}

File? _findShowHostDll() {
  if (!Platform.isWindows) return null;
  final overridePath =
      Platform.environment['KIRAKARA_SHOW_HOST_DLL']?.trim() ?? '';
  if (overridePath.isNotEmpty) {
    final override = File(overridePath);
    if (override.existsSync()) return override;
  }
  final configFile = File(
    p.join(Directory.current.path, 'config', 'kirakara.local.json'),
  );
  if (!configFile.existsSync()) return null;
  try {
    final decoded = jsonDecode(configFile.readAsStringSync());
    if (decoded is! Map<String, dynamic> || decoded['schemaVersion'] != 1) {
      return null;
    }
    final windows = decoded['windows'];
    if (windows is! Map<String, dynamic>) return null;
    final configuredPath = windows['showHostDll'];
    if (configuredPath is! String ||
        configuredPath.trim().isEmpty ||
        !p.isAbsolute(configuredPath.trim())) {
      return null;
    }
    final configured = File(configuredPath.trim());
    return configured.existsSync() ? configured : null;
  } on FormatException {
    return null;
  }
}
