class StageOverlayAsset {
  const StageOverlayAsset({
    required this.cacheKey,
    required this.localPath,
    required this.contentRevision,
  });

  final String cacheKey;
  final String localPath;
  final int contentRevision;

  bool get isValid => cacheKey.isEmpty == localPath.isEmpty;
}

class StageOverlayState {
  const StageOverlayState({
    required this.revision,
    this.qrVisible = false,
    this.qrPayload = '',
    this.qrDecoration,
    this.announcementVisible = false,
    this.announcementText = '',
    this.announcementDecoration,
  });

  final int revision;
  final bool qrVisible;
  final String qrPayload;
  final StageOverlayAsset? qrDecoration;
  final bool announcementVisible;
  final String announcementText;
  final StageOverlayAsset? announcementDecoration;

  bool get isValid =>
      revision >= 0 &&
      (!qrVisible || qrPayload.isNotEmpty) &&
      (!announcementVisible || announcementText.isNotEmpty) &&
      (qrDecoration?.isValid ?? true) &&
      (announcementDecoration?.isValid ?? true);
}
