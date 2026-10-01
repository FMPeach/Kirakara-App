class ImeCandidate {
  const ImeCandidate({
    required this.text,
    this.annotation,
    this.score,
  });

  final String text;
  final String? annotation;
  final double? score;
}
