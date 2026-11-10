import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/audience_overlay_options.dart';
import 'package:kirakara_app/domain/phone_order_qr_image.dart';

void main() {
  test('audience switches are independent', () {
    const defaults = AudienceOverlayOptions();
    expect(defaults.qrEnabled, isTrue);
    expect(defaults.queueEnabled, isTrue);
    expect(defaults.announcementEnabled, isFalse);
    for (final qr in [false, true]) {
      for (final queue in [false, true]) {
        final options = defaults.copyWith(qrEnabled: qr, queueEnabled: queue);
        expect(options.qrEnabled, qr);
        expect(options.queueEnabled, queue);
        expect(options.announcementEnabled, isFalse);
      }
    }
  });

  test('QR snapshot owns its immutable bytes and module geometry', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final image = PhoneOrderQrImage(
      endpoint: Uri.parse('http://192.168.1.2:7391'),
      revision: 1,
      pixelSize: 396,
      modules: 33,
      pngBytes: bytes,
    );
    bytes[0] = 9;
    expect(image.pngBytes[0], 1);
    expect(() => image.pngBytes[0] = 9, throwsUnsupportedError);
    expect(image.isValid, isTrue);
  });

  test('QR contract bounds match the Host input limits', () {
    PhoneOrderQrImage image(
            {int size = 396, int modules = 33, int revision = 1}) =>
        PhoneOrderQrImage(
          endpoint: Uri.parse('http://192.168.1.2:7391'),
          revision: revision,
          pixelSize: size,
          modules: modules,
          pngBytes: Uint8List.fromList([1]),
        );
    expect(image(size: 397).isValid, isFalse);
    expect(image(size: 0).isValid, isFalse);
    expect(image(size: 4096).isValid, isFalse);
    expect(image(modules: 0).isValid, isFalse);
    expect(image(revision: 0).isValid, isFalse);
  });
}
