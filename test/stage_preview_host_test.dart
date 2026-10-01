import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/playback_state.dart';
import 'package:kirakara_app/engine/stage_renderer.dart';
import 'package:kirakara_app/services/playback_service.dart';
import 'package:kirakara_app/services/queue_service.dart';
import 'package:kirakara_app/ui/stage/stage_preview_host.dart';

void main() {
  testWidgets('overlay updates keep the Stage surface widget stable',
      (tester) async {
    final queueService = QueueService();
    final playbackService = PlaybackService(queueService: queueService);
    final renderer = _CountingStageRenderer();
    addTearDown(playbackService.dispose);
    addTearDown(queueService.dispose);

    Widget buildHost(String overlayText) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 640,
          height: 360,
          child: StagePreviewHost(
            playbackService: playbackService,
            stageRenderer: renderer,
            overlays: <Widget>[Text(overlayText)],
          ),
        ),
      );
    }

    await tester.pumpWidget(buildHost('play'));
    expect(renderer.buildCount, 1);

    await tester.pumpWidget(buildHost('pause'));
    expect(find.text('pause'), findsOneWidget);
    expect(renderer.buildCount, 1);

    playbackService.play();
    await tester.pump();
    expect(renderer.buildCount, 2);
  });
}

class _CountingStageRenderer implements StageRenderer {
  int buildCount = 0;

  @override
  Widget buildStage({
    required PlaybackState playbackState,
    required MediaFrame mediaFrame,
    required RenderPreset preset,
  }) {
    buildCount += 1;
    return const ColoredBox(color: Color(0xff000000));
  }
}
