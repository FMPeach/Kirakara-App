import 'ime_candidate.dart';
import 'ime_mode.dart';

class ImeComposition {
  const ImeComposition({
    required this.mode,
    required this.rawInput,
    required this.preedit,
    required this.candidates,
    this.pageIndex = 0,
    this.hasPreviousPage = false,
    this.hasNextPage = false,
    this.errorMessage,
  });

  factory ImeComposition.empty(ImeMode mode) {
    return ImeComposition(
      mode: mode,
      rawInput: '',
      preedit: '',
      candidates: const [],
    );
  }

  final ImeMode mode;
  final String rawInput;
  final String preedit;
  final List<ImeCandidate> candidates;
  final int pageIndex;
  final bool hasPreviousPage;
  final bool hasNextPage;
  final String? errorMessage;

  ImeComposition copyWith({
    ImeMode? mode,
    String? rawInput,
    String? preedit,
    List<ImeCandidate>? candidates,
    int? pageIndex,
    bool? hasPreviousPage,
    bool? hasNextPage,
    String? errorMessage,
  }) {
    return ImeComposition(
      mode: mode ?? this.mode,
      rawInput: rawInput ?? this.rawInput,
      preedit: preedit ?? this.preedit,
      candidates: candidates ?? this.candidates,
      pageIndex: pageIndex ?? this.pageIndex,
      hasPreviousPage: hasPreviousPage ?? this.hasPreviousPage,
      hasNextPage: hasNextPage ?? this.hasNextPage,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
