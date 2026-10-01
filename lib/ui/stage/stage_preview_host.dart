import 'package:flutter/widgets.dart';

import '../../engine/stage_renderer.dart';
import '../../services/playback_service.dart';
import 'stage_screen.dart';

/// Keeps the native Stage texture subtree stable while Flutter overlays and
/// controller state update independently above it.
class StagePreviewHost extends StatefulWidget {
  const StagePreviewHost({
    super.key,
    required this.playbackService,
    required this.stageRenderer,
    this.showGuidePills = true,
    this.overlays = const <Widget>[],
  });

  final PlaybackService playbackService;
  final StageRenderer stageRenderer;
  final bool showGuidePills;
  final List<Widget> overlays;

  @override
  State<StagePreviewHost> createState() => _StagePreviewHostState();
}

class _StagePreviewHostState extends State<StagePreviewHost> {
  late Widget _stageSurface;

  @override
  void initState() {
    super.initState();
    _stageSurface = _buildStageSurface();
  }

  @override
  void didUpdateWidget(StagePreviewHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.playbackService, oldWidget.playbackService) ||
        !identical(widget.stageRenderer, oldWidget.stageRenderer) ||
        widget.showGuidePills != oldWidget.showGuidePills) {
      _stageSurface = _buildStageSurface();
    }
  }

  Widget _buildStageSurface() {
    return StageScreen(
      playbackService: widget.playbackService,
      stageRenderer: widget.stageRenderer,
      showGuidePills: widget.showGuidePills,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: _stageSurface),
        ...widget.overlays,
      ],
    );
  }
}
