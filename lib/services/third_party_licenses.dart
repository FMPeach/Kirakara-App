import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ThirdPartyLicense {
  ThirdPartyLicense(this.name, this.license, Iterable<String> texts)
      : texts = texts.toSet().toList(growable: false);
  final String name;
  final String license;
  final List<String> texts;
}

Future<List<ThirdPartyLicense>> loadThirdPartyLicenses() async {
  final raw =
      jsonDecode(await rootBundle.loadString('assets/licenses/catalog.json'))
          as List<dynamic>;
  final entries = <String, ThirdPartyLicense>{};
  for (final item in raw.cast<Map<String, dynamic>>()) {
    final name = item['name'] as String;
    entries[name.toLowerCase()] = ThirdPartyLicense(
        name,
        item['license'] as String,
        (item['texts'] as List<dynamic>).cast<String>());
  }
  await for (final entry in LicenseRegistry.licenses) {
    final text = entry.paragraphs.map((p) => p.text).join('\n\n');
    for (final name in entry.packages) {
      final key = name.toLowerCase();
      final old = entries[key];
      entries[key] = ThirdPartyLicense(
          old?.name ?? name, old?.license ?? '', [...?old?.texts, text]);
    }
  }
  return entries.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}
