import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../domain/phone_order_qr_image.dart';

typedef PhoneOrderQrRenderer = Future<PhoneOrderQrImage> Function(
    Uri endpoint, int revision);

/// 手机点歌弹窗和大屏共享一份成品图片；仅地址变化时生成。
class PhoneOrderQrService extends ChangeNotifier {
  PhoneOrderQrService({PhoneOrderQrRenderer? renderer})
      : _renderer = renderer ?? renderImage;

  final PhoneOrderQrRenderer _renderer;
  Uri? _endpoint;
  PhoneOrderQrImage? _image;
  Future<void>? _pending;
  int _serial = 0;
  bool _disposed = false;

  Uri? get endpoint => _endpoint;
  PhoneOrderQrImage? get image => _image;

  Future<void> updateEndpoint(Uri? endpoint) {
    if (_disposed) return Future.value();
    if (_endpoint == endpoint && (_image != null || _pending != null)) {
      return _pending ?? Future.value();
    }
    final serial = ++_serial;
    _endpoint = endpoint;
    _image = null;
    notifyListeners();
    if (endpoint == null) {
      _pending = null;
      return Future.value();
    }
    return _pending = _generate(endpoint, serial);
  }

  Future<void> _generate(Uri endpoint, int serial) async {
    try {
      final image = await _renderer(endpoint, serial);
      if (_disposed || serial != _serial) return;
      if (!image.isValid ||
          image.endpoint != endpoint ||
          image.revision != serial) {
        throw StateError('Invalid phone order QR image');
      }
      _image = image;
    } catch (error) {
      if (!_disposed && serial == _serial) {
        debugPrint('Phone order QR image unavailable: ${error.runtimeType}');
      }
    } finally {
      if (!_disposed && serial == _serial) {
        _pending = null;
        notifyListeners();
      }
    }
  }

  static Future<PhoneOrderQrImage> renderImage(
      Uri endpoint, int revision) async {
    final validation = QrValidator.validate(data: endpoint.toString());
    final qr = validation.qrCode;
    if (!validation.isValid || qr == null) {
      throw StateError('Phone order address cannot be encoded');
    }
    const quietModules = 4;
    const modulePixels = 12;
    final modules = qr.moduleCount + quietModules * 2;
    final pixels = modules * modulePixels;
    if (pixels > PhoneOrderQrImage.maxPixels) {
      throw StateError('Phone order QR exceeds image limits');
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    canvas.translate(quietModules * modulePixels.toDouble(),
        quietModules * modulePixels.toDouble());
    QrPainter.withQr(qr: qr, gapless: true).paint(
      canvas,
      ui.Size.square(qr.moduleCount * modulePixels.toDouble()),
    );
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(pixels, pixels);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('Phone order QR PNG unavailable');
        return PhoneOrderQrImage(
          endpoint: endpoint,
          revision: revision,
          pixelSize: pixels,
          modules: modules,
          pngBytes: bytes.buffer
              .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_serial;
    _image = null;
    super.dispose();
  }
}
