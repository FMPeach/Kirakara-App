import 'package:flutter/services.dart';

class AppInfo {
  const AppInfo(
      {required this.name, required this.version, required this.developer});
  final String name;
  final String version;
  final String developer;
}

class AppInfoService {
  const AppInfoService({this.channel = const MethodChannel('kirakara/window')});
  final MethodChannel channel;

  Future<String> version() async {
    return await channel.invokeMethod<String>('getAppVersion') ?? '未知版本';
  }

  Future<AppInfo> load() async {
    final info = await channel.invokeMapMethod<String, dynamic>('getAppInfo');
    if (info == null) throw StateError('应用信息不可用');
    return AppInfo(
        name: info['name'] as String,
        version: info['version'] as String,
        developer: info['developer'] as String);
  }
}
