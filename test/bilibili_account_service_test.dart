import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/bilibili_account_service.dart';

void main() {
  test('persists the selected Bilibili quality without requiring a login',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('kirakara_bilibili_account_');
    final path = '${directory.path}${Platform.pathSeparator}session.json';
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    final first = BilibiliAccountService(sessionFilePath: path);
    await first.load();
    await first.setPreferredQualityQn(120);
    first.dispose();

    final second = BilibiliAccountService(sessionFilePath: path);
    addTearDown(second.dispose);
    await second.load();

    expect(second.preferredQualityQn, 120);
    expect(second.isLoggedIn, isFalse);
    expect(second.cookieHeader, isNull);
  });

  test('removes legacy cookies and profile data from disk on startup',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('kirakara_bilibili_privacy_');
    final path = '${directory.path}${Platform.pathSeparator}session.json';
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final file = File(path);
    await file.writeAsString('''
{
  "preferred_quality_qn": 120,
  "cookies": {
    "SESSDATA": "legacy-secret-cookie",
    "bili_jct": "legacy-secret-csrf"
  },
  "profile": {
    "name": "legacy-user",
    "face_url": "https://example.invalid/avatar.jpg",
    "signature": "legacy-profile"
  }
}
''');

    final service = BilibiliAccountService(sessionFilePath: path);
    addTearDown(service.dispose);
    await service.load();

    expect(service.preferredQualityQn, 120);
    expect(service.isLoggedIn, isFalse);
    expect(service.cookieHeader, isNull);
    expect(service.profile, isNull);

    final persisted = await file.readAsString();
    expect(persisted, contains('"preferred_quality_qn": 120'));
    expect(persisted, isNot(contains('legacy-secret-cookie')));
    expect(persisted, isNot(contains('legacy-secret-csrf')));
    expect(persisted, isNot(contains('legacy-user')));
    expect(persisted, isNot(contains('cookies')));
    expect(persisted, isNot(contains('profile')));
  });
}
