import 'package:flutter/widgets.dart';

import '../domain/playback_state.dart';

class MediaFrame {
  const MediaFrame({
    required this.backgroundColor,
  });

  final Color backgroundColor;
}

class RenderPreset {
  const RenderPreset({
    this.resolution = const Size(1920, 1080),
    this.showGuidePills = true,
  });

  final Size resolution;
  final bool showGuidePills;
}

abstract class StageRenderer {
  Widget buildStage({
    required PlaybackState playbackState,
    required MediaFrame mediaFrame,
    required RenderPreset preset,
  });
}
