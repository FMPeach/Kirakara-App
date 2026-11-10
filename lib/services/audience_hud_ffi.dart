import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../domain/audience_overlay_options.dart';
import '../domain/phone_order_qr_image.dart';

typedef AudienceQueueEntry = ({String title, String artist});

abstract interface class AudienceHudSink {
  set onLanChanged(void Function()? callback);
  bool setImage(PhoneOrderQrImage? image);
  bool setState(AudienceOverlayOptions options, String network,
      List<AudienceQueueEntry> queue);
}

final class _QueueItem extends Struct {
  external Pointer<Utf16> title;
  external Pointer<Utf16> artist;
}

final class _HudState extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int abi;
  @Uint32()
  external int flags;
  @Uint32()
  external int count;
  @Uint64()
  external int revision;
  external Pointer<Utf16> network;
  external Pointer<_QueueItem> queue;
}

final class _QrImage extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int abi;
  @Uint64()
  external int revision;
  @Uint32()
  external int pixels;
  @Uint32()
  external int modules;
  external Pointer<Uint8> png;
  @Uint32()
  external int length;
  @Uint32()
  external int reserved;
}

typedef _SetStateN = Bool Function(Pointer<Void>, Pointer<_HudState>);
typedef _SetState = bool Function(Pointer<Void>, Pointer<_HudState>);
typedef _SetImageN = Bool Function(Pointer<Void>, Pointer<_QrImage>);
typedef _SetImage = bool Function(Pointer<Void>, Pointer<_QrImage>);
typedef _LanCallback = Void Function(Pointer<Void>, Uint64, Bool);
typedef _SetCallbackN = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_LanCallback>>, Pointer<Void>);
typedef _SetCallback = void Function(
    Pointer<Void>, Pointer<NativeFunction<_LanCallback>>, Pointer<Void>);

/// Optional additive Host ABI. Older DLLs continue to play without audience HUD.
class AudienceHudFFI implements AudienceHudSink {
  AudienceHudFFI(DynamicLibrary library, this._host) {
    try {
      _state = library.lookupFunction<_SetStateN, _SetState>(
          'show_host_set_audience_hud_state');
      _image = library.lookupFunction<_SetImageN, _SetImage>(
          'show_host_set_phone_order_qr_image');
      _callback = library.lookupFunction<_SetCallbackN, _SetCallback>(
          'show_host_set_lan_state_callback');
    } on ArgumentError {
      _state = null;
      _image = null;
      _callback = null;
    }
  }
  final Pointer<Void> _host;
  _SetState? _state;
  _SetImage? _image;
  _SetCallback? _callback;
  NativeCallable<_LanCallback>? _listener;
  void Function()? _onLanChanged;
  int _revision = 0;
  bool _disposed = false;
  PhoneOrderQrImage? _lastImage;

  @override
  set onLanChanged(void Function()? callback) {
    if (_disposed) return;
    _onLanChanged = callback;
    if (_callback == null) return;
    if (callback == null) {
      _callback!(_host, nullptr, nullptr);
      _listener?.close();
      _listener = null;
      return;
    }
    _listener ??= NativeCallable<_LanCallback>.listener(
        (Pointer<Void> context, int revision, bool available) {
      if (!_disposed) _onLanChanged?.call();
    });
    _callback!(_host, _listener!.nativeFunction, nullptr);
  }

  @override
  bool setImage(PhoneOrderQrImage? image) {
    if (_disposed || _image == null) return false;
    if (identical(image, _lastImage)) return true;
    if (image == null) {
      final result = _image!(_host, nullptr);
      if (result) _lastImage = null;
      return result;
    }
    if (!image.isValid) return false;
    final input = calloc<_QrImage>();
    final bytes = calloc<Uint8>(image.pngBytes.length);
    try {
      bytes.asTypedList(image.pngBytes.length).setAll(0, image.pngBytes);
      input.ref
        ..size = sizeOf<_QrImage>()
        ..abi = 1
        ..revision = image.revision
        ..pixels = image.pixelSize
        ..modules = image.modules
        ..png = bytes
        ..length = image.pngBytes.length;
      final result = _image!(_host, input);
      if (result) _lastImage = image;
      return result;
    } finally {
      calloc.free(bytes);
      calloc.free(input);
    }
  }

  @override
  bool setState(AudienceOverlayOptions options, String network,
      List<AudienceQueueEntry> queue) {
    if (_disposed || _state == null) return false;
    final input = calloc<_HudState>();
    final count = queue.length.clamp(0, 4);
    final entries = calloc<_QueueItem>(count == 0 ? 1 : count);
    final strings = <Pointer<Utf16>>[];
    Pointer<Utf16> text(String value) {
      var trimmed = value.length > 512 ? value.substring(0, 512) : value;
      if (trimmed.isNotEmpty &&
          trimmed.codeUnitAt(trimmed.length - 1) >= 0xd800 &&
          trimmed.codeUnitAt(trimmed.length - 1) <= 0xdbff) {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
      final pointer = trimmed.toNativeUtf16();
      strings.add(pointer);
      return pointer;
    }

    try {
      for (var i = 0; i < count; i++) {
        entries[i]
          ..title = text(queue[i].title)
          ..artist = text(queue[i].artist);
      }
      input.ref
        ..size = sizeOf<_HudState>()
        ..abi = 1
        ..flags = (options.qrEnabled ? 1 : 0) |
            (options.queueEnabled ? 2 : 0) |
            (options.announcementEnabled ? 4 : 0)
        ..count = count
        ..revision = ++_revision
        ..network = text(network)
        ..queue = entries;
      return _state!(_host, input);
    } finally {
      for (final pointer in strings) {
        calloc.free(pointer);
      }
      calloc.free(entries);
      calloc.free(input);
    }
  }

  void dispose() {
    if (_disposed) return;
    onLanChanged = null;
    _disposed = true;
  }
}
