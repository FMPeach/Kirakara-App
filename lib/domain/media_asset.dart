enum MediaAssetType {
  video,
  accompaniment,
  vocal,
  cover,
  lyric,
}

class MediaAsset {
  MediaAsset({
    required this.id,
    required this.type,
    required this.uri,
    this.version = 1,
    this.cachedPath,
    this.headers = const {},
  });

  final String id;
  final MediaAssetType type;
  final Uri uri;
  final int version;
  final Map<String, String> headers;
  String? cachedPath;
}
