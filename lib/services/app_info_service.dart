import 'package:flutter/services.dart';

class AppInfoService {
  const AppInfoService({this.channel = const MethodChannel('kirakara/window')});
  final MethodChannel channel;

  Future<String> version() async {
    return await channel.invokeMethod<String>('getAppVersion') ?? '未知版本';
  }
}
