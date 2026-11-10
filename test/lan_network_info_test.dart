import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/lan_network_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kirakara/window');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('wired connection displays its Windows profile name', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getLanNetworkInfo');
      expect(call.arguments, '192.168.1.2');
      return {'name': 'GZST', 'wifi': false};
    });
    final info = await LanNetworkInfo.read('192.168.1.2');
    expect(info!.name, 'GZST');
    expect(info.wifi, isFalse);
  });
  test('Wi-Fi SSID keeps Unicode and unavailable metadata is optional',
      () async {
    messenger.setMockMethodCallHandler(
        channel, (_) async => {'name': '无线网络 日本語', 'wifi': true});
    final info = await LanNetworkInfo.read('192.168.2.3');
    expect(info!.name, '无线网络 日本語');
    expect(info.wifi, isTrue);
    messenger.setMockMethodCallHandler(
        channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect(await LanNetworkInfo.read('192.168.2.3'), isNull);
  });
}
