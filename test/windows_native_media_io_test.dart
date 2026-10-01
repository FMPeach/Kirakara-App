import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
