import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kirakara_app/data/local_db/local_database.dart';
import 'package:kirakara_app/domain/lyric_project.dart';
import 'package:kirakara_app/domain/media_asset.dart';
import 'package:kirakara_app/domain/playback_state.dart';
import 'package:kirakara_app/domain/queue_item.dart';
import 'package:kirakara_app/domain/song.dart';
import 'package:kirakara_app/services/bilibili_account_service.dart';
import 'package:kirakara_app/services/display_manager.dart';
import 'package:kirakara_app/services/lan_server.dart';
import 'package:kirakara_app/services/native_window_service.dart';
import 'package:kirakara_app/services/playback_asset_cache.dart';
import 'package:kirakara_app/services/playback_service.dart';
import 'package:kirakara_app/services/playback_slot_manager.dart';
import 'package:kirakara_app/services/queue_service.dart';
import 'package:kirakara_app/services/search_service.dart';

/// 种子 3 首测试歌曲到内存 DB。
SearchService _testSearch() {
  final db = LocalDatabase(dbPath: ':memory:');
  db.open();
  _seedTestData(db);
  return SearchService(db: db)..invalidateCache();
}

void _seedTestData(LocalDatabase db) {
  db.db.execute(
      "INSERT INTO songs (id, title, artist_line) VALUES ('20001', 'Qi Feng', 'Nanatsukaze')");
  db.db.execute(
      "INSERT INTO songs (id, title, artist_line) VALUES ('20002', 'Ikari', 'Kanzaki Iori')");
  db.db.execute(
      "INSERT INTO songs (id, title, artist_line) VALUES ('20003', 'agony', 'KOTOKO')");
  db.db.execute("INSERT INTO song_tags (song_id, tag) VALUES ('20001', 'JP')");
  db.db.execute(
      "INSERT INTO song_tags (song_id, tag) VALUES ('20002', 'VOCALOID')");
  db.db.execute(
      "INSERT INTO song_tags (song_id, tag) VALUES ('20003', 'Anime')");
  db.db.execute("INSERT INTO song_tags (song_id, tag) VALUES ('20003', 'KRL')");
  db.db.execute(
      "INSERT INTO categories (id, type, name, note) VALUES ('101', 'song', 'Jpop', 'JP Pop')");
  db.db.execute(
      "INSERT INTO song_categories (song_id, category_id) VALUES ('20001', '101')");
  db.db.execute(
      "INSERT INTO song_categories (song_id, category_id) VALUES ('20003', '101')");
}

class _FakeNativeWindowService extends NativeWindowService {
  const _FakeNativeWindowService(this.displays);

  final List<Map<String, Object?>> displays;

  @override
  Future<List<Map<String, Object?>>> getDisplays() async => displays;
}

class _FakeAssetHttpClient extends http.BaseClient {
  _FakeAssetHttpClient({
    this.videoStarted,
    this.releaseVideo,
    this.audioStarted,
    this.releaseAudio,
    this.accompanimentStarted,
    this.releaseAccompaniment,
    this.videoTotalLength = 4,
    this.videoChunks = const [
      [1, 2],
      [3, 4],
    ],
  });

  final Completer<void>? videoStarted;
  final Completer<void>? releaseVideo;
  final Completer<void>? audioStarted;
  final Completer<void>? releaseAudio;
  final Completer<void>? accompanimentStarted;
  final Completer<void>? releaseAccompaniment;
  final int videoTotalLength;
  final List<List<int>> videoChunks;
  int fullVideoRequests = 0;
  int notFoundRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (path == '/media/video.mp4') {
      final range = request.headers[HttpHeaders.rangeHeader];
      if (range != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        final start = match == null ? 0 : int.parse(match.group(1)!);
        final endText = match?.group(2) ?? '';
        final end = endText.isEmpty ? start + 3 : int.parse(endText);
        final length = end - start + 1;
        return http.StreamedResponse(
          Stream.value(List<int>.filled(length, 9)),
          HttpStatus.partialContent,
          contentLength: length,
          headers: {
            HttpHeaders.acceptRangesHeader: 'bytes',
            HttpHeaders.contentLengthHeader: '$length',
            HttpHeaders.contentRangeHeader:
                'bytes $start-$end/$videoTotalLength',
          },
        );
      }
      fullVideoRequests++;
      if (videoStarted != null && !videoStarted!.isCompleted) {
        videoStarted!.complete();
      }
      final controller = StreamController<List<int>>();
      unawaited(() async {
        controller.add(videoChunks.first);
        final gate = releaseVideo;
        if (gate != null) {
          await gate.future;
        }
        for (final chunk in videoChunks.skip(1)) {
          controller.add(chunk);
        }
        await controller.close();
      }());
      return http.StreamedResponse(
        controller.stream,
        HttpStatus.ok,
        contentLength: videoTotalLength,
        headers: {HttpHeaders.contentLengthHeader: '$videoTotalLength'},
      );
    }
    if (path == '/media/vocal.m4a') {
      if (audioStarted != null && !audioStarted!.isCompleted) {
        audioStarted!.complete();
      }
      final controller = StreamController<List<int>>();
      unawaited(() async {
        final gate = releaseAudio;
        if (gate != null) await gate.future;
        controller.add([5, 6, 7]);
        await controller.close();
      }());
      return http.StreamedResponse(
        controller.stream,
        HttpStatus.ok,
        contentLength: 3,
        headers: {HttpHeaders.contentLengthHeader: '3'},
      );
    }
    if (path == '/media/inst.m4a') {
      if (accompanimentStarted != null && !accompanimentStarted!.isCompleted) {
        accompanimentStarted!.complete();
      }
      final controller = StreamController<List<int>>();
      unawaited(() async {
        final gate = releaseAccompaniment;
        if (gate != null) await gate.future;
        controller.add([8, 9, 10]);
        await controller.close();
      }());
      return http.StreamedResponse(
        controller.stream,
        HttpStatus.ok,
        contentLength: 3,
        headers: {HttpHeaders.contentLengthHeader: '3'},
      );
    }
    if (path == '/media/lyrics.krl') {
      return http.StreamedResponse(
        Stream.value('krl'.codeUnits),
        HttpStatus.ok,
        contentLength: 3,
        headers: {HttpHeaders.contentLengthHeader: '3'},
      );
    }
    notFoundRequests++;
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      HttpStatus.notFound,
    );
  }
}

class _AlwaysStatusHttpClient extends http.BaseClient {
  _AlwaysStatusHttpClient(this.statusCode);

  final int statusCode;
  int requestCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    return http.StreamedResponse(
      const Stream<List<int>>.empty(),
      statusCode,
    );
  }
}

class _ConcurrentVideoHttpClient extends http.BaseClient {
  _ConcurrentVideoHttpClient({int count = 4, this.resumableIndex})
      : started = List.generate(count, (_) => Completer<void>()),
        release = List.generate(count, (_) => Completer<void>()),
        requestCount = List.filled(count, 0),
        requestRanges = List.generate(count, (_) => <String?>[]);

  final int? resumableIndex;
  final List<Completer<void>> started;
  final List<Completer<void>> release;
  final List<int> requestCount;
  final List<List<String?>> requestRanges;
  int active = 0;
  int maxActive = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final match =
        RegExp(r'/media/video(\d+)\.mp4$').firstMatch(request.url.path);
    if (match == null) {
      return http.StreamedResponse(
        Stream.value([1]),
        HttpStatus.ok,
        contentLength: 1,
        headers: {HttpHeaders.contentLengthHeader: '1'},
      );
    }

    final index = int.parse(match.group(1)!);
    requestCount[index]++;
    final range = request.headers[HttpHeaders.rangeHeader];
    requestRanges[index].add(range);
    active++;
    if (active > maxActive) maxActive = active;
    if (!started[index].isCompleted) started[index].complete();

    var finished = false;
    void finish() {
      if (finished) return;
      finished = true;
      active--;
    }

    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(onCancel: finish);
    if (index == resumableIndex) {
      if (range != null) {
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
        );
        final remaining = 4 - start;
        unawaited(() async {
          controller.add(List<int>.filled(remaining, 9));
          unawaited(controller.close());
          finish();
        }());
        return http.StreamedResponse(
          controller.stream,
          HttpStatus.partialContent,
          contentLength: remaining,
          headers: {
            HttpHeaders.acceptRangesHeader: 'bytes',
            HttpHeaders.contentLengthHeader: '$remaining',
            HttpHeaders.contentRangeHeader: 'bytes $start-3/4',
          },
        );
      }
      unawaited(() async {
        controller.add([1, 2]);
        await release[index].future;
        if (!controller.isClosed) {
          controller.add([3, 4]);
          unawaited(controller.close());
        }
        finish();
      }());
      return http.StreamedResponse(
        controller.stream,
        HttpStatus.ok,
        contentLength: 4,
        headers: {HttpHeaders.contentLengthHeader: '4'},
      );
    }

    unawaited(() async {
      await release[index].future;
      if (!controller.isClosed) {
        controller.add([index, index + 1]);
        unawaited(controller.close());
      }
      finish();
    }());

    return http.StreamedResponse(
      controller.stream,
      HttpStatus.ok,
      contentLength: 2,
      headers: {HttpHeaders.contentLengthHeader: '2'},
    );
  }
}

void main() {
  test('queue and playback services keep room state locally', () {
    final search = _testSearch();
    final queue = QueueService();
    for (final song in search.featuredSongs.take(2)) {
      queue.addSong(song);
    }

    final first = queue.takeNext();
    final playback = PlaybackService(
      queueService: queue,
      initialItem: first,
    );
    addTearDown(playback.disposeService);

    expect(playback.state.currentSong?.id, first?.song.id);
    expect(queue.items.length, 1);

    playback.play();
    expect(playback.state.mode, PlaybackMode.playing);

    playback.next();
    expect(playback.state.currentSong?.id, search.featuredSongs[1].id);
    expect(queue.items, isEmpty);

    playback.toggleAudioTrack();
    expect(playback.state.audioTrackMode, AudioTrackMode.accompaniment);
  });

  test('failed queue rows are skipped until explicitly retried', () {
    final search = _testSearch();
    final queue = QueueService();
    final failed = queue.addSong(search.featuredSongs[0]);
    final playable = queue.addSong(search.featuredSongs[1]);

    queue.markFailed(failed.id, '下载失败');

    expect(queue.nextPlayableItem?.id, playable.id);
    expect(queue.takeNext()?.id, playable.id);
    expect(queue.items.single.id, failed.id);
    expect(queue.isFailed(failed.id), isTrue);

    queue.retry(failed.id);
    expect(queue.isFailed(failed.id), isFalse);
    expect(queue.nextPlayableItem?.id, failed.id);
  });

  test('replay emits a distinct command even when already at zero', () {
    final playback = PlaybackService(queueService: QueueService());
    addTearDown(playback.disposeService);

    expect(playback.replayRevision, 0);
    playback.replay();
    expect(playback.replayRevision, 1);
    expect(playback.state.position, Duration.zero);
    expect(playback.state.isPlaying, isTrue);

    playback.replay();
    expect(playback.replayRevision, 2);
  });

  test('engine position sync does not rebuild controller listeners', () {
    final search = _testSearch();
    final playback = PlaybackService(
      queueService: QueueService(),
      initialItem: QueueItem(
        id: 'current',
        song: search.featuredSongs.first,
        requestedBy: 'test',
        addedAt: DateTime(2026),
      ),
    );
    addTearDown(playback.disposeService);
    var notifications = 0;
    playback.addListener(() => notifications++);

    expect(
      playback.syncEnginePosition(const Duration(seconds: 1)),
      isTrue,
    );
    expect(playback.state.position, const Duration(seconds: 1));
    expect(notifications, 0);

    playback.pause();
    expect(notifications, 1);
  });

  test('starting a queued song consumes it instead of duplicating up next', () {
    final search = _testSearch();
    final queue = QueueService();
    final playback = PlaybackService(queueService: queue);
    addTearDown(playback.disposeService);

    final item = queue.addSong(search.featuredSongs.first);
    playback.setCurrentFromQueue(item, startPlaying: true);

    expect(playback.state.currentItem?.id, item.id);
    expect(playback.state.upNext, isNull);
    expect(queue.items, isEmpty);
  });

  test('starting an empty-room song does not notify the queue', () {
    final search = _testSearch();
    final queue = QueueService();
    var queueNotifications = 0;
    queue.addListener(() => queueNotifications++);
    final playback = PlaybackService(queueService: queue);
    addTearDown(playback.disposeService);

    playback.setCurrentSong(search.featuredSongs.first, startPlaying: true);

    expect(playback.state.currentSong?.id, search.featuredSongs.first.id);
    expect(playback.state.isPlaying, isTrue);
    expect(queue.items, isEmpty);
    expect(queueNotifications, 0);
  });

  test('starting a bumped song consumes it instead of duplicating up next', () {
    final search = _testSearch();
    final queue = QueueService();
    final playback = PlaybackService(queueService: queue);
    addTearDown(playback.disposeService);

    final item = queue.bumpToNext(search.featuredSongs.first);
    playback.setCurrentFromQueue(item, startPlaying: true);

    expect(playback.state.currentItem?.id, item.id);
    expect(playback.state.upNext, isNull);
    expect(queue.items, isEmpty);
  });

  test('advancing to the final queued song clears stale up next', () {
    final search = _testSearch();
    final queue = QueueService();
    for (final song in search.featuredSongs.take(2)) {
      queue.addSong(song);
    }

    final first = queue.takeNext();
    final playback = PlaybackService(
      queueService: queue,
      initialItem: first,
    );
    addTearDown(playback.disposeService);

    playback.refreshUpNext();
    expect(playback.state.upNext?.song.id, search.featuredSongs[1].id);

    playback.next();
    expect(playback.state.currentSong?.id, search.featuredSongs[1].id);
    expect(playback.state.upNext, isNull);
    expect(queue.items, isEmpty);
  });

  test('taking next preserves its prepared standby until consumption',
      () async {
    Song externalSong(String id) => Song(
          id: id,
          title: id,
          category: 'External',
          isExternal: true,
          assets: [
            MediaAsset(
              id: '$id-video',
              type: MediaAssetType.video,
              uri: Uri.parse('https://media.test/$id.mp4'),
            ),
          ],
        );

    final queue = QueueService();
    final slots = PlaybackSlotManager(queueService: queue);
    addTearDown(slots.dispose);
    final second = queue.addSong(externalSong('external-second'));
    final third = queue.addSong(externalSong('external-third'));
    await Future<void>.delayed(Duration.zero);
    expect(slots.preparedSongId, second.song.id);

    final taken = queue.takeNext();
    expect(taken?.id, second.id);
    final consumed = slots.consumeStandby(taken!.song.id);
    expect(consumed?.songId, second.song.id);

    await Future<void>.delayed(Duration.zero);
    expect(slots.preparedSongId, third.song.id);
  });

  test('refreshing up next clears stale value when queue becomes empty', () {
    final search = _testSearch();
    final queue = QueueService();
    for (final song in search.featuredSongs.take(2)) {
      queue.addSong(song);
    }

    final first = queue.takeNext();
    final playback = PlaybackService(
      queueService: queue,
      initialItem: first,
    );
    addTearDown(playback.disposeService);

    playback.refreshUpNext();
    final staleUpNext = playback.state.upNext;
    expect(staleUpNext, isNotNull);

    queue.remove(staleUpNext!.id);
    playback.refreshUpNext();
    expect(playback.state.upNext, isNull);
  });

  test('agony sample is searchable from the test catalog', () {
    final search = _testSearch();

    final byTitle = search.searchSongs('agony');
    expect(byTitle.single.id, '20003');
    expect(
        search.searchSongs('KOTOKO').map((song) => song.id), contains('20003'));

    final song = byTitle.single;
    expect(song.artist?.name, 'KOTOKO');
    expect(song.category, 'Jpop');
    expect(song.tags, contains('KRL'));
  });

  test('LAN search returns catalog index without duration metadata', () async {
    final search = _testSearch();
    final queue = QueueService();
    final playback = PlaybackService(queueService: queue);
    final account = BilibiliAccountService(
      sessionFilePath: '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'kirakara_bilibili_test_$pid.json',
    );
    final server = LanServer(
      queueService: queue,
      searchService: search,
      playbackService: playback,
      bilibiliAccountService: account,
    );
    addTearDown(playback.disposeService);
    addTearDown(account.dispose);
    addTearDown(server.stop);

    await server.start(port: 0);
    final uri = Uri.parse(
      'http://127.0.0.1:${server.localUri!.port}/api/search?q=agony',
    );
    final request = await HttpClient().getUrl(uri);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    final payload = jsonDecode(body) as List<dynamic>;
    final song = payload.single as Map<String, dynamic>;

    expect(song['id'], '20003');
    expect(song.containsKey('durationSeconds'), isFalse);
  });

  test('LAN server supports a loopback-isolated smoke binding', () async {
    final search = _testSearch();
    final queue = QueueService();
    final playback = PlaybackService(queueService: queue);
    final account = BilibiliAccountService(
      sessionFilePath: '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'kirakara_bilibili_loopback_test_$pid.json',
    );
    final server = LanServer(
      queueService: queue,
      searchService: search,
      playbackService: playback,
      bilibiliAccountService: account,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(playback.disposeService);
    addTearDown(account.dispose);
    addTearDown(server.stop);

    await server.start(port: 0);

    expect(server.localUri!.host, InternetAddress.loopbackIPv4.address);
    final client = HttpClient();
    addTearDown(client.close);
    final response = await (await client.getUrl(server.localUri!)).close();
    expect(response.statusCode, HttpStatus.ok);
    await response.drain<void>();
  });

  test('playback cache scopes a custom root to the current app session',
      () async {
    final cacheRoot =
        await Directory.systemTemp.createTemp('kirakara_cache_root_test_');
    final marker = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'kirakara_cache_session_$pid.path',
    );
    final session = Directory(
      '${cacheRoot.path}${Platform.pathSeparator}session_$pid',
    );
    addTearDown(() {
      if (marker.existsSync()) marker.deleteSync();
      if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
    });

    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheRoot: cacheRoot,
    );
    addTearDown(cache.dispose);

    expect(session.existsSync(), isTrue);
    expect(marker.existsSync(), isTrue);
    expect((await marker.readAsString()).trim(), session.absolute.path);

    cache.clear();
    expect(session.existsSync(), isFalse);
    expect(marker.existsSync(), isFalse);
    expect(cacheRoot.existsSync(), isTrue);
  });

  test('playback cache waits for audio and lyrics but not video', () async {
    final videoStarted = Completer<void>();
    final releaseVideo = Completer<void>();

    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });

    const baseUrl = 'http://catalog.test';
    final cache = PlaybackAssetCache(
      baseUrl: baseUrl,
      cacheDir: cacheDir,
      videoReadyBytes: 2,
      httpClient: _FakeAssetHttpClient(),
      mediaHttpClient: _FakeAssetHttpClient(
        videoStarted: videoStarted,
        releaseVideo: releaseVideo,
      ),
    );
    addTearDown(cache.dispose);

    final video = MediaAsset(
      id: 'song-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/media/video.mp4'),
    );
    final vocal = MediaAsset(
      id: 'song-vocal',
      type: MediaAssetType.vocal,
      uri: Uri.parse('/media/vocal.m4a'),
    );
    final lyric = MediaAsset(
      id: 'song-krl',
      type: MediaAssetType.lyric,
      uri: Uri.parse('/media/lyrics.krl'),
    );
    final song = Song(
      id: 'song',
      title: 'Progressive',
      category: 'Test',
      assets: [video, vocal, lyric],
      lyricProject: LyricProject(
        id: 'song-krl',
        songId: 'song',
        krlUri: lyric.uri,
        version: 1,
      ),
    );

    await cache.ensurePlaybackAssets(song).timeout(
          const Duration(seconds: 1),
          onTimeout: () => fail('playback preparation waited for video'),
        );
    await videoStarted.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () => fail('video prefetch was not started'),
    );

    expect(vocal.cachedPath, isNotNull);
    expect(File(vocal.cachedPath!).existsSync(), isTrue);
    expect(song.lyricProject!.cachedPath, isNotNull);
    expect(File(song.lyricProject!.cachedPath!).readAsStringSync(), 'krl');
    expect(video.cachedPath, isNull);
    final playbackUrl = cache.playbackPathFor(video);
    expect(playbackUrl, isNotNull);
    expect(playbackUrl, startsWith('http://127.0.0.1:'));

    final rangeResponse = await http.get(
      Uri.parse(playbackUrl!),
      headers: {HttpHeaders.rangeHeader: 'bytes=0-1'},
    );
    expect(rangeResponse.statusCode, HttpStatus.partialContent);
    expect(
        rangeResponse.headers[HttpHeaders.contentRangeHeader], 'bytes 0-1/4');
    expect(rangeResponse.bodyBytes, [1, 2]);

    releaseVideo.complete();
    for (var i = 0; i < 20 && video.cachedPath == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(video.cachedPath, isNotNull);
    expect(File(video.cachedPath!).existsSync(), isTrue);
    expect(cache.playbackPathFor(video), startsWith('http://127.0.0.1:'));
  });

  test('playback cache waits for the configured persisted video runway',
      () async {
    final videoStarted = Completer<void>();
    final releaseVideo = Completer<void>();
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_runway_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      videoReadyBytes: 4,
      httpClient: _FakeAssetHttpClient(),
      mediaHttpClient: _FakeAssetHttpClient(
        videoStarted: videoStarted,
        releaseVideo: releaseVideo,
      ),
    );
    addTearDown(cache.dispose);
    final video = MediaAsset(
      id: 'runway-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/media/video.mp4'),
    );
    final song = Song(
      id: 'runway-song',
      title: 'Runway',
      category: 'Test',
      assets: [video],
    );

    var ready = false;
    final preparation = cache.ensurePlaybackAssets(song).then((_) {
      ready = true;
    });
    await videoStarted.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(ready, isFalse);

    releaseVideo.complete();
    await preparation.timeout(const Duration(seconds: 1));
    expect(ready, isTrue);
  });

  test('playback cache batches tiny network chunks with bounded buffering',
      () async {
    const chunkBytes = 1024;
    const chunkCount = 2048;
    const totalBytes = chunkBytes * chunkCount;
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_batch_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final client = _FakeAssetHttpClient(
      videoTotalLength: totalBytes,
      videoChunks: List<List<int>>.generate(
        chunkCount,
        (_) => List<int>.filled(chunkBytes, 7),
      ),
    );
    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      httpClient: client,
      mediaHttpClient: client,
    );
    addTearDown(cache.dispose);
    final video = MediaAsset(
      id: 'batch-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/media/video.mp4'),
    );
    final song = Song(
      id: 'batch-song',
      title: 'Batch',
      category: 'Test',
      assets: [video],
    );

    await cache.ensureSongAssets(song).timeout(const Duration(seconds: 2));

    final diagnostics = cache.ioDiagnostics;
    expect(diagnostics.receivedChunks, chunkCount);
    expect(diagnostics.receivedBytes, totalBytes);
    expect(diagnostics.writtenBytes, totalBytes);
    expect(diagnostics.writeCalls, lessThanOrEqualTo(3));
    expect(diagnostics.peakBufferedBytes, lessThanOrEqualTo(1024 * 1024));
    expect(diagnostics.bufferedBytes, 0);
    expect(diagnostics.preemptionHandlers, 1);
  });

  test('production cache downloads and serves video through its I/O worker',
      () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originSubscription = origin.listen((request) async {
      const bytes = <int>[10, 11, 12, 13, 14, 15, 16, 17];
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = bytes.length - 1;
      if (rangeHeader != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader)!;
        start = int.parse(match.group(1)!);
        final endText = match.group(2)!;
        if (endText.isNotEmpty) end = int.parse(endText);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
      }
      final body = bytes.sublist(start, end + 1);
      request.response.headers.contentLength = body.length;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.add(body);
      await request.response.close();
    });
    addTearDown(() async {
      await originSubscription.cancel();
      await origin.close(force: true);
    });
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_worker_cache_test_');
    final cache = PlaybackAssetCache(
      baseUrl: 'http://${origin.address.address}:${origin.port}',
      cacheDir: cacheDir,
      videoReadyBytes: 2,
      enableNativeMediaIo: false,
    );
    addTearDown(() async {
      cache.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final video = MediaAsset(
      id: 'worker-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/video.mp4'),
    );
    final song = Song(
      id: 'worker-song',
      title: 'Worker',
      category: 'Test',
      assets: [video],
    );

    await cache.ensurePlaybackAssets(song).timeout(const Duration(seconds: 3));
    final playbackUrl = cache.playbackPathFor(video);
    expect(playbackUrl, startsWith('http://127.0.0.1:'));
    final response = await http.get(
      Uri.parse(playbackUrl!),
      headers: {HttpHeaders.rangeHeader: 'bytes=2-5'},
    );
    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.bodyBytes, [12, 13, 14, 15]);

    for (var i = 0; i < 40 && video.cachedPath == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(video.cachedPath, isNotNull);
    expect(await File(video.cachedPath!).readAsBytes(),
        [10, 11, 12, 13, 14, 15, 16, 17]);
    expect(cache.ioDiagnostics.receivedBytes, 8);
    expect(cache.ioDiagnostics.preemptionHandlers, 1);
  });

  test('local progressive response flushes cached bytes before EOF', () async {
    const prefixBytes = 64 * 1024;
    const totalBytes = prefixBytes * 2;
    final releaseVideo = Completer<void>();
    addTearDown(() {
      if (!releaseVideo.isCompleted) releaseVideo.complete();
    });
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_flush_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      videoReadyBytes: prefixBytes,
      httpClient: _FakeAssetHttpClient(),
      mediaHttpClient: _FakeAssetHttpClient(
        releaseVideo: releaseVideo,
        videoTotalLength: totalBytes,
        videoChunks: [
          List<int>.filled(prefixBytes, 1),
          List<int>.filled(prefixBytes, 2),
        ],
      ),
    );
    addTearDown(() async {
      cache.dispose();
      // HttpServer.close() is intentionally fire-and-forget because
      // ChangeNotifier.dispose is synchronous. Give the loopback handler one
      // event turn to release its Windows file handle before deleting the
      // test directory.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    final client = http.Client();
    addTearDown(client.close);
    final video = MediaAsset(
      id: 'flush-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/media/video.mp4'),
    );
    final song = Song(
      id: 'flush-song',
      title: 'Flush',
      category: 'Test',
      assets: [video],
    );

    await cache.ensurePlaybackAssets(song).timeout(const Duration(seconds: 1));
    final request =
        http.Request('GET', Uri.parse(cache.playbackPathFor(video)!))
          ..headers[HttpHeaders.rangeHeader] = 'bytes=0-${totalBytes - 1}';
    final response = await client.send(request);
    final firstChunk = Completer<List<int>>();
    final completed = Completer<void>();
    final received = <int>[];
    final subscription = response.stream.listen(
      (chunk) {
        received.addAll(chunk);
        if (!firstChunk.isCompleted && received.length >= prefixBytes) {
          firstChunk.complete(List.of(received));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completed.isCompleted) completed.completeError(error, stackTrace);
      },
      onDone: () {
        if (!completed.isCompleted) completed.complete();
      },
    );
    addTearDown(subscription.cancel);

    final prefix = await firstChunk.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () => fail('cached prefix was buffered until EOF'),
    );
    expect(prefix, hasLength(prefixBytes));
    expect(prefix, everyElement(1));
    releaseVideo.complete();
    await completed.future.timeout(const Duration(seconds: 1));
    expect(received, hasLength(totalBytes));
    expect(received.take(prefixBytes), everyElement(1));
    expect(received.skip(prefixBytes), everyElement(2));
    for (var i = 0; i < 40 && !cache.progressForSong(song).isComplete; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(cache.progressForSong(song).isComplete, isTrue);
    await subscription.cancel();
  });

  test('playback cache starts video while required audio is still loading',
      () async {
    final videoStarted = Completer<void>();
    final releaseVideo = Completer<void>();
    final audioStarted = Completer<void>();
    final releaseAudio = Completer<void>();
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      videoReadyBytes: 2,
      httpClient: _FakeAssetHttpClient(
        audioStarted: audioStarted,
        releaseAudio: releaseAudio,
      ),
      mediaHttpClient: _FakeAssetHttpClient(
        videoStarted: videoStarted,
        releaseVideo: releaseVideo,
      ),
    );
    addTearDown(cache.dispose);

    final video = MediaAsset(
      id: 'parallel-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/media/video.mp4'),
    );
    final vocal = MediaAsset(
      id: 'parallel-vocal',
      type: MediaAssetType.vocal,
      uri: Uri.parse('/media/vocal.m4a'),
    );
    final lyric = MediaAsset(
      id: 'parallel-krl',
      type: MediaAssetType.lyric,
      uri: Uri.parse('/media/lyrics.krl'),
    );
    final song = Song(
      id: 'parallel-song',
      title: 'Parallel',
      category: 'Test',
      assets: [video, vocal, lyric],
      lyricProject: LyricProject(
        id: 'parallel-krl',
        songId: 'parallel-song',
        krlUri: lyric.uri,
        version: 1,
      ),
    );

    final prepare = cache.ensurePlaybackAssets(song);
    await audioStarted.future.timeout(const Duration(seconds: 1));
    await videoStarted.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () => fail('video waited for the audio download to finish'),
    );

    releaseAudio.complete();
    await prepare.timeout(const Duration(seconds: 1));
    releaseVideo.complete();
    for (var i = 0; i < 20 && video.cachedPath == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(video.cachedPath, isNotNull);
  });

  test('playback cache waits for both audio tracks but not video', () async {
    final releaseAccompaniment = Completer<void>();
    final accompanimentStarted = Completer<void>();
    final releaseVideo = Completer<void>();
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      videoReadyBytes: 2,
      httpClient: _FakeAssetHttpClient(
        accompanimentStarted: accompanimentStarted,
        releaseAccompaniment: releaseAccompaniment,
      ),
      mediaHttpClient: _FakeAssetHttpClient(
        releaseVideo: releaseVideo,
      ),
    );
    addTearDown(cache.dispose);

    final video = MediaAsset(
      id: 'selected-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/media/video.mp4'),
    );
    final vocal = MediaAsset(
      id: 'selected-vocal',
      type: MediaAssetType.vocal,
      uri: Uri.parse('/media/vocal.m4a'),
    );
    final accompaniment = MediaAsset(
      id: 'selected-inst',
      type: MediaAssetType.accompaniment,
      uri: Uri.parse('/media/inst.m4a'),
    );
    final lyric = MediaAsset(
      id: 'selected-krl',
      type: MediaAssetType.lyric,
      uri: Uri.parse('/media/lyrics.krl'),
    );
    final song = Song(
      id: 'selected-song',
      title: 'Selected Track',
      category: 'Test',
      assets: [video, vocal, accompaniment, lyric],
      lyricProject: LyricProject(
        id: 'selected-krl',
        songId: 'selected-song',
        krlUri: lyric.uri,
        version: 1,
      ),
    );

    var completed = false;
    final prepare = cache.ensurePlaybackAssets(song).then((_) {
      completed = true;
    });
    await accompanimentStarted.future.timeout(const Duration(seconds: 1));

    String? playbackUrl;
    for (var i = 0; i < 20; i++) {
      playbackUrl = cache.playbackPathFor(video);
      if (playbackUrl != null && playbackUrl.startsWith('http://127.0.0.1:')) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);
    expect(vocal.cachedPath, isNotNull);
    expect(accompaniment.cachedPath, isNull);
    expect(playbackUrl, startsWith('http://127.0.0.1:'));

    releaseAccompaniment.complete();
    await prepare.timeout(const Duration(seconds: 1));
    expect(completed, isTrue);
    expect(accompaniment.cachedPath, isNotNull);

    releaseVideo.complete();
    for (var i = 0; i < 40 && video.cachedPath == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  });

  test('playback cache pulls fifteen mixed assets concurrently', () async {
    final client = _ConcurrentVideoHttpClient(count: 15);
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      httpClient: client,
      mediaHttpClient: client,
    );
    addTearDown(cache.dispose);

    const assetTypes = [
      MediaAssetType.video,
      MediaAssetType.vocal,
      MediaAssetType.accompaniment,
      MediaAssetType.lyric,
      MediaAssetType.cover,
    ];
    for (var songIndex = 0; songIndex < 3; songIndex++) {
      final song = Song(
        id: 'parallel-song-$songIndex',
        title: 'Parallel Song $songIndex',
        category: 'Test',
        assets: [
          for (var assetIndex = 0; assetIndex < assetTypes.length; assetIndex++)
            MediaAsset(
              id: 'parallel-$songIndex-$assetIndex',
              type: assetTypes[assetIndex],
              uri: Uri.parse(
                '/media/video${songIndex * assetTypes.length + assetIndex}.mp4',
              ),
            ),
        ],
      );
      cache
        ..setSongPriority(song.id, songIndex)
        ..prefetchPlaybackAssets(song);
    }

    await Future.wait(client.started.map((c) => c.future))
        .timeout(const Duration(seconds: 1));
    expect(client.maxActive, 15);
    expect(client.requestCount, everyElement(1));

    for (final release in client.release) {
      release.complete();
    }
    for (var i = 0; i < 40 && client.active > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(
      client.active,
      0,
      reason: 'requests=${client.requestCount}',
    );
  });

  test('promoted asset preempts and reconnects the latest lowest priority',
      () async {
    final client = _ConcurrentVideoHttpClient(count: 16, resumableIndex: 14);
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      httpClient: client,
      mediaHttpClient: client,
    );
    addTearDown(cache.dispose);

    final lowPriority = Song(
      id: 'low-priority',
      title: 'Low Priority',
      category: 'Test',
      assets: List.generate(
        15,
        (index) => MediaAsset(
          id: 'low-priority-$index',
          type: MediaAssetType.video,
          uri: Uri.parse('/media/video$index.mp4'),
        ),
      ),
    );
    final promoted = Song(
      id: 'promoted',
      title: 'Promoted',
      category: 'Test',
      assets: [
        MediaAsset(
          id: 'promoted',
          type: MediaAssetType.video,
          uri: Uri.parse('/media/video15.mp4'),
        ),
      ],
    );
    cache
      ..setSongPriority(lowPriority.id, 3)
      ..prefetchPlaybackAssets(lowPriority);

    await Future.wait(client.started.take(15).map((c) => c.future))
        .timeout(const Duration(seconds: 1));
    for (var i = 0;
        i < 40 && cache.progressForSong(lowPriority).downloadedBytes < 2;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(cache.progressForSong(lowPriority).downloadedBytes, 2);
    cache
      ..setSongPriority(promoted.id, 0)
      ..prefetchPlaybackAssets(promoted);
    await client.started[15].future.timeout(const Duration(seconds: 1));

    client.release[15].complete();
    for (var i = 0; i < 40 && client.requestCount[14] < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(
      client.requestCount[14],
      2,
      reason:
          'requests=${client.requestCount}, diagnostics=${cache.ioDiagnostics}',
    );
    expect(client.requestRanges[14], [null, 'bytes=2-']);
    expect(client.requestCount.take(14), everyElement(1));
    expect(cache.ioDiagnostics.preemptions, 1);
    expect(cache.ioDiagnostics.preemptionHandlers, 17);

    for (var i = 0; i < 15; i++) {
      client.release[i].complete();
    }
    for (var i = 0; i < 40 && client.active > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(
      client.active,
      0,
      reason: 'requests=${client.requestCount}',
    );
  });

  test('playback cache proxies far-ahead video ranges instead of waiting',
      () async {
    final videoStarted = Completer<void>();
    final releaseVideo = Completer<void>();

    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });

    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      videoReadyBytes: 2,
      httpClient: _FakeAssetHttpClient(),
      mediaHttpClient: _FakeAssetHttpClient(
        videoStarted: videoStarted,
        releaseVideo: releaseVideo,
        videoTotalLength: 1000000,
      ),
    );
    addTearDown(cache.dispose);

    final video = MediaAsset(
      id: 'long-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/media/video.mp4'),
    );
    final vocal = MediaAsset(
      id: 'long-vocal',
      type: MediaAssetType.vocal,
      uri: Uri.parse('/media/vocal.m4a'),
    );
    final lyric = MediaAsset(
      id: 'long-krl',
      type: MediaAssetType.lyric,
      uri: Uri.parse('/media/lyrics.krl'),
    );
    final song = Song(
      id: 'long-song',
      title: 'Long Progressive',
      category: 'Test',
      assets: [video, vocal, lyric],
      lyricProject: LyricProject(
        id: 'long-krl',
        songId: 'long-song',
        krlUri: lyric.uri,
        version: 1,
      ),
    );

    await cache.ensurePlaybackAssets(song);
    await videoStarted.future.timeout(const Duration(seconds: 1));
    final playbackUrl = cache.playbackPathFor(video);
    expect(playbackUrl, startsWith('http://127.0.0.1:'));

    final response = await http.get(
      Uri.parse(playbackUrl!),
      headers: {HttpHeaders.rangeHeader: 'bytes=900000-900003'},
    ).timeout(
      const Duration(seconds: 1),
      onTimeout: () => fail('far-ahead video range waited for local cache'),
    );

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers[HttpHeaders.contentRangeHeader],
      'bytes 900000-900003/1000000',
    );
    expect(response.bodyBytes, [9, 9, 9, 9]);

    releaseVideo.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('playback prefetch deduplicates downloads and ignores missing cover',
      () async {
    final videoStarted = Completer<void>();
    final releaseVideo = Completer<void>();
    final client = _FakeAssetHttpClient(
      videoStarted: videoStarted,
      releaseVideo: releaseVideo,
    );
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_cache_test_');
    addTearDown(() {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final cache = PlaybackAssetCache(
      baseUrl: 'http://catalog.test',
      cacheDir: cacheDir,
      videoReadyBytes: 2,
      httpClient: client,
      mediaHttpClient: client,
    );
    addTearDown(cache.dispose);

    final video = MediaAsset(
      id: 'dedupe-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/media/video.mp4'),
    );
    final vocal = MediaAsset(
      id: 'dedupe-vocal',
      type: MediaAssetType.vocal,
      uri: Uri.parse('/media/vocal.m4a'),
    );
    final lyric = MediaAsset(
      id: 'dedupe-krl',
      type: MediaAssetType.lyric,
      uri: Uri.parse('/media/lyrics.krl'),
    );
    final cover = MediaAsset(
      id: 'dedupe-cover',
      type: MediaAssetType.cover,
      uri: Uri.parse('/media/missing-cover.jpg'),
    );
    final song = Song(
      id: 'dedupe-song',
      title: 'Dedupe',
      category: 'Test',
      assets: [video, vocal, lyric, cover],
      lyricProject: LyricProject(
        id: 'dedupe-krl',
        songId: 'dedupe-song',
        krlUri: lyric.uri,
        version: 1,
      ),
    );

    cache.prefetchPlaybackAssets(song);
    cache.prefetchPlaybackAssets(song);
    await cache.ensurePlaybackAssets(song);
    await videoStarted.future.timeout(const Duration(seconds: 1));

    expect(client.fullVideoRequests, 1);
    expect(client.notFoundRequests, 1); // cover 404, handled gracefully

    releaseVideo.complete();
    for (var i = 0; i < 20 && !cache.progressForSong(song).isComplete; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final progress = cache.progressForSong(song);
    expect(progress.assetCount, 3); // cover is optional for playback
    expect(progress.completeAssets, 3);
    expect(progress.isComplete, isTrue);
  });

  for (final statusCode in [
    HttpStatus.notFound,
    HttpStatus.serviceUnavailable,
  ]) {
    test('required asset HTTP $statusCode retries five times then fails',
        () async {
      final client = _AlwaysStatusHttpClient(statusCode);
      final cacheDir = await Directory.systemTemp.createTemp(
        'kirakara_cache_failure_test_',
      );
      addTearDown(() {
        if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
      });
      final cache = PlaybackAssetCache(
        baseUrl: 'http://catalog.test',
        cacheDir: cacheDir,
        httpClient: client,
        mediaHttpClient: client,
        retryDelay: Duration.zero,
        maxAutomaticRetries: 5,
      );
      addTearDown(cache.dispose);
      final video = MediaAsset(
        id: 'failed-video-$statusCode',
        type: MediaAssetType.video,
        uri: Uri.parse('/media/failed-$statusCode.mp4'),
      );
      final song = Song(
        id: 'failed-song-$statusCode',
        title: 'Failed asset',
        category: 'Test',
        assets: [video],
      );

      await expectLater(
        cache.ensurePlaybackAssets(song),
        throwsA(
          isA<PlaybackAssetDownloadException>().having(
            (error) => error.statusCode,
            'statusCode',
            statusCode,
          ),
        ),
      );

      expect(client.requestCount, 6); // initial attempt + five retries
      expect(cache.progressForSong(song).hasFailed, isTrue);
    });
  }

  test('display manager selects the first non-primary display as stage',
      () async {
    final displayManager = DisplayManager(
      nativeWindowService: const _FakeNativeWindowService([
        {
          'id': r'\\.\DISPLAY1',
          'name': '涓绘樉绀哄櫒',
          'isPrimary': true,
          'left': 0,
          'top': 0,
          'width': 1920,
          'height': 1080,
        },
        {
          'id': r'\\.\DISPLAY2',
          'name': 'virtual stage',
          'isPrimary': false,
          'left': 1920,
          'top': 0,
          'width': 1920,
          'height': 1080,
        },
      ]),
    );

    await displayManager.detectDisplays();

    expect(displayManager.hasPhysicalStageDisplay, isTrue);
    expect(displayManager.stageDisplay?.id, r'\\.\DISPLAY2');
    expect(displayManager.stageDisplay?.left, 1920);
    expect(displayManager.stageDisplay?.sizeLabel, '1920x1080');
  });
}
