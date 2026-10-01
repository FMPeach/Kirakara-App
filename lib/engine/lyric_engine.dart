import '../domain/lyric_project.dart';

abstract class LyricEngine {
  Future<RenderedLyricLines> renderAt({
    required LyricProject project,
    required Duration position,
  });
}

class RenderedLyricLines {
  const RenderedLyricLines({
    required this.ruby,
    required this.currentPrefix,
    required this.currentTail,
    required this.nextLine,
  });

  final String ruby;
  final String currentPrefix;
  final String currentTail;
  final String nextLine;
}
