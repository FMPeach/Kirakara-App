import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/playback_state.dart';
import 'package:kirakara_app/domain/queue_item.dart';
import 'package:kirakara_app/domain/song.dart';
import 'package:kirakara_app/engine/kirakara_stage_renderer.dart';
import 'package:kirakara_app/engine/stage_renderer.dart';
import 'package:kirakara_app/services/kirakara_show_service.dart';
import 'package:kirakara_app/services/playback_service.dart';
import 'package:kirakara_app/services/queue_service.dart';
import 'package:kirakara_app/services/stage_texture_service.dart';

void main() {
  testWidgets('Windows Stage stays native across playback state transitions',
      (tester) async {
    final queueService = QueueService();
    final playbackService = PlaybackService(queueService: queueService);
    final showService = KirakaraShowService(playbackService: playbackService);
    final renderer = KirakaraStageRenderer(showService: showService);
    addTearDown(() async {
      await showService.dispose();
      playbackService.dispose();
      queueService.dispose();
    });

    final idle = renderer.buildStage(
      playbackState: PlaybackState.initial(),
      mediaFrame: const MediaFrame(backgroundColor: Color(0xffffffff)),
      preset: const RenderPreset(),
    );

    final selected = renderer.buildStage(
      playbackState: PlaybackState.initial(
        currentItem: QueueItem(
          id: 'queue-item',
          song: const Song(
            id: 'song',
            title: 'Song',
            category: 'test',
            assets: [],
          ),
          addedAt: DateTime.utc(2026),
        ),
      ),
      mediaFrame: const MediaFrame(backgroundColor: Color(0xffffffff)),
      preset: const RenderPreset(),
    );

    expect(identical(idle, selected), isTrue);
  }, skip: !Platform.isWindows);

  test('composed Stage bounds include the controller paint transform', () {
    final transform = Matrix4.identity()
      ..setEntry(0, 0, 0.5)
      ..setEntry(1, 1, 0.5)
      ..setEntry(0, 3, 20)
      ..setEntry(1, 3, 30);

    expect(
      transformedPhysicalStageBounds(
        transform: transform,
        size: const Size(1920, 1080),
        devicePixelRatio: 1.25,
      ),
      const Rect.fromLTWH(25, 37.5, 1200, 675),
    );
  });

  testWidgets(
      'composed Stage hole can be repainted without recycling the consumer',
      (tester) async {
    final queueService = QueueService();
    final playbackService = PlaybackService(queueService: queueService);
    final showService = KirakaraShowService(playbackService: playbackService);
    final textureController = _ComposedStageTextureController();
    final renderer = KirakaraStageRenderer(
      showService: showService,
      stageTextureController: textureController,
    );
    addTearDown(() async {
      await showService.dispose();
      playbackService.dispose();
      queueService.dispose();
    });

    final stage = renderer.buildStage(
      playbackState: PlaybackState.initial(),
      mediaFrame: const MediaFrame(backgroundColor: Color(0xff000000)),
      preset: const RenderPreset(),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 640,
          height: 360,
          child: stage,
        ),
      ),
    );
    await tester.pump();

    final customPaint = tester.widget<CustomPaint>(find.byType(CustomPaint));
    expect(customPaint.willChange, isTrue);
    final painter = customPaint.painter!;
    var invalidationCount = 0;
    void onInvalidated() => invalidationCount++;
    painter.addListener(onInvalidated);
    addTearDown(() => painter.removeListener(onInvalidated));

    await renderer.invalidatePreviewComposition();
    expect(invalidationCount, 1);
    await renderer.invalidatePreviewComposition();
    expect(invalidationCount, 2);
    await tester.pump();
    expect(find.byWidget(stage), findsOneWidget);
  }, skip: !Platform.isWindows);
}

class _ComposedStageTextureController extends StageTextureController {
  _ComposedStageTextureController()
      : super(
          textureChannel:
              const MethodChannel('kirakara/test_stage_renderer_texture'),
          compositorChannel:
              const MethodChannel('kirakara/test_stage_renderer_compositor'),
        );
  @override
  Future<StagePresentationAttachment?> attach(int hostHandle) async =>
      const StagePresentationAttachment.composed();

  @override
  Future<void> setActive(bool active) async {}

  @override
  Future<void> setComposedGeometry({
    required Rect physicalBounds,
    bool visible = true,
    String fit = 'contain',
  }) async {}
}
