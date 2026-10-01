import '../domain/song.dart';

enum SlotState { empty, preparing, ready, failed }

class PlaybackSlot {
  PlaybackSlot({required this.songId});

  final String songId;
  SlotState state = SlotState.empty;
  int generation = 0;
  int priority = 2; // 0=active, 1=standby, 2+=queue
  Song? song;

  String? videoPath;
  String? vocalPath;
  String? instPath;
  String? krlPath;
  String? error;

  /// 下载进度：total / downloaded (bytes)
  int downloadTotal = 0;
  int downloadedBytes = 0;
  bool downloadComplete = false;

  bool get isReady => state == SlotState.ready;
}
