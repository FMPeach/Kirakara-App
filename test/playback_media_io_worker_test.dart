import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/playback_media_io_worker.dart';

void main() {
  test('Dart worker cancels and resumes a partial response with Range',
      () async {
    const prefixBytes = 64 * 1024;
    const totalBytes = prefixBytes * 2;
    final releaseFirst = Completer<void>();
    final ranges = <String?>[];
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originSubscription = origin.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      if (range == null) {
        request.response.headers.contentLength = totalBytes;
        request.response.add(List<int>.filled(prefixBytes, 1));
        await request.response.flush();
        await releaseFirst.future;
        try {
          request.response.add(List<int>.filled(prefixBytes, 2));
          await request.response.close();
        } catch (_) {}
        return;
      }
      expect(range, 'bytes=$prefixBytes-');
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.contentLength = prefixBytes;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $prefixBytes-${totalBytes - 1}/$totalBytes',
      );
      request.response.add(List<int>.filled(prefixBytes, 2));
      await request.response.close();
    });
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_worker_resume_test_');
    final localPath = '${cacheDir.path}${Platform.pathSeparator}video.mp4';
    final worker = PlaybackMediaIoWorker();
    try {
      final available = Completer<void>();
      final first = await worker.startDownload(
        url: 'http://${origin.address.address}:${origin.port}/video.mp4',
        localPath: localPath,
        headers: const {},
        readyBytes: prefixBytes,
        isVideo: true,
        onProgress: (progress) {
          if (progress.available && !available.isCompleted) {
            available.complete();
          }
        },
      );
      await available.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => fail('worker did not publish the persisted prefix'),
      );
      first.cancel();
      final firstResult = await first.result.timeout(
        const Duration(seconds: 3),
        onTimeout: () => fail('worker cancellation did not finish'),
      );
      expect(firstResult.status, MediaIoWorkerAttemptStatus.preempted);

      releaseFirst.complete();
      final second = await worker.startDownload(
        url: 'http://${origin.address.address}:${origin.port}/video.mp4',
        localPath: localPath,
        headers: const {},
        readyBytes: prefixBytes,
        isVideo: true,
        onProgress: (_) {},
      );
      final secondResult = await second.result.timeout(
        const Duration(seconds: 3),
        onTimeout: () => fail('worker Range continuation did not finish'),
      );
      expect(secondResult.status, MediaIoWorkerAttemptStatus.finished);
      final bytes = await File('$localPath.part').readAsBytes();
      expect(bytes, hasLength(totalBytes));
      expect(bytes.take(prefixBytes), everyElement(1));
      expect(bytes.skip(prefixBytes), everyElement(2));
      expect(ranges, [null, 'bytes=$prefixBytes-']);
    } finally {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      await worker.dispose();
      await originSubscription.cancel();
      await origin.close(force: true);
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    }
  });
}
