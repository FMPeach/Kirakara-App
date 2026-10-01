import 'dart:io';

import 'package:flutter/services.dart';

class NativeWindowService {
  const NativeWindowService({
    this.channel = const MethodChannel('kirakara/window'),
  });

  final MethodChannel channel;

  /// 注册显示器热插拔回调。
  /// C++ 端收到 WM_DISPLAYCHANGE 后通过 MethodChannel 调用 "onDisplayChange"。
  void setDisplayChangeHandler(VoidCallback callback) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onDisplayChange') {
        callback();
      }
      return null;
    });
  }

  Future<int?> getFlutterViewHandle() async {
    if (!Platform.isWindows) return null;
    final handle = await channel.invokeMethod<int>('getFlutterViewHandle');
    if (handle == null || handle == 0) return null;
    return handle;
  }

  Future<List<Map<String, Object?>>> getDisplays() async {
    if (!Platform.isWindows) return const [];
    final raw = await channel.invokeMethod<List<Object?>>('getDisplays');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((display) => display.map(
              (key, value) => MapEntry(key.toString(), value),
            ))
        .toList(growable: false);
  }

  Future<bool> isControllerFullscreen() async {
    if (!Platform.isWindows) return false;
    return await channel.invokeMethod<bool>('isControllerFullscreen') ?? false;
  }

  Future<bool> setControllerFullscreen(bool fullscreen) async {
    if (!Platform.isWindows) return false;
    return await channel.invokeMethod<bool>(
          'setControllerFullscreen',
          fullscreen,
        ) ??
        false;
  }
}
