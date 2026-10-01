import 'package:flutter/widgets.dart';

class SearchQueryController extends ChangeNotifier {
  SearchQueryController({String text = ''}) {
    textController = TextEditingController(text: text);
    textController.addListener(_notifyQueryChanged);
  }

  late final TextEditingController textController;

  String get text => textController.text;

  void setText(String value) {
    if (value == textController.text) {
      return;
    }
    textController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void appendText(String value) {
    if (value.isEmpty) {
      return;
    }
    setText('$text$value');
  }

  void backspace() {
    if (text.isEmpty) {
      return;
    }
    final chars = text.characters;
    setText(chars.skipLast(1).toString());
  }

  void clear() {
    setText('');
  }

  void _notifyQueryChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    textController.removeListener(_notifyQueryChanged);
    textController.dispose();
    super.dispose();
  }
}
