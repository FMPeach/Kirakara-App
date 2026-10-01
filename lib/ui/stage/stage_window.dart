import 'package:flutter/widgets.dart';

import '../../engine/stage_renderer.dart';
import '../../services/display_manager.dart';
import '../../services/playback_service.dart';
import 'stage_screen.dart';

class StageWindowHost extends StatelessWidget {
  const StageWindowHost({
    super.key,
    required this.displayManager,
    required this.playbackService,
    required this.stageRenderer,
  });

  final DisplayManager displayManager;
  final PlaybackService playbackService;
  final StageRenderer stageRenderer;

  @override
  Widget build(BuildContext context) {
    return StageScreen(
      playbackService: playbackService,
      stageRenderer: stageRenderer,
      showGuidePills: false,
    );
  }
}
