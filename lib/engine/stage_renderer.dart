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

/// Optional contract for Stage renderers whose preview is composed below the
/// Flutter surface.
///
/// Removing a native dialog/overlay or finishing a top-level window move can
/// invalidate the alpha contents of Flutter's upper swapchain without changing
/// the Stage widget's layout. Implementations use this hook to repair the
/// composed preview consumer and repaint the transparent slot once; it must not
/// start a continuous frame pump.
abstract interface class StagePreviewCompositionController {
  Future<void> invalidatePreviewComposition();
}
