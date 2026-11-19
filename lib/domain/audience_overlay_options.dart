/// Audience-facing overlays; controller UI and phone ordering stay separate.
class AudienceOverlayOptions {
  const AudienceOverlayOptions({
    this.qrEnabled = true,
    this.queueEnabled = true,
    this.announcementEnabled = true,
    this.actionEnabled = true,
  });

  final bool qrEnabled;
  final bool queueEnabled;
  final bool announcementEnabled;
  final bool actionEnabled;

  AudienceOverlayOptions copyWith({
    bool? qrEnabled,
    bool? queueEnabled,
    bool? announcementEnabled,
    bool? actionEnabled,
  }) =>
      AudienceOverlayOptions(
        qrEnabled: qrEnabled ?? this.qrEnabled,
        queueEnabled: queueEnabled ?? this.queueEnabled,
        announcementEnabled: announcementEnabled ?? this.announcementEnabled,
        actionEnabled: actionEnabled ?? this.actionEnabled,
      );

  @override
  bool operator ==(Object other) =>
      other is AudienceOverlayOptions &&
      qrEnabled == other.qrEnabled &&
      queueEnabled == other.queueEnabled &&
      announcementEnabled == other.announcementEnabled &&
      actionEnabled == other.actionEnabled;

  @override
  int get hashCode =>
      Object.hash(qrEnabled, queueEnabled, announcementEnabled, actionEnabled);
}
