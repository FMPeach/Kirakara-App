import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kirakara_app/services/kirakara_show_ffi.dart';
import 'package:kirakara_app/services/stage_texture_service.dart';

const _videoPath = String.fromEnvironment('KIRAKARA_TEST_VIDEO');
const _lyricPath = String.fromEnvironment('KIRAKARA_TEST_LYRIC');
const _vocalPath = String.fromEnvironment('KIRAKARA_TEST_VOCAL');
const _accompanimentPath =
    String.fromEnvironment('KIRAKARA_TEST_ACCOMPANIMENT');
const _stageTextureChannel = MethodChannel('kirakara/stage_texture');

Future<Map<String, Object?>> _readDiagnosticsCounters() async {
  final result = await _stageTextureChannel.invokeMapMethod<String, Object?>(
    'getDiagnosticsCounters',
  );
  return result ?? <String, Object?>{};
}

int _counterDelta(
  Map<String, Object?> before,
  Map<String, Object?> after,
  String key,
) {
  return (after[key]! as int) - (before[key]! as int);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'external texture attaches while a real Show source plays',
    (tester) async {
      for (final fixture in <String>[
        _videoPath,
        _lyricPath,
        _vocalPath,
        _accompanimentPath,
      ]) {
        expect(
          fixture,
          isNotEmpty,
          reason: 'Pass all KIRAKARA_TEST_* paths with --dart-define.',
        );
        expect(File(fixture).existsSync(), isTrue, reason: fixture);
      }

      var show = KirakaraShowFFI();
      final texture = StageTextureController();
      addTearDown(() async {
        await texture.setActive(false);
        await texture.detach();
        show.stop();
        show.dispose();
      });

      show.setStageVisible(false);
      final attachment = await texture.attach(show.nativeHandleAddress);
      expect(attachment, isNotNull);
      expect(attachment!.isComposed, isFalse);
      final textureId = attachment.textureId;
      expect(textureId, isNotNull);
      expect(textureId, greaterThanOrEqualTo(0));
      await texture.setActive(true);

      await tester.pumpWidget(
        MaterialApp(
          home: ColoredBox(
            color: Colors.black,
            child: Texture(textureId: textureId!),
          ),
        ),
      );

      expect(
        show.load(
          _videoPath,
          lyricPath: _lyricPath,
          vocalPath: _vocalPath,
          accompanimentPath: _accompanimentPath,
        ),
        isTrue,
      );
      show.play();

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (show.position < 0.25 && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(show.position, greaterThanOrEqualTo(0.25));
      expect(tester.takeException(), isNull);

      if (Platform.environment['KIRAKARA_COMPOSITOR_DIAGNOSTICS'] == '1') {
        final activeBefore = await _readDiagnosticsCounters();
        expect(activeBefore['enabled'], isTrue);
        final activeSample = Stopwatch()..start();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        final activeAfter = await _readDiagnosticsCounters();
        activeSample.stop();
        final activeCallbacks = _counterDelta(
          activeBefore,
          activeAfter,
          'textureCallbacks',
        );
        final activeFrameAvailable = _counterDelta(
          activeBefore,
          activeAfter,
          'frameAvailableCalls',
        );
        final activeTextureAcquires = _counterDelta(
          activeBefore,
          activeAfter,
          'textureAcquires',
        );
        final activeAcquires = _counterDelta(
          activeBefore,
          activeAfter,
          'advancedTextureAcquires',
        );
        final activePresents = _counterDelta(
          activeBefore,
          activeAfter,
          'flutterPresents',
        );
        final activePresentsWithAcquire = _counterDelta(
          activeBefore,
          activeAfter,
          'flutterPresentsWithNewAcquire',
        );
        debugPrint(
          '[stage-baseline] active ${activeSample.elapsedMilliseconds}ms: '
          'callbacks=$activeCallbacks, '
          'frame_available=$activeFrameAvailable, '
          'texture_acquires=$activeTextureAcquires, '
          'advanced_acquires=$activeAcquires, presents=$activePresents, '
          'presents_with_new_acquire=$activePresentsWithAcquire',
        );
        expect(activeCallbacks, greaterThanOrEqualTo(45));
        expect(
          activeFrameAvailable,
          inInclusiveRange(activeCallbacks - 1, activeCallbacks + 1),
        );
        // At a 60 Hz desktop refresh, the stock external-texture path can
        // coalesce adjacent 60 Hz producer notifications before acquisition.
        // Phase 0 traces measured that behavior in both the official and the
        // unchanged local Engine, so this baseline protects minimum progress
        // and counter consistency instead of requiring the defect to vanish.
        final minimumAdvancedAcquires = (activeCallbacks * 2 / 3).floor();
        expect(
          activeAcquires,
          inInclusiveRange(minimumAdvancedAcquires, activeCallbacks),
        );
        expect(
          activeTextureAcquires,
          inInclusiveRange(activeAcquires, activeCallbacks + 2),
        );
        expect(
          activePresentsWithAcquire,
          // Counter snapshots cross the raster/present threads. One acquire
          // immediately before the first snapshot may be presented inside
          // the sample, or one acquire at the end may present just after it.
          inInclusiveRange(activeAcquires - 2, activeAcquires + 1),
        );
        expect(
          activePresents,
          inInclusiveRange(
            activePresentsWithAcquire,
            activePresentsWithAcquire + 3,
          ),
        );

        await _stageTextureChannel.invokeMethod<void>(
          'setWindowAvailableForTest',
          <String, Object?>{'available': false},
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        final hiddenBefore = await _readDiagnosticsCounters();
        expect(hiddenBefore['requestedActive'], isTrue);
        expect(hiddenBefore['active'], isFalse);
        expect(hiddenBefore['windowAvailable'], isFalse);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 750)),
        );
        final hiddenAfter = await _readDiagnosticsCounters();
        final hiddenCallbacks = _counterDelta(
          hiddenBefore,
          hiddenAfter,
          'textureCallbacks',
        );
        final hiddenPresents = _counterDelta(
          hiddenBefore,
          hiddenAfter,
          'flutterPresents',
        );
        debugPrint(
          '[stage-baseline] hidden 750ms: callbacks=$hiddenCallbacks, '
          'presents=$hiddenPresents',
        );
        expect(hiddenCallbacks, lessThanOrEqualTo(1));
        expect(hiddenPresents, lessThanOrEqualTo(2));

        await _stageTextureChannel.invokeMethod<void>(
          'setWindowAvailableForTest',
          <String, Object?>{'available': true},
        );
        final visibleBefore = await _readDiagnosticsCounters();
        expect(visibleBefore['active'], isTrue);
        expect(visibleBefore['windowAvailable'], isTrue);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 750)),
        );
        final visibleAfter = await _readDiagnosticsCounters();
        final visibleCallbacks = _counterDelta(
          visibleBefore,
          visibleAfter,
          'textureCallbacks',
        );
        final visibleAcquires = _counterDelta(
          visibleBefore,
          visibleAfter,
          'advancedTextureAcquires',
        );
        debugPrint(
          '[stage-baseline] visible again 750ms: callbacks=$visibleCallbacks, '
          'advanced_acquires=$visibleAcquires',
        );
        expect(visibleCallbacks, greaterThanOrEqualTo(30));
        expect(visibleAcquires, greaterThanOrEqualTo(20));

        await texture.setActive(false);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        final inactiveBefore = await _readDiagnosticsCounters();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 750)),
        );
        final inactiveAfter = await _readDiagnosticsCounters();
        final inactiveCallbacks = _counterDelta(
          inactiveBefore,
          inactiveAfter,
          'textureCallbacks',
        );
        final inactivePresents = _counterDelta(
          inactiveBefore,
          inactiveAfter,
          'flutterPresents',
        );
        debugPrint(
          '[stage-baseline] inactive 750ms: callbacks=$inactiveCallbacks, '
          'presents=$inactivePresents',
        );
        expect(inactiveCallbacks, lessThanOrEqualTo(1));
        expect(inactivePresents, lessThanOrEqualTo(2));
      }

      // Rebuild Show in the same process while keeping Flutter and the
      // registered Texture widget alive. Detach is the transaction boundary:
      // no bridge may retain a source or borrowed DLL entrypoint owned by the
      // old FFI instance.
      await texture.setActive(false);
      await texture.detach();
      show.stop();
      show.dispose();

      show = KirakaraShowFFI();
      show.setStageVisible(false);
      final replacement = await texture.attach(show.nativeHandleAddress);
      expect(replacement, isNotNull);
      expect(replacement!.isComposed, isFalse);
      expect(replacement.textureId, textureId);
      await texture.setActive(true);
      expect(
        show.load(
          _videoPath,
          lyricPath: _lyricPath,
          vocalPath: _vocalPath,
          accompanimentPath: _accompanimentPath,
        ),
        isTrue,
      );
      show.play();

      final replacementDeadline =
          DateTime.now().add(const Duration(seconds: 5));
      while (show.position < 0.25 &&
          DateTime.now().isBefore(replacementDeadline)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(show.position, greaterThanOrEqualTo(0.25));
      expect(tester.takeException(), isNull);

      if (Platform.environment['KIRAKARA_COMPOSITOR_DIAGNOSTICS'] == '1') {
        final rebuildBefore = await _readDiagnosticsCounters();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 750)),
        );
        final rebuildAfter = await _readDiagnosticsCounters();
        final rebuildCallbacks = _counterDelta(
          rebuildBefore,
          rebuildAfter,
          'textureCallbacks',
        );
        final rebuildAcquires = _counterDelta(
          rebuildBefore,
          rebuildAfter,
          'advancedTextureAcquires',
        );
        debugPrint(
          '[stage-baseline] rebuilt Show 750ms: '
          'callbacks=$rebuildCallbacks, advanced_acquires=$rebuildAcquires',
        );
        expect(rebuildCallbacks, greaterThanOrEqualTo(30));
        expect(rebuildAcquires, greaterThanOrEqualTo(20));
      }
    },
    skip: !Platform.isWindows,
  );
}
