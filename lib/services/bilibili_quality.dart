class BilibiliQualityOption {
  const BilibiliQualityOption({
    required this.qn,
    required this.label,
  });

  final int qn;
  final String label;
}

/// Bilibili video quality preferences exposed by Kirakara.
///
/// Values follow bilibili-API-collect's qn table. HDR, Dolby Vision, 8K and
/// HDR Vivid are deliberately excluded; Dolby Atmos and Hi-Res are audio
/// qualities and therefore never enter this video-only list.
const bilibiliQualityOptions = <BilibiliQualityOption>[
  BilibiliQualityOption(qn: 120, label: '4K 超清'),
  BilibiliQualityOption(qn: 116, label: '1080P 60帧'),
  BilibiliQualityOption(qn: 112, label: '1080P 高码率'),
  BilibiliQualityOption(qn: 80, label: '1080P 高清'),
  BilibiliQualityOption(qn: 74, label: '720P 60帧'),
  BilibiliQualityOption(qn: 64, label: '720P 高清'),
  BilibiliQualityOption(qn: 32, label: '480P 清晰'),
  BilibiliQualityOption(qn: 16, label: '360P 流畅'),
];

const defaultBilibiliQualityQn = 116;

final Set<int> bilibiliAllowedQualityQns =
    bilibiliQualityOptions.map((option) => option.qn).toSet();

int normalizeBilibiliQualityQn(int? qn) {
  return bilibiliAllowedQualityQns.contains(qn)
      ? qn!
      : defaultBilibiliQualityQn;
}

String bilibiliQualityLabel(int qn) {
  for (final option in bilibiliQualityOptions) {
    if (option.qn == qn) return option.label;
  }
  return 'QN $qn';
}
