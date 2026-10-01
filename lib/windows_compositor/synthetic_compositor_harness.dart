import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'compositor_probe_options.dart';

const _compositorChannel = MethodChannel('kirakara/dcomp_compositor');

int _counter(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! num) {
    throw StateError('Missing numeric compositor counter: $key');
  }
  return value.toInt();
}

bool _monitorInventoryIsSane(Object? value) {
  if (value is! List<Object?> || value.isEmpty) {
    return false;
  }
  return value.every((entry) {
    if (entry is! Map<Object?, Object?>) {
      return false;
    }
    final dpi = entry['dpi'];
    return dpi is num && dpi >= 96 && dpi <= 480;
  });
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

/// A transparent Flutter overlay used only by the Phase 2 synthetic DComp
/// validation. It deliberately has no recurring timer or active animation at
/// rest, so lower-visual progress can be compared with Flutter presents.
class SyntheticCompositorHarness extends StatefulWidget {
  const SyntheticCompositorHarness({super.key});

  @override
  State<SyntheticCompositorHarness> createState() =>
      _SyntheticCompositorHarnessState();
}

class _SyntheticCompositorHarnessState
    extends State<SyntheticCompositorHarness> {
  String _status = '正在等待首帧稳定…';
  bool _panelVisible = false;
  bool _pageVisible = false;
  bool _pulseExpanded = false;
  bool _probeRunning = false;
  int? _windowDpi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runProbe();
    });
  }

  Future<void> _runProbe() async {
    if (_probeRunning) {
      return;
    }
    _probeRunning = true;
    if (mounted) {
      setState(() => _status = '等待静止 UI 稳定…');
    }

    Map<String, Object?> report;
    try {
      await Future<void>.delayed(const Duration(seconds: 1));
      final backend = await _readMap('getBackendInfo');
      if (mounted) {
        setState(() => _windowDpi = _counter(backend, 'windowDpi'));
      }
      final before = await _readMap('getDiagnostics');
      final stopwatch = Stopwatch()..start();
      await Future<void>.delayed(const Duration(seconds: 2));
      final after = await _readMap('getDiagnostics');
      stopwatch.stop();

      final stageDelta = _counter(after, 'stagePresentCount') -
          _counter(before, 'stagePresentCount');
      final stageWakeDelta = _counter(after, 'stageWaitWakeCount') -
          _counter(before, 'stageWaitWakeCount');
      final flutterDelta = _counter(after, 'flutterPresentCount') -
          _counter(before, 'flutterPresentCount');

      final stall = await _readMap('stallPlatformThreadForTest', 750);
      final stallStageDelta = _counter(stall, 'stagePresentDelta');
      final stallFlutterDelta = _counter(stall, 'flutterPresentDelta');

      final resizeBefore = await _readMap('getDiagnostics');
      await _compositorChannel.invokeMethod<void>(
        'resizeWindowByForTest',
        const <String, int>{'widthDelta': -160, 'heightDelta': -90},
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final resizeContracted = await _readMap('getDiagnostics');
      await _compositorChannel.invokeMethod<void>(
        'resizeWindowByForTest',
        const <String, int>{'widthDelta': 160, 'heightDelta': 90},
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final resizeRestored = await _readMap('getDiagnostics');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final resizeAfter = await _readMap('getDiagnostics');

      final resizeCountDelta = _counter(resizeAfter, 'surfaceResizeCount') -
          _counter(resizeBefore, 'surfaceResizeCount');
      final resizeStageDelta = _counter(resizeAfter, 'stagePresentCount') -
          _counter(resizeRestored, 'stagePresentCount');
      final resizeFlutterDelta = _counter(resizeAfter, 'flutterPresentCount') -
          _counter(resizeBefore, 'flutterPresentCount');

      if (!mounted) {
        throw StateError('Synthetic compositor harness was unmounted.');
      }
      final overlayBefore = await _readMap('getDiagnostics');
      setState(() => _panelVisible = true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final overlayVisible = await _readMap('getDiagnostics');
      setState(() => _panelVisible = false);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final overlayAfter = await _readMap('getDiagnostics');

      final pageBefore = await _readMap('getDiagnostics');
      setState(() => _pageVisible = true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final pageVisible = await _readMap('getDiagnostics');
      setState(() => _pageVisible = false);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final pageAfter = await _readMap('getDiagnostics');

      final monitorValues = backend['monitors']! as List<Object?>;
      final monitorEntries = monitorValues
          .whereType<Map<Object?, Object?>>()
          .toList(growable: false);
      final originalMonitorIndex = _counter(backend, 'currentMonitorIndex');
      final originalMonitor = monitorEntries.firstWhere(
        (monitor) => monitor['index'] == originalMonitorIndex,
      );
      final originalMonitorDpi = (originalMonitor['dpi']! as num).toInt();
      Map<String, Object?> monitorMoveSample;
      var monitorMoveSucceeded = true;
      if (monitorEntries.length > 1) {
        Map<Object?, Object?>? targetMonitor;
        for (final monitor in monitorEntries) {
          if (monitor['index'] != originalMonitorIndex &&
              monitor['dpi'] != originalMonitorDpi) {
            targetMonitor = monitor;
            break;
          }
        }
        targetMonitor ??= monitorEntries.firstWhere(
          (monitor) => monitor['index'] != originalMonitorIndex,
        );
        final targetMonitorIndex = (targetMonitor['index']! as num).toInt();
        final targetMonitorDpi = (targetMonitor['dpi']! as num).toInt();
        final moveBefore = await _readMap('getDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'moveWindowToMonitorForTest',
          targetMonitorIndex,
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        final targetBackend = await _readMap('getBackendInfo');
        final targetDiagnostics = await _readMap('getDiagnostics');
        await _compositorChannel.invokeMethod<void>(
          'moveWindowToMonitorForTest',
          originalMonitorIndex,
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        final restoredBackend = await _readMap('getBackendInfo');
        final restoredDiagnostics = await _readMap('getDiagnostics');
        final stageDeltaToTarget =
            _counter(targetDiagnostics, 'stagePresentCount') -
                _counter(moveBefore, 'stagePresentCount');
        final stageDeltaToRestore =
            _counter(restoredDiagnostics, 'stagePresentCount') -
                _counter(targetDiagnostics, 'stagePresentCount');
        monitorMoveSucceeded = _counter(targetBackend, 'currentMonitorIndex') ==
                targetMonitorIndex &&
            _counter(restoredBackend, 'currentMonitorIndex') ==
                originalMonitorIndex &&
            _counter(targetBackend, 'windowDpi') == 96 &&
            _counter(restoredBackend, 'windowDpi') ==
                _counter(backend, 'windowDpi') &&
            _counter(targetBackend, 'windowDpiAwareness') == 0 &&
            _counter(restoredBackend, 'windowDpiAwareness') == 0 &&
            targetBackend['windowIsPerMonitorV2'] == false &&
            restoredBackend['windowIsPerMonitorV2'] == false &&
            _counter(moveBefore, 'topLevelWindow') ==
                _counter(targetDiagnostics, 'topLevelWindow') &&
            _counter(moveBefore, 'topLevelWindow') ==
                _counter(restoredDiagnostics, 'topLevelWindow') &&
            _counter(moveBefore, 'width') ==
                _counter(restoredDiagnostics, 'width') &&
            _counter(moveBefore, 'height') ==
                _counter(restoredDiagnostics, 'height') &&
            _counter(moveBefore, 'compositionTreeCommitCount') == 1 &&
            _counter(targetDiagnostics, 'compositionTreeCommitCount') == 1 &&
            _counter(
                  restoredDiagnostics,
                  'compositionTreeCommitCount',
                ) ==
                1 &&
            stageDeltaToTarget >= 15 &&
            stageDeltaToRestore >= 15;
        monitorMoveSample = <String, Object?>{
          'skipped': false,
          'originalMonitorIndex': originalMonitorIndex,
          'originalMonitorDpi': originalMonitorDpi,
          'targetMonitorIndex': targetMonitorIndex,
          'targetMonitorDpi': targetMonitorDpi,
          'before': moveBefore,
          'targetBackend': targetBackend,
          'targetDiagnostics': targetDiagnostics,
          'restoredBackend': restoredBackend,
          'restoredDiagnostics': restoredDiagnostics,
          'stagePresentDeltaToTarget': stageDeltaToTarget,
          'stagePresentDeltaToRestore': stageDeltaToRestore,
        };
      } else {
        monitorMoveSample = <String, Object?>{
          'skipped': true,
          'reason': 'single_monitor',
          'monitorCount': monitorEntries.length,
        };
      }

      // Allow any finite Material hover/focus/transition work caused by the
      // interaction samples to settle, then prove the harness returns to a
      // quiescent Flutter frame pump while Stage keeps advancing.
      await Future<void>.delayed(const Duration(milliseconds: 750));
      final postInteractionBefore = await _readMap('getDiagnostics');
      final postInteractionStopwatch = Stopwatch()..start();
      await Future<void>.delayed(const Duration(seconds: 2));
      final postInteractionAfter = await _readMap('getDiagnostics');
      postInteractionStopwatch.stop();
      final postInteractionDurationMilliseconds =
          postInteractionStopwatch.elapsedMilliseconds;
      final postInteractionStageDelta =
          _counter(postInteractionAfter, 'stagePresentCount') -
              _counter(postInteractionBefore, 'stagePresentCount');
      final postInteractionFlutterDelta =
          _counter(postInteractionAfter, 'flutterPresentCount') -
              _counter(postInteractionBefore, 'flutterPresentCount');
      final cadenceReferenceStagePresents =
          stageDelta + postInteractionStageDelta;
      final cadenceReferenceDurationMilliseconds =
          stopwatch.elapsedMilliseconds + postInteractionDurationMilliseconds;
      final cadenceExpectation = CompositorCadenceExpectation.fromReference(
        presentCount: cadenceReferenceStagePresents,
        durationMilliseconds: cadenceReferenceDurationMilliseconds,
      );

      final soakSeconds = parseCompositorSoakSeconds(
        Platform.environment['KIRAKARA_COMPOSITOR_SOAK_SECONDS'],
      );
      Map<String, Object?>? soakSample;
      var soakStageCadenceInRange = true;
      var soakStageWaitWasEventDriven = true;
      var soakFlutterStayedQuiescent = true;
      var soakDiagnosticsStayedHealthy = true;
      var soakTopologyStayedStable = true;
      if (soakSeconds > 0) {
        if (!mounted) {
          throw StateError('Synthetic compositor harness was unmounted.');
        }
        setState(() {
          _status = '正在执行 $soakSeconds 秒有界稳态门禁…';
        });
        await Future<void>.delayed(const Duration(milliseconds: 750));
        final beforeRssBytes = ProcessInfo.currentRss;
        final soakBefore = await _readMap('getDiagnostics');
        final soakStopwatch = Stopwatch()..start();
        final firstIntervalMilliseconds = soakSeconds * 500;
        await Future<void>.delayed(
          Duration(milliseconds: firstIntervalMilliseconds),
        );
        final soakMidpoint = await _readMap('getDiagnostics');
        final midpointElapsedMilliseconds = soakStopwatch.elapsedMilliseconds;
        final midpointRssBytes = ProcessInfo.currentRss;
        await Future<void>.delayed(
          Duration(
            milliseconds: soakSeconds * 1000 - firstIntervalMilliseconds,
          ),
        );
        final soakAfter = await _readMap('getDiagnostics');
        soakStopwatch.stop();
        final afterRssBytes = ProcessInfo.currentRss;
        final elapsedMilliseconds = soakStopwatch.elapsedMilliseconds;
        final secondIntervalMilliseconds =
            elapsedMilliseconds - midpointElapsedMilliseconds;

        int delta(
          Map<String, Object?> from,
          Map<String, Object?> to,
          String counter,
        ) =>
            _counter(to, counter) - _counter(from, counter);

        bool diagnosticsHealthy(Map<String, Object?> sample) =>
            sample['initializationHresult'] == 0 &&
            sample['lastStagePresentHresult'] == 0 &&
            sample['lastStagePacingStatus'] == 0 &&
            sample['lastResizeHresult'] == 0 &&
            sample['lastStageResourceHresult'] == 0 &&
            _counter(sample, 'stageDeviceRemovedCount') == 0 &&
            _counter(sample, 'stageOccludedCount') == 0 &&
            _counter(sample, 'stageHandleDuplicateFailureCount') == 0 &&
            _counter(sample, 'stageResourceOpenFailureCount') == 0;

        bool topologyStable(Map<String, Object?> sample) =>
            _counter(sample, 'topLevelWindow') ==
                _counter(soakBefore, 'topLevelWindow') &&
            _counter(sample, 'width') == _counter(soakBefore, 'width') &&
            _counter(sample, 'height') == _counter(soakBefore, 'height') &&
            _counter(sample, 'surfaceResizeCount') ==
                _counter(soakBefore, 'surfaceResizeCount') &&
            _counter(sample, 'compositionTreeCommitCount') ==
                _counter(soakBefore, 'compositionTreeCommitCount') &&
            _counter(sample, 'compositionTreeCommitCount') == 1;

        final firstStageDelta =
            delta(soakBefore, soakMidpoint, 'stagePresentCount');
        final secondStageDelta =
            delta(soakMidpoint, soakAfter, 'stagePresentCount');
        final soakStageDelta =
            delta(soakBefore, soakAfter, 'stagePresentCount');
        final firstWakeDelta =
            delta(soakBefore, soakMidpoint, 'stageWaitWakeCount');
        final secondWakeDelta =
            delta(soakMidpoint, soakAfter, 'stageWaitWakeCount');
        final soakWakeDelta =
            delta(soakBefore, soakAfter, 'stageWaitWakeCount');
        final firstFlutterDelta =
            delta(soakBefore, soakMidpoint, 'flutterPresentCount');
        final secondFlutterDelta =
            delta(soakMidpoint, soakAfter, 'flutterPresentCount');
        final soakFlutterDelta =
            delta(soakBefore, soakAfter, 'flutterPresentCount');
        soakStageCadenceInRange = cadenceExpectation.accepts(
              firstStageDelta,
              midpointElapsedMilliseconds,
            ) &&
            cadenceExpectation.accepts(
              secondStageDelta,
              secondIntervalMilliseconds,
            ) &&
            cadenceExpectation.accepts(
              soakStageDelta,
              elapsedMilliseconds,
            );
        soakStageWaitWasEventDriven =
            (firstWakeDelta - firstStageDelta).abs() <= 3 &&
                (secondWakeDelta - secondStageDelta).abs() <= 3 &&
                (soakWakeDelta - soakStageDelta).abs() <= 3;
        soakFlutterStayedQuiescent = firstFlutterDelta <= 3 &&
            secondFlutterDelta <= 3 &&
            soakFlutterDelta <= 3;
        soakDiagnosticsStayedHealthy =
            diagnosticsHealthy(soakMidpoint) && diagnosticsHealthy(soakAfter);
        soakTopologyStayedStable =
            topologyStable(soakMidpoint) && topologyStable(soakAfter);
        soakSample = <String, Object?>{
          'requestedDurationSeconds': soakSeconds,
          'elapsedMilliseconds': elapsedMilliseconds,
          'midpointElapsedMilliseconds': midpointElapsedMilliseconds,
          'before': soakBefore,
          'midpoint': soakMidpoint,
          'after': soakAfter,
          'stagePresentDelta': soakStageDelta,
          'stagePresentDeltaToMidpoint': firstStageDelta,
          'stagePresentDeltaAfterMidpoint': secondStageDelta,
          'stageWaitWakeDelta': soakWakeDelta,
          'stageWaitWakeDeltaToMidpoint': firstWakeDelta,
          'stageWaitWakeDeltaAfterMidpoint': secondWakeDelta,
          'flutterPresentDelta': soakFlutterDelta,
          'flutterPresentDeltaToMidpoint': firstFlutterDelta,
          'flutterPresentDeltaAfterMidpoint': secondFlutterDelta,
          'cadenceReferenceStagePresents': cadenceReferenceStagePresents,
          'cadenceReferenceDurationMilliseconds':
              cadenceReferenceDurationMilliseconds,
          'cadenceReferenceHz': cadenceExpectation.referenceHz,
          'minimumAcceptedStageHz': cadenceExpectation.minimumAcceptedHz,
          'maximumAcceptedStageHz': cadenceExpectation.maximumAcceptedHz,
          'stagePresentHz': cadenceExpectation.sampleHz(
            soakStageDelta,
            elapsedMilliseconds,
          ),
          'stagePresentHzToMidpoint': cadenceExpectation.sampleHz(
            firstStageDelta,
            midpointElapsedMilliseconds,
          ),
          'stagePresentHzAfterMidpoint': cadenceExpectation.sampleHz(
            secondStageDelta,
            secondIntervalMilliseconds,
          ),
          'minimumExpectedStagePresents':
              cadenceExpectation.minimumPresentCount(elapsedMilliseconds),
          'maximumExpectedStagePresents':
              cadenceExpectation.maximumPresentCount(elapsedMilliseconds),
          'beforeRssBytes': beforeRssBytes,
          'midpointRssBytes': midpointRssBytes,
          'afterRssBytes': afterRssBytes,
          'rssDeltaBytes': afterRssBytes - beforeRssBytes,
        };
      }

      bool keptWindowIdentity(
        Map<String, Object?> before,
        Map<String, Object?> visible,
        Map<String, Object?> after,
      ) {
        return _counter(before, 'topLevelWindow') ==
                _counter(visible, 'topLevelWindow') &&
            _counter(before, 'topLevelWindow') ==
                _counter(after, 'topLevelWindow') &&
            _counter(before, 'width') == _counter(visible, 'width') &&
            _counter(before, 'height') == _counter(visible, 'height') &&
            _counter(before, 'width') == _counter(after, 'width') &&
            _counter(before, 'height') == _counter(after, 'height') &&
            _counter(before, 'compositionTreeCommitCount') == 1 &&
            _counter(visible, 'compositionTreeCommitCount') == 1 &&
            _counter(after, 'compositionTreeCommitCount') == 1;
      }

      final overlayStageDelta = _counter(overlayVisible, 'stagePresentCount') -
          _counter(overlayBefore, 'stagePresentCount');
      final pageStageDelta = _counter(pageVisible, 'stagePresentCount') -
          _counter(pageBefore, 'stagePresentCount');
      final gates = <String, bool>{
        'backendMetadataMatches': backend['backend'] == 'synthetic' &&
            backend['backendSelection'] == 'environment' &&
            backend['abiVersion'] == 2 &&
            backend['patchsetVersion'] == 5 &&
            backend['patchsetRevision'] == 'windows-dcomp-stage-visual',
        'singleVisibleTopLevelWindow':
            backend['visibleTopLevelWindowCount'] == 1 &&
                _counter(after, 'topLevelWindow') != 0 &&
                _counter(backend, 'topLevelWindow') ==
                    _counter(after, 'topLevelWindow'),
        'windowDpiIsVirtualized': _counter(backend, 'windowDpi') == 96,
        'windowDpiAwarenessDisabled':
            backend['windowIsPerMonitorV2'] == false &&
                _counter(backend, 'windowDpiAwareness') == 0,
        'monitorInventoryMatches': backend['monitors'] is List<Object?> &&
            (backend['monitors']! as List<Object?>).length ==
                _counter(backend, 'monitorCount') &&
            _counter(backend, 'currentMonitorIndex') >= 0 &&
            _counter(backend, 'currentMonitorIndex') <
                _counter(backend, 'monitorCount') &&
            _monitorInventoryIsSane(backend['monitors']),
        'compositorActive': after['active'] == true,
        'inPlaceResizeCapability':
            (_counter(after, 'capabilities') & (1 << 5)) != 0,
        'initializationSucceeded': after['initializationHresult'] == 0,
        'stagePresentSucceeded': after['lastStagePresentHresult'] == 0,
        'stagePacingSucceeded': after['lastStagePacingStatus'] == 0,
        'stageMadeProgressWhileFlutterStatic': stageDelta >= 45,
        'stageWaitWasEventDriven': stageWakeDelta >= stageDelta - 2,
        'stagePacingWasBounded': stageDelta <= 1000 && stallStageDelta <= 500,
        'staticFlutterDidNotRepump': flutterDelta <= 3,
        'stageContinuedDuringPlatformStall': stallStageDelta >= 15,
        'platformStallDidNotPresentFlutter': stallFlutterDelta <= 1,
        'resizeSucceeded':
            resizeAfter['lastResizeHresult'] == 0 && resizeCountDelta >= 2,
        'resizeReachedContractedDimensions':
            _counter(resizeContracted, 'width') ==
                    _counter(resizeBefore, 'width') - 160 &&
                _counter(resizeContracted, 'height') ==
                    _counter(resizeBefore, 'height') - 90,
        'resizeRestoredOriginalDimensions': _counter(resizeRestored, 'width') ==
                _counter(resizeBefore, 'width') &&
            _counter(resizeRestored, 'height') ==
                _counter(resizeBefore, 'height'),
        'compositionTreeStayedAttached':
            _counter(resizeBefore, 'compositionTreeCommitCount') == 1 &&
                _counter(resizeAfter, 'compositionTreeCommitCount') == 1,
        'sameTopLevelWindowAfterResize':
            _counter(resizeBefore, 'topLevelWindow') ==
                _counter(resizeAfter, 'topLevelWindow'),
        'stageResumedAfterResize': resizeStageDelta >= 5,
        'resizeProducedFlutterFrames': resizeFlutterDelta >= 2,
        'overlayKeptWindowIdentity':
            keptWindowIdentity(overlayBefore, overlayVisible, overlayAfter),
        'stageContinuedUnderOverlay': overlayStageDelta >= 15,
        'pageKeptWindowIdentity':
            keptWindowIdentity(pageBefore, pageVisible, pageAfter),
        'stageContinuedUnderPage': pageStageDelta >= 15,
        'monitorMoveSkippedOrSucceeded': monitorMoveSucceeded,
        'stageContinuedAfterInteractions': postInteractionStageDelta >= 45,
        'flutterReturnedToQuiescence': postInteractionFlutterDelta <= 3,
        'noStageDeviceRemoval': resizeAfter['stageDeviceRemovedCount'] == 0,
        'noStageOcclusion': resizeAfter['stageOccludedCount'] == 0,
        if (soakSample != null) ...<String, bool>{
          'soakStageCadenceInRange': soakStageCadenceInRange,
          'soakStageWaitWasEventDriven': soakStageWaitWasEventDriven,
          'soakFlutterStayedQuiescent': soakFlutterStayedQuiescent,
          'soakDiagnosticsStayedHealthy': soakDiagnosticsStayedHealthy,
          'soakTopologyStayedStable': soakTopologyStayedStable,
        },
      };
      report = <String, Object?>{
        'schemaVersion': 1,
        'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'backend': backend,
        'staticSample': <String, Object?>{
          'durationMilliseconds': stopwatch.elapsedMilliseconds,
          'before': before,
          'after': after,
          'stagePresentDelta': stageDelta,
          'stageWaitWakeDelta': stageWakeDelta,
          'flutterPresentDelta': flutterDelta,
        },
        'platformThreadStall': stall,
        'resizeSample': <String, Object?>{
          'before': resizeBefore,
          'contracted': resizeContracted,
          'restored': resizeRestored,
          'after': resizeAfter,
          'surfaceResizeDelta': resizeCountDelta,
          'stagePresentDeltaAfterRestore': resizeStageDelta,
          'flutterPresentDelta': resizeFlutterDelta,
        },
        'overlaySample': <String, Object?>{
          'before': overlayBefore,
          'visible': overlayVisible,
          'after': overlayAfter,
          'stagePresentDeltaWhileVisible': overlayStageDelta,
        },
        'pageSample': <String, Object?>{
          'before': pageBefore,
          'visible': pageVisible,
          'after': pageAfter,
          'stagePresentDeltaWhileVisible': pageStageDelta,
        },
        'monitorMoveSample': monitorMoveSample,
        'postInteractionStaticSample': <String, Object?>{
          'durationMilliseconds': postInteractionDurationMilliseconds,
          'before': postInteractionBefore,
          'after': postInteractionAfter,
          'stagePresentDelta': postInteractionStageDelta,
          'flutterPresentDelta': postInteractionFlutterDelta,
        },
        if (soakSample != null) 'soakSample': soakSample,
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

    if (mounted) {
      setState(() {
        _status = report['passed'] == true
            ? '自动门槛通过；可继续手动检查缩放、遮盖与输入。'
            : '自动门槛失败；请查看诊断报告。';
        _probeRunning = false;
      });
    }
    if (Platform.environment['KIRAKARA_COMPOSITOR_AUTO_EXIT'] == '1') {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _compositorChannel.invokeMethod<void>('closeWindowForTest');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final sideWidth = math.min(260.0, constraints.maxWidth * 0.22);
            const headerHeight = 76.0;
            const footerHeight = 104.0;
            const gap = 18.0;
            final preview = Rect.fromLTWH(
              sideWidth + gap,
              headerHeight + gap,
              math.max(120, constraints.maxWidth - (sideWidth + gap) * 2),
              math.max(
                100,
                constraints.maxHeight - headerHeight - footerHeight - gap * 2,
              ),
            );
            return Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _PreviewMaskPainter(preview),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  height: headerHeight,
                  child: _Panel(
                    child: Row(
                      children: [
                        const Icon(Icons.layers_outlined, color: Colors.cyan),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Kirakara DirectComposition synthetic probe',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(_status, key: const Key('probe-status')),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: headerHeight + gap,
                  bottom: footerHeight + gap,
                  width: sideWidth,
                  child: _Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Flutter controls',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          key: const Key('toggle-overlay'),
                          onPressed: () => setState(
                            () => _panelVisible = !_panelVisible,
                          ),
                          icon: const Icon(Icons.view_sidebar_outlined),
                          label: Text(_panelVisible ? '关闭遮罩' : '覆盖 Stage'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          key: const Key('pulse-animation'),
                          onPressed: () => setState(
                            () => _pulseExpanded = !_pulseExpanded,
                          ),
                          icon: const Icon(Icons.animation),
                          label: const Text('有限动画'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          key: const Key('switch-page'),
                          onPressed: () => setState(() => _pageVisible = true),
                          icon: const Icon(Icons.flip_to_front_outlined),
                          label: const Text('切换页面'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          key: const Key('rerun-probe'),
                          onPressed: _probeRunning ? null : _runProbe,
                          icon: const Icon(Icons.speed),
                          label: const Text('重新测量'),
                        ),
                        const Spacer(),
                        AnimatedContainer(
                          key: const Key('finite-animation'),
                          duration: const Duration(milliseconds: 650),
                          curve: Curves.easeInOutCubic,
                          height: _pulseExpanded ? 116 : 44,
                          decoration: BoxDecoration(
                            color: Colors.cyan.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.center,
                          child: const Text('Flutter Visual'),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: headerHeight + gap,
                  bottom: footerHeight + gap,
                  width: sideWidth,
                  child: const _Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Input / IME',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 16),
                        TextField(
                          key: Key('ime-input'),
                          decoration: InputDecoration(
                            labelText: '焦点与输入测试',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        SizedBox(height: 16),
                        Text(
                          '中央区域不绘制背景，应该直接显示下层独立 D3D '
                          '动画。窗口缩放和跨屏 DPI 后边框仍应贴合。',
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned.fromRect(
                  rect: preview,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: const Key('transparent-preview-hole'),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        border: Border.all(color: Colors.cyan, width: 2),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: const Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Transparent Flutter preview hole'),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: footerHeight,
                  child: _Panel(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: <Widget>[
                        const _FooterItem(Icons.desktop_windows, '单顶层 HWND'),
                        const _FooterItem(Icons.opacity, '预乘 Alpha'),
                        const _FooterItem(Icons.swap_vert, '双 Visual'),
                        _FooterItem(
                          Icons.zoom_in,
                          _windowDpi == null
                              ? 'DPI …'
                              : '${(_windowDpi! / 96 * 100).round()}% DPI',
                        ),
                        const _FooterItem(
                          Icons.timer_off_outlined,
                          '无主动轮询',
                        ),
                      ],
                    ),
                  ),
                ),
                if (_panelVisible)
                  Positioned.fromRect(
                    rect: preview.deflate(36),
                    child: Material(
                      key: const Key('stage-cover-overlay'),
                      color: const Color(0xD91A2333),
                      borderRadius: BorderRadius.circular(24),
                      elevation: 18,
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Flutter 上层面板',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '此半透明面板应稳定覆盖实时 Stage；打开和关闭时不得'
                              '调整窗口大小，也不得重新挂载 HWND。',
                            ),
                            const Spacer(),
                            Align(
                              alignment: Alignment.bottomRight,
                              child: FilledButton(
                                onPressed: () =>
                                    setState(() => _panelVisible = false),
                                child: const Text('关闭'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_pageVisible)
                  Positioned(
                    left: 0,
                    top: headerHeight,
                    right: 0,
                    bottom: footerHeight,
                    child: Material(
                      key: const Key('alternate-page'),
                      color: const Color(0xFF101827),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.layers,
                              size: 72,
                              color: Colors.cyan,
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'Flutter 独立页面',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '页面切换期间仍使用同一顶层 HWND，Stage 继续在下层独立更新。',
                            ),
                            const SizedBox(height: 28),
                            FilledButton.icon(
                              key: const Key('return-to-preview'),
                              onPressed: () =>
                                  setState(() => _pageVisible = false),
                              icon: const Icon(Icons.arrow_back),
                              label: const Text('返回预览'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PreviewMaskPainter extends CustomPainter {
  const _PreviewMaskPainter(this.preview);

  final Rect preview;

  @override
  void paint(Canvas canvas, Size size) {
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(
        RRect.fromRectAndRadius(preview, const Radius.circular(28)),
      );
    canvas.drawPath(mask, Paint()..color = const Color(0xFF0B1018));
  }

  @override
  bool shouldRepaint(covariant _PreviewMaskPainter oldDelegate) {
    return oldDelegate.preview != preview;
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF21A1F2A),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _FooterItem extends StatelessWidget {
  const _FooterItem(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.cyan),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}
