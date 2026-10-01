part of '../../screens/browse_screen.dart';

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.chevron_left, size: 28),
        label: const Text(
          '返回',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: KiraColors.surface2,
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

class _AvatarLetter extends StatelessWidget {
  const _AvatarLetter({
    required this.text,
    required this.size,
    this.fontSize,
  });

  final String text;
  final double size;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xff3f6fea),
            Color(0xffd94e91),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x29ffffff)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize ?? size * 0.42,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0x1af2b84b),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: KiraColors.amber,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: const TextStyle(
          color: KiraColors.muted,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

IconData _categoryIcon(String name) {
  return switch (name) {
    '热门' => Icons.local_fire_department,
    '动画' => Icons.auto_awesome,
    'VOCALOID' => Icons.smart_toy,
    '东方' => Icons.nights_stay,
    '经典' => Icons.star,
    '角色歌' => Icons.person,
    _ => Icons.library_music,
  };
}

BoxDecoration _panelDecoration() {
  return BoxDecoration(
    color: KiraColors.surface,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: KiraColors.line),
  );
}

BoxDecoration _cardDecoration() {
  return BoxDecoration(
    color: KiraColors.surface2,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: KiraColors.line),
  );
}
