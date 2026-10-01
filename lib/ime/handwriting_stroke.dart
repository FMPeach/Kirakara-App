class ImeStrokePoint {
  const ImeStrokePoint({
    required this.x,
    required this.y,
  });

  final double x;
  final double y;
}

typedef ImeStroke = List<ImeStrokePoint>;
