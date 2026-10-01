import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/kirakara_show_ffi.dart';
import '../services/stage_texture_service.dart';

const _compositorChannel = MethodChannel('kirakara/dcomp_compositor');
const _showStatePlaying = 1;
const _showStatePaused = 2;
const _showStateStopped = 3;

Map<Object?, Object?> _map(Object? value, String label) {
  if (value is! Map<Object?, Object?>) {
    throw StateError('Missing compositor map: $label');
  }
  return value;
}

int _counter(Map<Object?, Object?> values, String key) {
  final value = values[key];
  if (value is! num) {
    throw StateError('Missing numeric compositor counter: $key');
  }
  return value.toInt();
}

Future<Map<String, Object?>> _readMap(String method,
    [Object? arguments]) async {
  final value = await _compositorChannel.invokeMapMethod<String, Object?>(
    method,
    arguments,
  );
  if (value == null) {
    throw StateError('Compositor method returned null: $method');
  }
  return value;
}

/// A bounded Phase 3 probe for the real Show -> NT handle -> keyed mutex ->
/// DirectComposition Stage path. It has no recurring timer or frame callback;
/// all samples are finite and the steady-state intervals leave Flutter idle.
class RealStageCompositorHarness extends StatefulWidget {
  const RealStageCompositorHarness({super.key});

  @override
  State<RealStageCompositorHarness> createState() =>
      _RealStageCompositorHarnessState();
}

class _RealStageCompositorHarnessState extends State<RealStageCompositorHarness>
    with WidgetsBindingObserver {
  final _previewKey = GlobalKey();
  final _stageController = StageTextureController();
  KirakaraShowFFI? _show;
  bool _probeRunning = false;
  bool _geometryScheduled = false;
  bool _overlayVisible = false;
  bool _pageVisible = false;
  bool _animatedOverlayVisible = false;
  bool _skipDisposeCleanup = false;
  String _fit = 'contain';
  String _status = '正在准备真实 Show Stage…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _runProbe());
  }

  @override
  void didChangeMetrics() {
    _scheduleGeometryReport();
  }

  String _fixture(String root, String name) {
    final path = '$root${Platform.pathSeparator}$name';
    if (!File(path).existsSync()) {
      throw StateError('Missing real Stage fixture: $path');
    }
    return path;
  }

  Future<void> _reportGeometry({bool visible = true}) async {
    final renderObject =
        _previewKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderObject == null || !renderObject.hasSize) {
      throw StateError('The real Stage preview slot has no layout.');
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final scale = View.of(context).devicePixelRatio;
    await _stageController.setComposedGeometry(
      physicalBounds: Rect.fromLTWH(
        topLeft.dx * scale,
        topLeft.dy * scale,
        renderObject.size.width * scale,
        renderObject.size.height * scale,
      ),
      visible: visible,
      fit: _fit,
    );
  }

  void _scheduleGeometryReport() {
    if (_geometryScheduled) return;
    _geometryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryScheduled = false;
      if (!mounted || !_stageController.isComposed) return;
      unawaited(_reportGeometry());
    });
  }

  List<Map<String, Object?>> _readEofMismatchCases(String root) {
    final manifestPath = _fixture(root, 'manifest.json');
    final decoded = jsonDecode(File(manifestPath).readAsStringSync());
    if (decoded is! Map) {
      throw StateError('EOF mismatch manifest is not a JSON object.');
    }
    final manifest = Map<String, Object?>.from(decoded);
    if (manifest['schemaVersion'] != 1 ||
        manifest['videoMasterClock'] != true) {
      throw StateError('EOF mismatch manifest contract is incompatible.');
    }
    final rawCases = manifest['cases'];
    if (rawCases is! List || rawCases.length != 2) {
      throw StateError('EOF mismatch manifest must contain exactly two cases.');
    }
    final cases = <Map<String, Object?>>[];
    final names = <String>{};
    for (final rawCase in rawCases) {
      if (rawCase is! Map) {
        throw StateError('EOF mismatch case is not a JSON object.');
      }
      final fixtureCase = Map<String, Object?>.from(rawCase);
      final name = fixtureCase['name'];
      if (name is! String || !names.add(name)) {
        throw StateError('EOF mismatch case has an invalid or duplicate name.');
      }
      for (final key in ['video', 'vocal', 'accompaniment']) {
        final fileName = fixtureCase[key];
        if (fileName is! String ||
            fileName.trim().isEmpty ||
            fileName.contains('/') ||
            fileName.contains(r'\')) {
          throw StateError('EOF mismatch case $name has no $key file.');
        }
        _fixture(root, fileName);
      }
      for (final key in [
        'videoDurationSeconds',
        'vocalDurationSeconds',
        'accompanimentDurationSeconds',
      ]) {
        final duration = fixtureCase[key];
        if (duration is! num ||
            !duration.toDouble().isFinite ||
            duration <= 0 ||
            duration > 20) {
          throw StateError('EOF mismatch case $name has invalid $key.');
        }
      }
      cases.add(fixtureCase);
    }
    if (!names.contains('audio-shorter-than-video') ||
        !names.contains('video-shorter-than-audio')) {
      throw StateError(
          'EOF mismatch manifest does not contain both directions.');
    }
    final audioShort = cases.singleWhere(
      (fixtureCase) => fixtureCase['name'] == 'audio-shorter-than-video',
    );
    final videoShort = cases.singleWhere(
      (fixtureCase) => fixtureCase['name'] == 'video-shorter-than-audio',
    );
    final audioShortLatestEof = [
      (audioShort['vocalDurationSeconds'] as num).toDouble(),
      (audioShort['accompanimentDurationSeconds'] as num).toDouble(),
    ].reduce((left, right) => left > right ? left : right);
    final videoShortEarliestAudioEof = [
      (videoShort['vocalDurationSeconds'] as num).toDouble(),
      (videoShort['accompanimentDurationSeconds'] as num).toDouble(),
    ].reduce((left, right) => left < right ? left : right);
    if ((audioShort['videoDurationSeconds'] as num).toDouble() -
                audioShortLatestEof <
            0.75 ||
        videoShortEarliestAudioEof -
                (videoShort['videoDurationSeconds'] as num).toDouble() <
            0.75) {
      throw StateError(
          'EOF mismatch fixture durations do not actually differ.');
    }
    return cases;
  }

  Future<Map<String, Object?>> _runEofMismatchCase(
    KirakaraShowFFI show,
    String mismatchRoot,
    String lyricPath,
    Map<String, Object?> fixtureCase,
  ) async {
    final name = fixtureCase['name']! as String;
    final videoDuration =
        (fixtureCase['videoDurationSeconds']! as num).toDouble();
    final vocalDuration =
        (fixtureCase['vocalDurationSeconds']! as num).toDouble();
    final accompanimentDuration =
        (fixtureCase['accompanimentDurationSeconds']! as num).toDouble();
    final latestAudioEof = vocalDuration > accompanimentDuration
        ? vocalDuration
        : accompanimentDuration;
    show.stop();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final before = await _readMap('getStageDiagnostics');
    final loaded = show.load(
      _fixture(mismatchRoot, fixtureCase['video']! as String),
      lyricPath: lyricPath,
      vocalPath: _fixture(mismatchRoot, fixtureCase['vocal']! as String),
      accompanimentPath:
          _fixture(mismatchRoot, fixtureCase['accompaniment']! as String),
      videoMasterClock: true,
    );
    if (!loaded) {
      throw StateError('Show rejected EOF mismatch case $name.');
    }
    show.setVolume(0);
    show.play();
    await Future<void>.delayed(const Duration(milliseconds: 750));
    final warm = await _readMap('getStageDiagnostics');
    final observedDuration = show.duration;
    final warmPosition = show.position;
    final warmState = show.state;
    if (!observedDuration.isFinite ||
        observedDuration <= 0 ||
        observedDuration > 20) {
      throw StateError(
          'Show reported an invalid duration for EOF mismatch case $name.');
    }

    Map<String, Object?>? afterAudioEof;
    double? afterAudioEofPosition;
    int? afterAudioEofState;
    bool? afterAudioEofBuffering;
    if (latestAudioEof < videoDuration) {
      final waitSeconds =
          (latestAudioEof + 0.35 - warmPosition).clamp(0.0, 20.0);
      await Future<void>.delayed(
        Duration(milliseconds: (waitSeconds * 1000).ceil()),
      );
      afterAudioEof = await _readMap('getStageDiagnostics');
      afterAudioEofPosition = show.position;
      afterAudioEofState = show.state;
      afterAudioEofBuffering = show.isBuffering;
    }

    final remainingSeconds =
        (observedDuration - show.position).clamp(0.0, 20.0) + 0.75;
    final eofWaitMilliseconds = (remainingSeconds * 1000).ceil();
    await Future<void>.delayed(
      Duration(milliseconds: eofWaitMilliseconds),
    );
    final after = await _readMap('getStageDiagnostics');
    return <String, Object?>{
      'name': name,
      'videoDurationSeconds': videoDuration,
      'vocalDurationSeconds': vocalDuration,
      'accompanimentDurationSeconds': accompanimentDuration,
      'observedDurationSeconds': observedDuration,
      'warmPositionSeconds': warmPosition,
      'warmState': warmState,
      'eofWaitMilliseconds': eofWaitMilliseconds,
      'before': before,
      'warm': warm,
      if (afterAudioEof != null) 'afterAudioEof': afterAudioEof,
      if (afterAudioEofPosition != null)
        'afterAudioEofPositionSeconds': afterAudioEofPosition,
      if (afterAudioEofState != null) 'afterAudioEofState': afterAudioEofState,
      if (afterAudioEofBuffering != null)
        'afterAudioEofBuffering': afterAudioEofBuffering,
      'after': after,
      'finalPositionSeconds': show.position,
      'finalDurationSeconds': show.duration,
      'finalState': show.state,
      'finalBuffering': show.isBuffering,
    };
  }

  Future<void> _loadFixture(
    KirakaraShowFFI show,
    String root,
    int index, {
    String? lyricPath,
    bool seamlessTransition = false,
  }) async {
    final loaded = show.load(
      _fixture(root, 'v$index.mp4'),
      lyricPath: lyricPath ?? _fixture(root, 'l$index.krl'),
      vocalPath: _fixture(root, 'vocal$index.wav'),
      accompanimentPath: _fixture(root, 'inst$index.wav'),
      videoMasterClock: true,
      seamlessTransition: seamlessTransition,
    );
    if (!loaded) {
      throw StateError('Show rejected fixture $index.');
    }
    show.setVolume(0);
    show.play();
  }

  Future<void> _runProbe() async {
    if (_probeRunning) return;
    _probeRunning = true;
    Map<String, Object?> report;
    try {
      final fixtureRoot =
          Platform.environment['KIRAKARA_COMPOSITOR_FIXTURE_ROOT'];
      if (fixtureRoot == null || fixtureRoot.trim().isEmpty) {
        throw StateError('KIRAKARA_COMPOSITOR_FIXTURE_ROOT is not set.');
      }
      final titleLyricPath =
          Platform.environment['KIRAKARA_COMPOSITOR_TITLE_KRL'];
      if (titleLyricPath == null ||
          titleLyricPath.trim().isEmpty ||
          !File(titleLyricPath).existsSync()) {
        throw StateError(
            'KIRAKARA_COMPOSITOR_TITLE_KRL does not name a fixture.');
      }
      final titleFixtureText = File(titleLyricPath).readAsStringSync();
      if (!titleFixtureText.contains('"songTitle"') ||
          !titleFixtureText.contains('"enabled": true')) {
        throw StateError('The title fixture does not enable songTitle.');
      }
      final lifecycleProbe =
          Platform.environment['KIRAKARA_COMPOSITOR_LIFECYCLE_PROBE'] == '1';
      final eofMismatchRootValue =
          Platform.environment['KIRAKARA_COMPOSITOR_EOF_MISMATCH_ROOT'];
      final eofMismatchRoot =
          eofMismatchRootValue == null || eofMismatchRootValue.trim().isEmpty
              ? null
              : eofMismatchRootValue.trim();
      final eofMismatchCases = eofMismatchRoot == null
          ? <Map<String, Object?>>[]
          : _readEofMismatchCases(eofMismatchRoot);
      var show = KirakaraShowFFI();
      _show = show;
      final attachment =
          await _stageController.attach(show.nativeHandleAddress);
      if (attachment == null || !attachment.isComposed) {
        throw StateError(
            'The real Stage probe did not attach composed output.');
      }
      await _reportGeometry();
      await _stageController.setActive(true);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final idleBeforeFirstSong = await _readMap('getStageDiagnostics');
      await _loadFixture(show, fixtureRoot, 1);
      if (mounted) {
        setState(() => _status = '真实 Stage 已连接，正在执行运行门禁…');
      }

      await Future<void>.delayed(const Duration(milliseconds: 1250));
      // The Win32 runner calls ShowWindow only after Flutter's first frame.
      // Read HWND visibility after the real Stage warm-up rather than racing
      // that one-time startup transition from the first post-frame callback.
      final backend = await _readMap('getBackendInfo');
      final staticBefore = await _readMap('getStageDiagnostics');
      final staticWatch = Stopwatch()..start();
      await Future<void>.delayed(const Duration(seconds: 2));
      final staticAfter = await _readMap('getStageDiagnostics');
      staticWatch.stop();
      final staticBeforeEngine = _map(staticBefore['engine'], 'static engine');
      final staticAfterEngine = _map(staticAfter['engine'], 'static engine');
      final staticStageDelta =
          _counter(staticAfterEngine, 'stagePresentCount') -
              _counter(staticBeforeEngine, 'stagePresentCount');
      final staticSubmitDelta =
          _counter(staticAfterEngine, 'stageFrameSubmitCount') -
              _counter(staticBeforeEngine, 'stageFrameSubmitCount');
      final staticFlutterDelta =
          _counter(staticAfterEngine, 'flutterPresentCount') -
              _counter(staticBeforeEngine, 'flutterPresentCount');

      final stall = await _readMap('stallPlatformThreadForTest', 750);

      final resizeBefore = await _readMap('getStageDiagnostics');
      final resizeBeforeEngine = _map(resizeBefore['engine'], 'resize engine');
      await _compositorChannel.invokeMethod<void>(
        'resizeWindowByForTest',
        const <String, int>{'widthDelta': -160, 'heightDelta': -90},
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      final resizeContracted = await _readMap('getStageDiagnostics');
      await _compositorChannel.invokeMethod<void>(
        'resizeWindowByForTest',
        const <String, int>{'widthDelta': 160, 'heightDelta': 90},
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      final resizeAfter = await _readMap('getStageDiagnostics');
      final resizeAfterEngine = _map(resizeAfter['engine'], 'resize engine');

      final geometryBefore = await _readMap('getStageDiagnostics');
      final geometryBeforeEngine =
          _map(geometryBefore['engine'], 'geometry engine');
      if (mounted) setState(() => _fit = 'cover');
      await WidgetsBinding.instance.endOfFrame;
      await _reportGeometry();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (mounted) setState(() => _fit = 'contain');
      await WidgetsBinding.instance.endOfFrame;
      await _reportGeometry();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final geometryAfter = await _readMap('getStageDiagnostics');
      final geometryAfterEngine =
          _map(geometryAfter['engine'], 'geometry engine');

      final overlayBefore = await _readMap('getStageDiagnostics');
      if (mounted) setState(() => _overlayVisible = true);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final overlayVisible = await _readMap('getStageDiagnostics');
      if (mounted) setState(() => _overlayVisible = false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final overlayAfter = await _readMap('getStageDiagnostics');

      final pageBefore = await _readMap('getStageDiagnostics');
      if (mounted) setState(() => _pageVisible = true);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final pageVisible = await _readMap('getStageDiagnostics');
      if (mounted) setState(() => _pageVisible = false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final pageAfter = await _readMap('getStageDiagnostics');

      final visibilityBefore = await _readMap('getStageDiagnostics');
      await _reportGeometry(visible: false);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final visibilityHiddenSettled = await _readMap('getStageDiagnostics');
      await Future<void>.delayed(const Duration(milliseconds: 750));
      final visibilityHiddenAfter = await _readMap('getStageDiagnostics');
      await _reportGeometry();
      await Future<void>.delayed(const Duration(milliseconds: 750));
      final visibilityRestored = await _readMap('getStageDiagnostics');

      final animationBefore = await _readMap('getStageDiagnostics');
      if (mounted) setState(() => _animatedOverlayVisible = true);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) setState(() => _animatedOverlayVisible = false);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final animationAfter = await _readMap('getStageDiagnostics');

      final pauseBefore = await _readMap('getStageDiagnostics');
      final pauseRequestedPosition = show.position;
      show.pause();
      // Show transport commands are delivered through its private Win32
      // message queue. Give that queue a bounded settling interval before
      // judging clock stability; do not poll it from Flutter.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final pauseSettledPosition = show.position;
      final pauseSettledState = show.state;
      final pauseSettled = await _readMap('getStageDiagnostics');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final pauseHeldPosition = show.position;
      final pauseHeldState = show.state;
      final pauseHeld = await _readMap('getStageDiagnostics');
      show.play();
      await Future<void>.delayed(const Duration(milliseconds: 750));
      final resumePosition = show.position;
      final resumeState = show.state;
      final pauseAfter = await _readMap('getStageDiagnostics');

      final switchBefore = await _readMap('getStageDiagnostics');
      show.stop();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _loadFixture(
        show,
        fixtureRoot,
        2,
        lyricPath: titleLyricPath,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1250));
      final switchAfter = await _readMap('getStageDiagnostics');
      final titledDuration = show.duration;
      final titledPosition = show.position;
      final titledState = show.state;

      final replayBefore = await _readMap('getStageDiagnostics');
      final replayBeforePosition = show.position;
      final nativeReplaySupported = show.replay();
      if (!nativeReplaySupported) {
        // The current Show ABI predates the optional replay export. This is
        // the same transport fallback used by the App: seek to zero and play.
        show.seek(0);
        show.play();
      }
      await Future<void>.delayed(const Duration(milliseconds: 750));
      final replayAfterPosition = show.position;
      final replayAfterState = show.state;
      final replayAfter = await _readMap('getStageDiagnostics');

      if (!(titledDuration > 0) || !titledDuration.isFinite) {
        throw StateError(
            'Show did not expose a finite duration for the titled fixture.');
      }
      final naturalNextPrepared = show.prepareNext(
        _fixture(fixtureRoot, 'v1.mp4'),
        lyricPath: _fixture(fixtureRoot, 'l1.krl'),
        vocalPath: _fixture(fixtureRoot, 'vocal1.wav'),
        accompanimentPath: _fixture(fixtureRoot, 'inst1.wav'),
        videoMasterClock: true,
      );
      if (!naturalNextPrepared) {
        throw StateError('Show rejected the prepared natural-next fixture.');
      }
      final eofWaitMilliseconds =
          (((titledDuration - replayAfterPosition).clamp(0.0, 20.0) + 0.75) *
                  1000)
              .ceil();
      final eofBefore = await _readMap('getStageDiagnostics');
      // One finite wait, derived from the media duration, exercises natural
      // EOF without adding a production timer or a high-frequency poller.
      await Future<void>.delayed(Duration(milliseconds: eofWaitMilliseconds));
      final eofPosition = show.position;
      final eofDuration = show.duration;
      final eofState = show.state;
      final eofBuffering = show.isBuffering;
      final eofAfter = await _readMap('getStageDiagnostics');

      final reloadBefore = eofAfter;
      await _loadFixture(
        show,
        fixtureRoot,
        1,
        seamlessTransition: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1250));
      final reloadPosition = show.position;
      final reloadState = show.state;
      final reloadAfter = await _readMap('getStageDiagnostics');

      final detachBefore = await _readMap('getStageDiagnostics');
      await _stageController.setActive(false);
      await _stageController.detach();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final detached = await _readMap('getStageDiagnostics');
      final reattached =
          await _stageController.attach(show.nativeHandleAddress);
      if (reattached == null || !reattached.isComposed) {
        throw StateError('The real Stage source did not reattach.');
      }
      await _reportGeometry();
      await _stageController.setActive(true);
      await Future<void>.delayed(const Duration(seconds: 1));
      final detachAfter = await _readMap('getStageDiagnostics');

      Map<Object?, Object?> engine(Map<String, Object?> sample) =>
          _map(sample['engine'], 'engine');
      int engineDelta(
        Map<String, Object?> before,
        Map<String, Object?> after,
        String counter,
      ) =>
          _counter(engine(after), counter) - _counter(engine(before), counter);
      int showDelta(
        Map<String, Object?> before,
        Map<String, Object?> after,
        String counter,
      ) =>
          _counter(_map(after['show'], 'after Show diagnostics'), counter) -
          _counter(_map(before['show'], 'before Show diagnostics'), counter);

      final lifecycleSamples = <String, Object?>{};
      final lifecycleGates = <String, bool>{};
      if (lifecycleProbe) {
        final lifecycleWindow = _counter(backend, 'topLevelWindow');

        final minimizeBefore = await _readMap('getStageDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'setWindowShowStateForTest',
          <String, Object?>{'state': 'minimized'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final minimizedBackend = await _readMap('getBackendInfo');
        final minimized = await _readMap('getStageDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'setWindowShowStateForTest',
          <String, Object?>{'state': 'restored'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 1250));
        await _reportGeometry();
        final restoredBackend = await _readMap('getBackendInfo');
        final restored = await _readMap('getStageDiagnostics');

        await _compositorChannel.invokeMethod<void>(
          'setWindowShowStateForTest',
          <String, Object?>{'state': 'maximized'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await _reportGeometry();
        final maximizedBackend = await _readMap('getBackendInfo');
        final maximized = await _readMap('getStageDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'setWindowShowStateForTest',
          <String, Object?>{'state': 'restored'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 1250));
        await _reportGeometry();
        final finalWindowBackend = await _readMap('getBackendInfo');
        final finalWindowState = await _readMap('getStageDiagnostics');

        // These bounded, test-only messages validate the same Win32 routing
        // and preview state machine used by real session/power notifications.
        // They do not claim that this workstation actually locked or slept;
        // those remain explicit manual hardware gates.
        final sessionBefore = await _readMap('getStageDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'postLifecycleSignalForTest',
          <String, Object?>{'signal': 'sessionLock'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final sessionLocked = await _readMap('getStageDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'postLifecycleSignalForTest',
          <String, Object?>{'signal': 'sessionUnlock'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final sessionUnlocked = await _readMap('getStageDiagnostics');

        final powerBefore = await _readMap('getStageDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'postLifecycleSignalForTest',
          <String, Object?>{'signal': 'powerSuspend'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final powerSuspended = await _readMap('getStageDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'postLifecycleSignalForTest',
          <String, Object?>{'signal': 'powerResume'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final powerResumed = await _readMap('getStageDiagnostics');

        final displayChangeBefore = await _readMap('getStageDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'postLifecycleSignalForTest',
          <String, Object?>{'signal': 'displayChange'},
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final displayChangeAfter = await _readMap('getStageDiagnostics');

        final rapidNavigationBefore = await _readMap('getStageDiagnostics');
        for (var index = 0; index < 6; index++) {
          if (mounted) setState(() => _pageVisible = true);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (mounted) setState(() => _pageVisible = false);
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        final rapidNavigationAfter = await _readMap('getStageDiagnostics');

        final rebuildBefore = await _readMap('getStageDiagnostics');
        final oldShowHandle = show.nativeHandleAddress;
        await _stageController.setActive(false);
        await _stageController.detach();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final rebuildDetached = await _readMap('getStageDiagnostics');
        show.stop();
        show.dispose();
        _show = null;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final afterShowDestroy = await _readMap('getStageDiagnostics');

        show = KirakaraShowFFI();
        _show = show;
        final newShowHandle = show.nativeHandleAddress;
        final rebuiltAttachment = await _stageController.attach(newShowHandle);
        if (rebuiltAttachment == null || !rebuiltAttachment.isComposed) {
          throw StateError('The rebuilt Show source did not attach.');
        }
        await _reportGeometry();
        await _stageController.setActive(true);
        await _loadFixture(show, fixtureRoot, 2);
        await Future<void>.delayed(const Duration(milliseconds: 1250));
        final rebuildAfter = await _readMap('getStageDiagnostics');

        lifecycleGates.addAll(<String, bool>{
          'minimizeObserved': minimizedBackend['windowIsMinimized'] == true,
          'stageSuspendedWhileMinimized': minimized['active'] == false &&
              minimized['requestedActive'] == true &&
              minimized['windowAvailable'] == false &&
              engineDelta(
                    minimizeBefore,
                    minimized,
                    'stagePresentCount',
                  ) <=
                  3 &&
              showDelta(minimizeBefore, minimized, 'publishedFrames') <= 3,
          'restoreObserved': restoredBackend['windowIsMinimized'] == false &&
              restoredBackend['windowIsVisible'] == true &&
              restored['active'] == true &&
              restored['requestedActive'] == true &&
              restored['windowAvailable'] == true &&
              _counter(restored, 'lastActivityTransitionResult') == 0,
          'stageRecoveredAfterRestore':
              engineDelta(minimized, restored, 'stagePresentCount') >= 20,
          'maximizeObserved': maximizedBackend['windowIsMaximized'] == true,
          'maximizedStageContinued':
              engineDelta(restored, maximized, 'stagePresentCount') >= 20,
          'finalRestoreObserved':
              finalWindowBackend['windowIsMinimized'] == false &&
                  finalWindowBackend['windowIsMaximized'] == false &&
                  finalWindowBackend['windowIsVisible'] == true,
          'windowIdentityPreserved': <Map<String, Object?>>[
            minimizedBackend,
            restoredBackend,
            maximizedBackend,
            finalWindowBackend,
          ].every(
            (sample) => _counter(sample, 'topLevelWindow') == lifecycleWindow,
          ),
          'stageRecoveredAfterFinalRestore': engineDelta(
                maximized,
                finalWindowState,
                'stagePresentCount',
              ) >=
              20,
          'sessionSignalSuspendedPreview': sessionLocked['active'] == false &&
              sessionLocked['requestedActive'] == true &&
              sessionLocked['windowAvailable'] == false &&
              engineDelta(
                    sessionBefore,
                    sessionLocked,
                    'stagePresentCount',
                  ) <=
                  3 &&
              showDelta(sessionBefore, sessionLocked, 'publishedFrames') <= 3,
          'sessionSignalRecoveredPreview': sessionUnlocked['active'] == true &&
              sessionUnlocked['windowAvailable'] == true &&
              engineDelta(
                    sessionLocked,
                    sessionUnlocked,
                    'stagePresentCount',
                  ) >=
                  20,
          'powerSignalSuspendedPreview': powerSuspended['active'] == false &&
              powerSuspended['requestedActive'] == true &&
              powerSuspended['windowAvailable'] == false &&
              engineDelta(
                    powerBefore,
                    powerSuspended,
                    'stagePresentCount',
                  ) <=
                  3 &&
              showDelta(powerBefore, powerSuspended, 'publishedFrames') <= 3,
          'powerSignalRecoveredPreview': powerResumed['active'] == true &&
              powerResumed['windowAvailable'] == true &&
              engineDelta(
                    powerSuspended,
                    powerResumed,
                    'stagePresentCount',
                  ) >=
                  20,
          'displayChangeSignalKeptStageAlive':
              displayChangeAfter['active'] == true &&
                  engineDelta(
                        displayChangeBefore,
                        displayChangeAfter,
                        'stagePresentCount',
                      ) >=
                      15,
          'rapidNavigationDidNotStopStage': engineDelta(
                rapidNavigationBefore,
                rapidNavigationAfter,
                'stagePresentCount',
              ) >=
              30,
          'rebuildDetachedOldSource': rebuildDetached['attached'] == false &&
              rebuildDetached['active'] == false &&
              afterShowDestroy['attached'] == false,
          'rebuiltShowAttached': rebuildAfter['attached'] == true &&
              rebuildAfter['active'] == true,
          'rebuiltShowProducedFrames': _counter(
                      _map(rebuildAfter['show'], 'rebuilt Show diagnostics'),
                      'publishedFrames') >=
                  45 &&
              engineDelta(
                    afterShowDestroy,
                    rebuildAfter,
                    'stagePresentCount',
                  ) >=
                  45,
        });
        lifecycleSamples.addAll(<String, Object?>{
          'window': <String, Object?>{
            'before': minimizeBefore,
            'minimizedBackend': minimizedBackend,
            'minimized': minimized,
            'restoredBackend': restoredBackend,
            'restored': restored,
            'maximizedBackend': maximizedBackend,
            'maximized': maximized,
            'finalBackend': finalWindowBackend,
            'final': finalWindowState,
          },
          'rapidNavigation': <String, Object?>{
            'before': rapidNavigationBefore,
            'after': rapidNavigationAfter,
          },
          'syntheticLifecycleSignals': <String, Object?>{
            'realOperatingSystemTransition': false,
            'session': <String, Object?>{
              'before': sessionBefore,
              'locked': sessionLocked,
              'unlocked': sessionUnlocked,
            },
            'power': <String, Object?>{
              'before': powerBefore,
              'suspended': powerSuspended,
              'resumed': powerResumed,
            },
            'displayChange': <String, Object?>{
              'before': displayChangeBefore,
              'after': displayChangeAfter,
            },
          },
          'showRebuild': <String, Object?>{
            'oldHandle': oldShowHandle,
            'newHandle': newShowHandle,
            'before': rebuildBefore,
            'detached': rebuildDetached,
            'afterDestroy': afterShowDestroy,
            'after': rebuildAfter,
          },
        });
      }

      Map<String, Object?>? audioShorterThanVideo;
      Map<String, Object?>? videoShorterThanAudio;
      Map<String, Object?>? eofMismatchRecoveryBefore;
      Map<String, Object?>? eofMismatchRecoveryAfter;
      double? eofMismatchRecoveryPosition;
      int? eofMismatchRecoveryState;
      if (eofMismatchCases.isNotEmpty) {
        final lyricPath = _fixture(fixtureRoot, 'l1.krl');
        audioShorterThanVideo = await _runEofMismatchCase(
          show,
          eofMismatchRoot!,
          lyricPath,
          eofMismatchCases.singleWhere(
            (fixtureCase) => fixtureCase['name'] == 'audio-shorter-than-video',
          ),
        );
        videoShorterThanAudio = await _runEofMismatchCase(
          show,
          eofMismatchRoot,
          lyricPath,
          eofMismatchCases.singleWhere(
            (fixtureCase) => fixtureCase['name'] == 'video-shorter-than-audio',
          ),
        );
        show.stop();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        eofMismatchRecoveryBefore = await _readMap('getStageDiagnostics');
        await _loadFixture(show, fixtureRoot, 1);
        await Future<void>.delayed(const Duration(milliseconds: 1250));
        eofMismatchRecoveryPosition = show.position;
        eofMismatchRecoveryState = show.state;
        eofMismatchRecoveryAfter = await _readMap('getStageDiagnostics');
      }

      await Future<void>.delayed(const Duration(milliseconds: 750));
      final settledBefore = await _readMap('getStageDiagnostics');
      await Future<void>.delayed(const Duration(seconds: 2));
      final settledAfter = await _readMap('getStageDiagnostics');

      final staticShow = _map(staticAfter['show'], 'Show diagnostics');
      final switchBeforeShow = _map(switchBefore['show'], 'Show diagnostics');
      final switchAfterShow = _map(switchAfter['show'], 'Show diagnostics');
      final finalEngine = engine(settledAfter);
      final finalShow = _map(settledAfter['show'], 'Show diagnostics');
      final idleEngine = engine(idleBeforeFirstSong);
      final gates = <String, bool>{
        'backendMetadataMatches': backend['backend'] == 'composed' &&
            backend['backendSelection'] == 'custom-engine-default' &&
            backend['abiVersion'] == 2 &&
            backend['patchsetVersion'] == 5 &&
            backend['patchsetRevision'] == 'windows-dcomp-stage-visual',
        'idleBeforeFirstSongPresentedBlackPlaceholder':
            _counter(idleEngine, 'stagePresentCount') >= 1 &&
                _counter(idleEngine, 'stageFrameSubmitCount') == 0 &&
                _counter(idleEngine, 'stageResourceGeneration') == 0 &&
                _counter(idleEngine, 'stageFrameId') == 0 &&
                idleEngine['lastStagePresentHresult'] == 0 &&
                idleEngine['lastStageResourceHresult'] == 0,
        'singleVisibleTopLevelWindow':
            backend['visibleInteractiveTopLevelWindowCount'] == 1 &&
                _counter(backend, 'visibleTopLevelWindowCount') >= 1 &&
                _counter(backend, 'topLevelWindow') != 0,
        'windowDpiAwarenessDisabled':
            backend['windowIsPerMonitorV2'] == false &&
                _counter(backend, 'windowDpiAwareness') == 0 &&
                _counter(backend, 'windowDpi') == 96,
        'sessionNotificationsRegistered':
            backend['sessionNotificationsRegistered'] == true,
        'stageAttachedAndActive':
            staticAfter['attached'] == true && staticAfter['active'] == true,
        'stageMadeProgressWhileFlutterStatic': staticStageDelta >= 45,
        'showSubmittedFramesWhileFlutterStatic': staticSubmitDelta >= 45,
        'staticFlutterDidNotRepump': staticFlutterDelta <= 3,
        'stageContinuedDuringPlatformStall':
            _counter(stall, 'stagePresentDelta') >= 15,
        'platformStallDidNotPresentFlutter':
            _counter(stall, 'flutterPresentDelta') <= 1,
        'resizeUsedSameTopLevelWindow':
            _counter(resizeBeforeEngine, 'topLevelWindow') ==
                _counter(resizeAfterEngine, 'topLevelWindow'),
        'resizeUpdatedBothSurfaces':
            _counter(resizeAfterEngine, 'surfaceResizeCount') -
                        _counter(resizeBeforeEngine, 'surfaceResizeCount') >=
                    2 &&
                engineDelta(
                      resizeBefore,
                      resizeAfter,
                      'stagePresentCount',
                    ) >=
                    20,
        'fitAndClipUpdatedGeometry': _counter(
                    geometryAfterEngine, 'stageGeometryUpdateCount') -
                _counter(geometryBeforeEngine, 'stageGeometryUpdateCount') >=
            2,
        'stageContinuedUnderOverlay':
            engineDelta(overlayBefore, overlayVisible, 'stagePresentCount') >=
                15,
        'stageContinuedUnderOpaquePage':
            engineDelta(pageBefore, pageVisible, 'stagePresentCount') >= 15,
        'hiddenGeometryStoppedPreviewWork':
            visibilityHiddenSettled['requestedActive'] == true &&
                visibilityHiddenSettled['active'] == false &&
                visibilityHiddenSettled['geometryVisible'] == false &&
                engineDelta(
                      visibilityHiddenSettled,
                      visibilityHiddenAfter,
                      'stagePresentCount',
                    ) <=
                    1 &&
                showDelta(
                      visibilityHiddenSettled,
                      visibilityHiddenAfter,
                      'publishedFrames',
                    ) <=
                    1,
        'visibleGeometryResumedPreview':
            visibilityRestored['requestedActive'] == true &&
                visibilityRestored['active'] == true &&
                visibilityRestored['geometryVisible'] == true &&
                engineDelta(
                      visibilityHiddenAfter,
                      visibilityRestored,
                      'stagePresentCount',
                    ) >=
                    30,
        'stageContinuedDuringFlutterAnimation': engineDelta(
              animationBefore,
              animationAfter,
              'stagePresentCount',
            ) >=
            45,
        'flutterAnimationActuallyPresented': engineDelta(
              animationBefore,
              animationAfter,
              'flutterPresentCount',
            ) >=
            10,
        'pauseSettledAndHeld': pauseSettledState == _showStatePaused &&
            pauseHeldState == _showStatePaused &&
            (pauseHeldPosition - pauseSettledPosition).abs() <= 0.08,
        'pausedStaticStageStoppedPresenting': engineDelta(
                  pauseSettled,
                  pauseHeld,
                  'stagePresentCount',
                ) <=
                2 &&
            showDelta(pauseSettled, pauseHeld, 'publishedFrames') <= 2,
        'resumeAdvancedClock': resumeState == _showStatePlaying &&
            resumePosition >= pauseHeldPosition + 0.35,
        'contentGenerationAdvanced':
            _counter(switchAfterShow, 'contentGeneration') >
                _counter(switchBeforeShow, 'contentGeneration'),
        'untitledThenTitledProgramsLoaded': titledState == _showStatePlaying &&
            titledDuration > 0 &&
            titledPosition >= 0.5,
        'stageContinuedAfterSongSwitch':
            engineDelta(switchBefore, switchAfter, 'stagePresentCount') >= 20,
        'replayReturnedToProgramStart': replayBeforePosition >= 1.0 &&
            replayAfterState == _showStatePlaying &&
            replayAfterPosition <= 1.25 &&
            replayAfterPosition <= replayBeforePosition - 0.2,
        'naturalEofStoppedCleanly': eofState == _showStateStopped &&
            !eofBuffering &&
            eofDuration > 0 &&
            eofPosition >= eofDuration - 0.75,
        'reloadAfterNaturalEofResumed': naturalNextPrepared &&
            reloadState == _showStatePlaying &&
            reloadPosition >= 0.5 &&
            _counter(
                  _map(reloadAfter['show'], 'Show diagnostics'),
                  'contentGeneration',
                ) >
                _counter(
                  _map(reloadBefore['show'], 'Show diagnostics'),
                  'contentGeneration',
                ) &&
            engineDelta(reloadBefore, reloadAfter, 'stagePresentCount') >= 20,
        'detachWasVisibleInDiagnostics':
            detached['attached'] == false && detached['active'] == false,
        'reattachResumedStage': detachAfter['attached'] == true &&
            detachAfter['active'] == true &&
            engineDelta(detachBefore, detachAfter, 'stagePresentCount') >= 15,
        'flutterReturnedToQuiescence':
            engineDelta(settledBefore, settledAfter, 'flutterPresentCount') <=
                3,
        'stageContinuedAfterInteractions':
            engineDelta(settledBefore, settledAfter, 'stagePresentCount') >= 45,
        'showReportedFrames': _counter(staticShow, 'publishedFrames') >= 45 &&
            (lifecycleProbe
                ? _counter(finalShow, 'publishedFrames') >= 45
                : _counter(finalShow, 'publishedFrames') >=
                    _counter(staticShow, 'publishedFrames')),
        'noRejectedCallbacks':
            _counter(settledAfter, 'callbackRejectedCount') == 0,
        'noHandleDuplicationFailures':
            _counter(finalEngine, 'stageHandleDuplicateFailureCount') == 0,
        'noResourceOpenFailures':
            _counter(finalEngine, 'stageResourceOpenFailureCount') == 0 &&
                _counter(finalEngine, 'lastStageResourceHresult') == 0,
        'noStaleDescriptors':
            _counter(finalEngine, 'stageFrameStaleCount') == 0,
        'noDeviceRemoval':
            _counter(finalEngine, 'stageDeviceRemovedCount') == 0,
        'showLastOperationSucceeded': _counter(finalShow, 'lastHresult') == 0,
      };
      if (audioShorterThanVideo != null &&
          videoShorterThanAudio != null &&
          eofMismatchRecoveryBefore != null &&
          eofMismatchRecoveryAfter != null) {
        final audioWarm = Map<String, Object?>.from(
          _map(audioShorterThanVideo['warm'], 'audio-short warm sample'),
        );
        final audioAfterEof = Map<String, Object?>.from(
          _map(
            audioShorterThanVideo['afterAudioEof'],
            'audio-short post-audio-EOF sample',
          ),
        );
        final audioVideoDuration =
            (audioShorterThanVideo['videoDurationSeconds']! as num).toDouble();
        final audioVocalDuration =
            (audioShorterThanVideo['vocalDurationSeconds']! as num).toDouble();
        final audioAccompanimentDuration =
            (audioShorterThanVideo['accompanimentDurationSeconds']! as num)
                .toDouble();
        final audioLatestEof = audioVocalDuration > audioAccompanimentDuration
            ? audioVocalDuration
            : audioAccompanimentDuration;
        final audioObservedDuration =
            (audioShorterThanVideo['observedDurationSeconds']! as num)
                .toDouble();
        final videoDuration =
            (videoShorterThanAudio['videoDurationSeconds']! as num).toDouble();
        final videoVocalDuration =
            (videoShorterThanAudio['vocalDurationSeconds']! as num).toDouble();
        final videoAccompanimentDuration =
            (videoShorterThanAudio['accompanimentDurationSeconds']! as num)
                .toDouble();
        final videoEarliestAudioEof =
            videoVocalDuration < videoAccompanimentDuration
                ? videoVocalDuration
                : videoAccompanimentDuration;
        final videoObservedDuration =
            (videoShorterThanAudio['observedDurationSeconds']! as num)
                .toDouble();
        gates.addAll(<String, bool>{
          'audioEofDidNotEndVideoMasterProgram':
              audioVideoDuration - audioLatestEof >= 0.75 &&
                  (audioObservedDuration - audioVideoDuration).abs() <= 0.35 &&
                  audioShorterThanVideo['warmState'] == _showStatePlaying &&
                  audioShorterThanVideo['afterAudioEofState'] ==
                      _showStatePlaying &&
                  audioShorterThanVideo['afterAudioEofBuffering'] == false &&
                  (audioShorterThanVideo['afterAudioEofPositionSeconds']!
                              as num)
                          .toDouble() >=
                      audioLatestEof + 0.1 &&
                  engineDelta(
                        audioWarm,
                        audioAfterEof,
                        'stagePresentCount',
                      ) >=
                      15 &&
                  audioShorterThanVideo['finalState'] == _showStateStopped &&
                  audioShorterThanVideo['finalBuffering'] == false &&
                  (audioShorterThanVideo['finalPositionSeconds']! as num)
                          .toDouble() >=
                      audioObservedDuration - 0.75,
          'videoEofEndedProgramWithLongerAudio':
              videoEarliestAudioEof - videoDuration >= 0.75 &&
                  (videoObservedDuration - videoDuration).abs() <= 0.35 &&
                  videoShorterThanAudio['warmState'] == _showStatePlaying &&
                  videoShorterThanAudio['finalState'] == _showStateStopped &&
                  videoShorterThanAudio['finalBuffering'] == false &&
                  (videoShorterThanAudio['finalPositionSeconds']! as num)
                          .toDouble() >=
                      videoObservedDuration - 0.75,
          'normalProgramRecoveredAfterEofMismatch':
              eofMismatchRecoveryState == _showStatePlaying &&
                  eofMismatchRecoveryPosition != null &&
                  eofMismatchRecoveryPosition >= 0.5 &&
                  engineDelta(
                        eofMismatchRecoveryBefore,
                        eofMismatchRecoveryAfter,
                        'stagePresentCount',
                      ) >=
                      20,
        });
      }
      for (final entry in lifecycleGates.entries) {
        gates['lifecycle.${entry.key}'] = entry.value;
      }
      report = <String, Object?>{
        'schemaVersion': 1,
        'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'backend': backend,
        'idleBeforeFirstSong': idleBeforeFirstSong,
        'staticSample': <String, Object?>{
          'durationMilliseconds': staticWatch.elapsedMilliseconds,
          'before': staticBefore,
          'after': staticAfter,
          'stagePresentDelta': staticStageDelta,
          'stageFrameSubmitDelta': staticSubmitDelta,
          'flutterPresentDelta': staticFlutterDelta,
        },
        'platformThreadStall': stall,
        'resizeSample': <String, Object?>{
          'before': resizeBefore,
          'contracted': resizeContracted,
          'after': resizeAfter,
        },
        'geometrySample': <String, Object?>{
          'before': geometryBefore,
          'after': geometryAfter,
        },
        'overlaySample': <String, Object?>{
          'before': overlayBefore,
          'visible': overlayVisible,
          'after': overlayAfter,
        },
        'pageSample': <String, Object?>{
          'before': pageBefore,
          'visible': pageVisible,
          'after': pageAfter,
        },
        'visibilitySample': <String, Object?>{
          'before': visibilityBefore,
          'hiddenSettled': visibilityHiddenSettled,
          'hiddenAfter': visibilityHiddenAfter,
          'restored': visibilityRestored,
        },
        'animationSample': <String, Object?>{
          'before': animationBefore,
          'after': animationAfter,
        },
        'pauseResumeSample': <String, Object?>{
          'before': pauseBefore,
          'requestedPositionSeconds': pauseRequestedPosition,
          'settledPositionSeconds': pauseSettledPosition,
          'settledState': pauseSettledState,
          'settledDiagnostics': pauseSettled,
          'heldPositionSeconds': pauseHeldPosition,
          'heldState': pauseHeldState,
          'heldDiagnostics': pauseHeld,
          'resumePositionSeconds': resumePosition,
          'resumeState': resumeState,
          'after': pauseAfter,
        },
        'generationSwitchSample': <String, Object?>{
          'untitledLyricPath': _fixture(fixtureRoot, 'l1.krl'),
          'titledLyricPath': titleLyricPath,
          'before': switchBefore,
          'after': switchAfter,
          'titledPositionSeconds': titledPosition,
          'titledDurationSeconds': titledDuration,
          'titledState': titledState,
        },
        'replaySample': <String, Object?>{
          'nativeReplaySupported': nativeReplaySupported,
          'before': replayBefore,
          'beforePositionSeconds': replayBeforePosition,
          'afterPositionSeconds': replayAfterPosition,
          'afterState': replayAfterState,
          'after': replayAfter,
        },
        'naturalEofSample': <String, Object?>{
          'waitMilliseconds': eofWaitMilliseconds,
          'before': eofBefore,
          'after': eofAfter,
          'positionSeconds': eofPosition,
          'durationSeconds': eofDuration,
          'state': eofState,
          'buffering': eofBuffering,
        },
        'reloadAfterNaturalEofSample': <String, Object?>{
          'prepared': naturalNextPrepared,
          'seamlessTransition': true,
          'before': reloadBefore,
          'after': reloadAfter,
          'positionSeconds': reloadPosition,
          'state': reloadState,
        },
        if (audioShorterThanVideo != null && videoShorterThanAudio != null)
          'eofMismatchSample': <String, Object?>{
            'fixtureRoot': eofMismatchRoot,
            'audioShorterThanVideo': audioShorterThanVideo,
            'videoShorterThanAudio': videoShorterThanAudio,
            'recovery': <String, Object?>{
              'before': eofMismatchRecoveryBefore,
              'after': eofMismatchRecoveryAfter,
              'positionSeconds': eofMismatchRecoveryPosition,
              'state': eofMismatchRecoveryState,
            },
          },
        'detachReattachSample': <String, Object?>{
          'before': detachBefore,
          'detached': detached,
          'after': detachAfter,
        },
        'postInteractionStaticSample': <String, Object?>{
          'before': settledBefore,
          'after': settledAfter,
        },
        if (lifecycleProbe)
          'lifecycle': <String, Object?>{
            ...lifecycleSamples,
            'gates': lifecycleGates,
            'passed': lifecycleGates.values.every((value) => value),
          },
        'gates': gates,
        'passed': gates.values.every((value) => value),
      };
    } catch (error, stackTrace) {
      report = <String, Object?>{
        'schemaVersion': 1,
        'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'passed': false,
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      };
    }

    final reportPath = Platform.environment['KIRAKARA_COMPOSITOR_REPORT_PATH'];
    if (reportPath != null && reportPath.trim().isNotEmpty) {
      final file = File(reportPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
    }
    final keepOpen =
        Platform.environment['KIRAKARA_COMPOSITOR_KEEP_OPEN'] == '1';
    final exitWhileActive =
        Platform.environment['KIRAKARA_COMPOSITOR_EXIT_WHILE_ACTIVE'] == '1';
    if (exitWhileActive) {
      _skipDisposeCleanup = true;
    }
    if (!keepOpen && !exitWhileActive) {
      await _stageController.setActive(false);
      await _stageController.detach();
      _show?.dispose();
      _show = null;
    }
    if (mounted) {
      setState(() {
        _status = report['passed'] == true
            ? '真实 Show Stage 自动门禁通过。'
            : '真实 Show Stage 自动门禁失败；请查看报告。';
        _probeRunning = false;
      });
    }
    if (!keepOpen &&
        Platform.environment['KIRAKARA_COMPOSITOR_AUTO_EXIT'] == '1') {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _compositorChannel.invokeMethod<void>('closeWindowForTest');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_skipDisposeCleanup) {
      unawaited(_stageController.setActive(false));
      unawaited(_stageController.detach());
      _show?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleGeometryReport();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: <Widget>[
            const Positioned.fill(
              child: ColoredBox(color: Color(0xff101722)),
            ),
            Positioned(
              left: 72,
              right: 72,
              top: 96,
              bottom: 86,
              child: CustomPaint(
                key: _previewKey,
                painter: const _StageHolePainter(),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: 28,
              top: 24,
              child: Text(
                'Kirakara real Stage compositor · $_fit',
                style: const TextStyle(fontSize: 20),
              ),
            ),
            Positioned(
              left: 28,
              bottom: 28,
              child: Text(_status),
            ),
            if (_overlayVisible)
              Positioned(
                left: 130,
                right: 130,
                top: 150,
                bottom: 140,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xcc202838),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Center(
                    child: Text(
                      '半透明 Flutter 面板覆盖实时 Stage',
                      style: TextStyle(fontSize: 24),
                    ),
                  ),
                ),
              ),
            if (_pageVisible)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xff243049),
                  child: Center(
                    child: Text(
                      'Flutter 全屏页面（Stage 仍独立更新）',
                      style: TextStyle(fontSize: 28),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _animatedOverlayVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeInOut,
                  child: const ColoredBox(
                    color: Color(0x9928507a),
                    child: Center(
                      child: Text(
                        'Flutter 动画压力样本',
                        style: TextStyle(fontSize: 30),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StageHolePainter extends CustomPainter {
  const _StageHolePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(24)),
      Paint()
        ..isAntiAlias = true
        ..blendMode = BlendMode.clear,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds.deflate(1), const Radius.circular(23)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white38,
    );
  }

  @override
  bool shouldRepaint(covariant _StageHolePainter oldDelegate) => false;
}
