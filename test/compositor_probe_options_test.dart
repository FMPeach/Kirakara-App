import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/windows_compositor/compositor_probe_options.dart';

void main() {
  group('parseCompositorSoakSeconds', () {
    test('disables the bounded soak when unset or zero', () {
      expect(parseCompositorSoakSeconds(null), 0);
      expect(parseCompositorSoakSeconds(''), 0);
      expect(parseCompositorSoakSeconds('   '), 0);
      expect(parseCompositorSoakSeconds('0'), 0);
    });

    test('accepts the inclusive bounded duration range', () {
      expect(parseCompositorSoakSeconds('30'), 30);
      expect(parseCompositorSoakSeconds(' 30 '), 30);
      expect(parseCompositorSoakSeconds('1800'), 1800);
      expect(parseCompositorSoakSeconds('14400'), 14400);
    });

    test('rejects short, excessive, and malformed durations', () {
      for (final value in <String>['-1', '1', '29', '14401', 'thirty']) {
        expect(
          () => parseCompositorSoakSeconds(value),
          throwsA(isA<StateError>()),
          reason: value,
        );
      }
    });
  });

  group('CompositorCadenceExpectation', () {
    test('accepts stable 60 Hz samples and rejects cadence drift', () {
      final expectation = CompositorCadenceExpectation.fromReference(
        presentCount: 120,
        durationMilliseconds: 2000,
      );

      expect(expectation.referenceIsSane, isTrue);
      expect(expectation.referenceHz, 60);
      expect(expectation.minimumAcceptedHz, 54);
      expect(expectation.maximumAcceptedHz, 66);
      expect(expectation.accepts(900, 15000), isTrue);
      expect(expectation.accepts(810, 15000), isTrue);
      expect(expectation.accepts(990, 15000), isTrue);
      expect(expectation.accepts(809, 15000), isFalse);
      expect(expectation.accepts(991, 15000), isFalse);
    });

    test('uses the measured compositor clock instead of assuming 60 Hz', () {
      final expectation = CompositorCadenceExpectation.fromReference(
        presentCount: 544,
        durationMilliseconds: 4002,
      );

      expect(expectation.referenceHz, closeTo(135.93, 0.01));
      expect(expectation.accepts(2113, 15003), isTrue);
      expect(expectation.accepts(900, 15000), isFalse);
      expect(expectation.sampleHz(4225, 30005), closeTo(140.81, 0.01));
    });

    test('rejects an implausible reference clock', () {
      final stopped = CompositorCadenceExpectation.fromReference(
        presentCount: 0,
        durationMilliseconds: 2000,
      );
      final excessive = CompositorCadenceExpectation.fromReference(
        presentCount: 800,
        durationMilliseconds: 2000,
      );

      expect(stopped.referenceIsSane, isFalse);
      expect(stopped.accepts(900, 15000), isFalse);
      expect(excessive.referenceIsSane, isFalse);
      expect(excessive.accepts(5400, 15000), isFalse);
    });

    test('rejects invalid counters and durations', () {
      expect(
        () => CompositorCadenceExpectation.fromReference(
          presentCount: -1,
          durationMilliseconds: 2000,
        ),
        throwsArgumentError,
      );
      expect(
        () => CompositorCadenceExpectation.fromReference(
          presentCount: 120,
          durationMilliseconds: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
