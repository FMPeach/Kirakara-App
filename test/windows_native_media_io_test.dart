import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/domain/media_asset.dart';
import 'package:kirakara_app/domain/song.dart';
import 'package:kirakara_app/services/playback_asset_cache.dart';
import 'package:kirakara_app/services/playback_media_io_worker.dart';
import 'package:kirakara_app/services/windows_native_media_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('kirakara/test_media_io');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native media I/O polls one completed transfer at low frequency',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'probe':
          return <String, dynamic>{
            'available': true,
            'backend': 'winhttp',
            'version': 1,
          };
        case 'start':
          return true;
        case 'poll':
          return <Map<String, dynamic>>[
            {
              'id': 1,
              'status': 'finished',
              'totalLength': 8,
              'downloadedBytes': 8,
              'persistedBytes': 8,
              'receivedBytes': 8,
              'readCalls': 1,
              'writeCalls': 1,
              'statusCode': 200,
              'responseReceived': true,
            },
          ];
        case 'release':
          return null;
      }
      throw MissingPluginException();
    });
    final progress = <MediaIoWorkerProgress>[];
    final backend = WindowsNativeMediaIo(channel: channel);
    addTearDown(backend.dispose);

    final operation = await backend.startDownload(
      url: 'https://example.test/video.mp4',
      localPath: r'C:\temp\video.mp4',
      headers: const {'Cookie': 'memory-only'},
      readyBytes: 4,
      isVideo: true,
      onProgress: progress.add,
    );
    expect(operation, isNotNull);
    final result = await operation!.result.timeout(const Duration(seconds: 1));

    expect(result.status, MediaIoWorkerAttemptStatus.finished);
    expect(result.actualLength, 8);
    expect(result.writeCalls, 1);
    expect(result.responseReceived, isTrue);
    expect(progress.single.available, isTrue);
    expect(calls, containsAllInOrder(['probe', 'start', 'poll', 'release']));
  });

  test('native capability failure is cached only in the backend instance',
      () async {
    var probes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'probe') {
        probes++;
        throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    final backend = WindowsNativeMediaIo(channel: channel);
    addTearDown(backend.dispose);

    expect(await backend.isAvailable(), isFalse);
    expect(await backend.isAvailable(), isFalse);
    expect(probes, 1);
  });

  test('native transport failure stays on the native retry path', () async {
    const productionChannel = MethodChannel('kirakara/media_io');
    var nativeStarts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(productionChannel, (call) async {
      switch (call.method) {
        case 'probe':
          return <String, dynamic>{
            'available': true,
            'backend': 'winhttp',
            'version': 1,
          };
        case 'start':
          nativeStarts++;
          return true;
        case 'poll':
          return <Map<String, dynamic>>[
            {
              'id': 1,
              'status': 'failed',
              'totalLength': null,
              'downloadedBytes': 0,
              'persistedBytes': 0,
              'receivedBytes': 0,
              'readCalls': 0,
              'writeCalls': 0,
              'statusCode': 0,
              'responseReceived': false,
              'failureStage': 'receive_headers',
              'win32Error': 12029,
              'error': 'WinHttpSendRequest failed: 12029',
            },
          ];
        case 'release':
          return null;
      }
      throw MissingPluginException();
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(productionChannel, null);
    });

    final cacheDir = await Directory.systemTemp.createTemp(
      'kirakara_native_failure_',
    );
    final cache = PlaybackAssetCache(
      baseUrl: 'https://example.test',
      cacheDir: cacheDir,
      maxAutomaticRetries: 0,
    );
    addTearDown(() async {
      cache.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });
    final video = MediaAsset(
      id: 'native-fallback-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/video.mp4'),
    );
    final song = Song(
      id: 'native-fallback-song',
      title: 'Native fallback',
      category: 'Test',
      assets: [video],
    );

    await expectLater(
      cache.ensureSongAssets(song).timeout(const Duration(seconds: 3)),
      throwsA(isA<PlaybackAssetDownloadException>()),
    );

    expect(nativeStarts, 1);
    expect(video.cachedPath, isNull);
  });
}
