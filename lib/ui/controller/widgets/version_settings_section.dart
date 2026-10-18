import 'package:flutter/material.dart';

import '../../../services/app_info_service.dart';
import '../../../services/third_party_licenses.dart';
import '../../theme/kirakara_theme.dart';

class VersionSettingsSection extends StatefulWidget {
  const VersionSettingsSection(
      {super.key, this.loadVersion, this.loadInfo, this.loadLicenses});
  final Future<String> Function()? loadVersion;
  final Future<AppInfo> Function()? loadInfo;
  final Future<List<ThirdPartyLicense>> Function()? loadLicenses;

  @override
  State<VersionSettingsSection> createState() => _VersionSettingsSectionState();
}

class _VersionSettingsSectionState extends State<VersionSettingsSection> {
  late final Future<AppInfo> _info = _loadInfo().catchError((Object _) =>
      const AppInfo(name: 'Kirakara', version: '未知版本', developer: ''));

  Future<AppInfo> _loadInfo() async {
    if (widget.loadInfo != null) return widget.loadInfo!();
    if (widget.loadVersion != null) {
      return AppInfo(
          name: 'Kirakara',
          version: await widget.loadVersion!(),
          developer: 'Project Kirakara');
    }
    return const AppInfoService().load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppInfo>(
        future: _info,
        builder: (context, snapshot) {
          final info = snapshot.data;
          final name = info?.name ?? 'Kirakara';
          final version = info?.version ?? '读取中…';
          return Column(children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('关于 $name',
                  style: const TextStyle(
                      color: KiraColors.muted, fontWeight: FontWeight.w700)),
              subtitle: Text(version,
                  key: const ValueKey('app-version'),
                  style:
                      const TextStyle(color: KiraColors.muted, fontSize: 11)),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('第三方许可证',
                  style: TextStyle(
                      color: KiraColors.muted, fontWeight: FontWeight.w700)),
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
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
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
