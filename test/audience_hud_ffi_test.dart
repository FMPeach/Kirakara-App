import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/audience_overlay_options.dart';
import 'package:kirakara_app/services/kirakara_show_ffi.dart';
import 'package:kirakara_app/services/phone_order_qr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['KIRAKARA_SHOW_TEST_DLL'];
  test('shared App PNG crosses the real additive Host ABI', () async {
    final host = KirakaraShowFFI(dllPath: path);
    addTearDown(host.dispose);
    final qr = PhoneOrderQrService();
    addTearDown(qr.dispose);
    await qr.updateEndpoint(Uri.parse('http://192.168.1.2:7391'));
    expect(host.audienceHud.setImage(qr.image), isTrue);
    expect(
        host.audienceHud.setState(const AudienceOverlayOptions(), '测试 Wi-Fi',
            [(title: '测试曲目', artist: '歌手')],
            wifi: true, current: (title: '当前歌曲', artist: '当前歌手')),
        isTrue);
    host.audienceHud.onLanChanged = () {};
    host.audienceHud.onLanChanged = null;
    expect(host.audienceHud.setImage(null), isTrue);
    expect(host.position, 0);
    expect(
        host.audienceHud.setState(
            const AudienceOverlayOptions(qrEnabled: false), '', const []),
        isTrue);
  },
      skip: path == null
          ? 'Set KIRAKARA_SHOW_TEST_DLL for native integration'
          : false);
}
