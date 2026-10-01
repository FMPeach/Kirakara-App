import 'package:flutter/material.dart';

import '../theme/kirakara_theme.dart';

class TouchKeyboardLayout extends StatelessWidget {
  const TouchKeyboardLayout({
    super.key,
    required this.keys,
    required this.onKey,
    this.crossAxisCount = 6,
  });

  final List<String> keys;
  final ValueChanged<String> onKey;
  final int crossAxisCount;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final keyLabel = keys[index];
        final action = keyLabel.length > 1;
        return _KeyboardKey(
          label: keyLabel,
          action: action,
          onTap: () => onKey(keyLabel),
        );
      },
    );
  }
}

class _KeyboardKey extends StatelessWidget {
  const _KeyboardKey({
    required this.label,
    required this.action,
    required this.onTap,
  });

  final String label;
  final bool action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          decoration: BoxDecoration(
            color: KiraColors.surface2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x1affffff)),
          ),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: action ? KiraColors.amber : KiraColors.cream,
                fontSize: action ? 15 : 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
