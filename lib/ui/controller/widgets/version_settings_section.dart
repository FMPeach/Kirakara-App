import 'package:flutter/material.dart';

import '../../../services/app_info_service.dart';
import '../../../services/third_party_licenses.dart';
import '../../theme/kirakara_theme.dart';

class VersionSettingsSection extends StatefulWidget {
  const VersionSettingsSection(
      {super.key, this.loadVersion, this.loadLicenses});
  final Future<String> Function()? loadVersion;
  final Future<List<ThirdPartyLicense>> Function()? loadLicenses;

  @override
  State<VersionSettingsSection> createState() => _VersionSettingsSectionState();
}

class _VersionSettingsSectionState extends State<VersionSettingsSection> {
  late final Future<String> _version =
      (widget.loadVersion ?? const AppInfoService().version)()
          .catchError((Object _) => '未知版本');

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: _version,
        builder: (context, snapshot) {
          final version = snapshot.data ?? '读取中…';
          return Column(children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('关于 Kirakara'),
              subtitle: Text(version, key: const ValueKey('app-version')),
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Kirakara'),
                    content: Text('$version\n\nProject Kirakara\nMIT'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'))
                  ],
                ),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('第三方许可证'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) =>
                    ThirdPartyLicensesPage(load: widget.loadLicenses),
              )),
            ),
          ]);
        },
      );
}

class ThirdPartyLicensesPage extends StatefulWidget {
  const ThirdPartyLicensesPage({super.key, this.load});
  final Future<List<ThirdPartyLicense>> Function()? load;
  @override
  State<ThirdPartyLicensesPage> createState() => _ThirdPartyLicensesPageState();
}

class _ThirdPartyLicensesPageState extends State<ThirdPartyLicensesPage> {
  late final Future<List<ThirdPartyLicense>> _entries =
      (widget.load ?? loadThirdPartyLicenses)();

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: KiraColors.bg,
        appBar: AppBar(title: const Text('第三方许可证')),
        body: FutureBuilder<List<ThirdPartyLicense>>(
          future: _entries,
          builder: (context, snapshot) {
            if (snapshot.hasError) return const Center(child: Text('无法读取许可证'));
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            final entries = snapshot.data!;
            return ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  title: Text(entry.name),
                  subtitle: entry.license.isEmpty ? null : Text(entry.license),
                  onTap: () {
                    final paragraphs =
                        entry.texts.join('\n\n').split(RegExp(r'\n\s*\n'));
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text(entry.name)),
                        body: ListView.builder(
                          padding: const EdgeInsets.all(24),
                          itemCount: paragraphs.length,
                          itemBuilder: (_, i) => Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: SelectableText(paragraphs[i]),
                          ),
                        ),
                      ),
                    ));
                  },
                );
              },
            );
          },
        ),
      );
}
