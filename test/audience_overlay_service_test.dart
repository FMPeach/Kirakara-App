import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/data/local_db/local_database.dart';
import 'package:kirakara_app/domain/audience_overlay_options.dart';
import 'package:kirakara_app/domain/phone_order_qr_image.dart';
import 'package:kirakara_app/domain/song.dart';
import 'package:kirakara_app/domain/stage_overlay_state.dart';
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
  final actions = <PlaybackActionEvent>[];

  @override
  bool notifyPlaybackAction(PlaybackActionEvent event) {
    actions.add(event);
    return true;
  }

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
        bindAddress: InternetAddress.loopbackIPv4,
        qrImages: images);
    final settings = SettingsService(
        initialCacheDirectoryPath: dir.path,
        settingsFilePath: '${dir.path}/settings.json');
    addTearDown(settings.dispose);
    final sink = _Sink();
    final announcements = <StageOverlayState>[];
    final service = AudienceOverlayService(
        settings: settings,
        lan: lan,
        sink: sink,
        queue: queue,
        playback: playback,
        announcementSink: (state) {
          announcements.add(state);
          return true;
        });
    expect(announcements, isEmpty);
    await settings.setAudienceOverlay(
        settings.audienceOverlay.copyWith(announcementEnabled: true));
    const idleText = '当前播放：等待点歌  ·  下一首：暂无，快去点一首吧';
    expect(announcements.single.announcementText, idleText);
    expect(announcements.single.announcementVisible, isTrue);
    await settings.setCustomAnnouncement('自定义公告');
    expect(announcements.last.announcementText, '自定义公告  ·  $idleText');
    await settings.setCustomAnnouncement(' \n');
    expect(announcements.last.announcementText, idleText);
    expect(announcements.last.announcementVisible, isTrue);
    await settings.setCustomAnnouncement('自定义公告');
    playback.pause();
    playback.next(requestedByUser: true);
    expect(sink.actions, isEmpty);
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
    expect(announcements.last.announcementText, contains('当前播放：Song 1 - 未知歌手'));
    expect(announcements.last.announcementText, contains('下一首：Song 2 - 未知歌手'));
    final afterAnnouncement = announcements.length;
    for (var i = 0; i < 100; i++) {
      playback.syncEnginePosition(Duration(seconds: i));
      playback.setVolume(i);
    }
    expect(sink.actions, isEmpty);
    expect(announcements.length, afterAnnouncement,
        reason: 'position and volume do not republish text');
    Future<void> remote(String action, {int? volume}) async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          lan.localUri!.resolve('/api/playback/$action'),
        );
        if (volume != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode({'volume': volume}));
        }
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 200);
      } finally {
        client.close(force: true);
      }
    }

    playback.pause();
    playback.pause();
    playback.play();
    playback.play();
    expect(announcements.length, afterAnnouncement,
        reason: 'play and pause never append transient playback states');
    expect(announcements.last.announcementText,
        '自定义公告  ·  当前播放：Song 1 - 未知歌手  ·  下一首：Song 2 - 未知歌手');
    playback.replay();
    playback.replay();
    expect(announcements.length, afterAnnouncement + 2,
        reason: 'each replay resends identical text');
    expect(announcements.last.announcementText,
        announcements[afterAnnouncement - 1].announcementText);
    expect(announcements.last.revision,
        greaterThan(announcements[afterAnnouncement - 1].revision));
    expect(sink.actions.map((e) => e.action), [
      PlaybackAction.pause,
      PlaybackAction.play,
      PlaybackAction.replay,
      PlaybackAction.replay,
    ]);
    expect(sink.states, afterCurrent);
    expect(announcements.length, afterAnnouncement + 2);
    for (var i = 0; i < 100; i++) {
      // Download completion/availability can notify both services without
      // changing any row displayed by the audience HUD.
      queue.retry(queue.items.first.id);
      playback.refreshUpNext();
    }
    expect(sink.states, afterCurrent);
    expect(sink.actions.length, 4);
    expect(announcements.length, afterAnnouncement + 2,
        reason: 'download notifications do not restart unchanged text');
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

    await lan.start(port: 0);
    addTearDown(lan.stop);
    await remote('pause');
    await remote('play');
    await remote('next');
    expect(sink.actions.skip(4).map((e) => e.action), [
      PlaybackAction.pause,
      PlaybackAction.play,
      PlaybackAction.skip,
    ]);
    expect(playback.state.currentItem?.song.title, 'Song 3');
    playback.next();
    expect(sink.actions.length, 7, reason: 'auto-advance is not a manual skip');
    playback.pause();
    playback.next();
    expect(sink.actions.skip(7).map((e) => e.action), [
      PlaybackAction.pause,
      PlaybackAction.none,
    ]);
    expect(sink.actions.map((e) => e.sequence),
        List.generate(sink.actions.length, (i) => i + 1));

    final audioStart = sink.actions.length;
    final beforeAudio = sink.states;
    playback.pause();
    playback.toggleAudioTrack();
    playback.changeVolumeBy(6);
    playback.changeVolumeBy(6); // Already at 100.
    playback.setVolume(0);
    playback.changeVolumeBy(-6); // Already at 0.
    playback.toggleAudioTrack();
    await remote('volume', volume: 30);
    await remote('volume', volume: 30);
    await remote('volume', volume: 24);
    await remote('track');
    expect(sink.actions.skip(audioStart).map((e) => e.action), [
      PlaybackAction.pause,
      PlaybackAction.accompaniment,
      PlaybackAction.volumeUp,
      PlaybackAction.vocal,
      PlaybackAction.volumeUp,
      PlaybackAction.volumeDown,
      PlaybackAction.accompaniment,
    ]);
    expect(sink.states, beforeAudio, reason: 'action events do not redraw HUD');

    final toggleStart = sink.actions.length;
    final currentOptions = settings.audienceOverlay;
    await settings.setAudienceOverlay(
      currentOptions.copyWith(actionEnabled: false),
    );
    playback.changeVolumeBy(-6);
    await remote('track');
    expect(playback.state.volume, 18);
    expect(sink.actions.skip(toggleStart).map((e) => e.action), [
      PlaybackAction.none,
    ]);
    await settings.setAudienceOverlay(currentOptions);
    expect(sink.actions.skip(toggleStart).map((e) => e.action), [
      PlaybackAction.none,
      PlaybackAction.pause,
    ]);
    expect(sink.states, beforeAudio, reason: 'the switch only affects actions');
    playback.toggleAudioTrack();
    playback.next();
    expect(sink.actions.last.action, PlaybackAction.none,
        reason: 'changing songs clears the pause behind an audio action');

    playback.setCurrentSong(const Song(
      id: 'external',
      title: 'One track',
      category: '',
      assets: [],
      isExternal: true,
    ));
    final beforeExternal = sink.actions.length;
    await remote('track');
    expect(sink.actions.length, beforeExternal,
        reason: 'a single-track song cannot switch vocal/accompaniment');
    await remote('volume', volume: 66);
    expect(sink.actions.last.action, PlaybackAction.volumeUp);
    expect(sink.actions.map((e) => e.sequence),
        List.generate(sink.actions.length, (i) => i + 1));

    await settings.setAudienceOverlay(
        settings.audienceOverlay.copyWith(announcementEnabled: true));
    queue.clear();
    playback.next();
    expect(announcements.last.announcementText, '自定义公告  ·  $idleText');
    await settings.setCustomAnnouncement('');
    expect(announcements.last.announcementText, idleText);
    expect(announcements.last.announcementVisible, isTrue);

    final beforeDispose = sink.states;
    final actionCount = sink.actions.length;
    service.dispose();
    queue.bumpToNext(next.song);
    playback.pause();
    expect(sink.states, beforeDispose);
    expect(sink.actions.length, actionCount);
    expect(sink.onLanChanged, isNull);
  });
}
