import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/bilibili_quality.dart';
import 'package:kirakara_app/services/bilibili_resolver.dart';

void main() {
  group('Bilibili DASH CDN selection', () {
    test('prefers a regular CDN backup over an MCDN base URL', () {
      final selected = selectBilibiliStreamUrl({
        'baseUrl': 'https://edge.mcdn.bilivideo.cn/audio.m4s',
        'backupUrl': [
          'https://upos-sz-mirrorcos.bilivideo.com/audio.m4s',
        ],
      });

      expect(
        selected,
        'https://upos-sz-mirrorcos.bilivideo.com/audio.m4s',
      );
    });

    test('keeps a regular base URL ahead of its backups', () {
      final selected = selectBilibiliStreamUrl({
        'base_url': 'https://cn-gddg-cm-01.bilivideo.com/audio.m4s',
        'backup_url': [
          'https://upos-sz-mirrorcos.bilivideo.com/audio.m4s',
        ],
      });

      expect(
        selected,
        'https://cn-gddg-cm-01.bilivideo.com/audio.m4s',
      );
    });

    test('falls back to MCDN when it is the only candidate', () {
      final selected = selectBilibiliStreamUrl({
        'baseUrl': 'https://edge.mcdn.bilivideo.cn/audio.m4s',
      });

      expect(selected, 'https://edge.mcdn.bilivideo.cn/audio.m4s');
    });
  });

  group('Bilibili video quality preferences', () {
    test('contains only regular SDR video qualities up to 4K', () {
      expect(
        bilibiliQualityOptions.map((option) => option.qn),
        orderedEquals(<int>[120, 116, 112, 80, 74, 64, 32, 16]),
      );
    });

    test('excludes bangumi repair, premium dynamic range and audio qn values',
        () {
      for (final excluded in <int>[
        100, // Bangumi-only 720P smart repair.
        125, // HDR.
        126, // Dolby Vision.
        127, // 8K.
        129, // HDR Vivid.
        30250, // Dolby Atmos audio.
        30251, // Hi-Res audio.
      ]) {
        expect(bilibiliAllowedQualityQns, isNot(contains(excluded)));
      }
    });

    test('does not request guest preview mode for authenticated playback', () {
      final parameters = buildBilibiliPlayUrlParameters(
        cid: 29804793261,
        preferredQuality: 116,
        authenticated: true,
      );

      expect(parameters['qn'], '116');
      expect(parameters, isNot(contains('try_look')));
    });

    test('keeps guest preview mode for playback without a session', () {
      final parameters = buildBilibiliPlayUrlParameters(
        cid: 29804793261,
        preferredQuality: 116,
        authenticated: false,
      );

      expect(parameters['try_look'], '1');
    });
  });
}
