import 'package:flutter/material.dart';

import '../theme/kirakara_theme.dart';

class MockQrCode extends StatelessWidget {
  const MockQrCode({
    super.key,
    this.caption,
    this.size = 116,
  });

  final String? caption;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: KiraColors.cream,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Expanded(
            child: GridView.count(
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 7,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              children: List.generate(49, (index) {
                final filled = index % 2 == 0 ||
                    index == 10 ||
                    index == 17 ||
                    index == 25 ||
                    index == 33 ||
                    index == 41;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: filled ? KiraColors.page : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
          ),
          if (caption != null)
            Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: KiraColors.page,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}
