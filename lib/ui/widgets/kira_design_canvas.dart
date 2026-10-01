import 'package:flutter/material.dart';

class KiraDesignCanvas extends StatelessWidget {
  const KiraDesignCanvas({
    super.key,
    required this.child,
  });

  static const Size stageSize = Size(1920, 1080);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: stageSize.width,
          height: stageSize.height,
          child: child,
        ),
      ),
    );
  }
}
