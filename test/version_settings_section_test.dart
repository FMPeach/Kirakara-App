import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/app_info_service.dart';
import 'package:kirakara_app/services/third_party_licenses.dart';
import 'package:kirakara_app/ui/controller/widgets/version_settings_section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version is read from the built Windows runner', () async {
    const channel = MethodChannel('kirakara/window');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getAppVersion');
      return '2.3.4+56';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    expect(await const AppInfoService().version(), '2.3.4+56');
  });

  test('name, version and developer come from native package metadata',
      () async {
    const channel = MethodChannel('kirakara/window');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getAppInfo');
      return {
        'name': 'Custom Name',
        'version': '2.3.4+56',
        'developer': 'Custom Team'
      };
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final info = await const AppInfoService().load();
    expect(info.name, 'Custom Name');
    expect(info.version, '2.3.4+56');
    expect(info.developer, 'Custom Team');
  });

  testWidgets('about follows the packaged name and developer', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: VersionSettingsSection(
      loadInfo: () async => const AppInfo(
          name: 'Custom Name', version: '2.3.4+56', developer: 'Custom Team'),
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于 Custom Name'));
    await tester.pumpAndSettle();
    expect(find.text('Custom Name'), findsOneWidget);
    expect(find.textContaining('Custom Team'), findsOneWidget);
  });

  testWidgets('version section has exactly two menus and loads version once',
      (tester) async {
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: VersionSettingsSection(
      loadVersion: () async {
        loads++;
        return '2.3.4+56';
      },
      loadLicenses: () async => [
        ThirdPartyLicense(
            'Test component', 'MIT', ['Full copyright and permission text.'])
      ],
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.text('2.3.4+56'), findsOneWidget);
    await tester.tap(find.text('第三方许可证'));
    await tester.pumpAndSettle();
    expect(find.text('Test component'), findsOneWidget);
    await tester.tap(find.text('Test component'));
    await tester.pumpAndSettle();
    expect(find.text('Full copyright and permission text.'), findsOneWidget);
    expect(loads, 1);
  });

  test('offline native notices contain complete license texts', () async {
    final entries = await loadThirdPartyLicenses();
    expect(entries.any((entry) => entry.name == 'Kirakara Show'), isTrue);
    expect(entries.any((entry) => entry.name == 'Flutter Engine'), isTrue);
    expect(
        entries.every(
            (entry) => entry.texts.every((text) => text.trim().isNotEmpty)),
        isTrue);
  });
}
