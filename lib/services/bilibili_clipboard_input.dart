const int maxBilibiliClipboardInputCodeUnits = 64 * 1024;

final RegExp _urlPattern = RegExp(
  r'https?://[^\s<>"\u201c\u201d]+',
  caseSensitive: false,
);
final RegExp _videoPathPattern = RegExp(
  r'^/video/(?:BV[a-zA-Z0-9]{10}|av\d+)(?:/|$)',
  caseSensitive: false,
);
final RegExp _bvPattern = RegExp(
  r'\bBV[a-zA-Z0-9]{10}\b',
  caseSensitive: false,
);
final RegExp _avPattern = RegExp(r'\bav(\d+)\b', caseSensitive: false);
final RegExp _trailingUrlPunctuation =
    RegExp(r'''[\]\[(){}<>"'，。；;！!？?,、【】（）「」『』]+$''');

/// Extracts one supported Bilibili URL, BV id, or AV id from text pasted into
/// the external-link field. No other text input uses this normalization.
String? extractBilibiliClipboardInput(String clipboardText) {
  final trimmed = clipboardText.trim();
  if (trimmed.isEmpty || trimmed.length > maxBilibiliClipboardInputCodeUnits) {
    return null;
  }

  for (final match in _urlPattern.allMatches(trimmed)) {
    final candidate = match.group(0)!.replaceFirst(_trailingUrlPunctuation, '');
    final uri = Uri.tryParse(candidate);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      continue;
    }
    final host = uri.host.toLowerCase();
    if ((host == 'b23.tv' || host.endsWith('.b23.tv')) &&
        uri.pathSegments.isNotEmpty) {
      return candidate;
    }
    if ((host == 'bilibili.com' || host.endsWith('.bilibili.com')) &&
        _videoPathPattern.hasMatch(uri.path)) {
      return candidate;
    }
  }

  final bvMatch = _bvPattern.firstMatch(trimmed);
  if (bvMatch != null) {
    final value = bvMatch.group(0)!;
    return 'BV${value.substring(2)}';
  }

  final avMatch = _avPattern.firstMatch(trimmed);
  if (avMatch != null) return 'av${avMatch.group(1)}';
  return null;
}
