import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/media_asset.dart';
import 'package:kirakara_app/domain/song.dart';
import 'package:kirakara_app/services/playback_download_scheduler.dart';

Song _song(String id, {int version = 1}) => Song(
      id: id,
      title: id,
      category: 'Test',
      isExternal: true,
      assets: [
        MediaAsset(
          id: '$id-video',
          type: MediaAssetType.video,
          version: version,
          uri: Uri.parse('https://media.test/$id.mp4'),
        ),
      ],
    );

class _Downloads {
  _Downloads() {
    scheduler = PlaybackDownloadScheduler(
      download: (song) {
        started.add(song.id);
        final task = Completer<void>();
        pending[PlaybackDownloadScheduler.identityOf(song)] = task;
        return task.future;
      },
      isCached: (song) => cached.contains(
        PlaybackDownloadScheduler.identityOf(song),
      ),
      setPriority: (songId, priority) => priorities[songId] = priority,
      onFailure: (song, _) => failures.add(song.id),
    );
  }

  late final PlaybackDownloadScheduler scheduler;
  final started = <String>[];
  final cached = <String>{};
  final pending = <String, Completer<void>>{};
  final priorities = <String, int>{};
  final failures = <String>[];

  void update(List<Song> songs, {Song? active, int lookahead = 3}) {
    scheduler.update(
      queuedSongs: songs,
      activeSong: active,
      lookahead: lookahead,
    );
  }

  void finish(Song song) {
    final key = PlaybackDownloadScheduler.identityOf(song);
    cached.add(key);
    pending.remove(key)!.complete();
  }

  void fail(Song song) {
    pending
        .remove(PlaybackDownloadScheduler.identityOf(song))!
        .completeError(StateError('download failed'));
  }
}

void main() {
  const fiveSeconds = Duration(seconds: 5);

  testWidgets('当前和下一首立即准备，后排每五秒只放行一首并保持窗口上限', (tester) async {
    final downloads = _Downloads();
    final active = _song('active');
    final queue = List.generate(5, (i) => _song('queued-$i'));
    downloads.update(queue, active: active);
    await tester.pump();
    expect(downloads.started, ['active', 'queued-0']);
    await tester.pump(const Duration(milliseconds: 4999));
    expect(downloads.started, hasLength(2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(downloads.started, ['active', 'queued-0', 'queued-1']);
    await tester.pump(fiveSeconds);
    expect(downloads.started, ['active', 'queued-0', 'queued-1', 'queued-2']);
    await tester.pump(const Duration(minutes: 1));
    expect(downloads.started, hasLength(4));
    downloads.scheduler.dispose();
  });

  testWidgets('点歌列表不变且当前首不切歌，完整缓存自动滚动到列表末尾', (tester) async {
    final downloads = _Downloads();
    final queue = List.generate(8, (i) => _song('queued-$i'));
    downloads.update(queue, lookahead: 1);
    await tester.pump();
    for (var i = 0; i < queue.length; i++) {
      expect(downloads.started.last, queue[i].id);
      downloads.finish(queue[i]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 4999));
      expect(downloads.started, hasLength(i + 1));
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(downloads.started, queue.map((song) => song.id));
    downloads.scheduler.dispose();
  });

  testWidgets('完整结束事件重新留足五秒，不会沿用即将到期的旧补位事件', (tester) async {
    final downloads = _Downloads();
    final queue = List.generate(4, (i) => _song('queued-$i'));
    downloads.update(queue);
    await tester.pump();
    await tester.pump(fiveSeconds);
    expect(downloads.started, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
    downloads.finish(queue.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 4999));
    expect(downloads.started, hasLength(2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(downloads.started.last, queue[2].id);
    downloads.scheduler.dispose();
  });

  testWidgets('已缓存项和重复点歌不占窗口，也不额外等待五秒', (tester) async {
    final downloads = _Downloads();
    final first = _song('first');
    final cached = _song('cached');
    final last = _song('last');
    downloads.cached.add(PlaybackDownloadScheduler.identityOf(cached));
    downloads.update([first, _song('first'), cached, last], lookahead: 1);
    await tester.pump();
    expect(downloads.started, ['first']);
    downloads.finish(first);
    await tester.pump();
    await tester.pump(fiveSeconds);
    expect(downloads.started, ['first', 'last']);
    downloads.scheduler.dispose();
  });

  testWidgets('顶歌绕过冷却，当前首优先级不被队列内的重复歌曲覆盖', (tester) async {
    final downloads = _Downloads();
    final active = _song('active');
    final first = _song('first');
    final promoted = _song('promoted');
    downloads.update([first, promoted], active: active);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    downloads.update([promoted, first, _song('active')], active: active);
    await tester.pump();
    expect(downloads.started, ['active', 'first', 'promoted']);
    expect(downloads.priorities['active'], 0);
    expect(downloads.priorities['promoted'], 1);
    expect(downloads.priorities['first'], 2);
    downloads.scheduler.dispose();
  });

  testWidgets('补位时使用最新队列，删歌不会启动旧候选，清空队列取消补位', (tester) async {
    final downloads = _Downloads();
    final first = _song('first');
    final removed = _song('removed');
    final remaining = _song('remaining');
    downloads.update([first, removed, remaining]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    downloads.update([first, remaining]);
    await tester.pump(const Duration(seconds: 3));
    expect(downloads.started, ['first', 'remaining']);
    downloads.update([]);
    downloads.finish(first);
    downloads.finish(remaining);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(downloads.started, ['first', 'remaining']);
    expect(downloads.priorities['remaining'], 4);
    downloads.scheduler.dispose();
  });

  testWidgets('调低窗口不打断已有下载，空位不足时不新开后台任务', (tester) async {
    final downloads = _Downloads();
    final queue = List.generate(5, (i) => _song('queued-$i'));
    downloads.update(queue);
    await tester.pump();
    await tester.pump(fiveSeconds);
    await tester.pump(fiveSeconds);
    expect(downloads.started, hasLength(3));
    downloads.update(queue, lookahead: 1);
    downloads.finish(queue[0]);
    downloads.finish(queue[1]);
    await tester.pump();
    await tester.pump(fiveSeconds);
    expect(downloads.started, hasLength(3));
    downloads.finish(queue[2]);
    await tester.pump();
    await tester.pump(fiveSeconds);
    expect(downloads.started.last, queue[3].id);
    downloads.scheduler.dispose();
  });

  testWidgets('最终失败释放窗口并冷却，不循环重试失败曲目', (tester) async {
    final downloads = _Downloads();
    final first = _song('failed');
    final next = _song('next');
    downloads.update([first, next], lookahead: 1);
    await tester.pump();
    downloads.fail(first);
    await tester.pump();
    expect(downloads.failures, ['failed']);
    await tester.pump(const Duration(milliseconds: 4999));
    expect(downloads.started, ['failed']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(downloads.started, ['failed', 'next']);
    downloads.scheduler.dispose();
  });

  testWidgets('移除失败记录后重试以及不同资源版本可以重新调度', (tester) async {
    final downloads = _Downloads();
    final song = _song('retry');
    downloads.update([song]);
    await tester.pump();
    downloads.fail(song);
    await tester.pump();
    downloads.update([]);
    downloads.update([song]);
    await tester.pump();
    expect(downloads.started, ['retry', 'retry']);
    downloads.finish(song);
    await tester.pump();
    downloads.update([_song('retry', version: 2)]);
    await tester.pump();
    expect(downloads.started, ['retry', 'retry', 'retry']);
    downloads.scheduler.dispose();
  });

  testWidgets('销毁后取消计时器，晚到的下载完成也不会继续调度', (tester) async {
    final downloads = _Downloads();
    final first = _song('first');
    downloads.update([first, _song('later')]);
    await tester.pump();
    downloads.scheduler.dispose();
    downloads.finish(first);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(downloads.started, ['first']);
  });
}
