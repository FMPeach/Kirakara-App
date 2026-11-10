import 'dart:typed_data';

/// One App-generated image shared by the phone dialog and Show's HUD.
class PhoneOrderQrImage {
  PhoneOrderQrImage({
    required this.endpoint,
    required this.revision,
    required this.pixelSize,
    required this.modules,
    required Uint8List pngBytes,
  }) : pngBytes = Uint8List.fromList(pngBytes).asUnmodifiableView();

  static const maxBytes = 4 * 1024 * 1024;
  static const maxPixels = 2048;
  static const maxModules = 185;

  final Uri endpoint;
  final int revision;
  final int pixelSize;

  /// Whole image, including the white quiet zone, measured in QR modules.
  final int modules;
  final Uint8List pngBytes;

  bool get isValid =>
      (endpoint.scheme == 'http' || endpoint.scheme == 'https') &&
      endpoint.host.isNotEmpty &&
      revision > 0 &&
      pixelSize > 0 &&
      pixelSize <= maxPixels &&
      modules > 0 &&
      modules <= maxModules &&
      pixelSize % modules == 0 &&
      pngBytes.isNotEmpty &&
      pngBytes.length <= maxBytes;
}
