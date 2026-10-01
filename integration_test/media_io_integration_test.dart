import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kirakara_app/domain/media_asset.dart';
import 'package:kirakara_app/domain/song.dart';
import 'package:kirakara_app/services/playback_asset_cache.dart';
import 'package:kirakara_app/services/playback_media_io_worker.dart';
import 'package:kirakara_app/services/windows_native_media_io.dart';
import 'package:http/http.dart' as http;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('WinHTTP downloads while the worker serves a progressive range',
      (_) async {
    const prefixBytes = 512 * 1024;
    const totalBytes = 2 * 1024 * 1024;
    final releaseTail = Completer<void>();
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originSubscription = origin.listen((request) async {
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader)!;
        final start = int.parse(match.group(1)!);
        final endText = match.group(2)!;
        final end = endText.isEmpty ? totalBytes - 1 : int.parse(endText);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$totalBytes',
        );
        request.response.headers.contentLength = end - start + 1;
        request.response.add(List<int>.filled(end - start + 1, 9));
        await request.response.close();
        return;
      }
      request.response.headers.contentLength = totalBytes;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.add(List<int>.filled(prefixBytes, 3));
      await request.response.flush();
      await releaseTail.future;
      request.response.add(List<int>.filled(totalBytes - prefixBytes, 4));
      await request.response.close();
    });
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_native_io_test_');
    final cache = PlaybackAssetCache(
      baseUrl: 'http://${origin.address.address}:${origin.port}',
      cacheDir: cacheDir,
      videoReadyBytes: prefixBytes,
      debugMediaIo: true,
    );
    final video = MediaAsset(
      id: 'native-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/video.mp4'),
    );
    final song = Song(
      id: 'native-song',
      title: 'Native I/O',
      category: 'Test',
      assets: [video],
    );
    try {
      await cache
          .ensurePlaybackAssets(song)
          .timeout(const Duration(seconds: 10));
      final playbackUrl = cache.playbackPathFor(video);
      expect(playbackUrl, startsWith('http://127.0.0.1:'));
      final prefix = await http.get(
        Uri.parse(playbackUrl!),
        headers: {HttpHeaders.rangeHeader: 'bytes=0-3'},
      );
      expect(prefix.statusCode, HttpStatus.partialContent);
      expect(prefix.bodyBytes, [3, 3, 3, 3]);

      releaseTail.complete();
      for (var i = 0; i < 80 && video.cachedPath == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(video.cachedPath, isNotNull);
      expect(await File(video.cachedPath!).length(), totalBytes);
      expect(cache.ioDiagnostics.receivedBytes, totalBytes);
      expect(cache.ioDiagnostics.writeCalls, lessThanOrEqualTo(3));
    } finally {
      if (!releaseTail.isCompleted) releaseTail.complete();
      cache.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await originSubscription.cancel();
      await origin.close(force: true);
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    }
  });

  testWidgets('WinHTTP cancellation resumes the partial file with Range',
      (_) async {
    const prefixBytes = 512 * 1024;
    const totalBytes = 1024 * 1024;
    final releaseFirstResponse = Completer<void>();
    final ranges = <String?>[];
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originSubscription = origin.listen((request) async {
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(rangeHeader);
      if (rangeHeader == null) {
        request.response.headers.contentLength = totalBytes;
        request.response.add(List<int>.filled(prefixBytes, 5));
        await request.response.flush();
        await releaseFirstResponse.future;
        try {
          request.response.add(List<int>.filled(totalBytes - prefixBytes, 6));
          await request.response.close();
        } catch (_) {}
        return;
      }
      final start = int.parse(
        RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader)!.group(1)!,
      );
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${totalBytes - 1}/$totalBytes',
      );
      request.response.headers.contentLength = totalBytes - start;
      request.response.add(List<int>.filled(totalBytes - start, 6));
      await request.response.close();
    });
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_native_resume_test_');
    final localPath = '${cacheDir.path}${Platform.pathSeparator}video.mp4';
    final backend = WindowsNativeMediaIo();
    try {
      final firstReady = Completer<void>();
      final first = await backend.startDownload(
        url: 'http://${origin.address.address}:${origin.port}/video.mp4',
        localPath: localPath,
        headers: const {},
        readyBytes: prefixBytes,
        isVideo: true,
        onProgress: (progress) {
          if (progress.available && !firstReady.isCompleted) {
            firstReady.complete();
          }
        },
      );
      expect(first, isNotNull);
      await firstReady.future.timeout(const Duration(seconds: 5));
      first!.cancel();
      final firstResult =
          await first.result.timeout(const Duration(seconds: 5));
      expect(firstResult.status, MediaIoWorkerAttemptStatus.preempted);

      releaseFirstResponse.complete();
      final second = await backend.startDownload(
        url: 'http://${origin.address.address}:${origin.port}/video.mp4',
        localPath: localPath,
        headers: const {},
        readyBytes: prefixBytes,
        isVideo: true,
        onProgress: (_) {},
      );
      expect(second, isNotNull);
      final secondResult =
          await second!.result.timeout(const Duration(seconds: 5));
      expect(secondResult.status, MediaIoWorkerAttemptStatus.finished);
      expect(await File('$localPath.part').length(), totalBytes);
      expect(ranges, [null, 'bytes=$prefixBytes-']);
    } finally {
      if (!releaseFirstResponse.isCompleted) releaseFirstResponse.complete();
      backend.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await originSubscription.cancel();
      await origin.close(force: true);
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    }
  });

  testWidgets('WinHTTP persists a partial batch after the latency bound',
      (_) async {
    const prefixBytes = 512 * 1024;
    const slowChunkBytes = 64 * 1024;
    const totalBytes = 2 * 1024 * 1024;
    final releaseSmallChunks = Completer<void>();
    final releaseRemainder = Completer<void>();
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originSubscription = origin.listen((request) async {
      request.response.headers.contentLength = totalBytes;
      request.response.add(List<int>.filled(prefixBytes, 1));
      await request.response.flush();
      await releaseSmallChunks.future;
      request.response.add(List<int>.filled(slowChunkBytes, 2));
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      request.response.add(List<int>.filled(slowChunkBytes, 2));
      await request.response.flush();
      await releaseRemainder.future;
      request.response.add(
        List<int>.filled(totalBytes - prefixBytes - slowChunkBytes * 2, 3),
      );
      await request.response.close();
    });
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_latency_flush_test_');
    final localPath = '${cacheDir.path}${Platform.pathSeparator}video.mp4';
    final backend = WindowsNativeMediaIo();
    final prefixPersisted = Completer<void>();
    final partialBatchPersisted = Completer<void>();
    try {
      final download = await backend.startDownload(
        url: 'http://${origin.address.address}:${origin.port}/video.mp4',
        localPath: localPath,
        headers: const {},
        readyBytes: prefixBytes,
        isVideo: true,
        onProgress: (progress) {
          if (progress.persistedBytes >= prefixBytes &&
              !prefixPersisted.isCompleted) {
            prefixPersisted.complete();
          }
          if (progress.persistedBytes > prefixBytes &&
              !partialBatchPersisted.isCompleted) {
            partialBatchPersisted.complete();
          }
        },
      );
      expect(download, isNotNull);
      await prefixPersisted.future.timeout(const Duration(seconds: 5));
      releaseSmallChunks.complete();
      await partialBatchPersisted.future.timeout(const Duration(seconds: 3));
      releaseRemainder.complete();
      final result = await download!.result.timeout(const Duration(seconds: 5));
      expect(result.status, MediaIoWorkerAttemptStatus.finished);
      expect(result.actualLength, totalBytes);
      expect(result.writeCalls, greaterThan(2));
    } finally {
      if (!releaseSmallChunks.isCompleted) releaseSmallChunks.complete();
      if (!releaseRemainder.isCompleted) releaseRemainder.complete();
      backend.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await originSubscription.cancel();
      await origin.close(force: true);
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    }
  });

  testWidgets('WinHTTP slow tail keeps the progressive response alive',
      (_) async {
    const prefixBytes = 512 * 1024;
    const slowChunkBytes = 64 * 1024;
    const totalBytes = 2 * 1024 * 1024;
    final releaseSlowTail = Completer<void>();
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originSubscription = origin.listen((request) async {
      request.response.headers.contentLength = totalBytes;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.add(List<int>.filled(prefixBytes, 3));
      await request.response.flush();
      await releaseSlowTail.future;

      // Leave less than one native write batch pending for longer than the
      // progressive server's inactive-producer timeout. An active producer
      // must keep the response alive, and the next chunk must trigger the
      // native bounded-latency write.
      request.response.add(List<int>.filled(slowChunkBytes, 4));
      await request.response.flush();
      await Future<void>.delayed(const Duration(seconds: 6));
      request.response.add(List<int>.filled(slowChunkBytes, 4));
      await request.response.flush();
      request.response.add(
        List<int>.filled(totalBytes - prefixBytes - slowChunkBytes * 2, 5),
      );
      await request.response.close();
    });
    final cacheDir =
        await Directory.systemTemp.createTemp('kirakara_slow_tail_test_');
    final cache = PlaybackAssetCache(
      baseUrl: 'http://${origin.address.address}:${origin.port}',
      cacheDir: cacheDir,
      videoReadyBytes: prefixBytes,
    );
    final video = MediaAsset(
      id: 'slow-tail-video',
      type: MediaAssetType.video,
      uri: Uri.parse('/video.mp4'),
    );
    final song = Song(
      id: 'slow-tail-song',
      title: 'Slow tail',
      category: 'Test',
      assets: [video],
    );
    final client = HttpClient();
    try {
      await cache
          .ensurePlaybackAssets(song)
          .timeout(const Duration(seconds: 10));
      final playbackUrl = cache.playbackPathFor(video);
      expect(playbackUrl, startsWith('http://127.0.0.1:'));

      final response = await (await client.getUrl(Uri.parse(playbackUrl!)))
          .close()
          .timeout(const Duration(seconds: 5));
      var receivedBytes = 0;
      final sawPrefix = Completer<void>();
      final responseDone = Completer<void>();
      response.listen(
        (chunk) {
          receivedBytes += chunk.length;
          if (receivedBytes >= prefixBytes && !sawPrefix.isCompleted) {
            sawPrefix.complete();
          }
        },
        onError: responseDone.completeError,
        onDone: responseDone.complete,
        cancelOnError: true,
      );
      await sawPrefix.future.timeout(const Duration(seconds: 5));
      releaseSlowTail.complete();
      await responseDone.future.timeout(const Duration(seconds: 12));

      expect(response.statusCode, HttpStatus.ok);
      expect(receivedBytes, totalBytes);
      for (var i = 0; i < 80 && !cache.songProgress(song).complete; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(cache.songProgress(song).complete, isTrue);
      expect(cache.ioDiagnostics.writeCalls, greaterThan(1));
    } finally {
      if (!releaseSlowTail.isCompleted) releaseSlowTail.complete();
      client.close(force: true);
      cache.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await originSubscription.cancel();
      await origin.close(force: true);
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    }
  });
}
