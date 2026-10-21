import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kirakara_app/data/local_db/local_database.dart';
import 'package:kirakara_app/domain/media_asset.dart';
import 'package:kirakara_app/domain/song.dart';
import 'package:kirakara_app/services/bilibili_account_service.dart';
import 'package:kirakara_app/services/lan_server.dart';
import 'package:kirakara_app/services/playback_asset_cache.dart';
import 'package:kirakara_app/services/playback_service.dart';
import 'package:kirakara_app/services/queue_service.dart';
import 'package:kirakara_app/services/search_service.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aB1sAAAAASUVORK5CYII=',
);

Song _song(
        {String id = 'cover-song', MediaAsset? cover, bool external = false}) =>
    Song(
      id: id,
      title: id,
      category: 'Test',
      isExternal: external,
      assets: [if (cover != null) cover],
    );

Future<({LanServer server, PlaybackService playback})> _start(
  Directory directory,
  Song song, {
  PlaybackAssetCache? assetCache,
}) async {
  final db = LocalDatabase(dbPath: ':memory:')..open();
  addTearDown(db.close);
  final queue = QueueService();
  final playback = PlaybackService(queueService: queue)..setCurrentSong(song);
  final account = BilibiliAccountService(
    sessionFilePath: '${directory.path}/unused-session.json',
  );
  addTearDown(account.dispose);
  addTearDown(playback.dispose);
  addTearDown(queue.dispose);
  final server = LanServer(
    queueService: queue,
    searchService: SearchService(db: db),
    playbackService: playback,
    bilibiliAccountService: account,
    assetCache: assetCache,
    bindAddress: InternetAddress.loopbackIPv4,
  );
  await server.start(port: 0);
  addTearDown(server.stop);
  return (server: server, playback: playback);
}

Future<Map<String, dynamic>> _state(LanServer server) async =>
    jsonDecode((await http.get(server.localUri!.resolve('/api/playback'))).body)
        as Map<String, dynamic>;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kirakara_lan_cover_');
    addTearDown(() => directory.delete(recursive: true));
  });

  test(
      'state polling is metadata-only and cover fetch resolves relative assets',
      () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    var imageRequests = 0;
    origin.listen((request) async {
      imageRequests++;
      expect(request.uri.path, '/covers/song.png');
      expect(request.headers.value('x-cover-test'), 'catalog');
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(_png);
      await request.response.close();
    });
    final cache = PlaybackAssetCache(
      baseUrl: 'http://127.0.0.1:${origin.port}',
      cacheDir: directory,
      enableNativeMediaIo: false,
    );
    addTearDown(cache.dispose);
    final running = await _start(
      directory,
      _song(
          cover: MediaAsset(
        id: 'cover',
        type: MediaAssetType.cover,
        uri: Uri.parse('/covers/song.png'),
        version: 3,
        headers: const {'x-cover-test': 'catalog'},
      )),
      assetCache: cache,
    );

    final first = await _state(running.server);
    final coverUrl = first['currentSong']['coverUrl'] as String;
    expect(coverUrl, startsWith('/api/playback/cover?'));
    for (var i = 0; i < 3; i++) {
      expect(
          (await _state(running.server))['currentSong']['coverUrl'], coverUrl);
    }
    expect(imageRequests, 0);
    final image = await http.get(running.server.localUri!.resolve(coverUrl));
    expect(image.statusCode, HttpStatus.ok);
    expect(image.bodyBytes, _png);
    expect(image.headers['content-type'], startsWith('image/png'));
    expect(image.headers['cache-control'], 'private, max-age=3600');
    expect(imageRequests, 1);
  });

  test('cached cover is served locally and old song/version URLs cannot bleed',
      () async {
    final file = File('${directory.path}/cover.png');
    await file.writeAsBytes(_png);
    MediaAsset cover(int version) => MediaAsset(
          id: 'cover',
          type: MediaAssetType.cover,
          uri: Uri.parse('http://127.0.0.1:9/unreachable.png'),
          cachedPath: file.path,
          version: version,
        );
    final running = await _start(directory, _song(cover: cover(1)));
    final firstUrl =
        (await _state(running.server))['currentSong']['coverUrl'] as String;
    expect(firstUrl, isNot(contains(directory.path)));
    final image = await http.get(running.server.localUri!.resolve(firstUrl));
    expect(image.statusCode, HttpStatus.ok);
    expect(image.bodyBytes, _png);

    running.playback.setCurrentSong(_song(cover: cover(2)));
    final secondUrl =
        (await _state(running.server))['currentSong']['coverUrl'] as String;
    expect(secondUrl, isNot(firstUrl));
    expect(
        (await http.get(running.server.localUri!.resolve(firstUrl))).statusCode,
        HttpStatus.notFound);
    running.playback.setCurrentSong(_song(id: 'next-song', cover: cover(2)));
    expect(
        (await http.get(running.server.localUri!.resolve(secondUrl)))
            .statusCode,
        HttpStatus.notFound);
  });

  test('external, coverless and empty playback do not advertise an image',
      () async {
    final cover = MediaAsset(
      id: 'external-cover',
      type: MediaAssetType.cover,
      uri: Uri.parse('https://example.invalid/external.jpg'),
    );
    final running =
        await _start(directory, _song(cover: cover, external: true));
    expect((await _state(running.server))['currentSong']['coverUrl'], isNull);
    expect(
        (await http.get(running.server.localUri!.resolve(
          '/api/playback/cover?songId=cover-song&version=1',
        )))
            .statusCode,
        HttpStatus.notFound);
    running.playback.setCurrentSong(_song());
    expect((await _state(running.server))['currentSong']['coverUrl'], isNull);
    running.playback.next();
    expect((await _state(running.server))['currentSong'], isNull);
  });
}
