import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/data/local_db/local_database.dart';
import 'package:kirakara_app/domain/audience_overlay_options.dart';
import 'package:kirakara_app/domain/phone_order_qr_image.dart';
import 'package:kirakara_app/domain/song.dart';
import 'package:kirakara_app/services/audience_hud_ffi.dart';
import 'package:kirakara_app/services/audience_overlay_service.dart';
import 'package:kirakara_app/services/bilibili_account_service.dart';
import 'package:kirakara_app/services/lan_server.dart';
import 'package:kirakara_app/services/phone_order_qr_service.dart';
import 'package:kirakara_app/services/playback_service.dart';
import 'package:kirakara_app/services/queue_service.dart';
import 'package:kirakara_app/services/search_service.dart';
import 'package:kirakara_app/services/settings_service.dart';

class _Sink implements AudienceHudSink {
  @override
  void Function()? onLanChanged;
  int states = 0;
  PhoneOrderQrImage? image;
  List<AudienceQueueEntry> queue = [];
  AudienceQueueEntry? current;
  AudienceOverlayOptions? options;
  @override
  bool setImage(PhoneOrderQrImage? value) {
    image = value;
    return true;
  }

  @override
  bool setState(AudienceOverlayOptions value, String network,
      List<AudienceQueueEntry> entries,
      {bool wifi = false, AudienceQueueEntry? current}) {
    states++;
    options = value;
    queue = List.of(entries);
    this.current = current;
    return true;
  }
}

void main() {
  test('HUD publishes current plus four upcoming only on content events',
      () async {
    final dir = Directory.systemTemp.createTempSync('kirakara_hud_sync_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = LocalDatabase(dbPath: ':memory:')..open();
    addTearDown(db.close);
    final queue = QueueService();
    addTearDown(queue.dispose);
    final playback = PlaybackService(queueService: queue);
    addTearDown(playback.dispose);
    final account =
        BilibiliAccountService(sessionFilePath: '${dir.path}/unused.json');
    addTearDown(account.dispose);
    var generations = 0;
    final images = PhoneOrderQrService(renderer: (uri, revision) async {
      generations++;
      return PhoneOrderQrImage(
          endpoint: uri,
          revision: revision,
          pixelSize: 132,
          modules: 33,
          pngBytes: Uint8List.fromList([1]));
    });
    addTearDown(images.dispose);
    final lan = LanServer(
        queueService: queue,
        searchService: SearchService(db: db),
        playbackService: playback,
        bilibiliAccountService: account,
        qrImages: images);
    final settings = SettingsService(
        initialCacheDirectoryPath: dir.path,
        settingsFilePath: '${dir.path}/settings.json');
    addTearDown(settings.dispose);
    final sink = _Sink();
    final service = AudienceOverlayService(
        settings: settings,
        lan: lan,
        sink: sink,
        queue: queue,
        playback: playback);
    for (var i = 1; i <= 5; i++) {
      queue.addSong(
          Song(id: '$i', title: 'Song $i', category: '', assets: const []));
    }
    expect(sink.queue.map((entry) => entry.title),
        ['Song 1', 'Song 2', 'Song 3', 'Song 4']);
    final count = sink.states;
    queue.addSong(
        const Song(id: '6', title: 'Song 6', category: '', assets: []));
    expect(sink.states, count);
    final next = queue.takeNext()!;
    expect(sink.queue.first.title, 'Song 2');
    playback.setCurrent(next);
    expect(sink.current, (title: 'Song 1', artist: ''));
    expect(sink.queue.map((entry) => entry.title),
        ['Song 2', 'Song 3', 'Song 4', 'Song 5']);
    final afterCurrent = sink.states;
    for (var i = 0; i < 100; i++) {
      playback.syncEnginePosition(Duration(seconds: i));
      playback.setVolume(i);
    }
    playback.pause();
    playback.play();
    playback.replay();
    expect(sink.states, afterCurrent);
    queue.markFailed(queue.items.first.id, 'test');
    expect(sink.queue.first.title, 'Song 3');
    await images.updateEndpoint(Uri.parse('http://192.168.1.2:7391'));
    expect(identical(sink.image, images.image), isTrue);
    await settings.setAudienceOverlay(
        const AudienceOverlayOptions(qrEnabled: false, queueEnabled: true));
    expect(sink.options!.qrEnabled, isFalse);
    expect(sink.options!.queueEnabled, isTrue);
    expect(lan.isRunning, isFalse);
    expect(identical(playback.state.currentItem, next), isTrue);
    expect(generations, 1);
    final beforeDispose = sink.states;
    service.dispose();
    queue.bumpToNext(next.song);
    expect(sink.states, beforeDispose);
    expect(sink.onLanChanged, isNull);
  });
}
