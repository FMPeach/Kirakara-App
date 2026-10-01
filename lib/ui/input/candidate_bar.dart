import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ime/ime_candidate.dart';
import '../theme/kirakara_theme.dart';

class CandidateBar extends StatelessWidget {
  const CandidateBar({
    super.key,
    required this.candidates,
    required this.preedit,
    required this.onCandidateSelected,
    this.errorMessage,
  });

  final List<ImeCandidate> candidates;
  final String preedit;
  final ValueChanged<int> onCandidateSelected;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final error = errorMessage;
    return Container(
      height: 52,
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: KiraColors.line)),
      ),
      child: error != null && error.isNotEmpty
          ? _CandidateError(message: error, preedit: preedit)
          : _candidateScroller(),
    );
  }

  Widget _candidateScroller() {
    return ScrollConfiguration(
      behavior: const MaterialScrollBehavior().copyWith(
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
        },
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (preedit.isNotEmpty) ...[
              _PreeditChip(text: preedit),
              const SizedBox(width: 8),
            ],
            for (var index = 0; index < candidates.length; index++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _CandidateChip(
                  index: index,
                  candidate: candidates[index],
                  onTap: () => onCandidateSelected(index),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CandidateError extends StatelessWidget {
  const _CandidateError({required this.message, required this.preedit});

  final String message;
  final String preedit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.error_outline, size: 18, color: KiraColors.red),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: KiraColors.red,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (preedit.isNotEmpty) ...[
          const SizedBox(width: 8),
          SizedBox(width: 120, child: _PreeditChip(text: preedit)),
        ],
      ],
    );
  }
}

class _PreeditChip extends StatelessWidget {
  const _PreeditChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0x12ffffff),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: KiraColors.line),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: KiraColors.muted,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CandidateChip extends StatelessWidget {
  const _CandidateChip({
    required this.index,
    required this.candidate,
    required this.onTap,
  });

  final int index;
  final ImeCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: KiraColors.surface2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: KiraColors.line),
          ),
          child: Center(
            child: Text(
              '${index + 1} ${candidate.text}',
              style: const TextStyle(
                color: KiraColors.cream,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
