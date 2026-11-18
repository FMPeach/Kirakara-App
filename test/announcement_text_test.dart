import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/announcement_text.dart';
import 'package:kirakara_app/domain/artist.dart';
import 'package:kirakara_app/domain/song.dart';

void main() {
  const current = Song(
    id: 'current',
    title: '当前曲目',
    category: '',
    assets: [],
    artist: Artist(id: 'artist', name: '演唱者'),
  );
  const next = Song(id: 'next', title: '待播曲目', category: '', assets: []);

  test('empty announcement and queue retain the App idle wording', () {
    expect(
        buildAnnouncementItems(
            customAnnouncement: ' \n', current: null, next: null),
        [
          '当前播放：等待点歌',
          '下一首：暂无，快去点一首吧',
        ]);
  });

  test('custom text uses the same order and separator as the controller', () {
    final items = buildAnnouncementItems(
        customAnnouncement: '  欢迎点歌  ', current: current, next: next);
    expect(items.join(announcementSeparator),
        '欢迎点歌  ·  当前播放：当前曲目 - 演唱者  ·  下一首：待播曲目 - 未知歌手');
  });

  test('last song retains the empty next-song prompt', () {
    expect(
        buildAnnouncementItems(
            customAnnouncement: '', current: current, next: null),
        [
          '当前播放：当前曲目 - 演唱者',
          '下一首：暂无，快去点一首吧',
        ]);
  });

  test('a queued song is included before any current song starts', () {
    expect(
        buildAnnouncementItems(
            customAnnouncement: '', current: null, next: next),
        [
          '当前播放：等待点歌',
          '下一首：待播曲目 - 未知歌手',
        ]);
  });

  test('transient status is optional and belongs to the controller only', () {
    for (final status in ['正在加载', '正在缓冲', '已停止', '暂停中']) {
      final controller = buildAnnouncementItems(
          customAnnouncement: '',
          current: current,
          next: next,
          currentStatus: status);
      final audience = buildAnnouncementItems(
          customAnnouncement: '', current: current, next: next);
      expect(controller[0], '${audience[0]} · $status');
      expect(audience.join(announcementSeparator), isNot(contains(status)));
    }
  });
}
