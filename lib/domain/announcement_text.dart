import 'song.dart';

const announcementSeparator = '  ·  ';

/// 顶栏和观众报幕共用的文案；顶栏可另附当前播放状态。
List<String> buildAnnouncementItems({
  required String customAnnouncement,
  required Song? current,
  required Song? next,
  String currentStatus = '',
}) {
  final custom = customAnnouncement.trim();
  var currentText = '当前播放：${_songLabel(current, fallback: '等待点歌')}';
  if (currentStatus.isNotEmpty) {
    currentText += ' · $currentStatus';
  }
  return [
    if (custom.isNotEmpty) custom,
    currentText,
    next == null ? '下一首：暂无，快去点一首吧' : '下一首：${_songLabel(next)}',
  ];
}

String _songLabel(Song? song, {String fallback = '暂无'}) {
  if (song == null) return fallback;
  return '${song.title} - ${song.artist?.name ?? '未知歌手'}';
}
