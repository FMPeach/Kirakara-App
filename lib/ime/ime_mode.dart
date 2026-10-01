enum ImeMode {
  english,
  numeric,
  pinyin,
  japaneseRomaji,
  handwriting,
}

extension ImeModeLabel on ImeMode {
  String get label {
    return switch (this) {
      ImeMode.english => '英文',
      ImeMode.numeric => '数字',
      ImeMode.pinyin => '拼音',
      ImeMode.japaneseRomaji => '日语罗马音',
      ImeMode.handwriting => '手写',
    };
  }
}
