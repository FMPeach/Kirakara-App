import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/ime/handwriting_stroke.dart';
import 'package:kirakara_app/ui/input/handwriting_pad.dart';
import 'package:kirakara_app/ui/theme/kirakara_theme.dart';

void main() {
  testWidgets('handwriting stroke repaints before pointer up', (tester) async {
    final recognized = <List<ImeStroke>>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildKirakaraTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: HandwritingPad(
                onRecognize: (strokes) async => recognized.add(strokes),
                onBackspace: () async {},
                onClear: () async {},
                clearRevision: 0,
              ),
            ),
          ),
        ),
      ),
    );

    final handwritingCanvas = find.descendant(
      of: find.byType(HandwritingPad),
      matching: find.byType(CustomPaint),
    );
    final paintRect = tester.getRect(handwritingCanvas);
    final gesture = await tester.startGesture(
      paintRect.topLeft + const Offset(40, 40),
    );
    await tester.pump();
    final beforeMove = tester.widget<CustomPaint>(handwritingCanvas).painter!;

    await gesture.moveTo(paintRect.topLeft + const Offset(140, 140));
    await tester.pump();
    final duringMove = tester.widget<CustomPaint>(handwritingCanvas).painter!;

    expect(identical(duringMove, beforeMove), isFalse);
    expect(duringMove.shouldRepaint(beforeMove), isTrue);
    expect(recognized, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(recognized, hasLength(1));
  });
}
