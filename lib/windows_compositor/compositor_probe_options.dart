import 'dart:math' as math;

int parseCompositorSoakSeconds(String? raw) {
  final normalized = raw?.trim();
  if (normalized == null || normalized.isEmpty) {
    return 0;
  }
  final value = int.tryParse(normalized);
  if (value == 0) {
    return 0;
  }
  if (value == null || value < 30 || value > 14400) {
    throw StateError(
      'KIRAKARA_COMPOSITOR_SOAK_SECONDS must be between 30 and 14400.',
    );
  }
  return value;
}

class CompositorCadenceExpectation {
  CompositorCadenceExpectation._({
    required this.referenceHz,
    required this.minimumAcceptedHz,
    required this.maximumAcceptedHz,
    required this.referenceIsSane,
  });

  factory CompositorCadenceExpectation.fromReference({
    required int presentCount,
    required int durationMilliseconds,
    double minimumSaneHz = 30,
    double maximumSaneHz = 360,
    double toleranceFraction = 0.10,
    double minimumToleranceHz = 5,
  }) {
    if (presentCount < 0) {
      throw ArgumentError.value(presentCount, 'presentCount');
    }
    if (durationMilliseconds <= 0) {
      throw ArgumentError.value(
        durationMilliseconds,
        'durationMilliseconds',
      );
    }
    if (minimumSaneHz <= 0 || maximumSaneHz <= minimumSaneHz) {
      throw ArgumentError('Invalid sane compositor cadence range.');
    }
    if (toleranceFraction < 0 || minimumToleranceHz < 0) {
      throw ArgumentError('Cadence tolerances cannot be negative.');
    }

    final referenceHz = presentCount * 1000 / durationMilliseconds;
    final toleranceHz = math.max(
      referenceHz * toleranceFraction,
      minimumToleranceHz,
    );
    return CompositorCadenceExpectation._(
      referenceHz: referenceHz,
      minimumAcceptedHz: math.max(
        minimumSaneHz,
        referenceHz - toleranceHz,
      ),
      maximumAcceptedHz: math.min(
        maximumSaneHz,
        referenceHz + toleranceHz,
      ),
      referenceIsSane:
          referenceHz >= minimumSaneHz && referenceHz <= maximumSaneHz,
    );
  }

  final double referenceHz;
  final double minimumAcceptedHz;
  final double maximumAcceptedHz;
  final bool referenceIsSane;

  int minimumPresentCount(int durationMilliseconds) {
    _validateSampleDuration(durationMilliseconds);
    return (minimumAcceptedHz * durationMilliseconds / 1000).ceil();
  }

  int maximumPresentCount(int durationMilliseconds) {
    _validateSampleDuration(durationMilliseconds);
    return (maximumAcceptedHz * durationMilliseconds / 1000).floor();
  }

  double sampleHz(int presentCount, int durationMilliseconds) {
    if (presentCount < 0) {
      throw ArgumentError.value(presentCount, 'presentCount');
    }
    _validateSampleDuration(durationMilliseconds);
    return presentCount * 1000 / durationMilliseconds;
  }

  bool accepts(int presentCount, int durationMilliseconds) {
    if (!referenceIsSane) {
      return false;
    }
    return presentCount >= minimumPresentCount(durationMilliseconds) &&
        presentCount <= maximumPresentCount(durationMilliseconds);
  }

  void _validateSampleDuration(int durationMilliseconds) {
    if (durationMilliseconds <= 0) {
      throw ArgumentError.value(
        durationMilliseconds,
        'durationMilliseconds',
      );
    }
  }
}
