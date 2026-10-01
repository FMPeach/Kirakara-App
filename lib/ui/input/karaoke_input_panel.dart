import 'package:flutter/material.dart';

import '../../ime/ime_controller.dart';
import '../../ime/ime_mode.dart';
import '../theme/kirakara_theme.dart';
import 'candidate_bar.dart';
import 'handwriting_pad.dart';
import 'touch_keyboard_layout.dart';

class KaraokeInputPanel extends StatelessWidget {
  const KaraokeInputPanel({
    super.key,
    required this.activeTab,
    required this.placeholder,
    required this.controller,
    required this.searchFocusNode,
    required this.imeController,
    required this.onTab,
    required this.onSearch,
    this.tabs = const ['歌名', '歌手', '分类'],
  });

  final String activeTab;
  final String placeholder;
  final TextEditingController controller;
  final FocusNode searchFocusNode;
  final ImeController imeController;
  final List<String> tabs;
  final ValueChanged<String> onTab;
  final VoidCallback onSearch;

  static const _letters = [
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    '退格',
    '清空',
    '空格',
    '搜索',
  ];
  static const _dialKeys = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '退格',
    '0',
    '搜索',
  ];
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: const Color(0x0EFFFFFF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x14FFFFFF)),
              ),
              child: Row(
                children: [
                  for (final tab in tabs)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Material(
                          color: activeTab == tab
                              ? KiraColors.red
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            onTap: () => onTab(tab),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              height: 50,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: activeTab == tab
                                      ? const Color(0x38FFFFFF)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Text(
                                tab,
                                style: TextStyle(
                                  color: activeTab == tab
                                      ? Colors.white
                                      : const Color(0xC7FFFFFF),
                                  fontSize: 19,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 60,
              child: TextField(
                controller: controller,
                focusNode: searchFocusNode,
                onSubmitted: (_) => onSearch(),
                decoration: InputDecoration(
                  hintText: placeholder,
                  hintStyle: const TextStyle(
                    color: Color(0x8effffff),
                    fontWeight: FontWeight.w700,
                  ),
                  prefixIcon:
                      const Icon(Icons.search, color: Color(0xccffffff)),
                  filled: true,
                  fillColor: const Color(0x18ffffff),
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: KiraColors.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: KiraColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: KiraColors.lineStrong),
                  ),
                ),
                style: const TextStyle(
                  color: KiraColors.cream,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Spacer(),
            AnimatedBuilder(
              animation: imeController,
              builder: (context, _) {
                final composition = imeController.composition;
                return CandidateBar(
                  preedit: composition.preedit,
                  candidates: composition.candidates,
                  errorMessage: composition.errorMessage,
                  onCandidateSelected: imeController.commitCandidate,
                );
              },
            ),
            AnimatedBuilder(
              animation: imeController,
              builder: (context, _) {
                if (imeController.mode == ImeMode.handwriting) {
                  return HandwritingPad(
                    onRecognize: imeController.recognizeHandwritingStrokes,
                    onClear: imeController.clearComposition,
                    onBackspace: imeController.backspaceSearchText,
                    clearRevision: imeController.handwritingClearRevision,
                  );
                }
                if (imeController.mode == ImeMode.numeric) {
                  return Center(
                    child: SizedBox(
                      width: 276,
                      child: TouchKeyboardLayout(
                        keys: _dialKeys,
                        crossAxisCount: 3,
                        onKey: _handleKey,
                      ),
                    ),
                  );
                }
                return TouchKeyboardLayout(keys: _letters, onKey: _handleKey);
              },
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.only(top: 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: KiraColors.line)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final mode in ImeMode.values) ...[
                    AnimatedBuilder(
                      animation: imeController,
                      builder: (context, _) {
                        return TextButton(
                          onPressed: () => imeController.setMode(mode),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            foregroundColor: imeController.mode == mode
                                ? KiraColors.amber
                                : KiraColors.muted,
                          ),
                          child: Text(
                            mode.label,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        );
                      },
                    ),
                    if (mode != ImeMode.values.last) const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleKey(String key) {
    searchFocusNode.unfocus();
    if (key == '搜索') {
      imeController.commitRaw().then((_) => onSearch());
      return;
    }
    imeController.handleKeyboardKey(key);
  }
}

BoxDecoration _panelDecoration() {
  return BoxDecoration(
    color: KiraColors.surface,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: KiraColors.line),
  );
}
