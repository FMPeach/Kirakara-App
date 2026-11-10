import 'dart:io';

import 'package:flutter/services.dart';

class LanNetworkInfo {
  const LanNetworkInfo({required this.name, required this.wifi});
  final String name;
  final bool wifi;

  static Future<LanNetworkInfo?> read(String address) async {
    if (!Platform.isWindows) return null;
    try {
      final value = await const MethodChannel('kirakara/window')
          .invokeMapMethod<String, Object?>('getLanNetworkInfo', address);
      final name = value?['name'];
      if (name is! String || name.trim().isEmpty) return null;
      return LanNetworkInfo(name: name.trim(), wifi: value?['wifi'] == true);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
