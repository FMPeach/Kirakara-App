import 'package:flutter/material.dart';

import '../theme/kirakara_theme.dart';

class KtvIconButton extends StatelessWidget {
  const KtvIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.label,
    this.active = false,
    this.foregroundColor,
    this.width,
  });

  final IconData icon;
  final String? label;
  final VoidCallback? onPressed;
  final bool active;
  final Color? foregroundColor;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 80,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          backgroundColor: active ? KiraColors.red : KiraColors.surface2,
          foregroundColor: foregroundColor ?? KiraColors.cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: KiraColors.line),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30),
            if (label != null) ...[
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  label!,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 58,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: IconButton.filled(
        onPressed: onPressed,
        icon: Icon(icon, size: size * 0.52),
        style: IconButton.styleFrom(
          backgroundColor: KiraColors.surface3,
          foregroundColor: KiraColors.cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: KiraColors.line),
          ),
        ),
      ),
    );
  }
}
