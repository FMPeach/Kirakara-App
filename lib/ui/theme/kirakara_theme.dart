import 'package:flutter/material.dart';

class KiraColors {
  static const bg = Color(0xff0d0e10);
  static const page = Color(0xff111216);
  static const surface = Color(0xff18191d);
  static const surface2 = Color(0xff222329);
  static const surface3 = Color(0xff2b2d34);
  static const line = Color(0x1fffffff);
  static const lineStrong = Color(0x33ffffff);
  static const text = Color(0xfff7f4ee);
  static const muted = Color(0xffa8a6a0);
  static const cream = Color(0xfff4eee2);
  static const red = Color(0xffdd3e38);
  static const redDark = Color(0xffa91f1a);
  static const amber = Color(0xfff2b84b);
  static const teal = Color(0xff22c59b);
  static const blue = Color(0xff3277f2);
  static const cyan = Color(0xff14bfd0);
  static const pink = Color(0xffe95895);
  static const violet = Color(0xff4c36b8);
  static const orange = Color(0xffdc7a32);
}

ThemeData buildKirakaraTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Colors.black,
    colorScheme: base.colorScheme.copyWith(
      primary: KiraColors.red,
      secondary: KiraColors.amber,
      surface: KiraColors.surface,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: KiraColors.text,
      displayColor: KiraColors.text,
      fontFamily: 'Microsoft YaHei UI',
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Noto Sans CJK SC',
        'Noto Sans CJK JP',
        'Yu Gothic UI',
        'Yu Gothic',
        'Segoe UI',
      ],
    ),
  );
}
