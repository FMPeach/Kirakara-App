import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/kirakara_show_ffi.dart';

void main() {
  test('idle background is resolved beside the App, independently of cwd', () {
    expect(
      KirakaraShowFFI.idleBackgroundImagePath(
        executablePath: r'D:\点歌 测试\Kirakara\kirakara_app.exe',
      ),
      r'D:\点歌 测试\Kirakara\data\idle-background.png',
    );
  }, skip: !Platform.isWindows);
}
