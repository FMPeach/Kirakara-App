import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/app_info_service.dart';
import 'package:kirakara_app/services/third_party_licenses.dart';
import 'package:kirakara_app/ui/controller/widgets/version_settings_section.dart';
import 'package:kirakara_app/ui/theme/kirakara_theme.dart';

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
        'version': 'v0.1 Beta',
        'developer': 'Custom Team'
      };
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final info = await const AppInfoService().load();
    expect(info.name, 'Custom Name');
    expect(info.version, 'v0.1 Beta');
    expect(info.developer, 'Custom Team');
  });

  testWidgets('about displays the packaged name and version without a popup',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: VersionSettingsSection(
      loadInfo: () async => const AppInfo(
          name: 'Custom Name', version: 'v0.1 Beta', developer: 'Custom Team'),
    ))));
    await tester.pumpAndSettle();
    final about = tester
        .widget<ListTile>(find.widgetWithText(ListTile, '关于 Custom Name'));
    expect(about.onTap, isNull);
    expect(about.onLongPress, isNull);
    await tester.tap(find.text('关于 Custom Name'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('关于 Custom Name'), findsOneWidget);
    expect(find.text('v0.1 Beta'), findsOneWidget);
  });

  testWidgets('only licenses navigate and version loads once', (tester) async {
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
    expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .where((tile) => tile.onTap != null),
        hasLength(1));
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

  testWidgets('version titles and subtitle match media settings typography',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildKirakaraTheme(),
      home: Scaffold(
        body: Column(children: [
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('缓存目录',
                style: TextStyle(
                    color: KiraColors.muted, fontWeight: FontWeight.w700)),
            subtitle: Text('D:\\Kirakara_Cache',
                style: TextStyle(color: KiraColors.muted, fontSize: 11)),
          ),
          VersionSettingsSection(loadVersion: () async => '2.3.4+56'),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    TextStyle renderedStyle(String text) => tester
        .widget<RichText>(find.descendant(
            of: find.text(text), matching: find.byType(RichText)))
        .text
        .style!;

    final mediaTitle = renderedStyle('缓存目录');
    for (final title in ['关于 Kirakara', '第三方许可证']) {
      expect(renderedStyle(title), mediaTitle);
    }
    expect(renderedStyle('2.3.4+56'), renderedStyle('D:\\Kirakara_Cache'));
    expect(find.byIcon(Icons.chevron_right), findsNothing);
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
