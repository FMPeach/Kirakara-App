import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/phone_order_qr_image.dart';
import 'package:kirakara_app/services/phone_order_qr_service.dart';

PhoneOrderQrImage _image(Uri uri, int revision) => PhoneOrderQrImage(
      endpoint: uri,
      revision: revision,
      pixelSize: 396,
      modules: 33,
      pngBytes: Uint8List.fromList([1, 2, 3]),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = Uri.parse('http://192.168.1.2:7391');
  final second = Uri.parse('http://192.168.2.4:7391');

  test('all consumers reuse a single image until the address changes',
      () async {
    var renders = 0;
    final service = PhoneOrderQrService(renderer: (uri, revision) async {
      renders++;
      return _image(uri, revision);
    });
    addTearDown(service.dispose);
    await service.updateEndpoint(first);
    final shared = service.image;
    for (var i = 0; i < 20; i++) {
      await service.updateEndpoint(first);
      expect(identical(service.image, shared), isTrue);
    }
    expect(renders, 1);
    await service.updateEndpoint(second);
    expect(service.image!.endpoint, second);
    expect(service.image!.revision, greaterThan(shared!.revision));
    await service.updateEndpoint(null);
    expect(service.image, isNull);
    expect(service.endpoint, isNull);
    await service.updateEndpoint(first);
    expect(renders, 3);
  });

  test('late generation cannot resurrect an old network or a disposed service',
      () async {
    final requests = <Completer<PhoneOrderQrImage>>[];
    final service = PhoneOrderQrService(renderer: (uri, revision) {
      final completer = Completer<PhoneOrderQrImage>();
      requests.add(completer);
      return completer.future;
    });
    final a = service.updateEndpoint(first);
    final b = service.updateEndpoint(second);
    requests[1].complete(_image(second, 2));
    await b;
    requests[0].complete(_image(first, 1));
    await a;
    expect(service.image!.endpoint, second);
    final c = service.updateEndpoint(first);
    service.dispose();
    requests[2].complete(_image(first, 3));
    await c;
    expect(service.image, isNull);
  });

  test('real QR PNG has module-aligned size and a four-module white quiet zone',
      () async {
    final image = await PhoneOrderQrService.renderImage(first, 1);
    expect(image.isValid, isTrue);
    expect(image.pixelSize, image.modules * 12);
    final codec = await ui.instantiateImageCodec(image.pngBytes);
    final frame = await codec.getNextFrame();
    final pixels = await frame.image.toByteData();
    expect(frame.image.width, image.pixelSize);
    final rgba = pixels!.buffer.asUint8List();
    for (var y = 0; y < 48; y++) {
      for (var x = 0; x < image.pixelSize; x++) {
        final offset = (y * image.pixelSize + x) * 4;
        expect(rgba.sublist(offset, offset + 4), [255, 255, 255, 255]);
      }
    }
    frame.image.dispose();
    codec.dispose();
  });
}
