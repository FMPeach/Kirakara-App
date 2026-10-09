class ServerEndpoints {
  ServerEndpoints._();

  /// Public song catalog and relative media origin.
  static final songService = Uri.parse('https://song.kirakara.moe/');

  /// Development server used only when the public endpoint is unavailable.
  static final localSongService = Uri.parse('http://localhost:7392/');
}
