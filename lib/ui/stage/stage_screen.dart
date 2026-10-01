import 'package:flutter/material.dart';

import '../../engine/stage_renderer.dart';
import '../../services/playback_service.dart';

class StageScreen extends StatelessWidget {
  const StageScreen({
    super.key,
    required this.playbackService,
    required this.stageRenderer,
    this.showGuidePills = true,
  });

  final PlaybackService playbackService;
  final StageRenderer stageRenderer;
  final bool showGuidePills;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: playbackService,
      builder: (context, _) {
        final song = playbackService.state.currentSong;
        return SizedBox.expand(
          child: stageRenderer.buildStage(
            playbackState: playbackService.state,
            mediaFrame: MediaFrame(
              backgroundColor: Color(song?.coverColor ?? 0xff111216),
            ),
            preset: RenderPreset(showGuidePills: showGuidePills),
          ),
        );
      },
    );
  }
}
