class LyricProject {
  LyricProject({
    required this.id,
    required this.songId,
    required this.krlUri,
    required this.version,
    this.cachedPath,
  });

  final String id;
  final String songId;
  final Uri krlUri;
  final int version;
  String? cachedPath;
}
