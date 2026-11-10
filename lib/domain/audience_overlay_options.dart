/// Audience-facing overlays; controller UI and phone ordering stay separate.
class AudienceOverlayOptions {
  const AudienceOverlayOptions({
    this.qrEnabled = true,
    this.queueEnabled = true,
    this.announcementEnabled = false,
  });

  final bool qrEnabled;
  final bool queueEnabled;
  final bool announcementEnabled;

  AudienceOverlayOptions copyWith({
    bool? qrEnabled,
    bool? queueEnabled,
    bool? announcementEnabled,
  }) =>
      AudienceOverlayOptions(
        qrEnabled: qrEnabled ?? this.qrEnabled,
        queueEnabled: queueEnabled ?? this.queueEnabled,
        announcementEnabled: announcementEnabled ?? this.announcementEnabled,
      );

  @override
  bool operator ==(Object other) =>
      other is AudienceOverlayOptions &&
      qrEnabled == other.qrEnabled &&
      queueEnabled == other.queueEnabled &&
      announcementEnabled == other.announcementEnabled;

  @override
  int get hashCode => Object.hash(qrEnabled, queueEnabled, announcementEnabled);
}
