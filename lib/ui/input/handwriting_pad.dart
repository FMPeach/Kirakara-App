import 'package:flutter/material.dart';

import '../../ime/handwriting_stroke.dart';
import '../theme/kirakara_theme.dart';

class HandwritingPad extends StatefulWidget {
  const HandwritingPad({
    super.key,
    required this.onRecognize,
    required this.onBackspace,
    required this.onClear,
    required this.clearRevision,
  });

  final Future<void> Function(List<ImeStroke> strokes) onRecognize;
  final Future<void> Function() onBackspace;
  final Future<void> Function() onClear;
  final int clearRevision;

  @override
  State<HandwritingPad> createState() => _HandwritingPadState();
}

class _HandwritingPadState extends State<HandwritingPad> {
  List<ImeStroke> _strokes = const [];
  ImeStroke? _activeStroke;

  @override
  void didUpdateWidget(covariant HandwritingPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clearRevision != widget.clearRevision) {
      _strokes = const [];
      _activeStroke = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 376,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: KiraColors.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x1affffff)),
        ),
        child: Column(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  setState(() {
                    _activeStroke = [
                      _toStrokePoint(details.localPosition),
                    ];
                  });
                },
                onPanUpdate: (details) {
                  setState(() {
                    final stroke = _activeStroke;
                    if (stroke != null) {
                      _activeStroke = List.unmodifiable([
                        ...stroke,
                        _toStrokePoint(details.localPosition),
                      ]);
                    }
                  });
                },
                onPanEnd: (_) {
                  setState(() {
                    final stroke = _activeStroke;
                    if (stroke != null && stroke.isNotEmpty) {
                      _strokes = List.unmodifiable([
                        ..._strokes,
                        List<ImeStrokePoint>.unmodifiable(stroke),
                      ]);
                    }
                    _activeStroke = null;
                  });
                  _recognize();
                },
                child: CustomPaint(
                  painter: _HandwritingPainter(
                    strokes: _strokes,
                    activeStroke: _activeStroke,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: KiraColors.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _PadAction(
                      label: '撤销一笔',
                      onTap: _undoStroke,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PadAction(
                      label: '清空',
                      onTap: _clear,
                      destructive: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PadAction(
                      label: '退格',
                      onTap: widget.onBackspace,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  ImeStrokePoint _toStrokePoint(Offset offset) {
    return ImeStrokePoint(x: offset.dx, y: offset.dy);
  }

  void _undoStroke() {
    setState(() {
      if (_strokes.isNotEmpty) {
        _strokes = List.unmodifiable(
          _strokes.take(_strokes.length - 1),
        );
      }
    });
    if (_strokes.isEmpty) {
      widget.onClear();
      return;
    }
    _recognize();
  }

  void _clear() {
    setState(() {
      _strokes = const [];
      _activeStroke = null;
    });
    widget.onClear();
  }

  void _recognize() {
    if (_strokes.isEmpty) {
      widget.onClear();
      return;
    }
    widget.onRecognize(List.unmodifiable(_strokes));
  }
}

class _PadAction extends StatelessWidget {
  const _PadAction({
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final foreground = destructive ? KiraColors.amber : KiraColors.cream;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 86),
          child: Ink(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: KiraColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x24ffffff)),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HandwritingPainter extends CustomPainter {
  const _HandwritingPainter({
    required this.strokes,
    required this.activeStroke,
  });

  final List<ImeStroke> strokes;
  final ImeStroke? activeStroke;

  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = const Color(0x14ffffff)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      guide,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      guide,
    );

    final paint = Paint()
      ..color = KiraColors.cream
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in [
      ...strokes,
      if (activeStroke != null) activeStroke!
    ]) {
      if (stroke.length < 2) {
        continue;
      }
      final path = Path()..moveTo(stroke.first.x, stroke.first.y);
      for (final point in stroke.skip(1)) {
        path.lineTo(point.x, point.y);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HandwritingPainter oldDelegate) {
    return oldDelegate.strokes != strokes ||
        oldDelegate.activeStroke != activeStroke;
  }
}
