import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../domain/playback_state.dart';
import '../services/kirakara_show_service.dart';
import '../services/stage_texture_service.dart';
import 'stage_renderer.dart';

class KirakaraStageRenderer
    implements StageRenderer, StagePreviewCompositionController {
  KirakaraStageRenderer({
    required KirakaraShowService showService,
    StageTextureController? stageTextureController,
  })  : _showService = showService,
        _stageTextureController =
            stageTextureController ?? StageTextureController() {
    _stageTextureController.onPreviewSurfaceInvalidated =
        _handleNativePreviewSurfaceInvalidation;
    _windowsStage = _KirakaraGpuStageWidget(
      showService: _showService,
      textureController: _stageTextureController,
      previewRepaint: _previewRepaint,
    );
  }

  final KirakaraShowService _showService;
  final StageTextureController _stageTextureController;
  final _StagePreviewRepaintSignal _previewRepaint =
      _StagePreviewRepaintSignal();
  late final Widget _windowsStage;

  @override
  Future<void> invalidatePreviewComposition() async {
    if (!Platform.isWindows) return;
    // Only replay the transparent clear operation on Flutter's upper surface.
    // The lower Stage Visual remains attached throughout; recycling that
    // consumer creates a visible one-frame gap after moves and modal routes.
    _previewRepaint.pulse();
  }

  void _handleNativePreviewSurfaceInvalidation() {
    unawaited(invalidatePreviewComposition());
  }

  @override
  Widget buildStage({
    required PlaybackState playbackState,
    required MediaFrame mediaFrame,
    required RenderPreset preset,
  }) {
    if (Platform.isWindows) {
      // Show and the patched Windows compositor own the Stage contents once
      // attached. Do not cover that native Visual from transient Flutter
      // playback/loading state: doing so hides Show's retained transition
      // frame even though the physical Stage continues presenting normally.
      // The widget itself is black before attachment, while the compositor
      // supplies an opaque-black placeholder before the first native frame.
      return _windowsStage;
    }
    return ColoredBox(color: mediaFrame.backgroundColor);
  }
}

class _KirakaraGpuStageWidget extends StatefulWidget {
  const _KirakaraGpuStageWidget({
    required this.showService,
    required this.textureController,
    required this.previewRepaint,
  });

  final KirakaraShowService showService;
  final StageTextureController textureController;
  final Listenable previewRepaint;

  @override
  State<_KirakaraGpuStageWidget> createState() =>
      _KirakaraGpuStageWidgetState();
}

class _KirakaraGpuStageWidgetState extends State<_KirakaraGpuStageWidget> {
  StagePresentationAttachment? _attachment;

  @override
  void initState() {
    super.initState();
    unawaited(_attachTexture());
  }

  Future<void> _attachTexture() async {
    final attachment = await widget.textureController.attach(
      widget.showService.nativeHandleAddress,
    );
    if (!mounted) {
      await widget.textureController.setActive(false);
      return;
    }
    if (attachment == null) return;
    setState(() => _attachment = attachment);
    if (attachment.isComposed) {
      // Let the transparent slot publish its physical bounds before Show can
      // deliver the first frame. The Engine keeps the lower Visual detached
      // until both geometry and a resource are available.
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) return;
    await widget.textureController.setActive(true);
  }

  @override
  void dispose() {
    unawaited(widget.textureController.setActive(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final attachment = _attachment;
    if (attachment == null) {
      return const ColoredBox(color: Colors.black);
    }
    if (attachment.isComposed) {
      return _ComposedStageHole(
        controller: widget.textureController,
        previewRepaint: widget.previewRepaint,
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Texture(
        textureId: attachment.textureId!,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class _ComposedStageHole extends StatefulWidget {
  const _ComposedStageHole({
    required this.controller,
    required this.previewRepaint,
  });

  final StageTextureController controller;
  final Listenable previewRepaint;

  @override
  State<_ComposedStageHole> createState() => _ComposedStageHoleState();
}

class _ComposedStageHoleState extends State<_ComposedStageHole>
    with WidgetsBindingObserver {
  final _slotKey = GlobalKey();
  bool _reportScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleGeometryReport();
  }

  @override
  void didUpdateWidget(_ComposedStageHole oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleGeometryReport();
  }

  @override
  void didChangeMetrics() {
    _scheduleGeometryReport();
  }

  void _scheduleGeometryReport() {
    if (_reportScheduled) return;
    _reportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      if (!mounted) return;
      final renderObject =
          _slotKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderObject == null || !renderObject.hasSize) return;
      final scale = View.of(context).devicePixelRatio;
      unawaited(widget.controller.setComposedGeometry(
        physicalBounds: transformedPhysicalStageBounds(
          transform: renderObject.getTransformTo(null),
          size: renderObject.size,
          devicePixelRatio: scale,
        ),
        // The unified Stage texture already contains Show's authored
        // letterbox/pillarbox canvas. Match the legacy Flutter Texture path by
        // mapping that completed canvas to the actual preview viewport.
        fit: 'fill',
      ));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleGeometryReport();
    return _StageGeometryObserver(
      onGeometryChanged: _scheduleGeometryReport,
      child: CustomPaint(
        key: _slotKey,
        painter: _ClearStageHolePainter(widget.previewRepaint),
        // The clear operation is destination-dependent: once flattened into a
        // raster-cache bitmap, its transparent pixels can no longer erase the
        // opaque controller background below them. Keep the containing
        // DisplayList live so every already-scheduled Flutter frame replays
        // the clear operation. This is only a cache hint; it does not request
        // frames or start a frame pump while the UI is idle.
        willChange: true,
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Converts the complete paint transform of the Flutter preview slot to the
/// physical client-space rectangle expected by DirectComposition.
///
/// In particular, [RenderBox.localToGlobal] transforms only a point. Pairing
/// that point with the untransformed render-box size leaves a Stage Visual at
/// its 1920x1080 design dimensions whenever [FittedBox] scales the controller
/// UI down. Transforming the full rectangle keeps the native lower Visual and
/// Flutter's transparent hole coincident at every window size.
@visibleForTesting
Rect transformedPhysicalStageBounds({
  required Matrix4 transform,
  required Size size,
  required double devicePixelRatio,
}) {
  final logicalBounds = MatrixUtils.transformRect(
    transform,
    Offset.zero & size,
  );
  return Rect.fromLTRB(
    logicalBounds.left * devicePixelRatio,
    logicalBounds.top * devicePixelRatio,
    logicalBounds.right * devicePixelRatio,
    logicalBounds.bottom * devicePixelRatio,
  );
}

/// Reports only real layout/paint-transform changes. This is deliberately not
/// a timer: a static Flutter scene performs no work while the lower Stage
/// Visual continues presenting independently.
class _StageGeometryObserver extends SingleChildRenderObjectWidget {
  const _StageGeometryObserver({
    required this.onGeometryChanged,
    required super.child,
  });

  final VoidCallback onGeometryChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderStageGeometryObserver(onGeometryChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderStageGeometryObserver renderObject,
  ) {
    renderObject.onGeometryChanged = onGeometryChanged;
  }
}

class _RenderStageGeometryObserver extends RenderProxyBox {
  _RenderStageGeometryObserver(this._onGeometryChanged);

  VoidCallback _onGeometryChanged;
  Rect? _lastGlobalBounds;

  set onGeometryChanged(VoidCallback value) {
    _onGeometryChanged = value;
  }

  @override
  void attach(PipelineOwner owner) {
    _lastGlobalBounds = null;
    super.attach(owner);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final globalBounds = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & size,
    );
    if (_lastGlobalBounds != globalBounds) {
      _lastGlobalBounds = globalBounds;
      _onGeometryChanged();
    }
    super.paint(context, offset);
  }
}

class _ClearStageHolePainter extends CustomPainter {
  _ClearStageHolePainter(Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // Do not wrap this in saveLayer: the clear operation intentionally removes
    // the already-painted Flutter background from the upper premultiplied-alpha
    // surface. Later Stack children (buttons, dialogs, masks) paint above it.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..isAntiAlias = false
        ..blendMode = BlendMode.clear,
    );
  }

  @override
  bool shouldRepaint(covariant _ClearStageHolePainter oldDelegate) => false;
}

class _StagePreviewRepaintSignal extends ChangeNotifier {
  void pulse() => notifyListeners();
}
