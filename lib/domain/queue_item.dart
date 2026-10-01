import 'song.dart';

class QueueItem {
  QueueItem({
    required this.id,
    required this.song,
    required this.addedAt,
    this.requestedBy = '本机',
  });

  final String id;
  final Song song;
  final DateTime addedAt;
  final String requestedBy;
}
