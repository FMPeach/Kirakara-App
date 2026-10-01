import 'package:flutter/services.dart';

enum ClipboardReadFailure {
  unavailable,
  tooLarge,
}

class ClipboardReadException implements Exception {
  const ClipboardReadException(this.failure);

  final ClipboardReadFailure failure;

  String get userMessage => switch (failure) {
        ClipboardReadFailure.unavailable => '暂时无法读取剪贴板，请稍后重试',
        ClipboardReadFailure.tooLarge => '剪贴板文本过长，请只复制 Bilibili 链接或编号',
      };
}

/// Reads text only in direct response to a user action.
///
/// This service never listens to, caches, logs, or persists clipboard data.
/// The custom Windows Engine performs bounded OpenClipboard retries below the
/// standard Flutter API; stock engines continue to use their normal behavior.
class ClipboardService {
  const ClipboardService();

  static const int maxTextCodeUnits = 1024 * 1024;
  static const int _windowsBufferOverflow = 111;

  Future<String?> readText() async {
    final ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } on PlatformException catch (error) {
      if (error.details == _windowsBufferOverflow ||
          error.message == 'Clipboard text is too large') {
        throw const ClipboardReadException(ClipboardReadFailure.tooLarge);
      }
      throw const ClipboardReadException(ClipboardReadFailure.unavailable);
    }

    final text = data?.text;
    if (text == null || text.isEmpty) return null;
    if (text.length > maxTextCodeUnits) {
      throw const ClipboardReadException(ClipboardReadFailure.tooLarge);
    }
    return text;
  }
}
