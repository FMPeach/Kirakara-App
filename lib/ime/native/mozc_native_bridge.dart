import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ime_native_bridge.dart';

class MozcNativeBridgeProbe {
  const MozcNativeBridgeProbe({
    this.executablePath,
  });

  final String? executablePath;

  NativeImeBridge probe() {
    if (!Platform.isWindows) {
      return const UnavailableNativeImeBridge(
        engineName: 'mozc',
        reason: 'Mozc helper is only bundled for Windows in this prototype',
      );
    }

    final path = executablePath ?? _defaultExecutablePath();
    if (!File(path).existsSync()) {
      return UnavailableNativeImeBridge(
        engineName: 'mozc',
        reason: 'Mozc helper was not found at $path',
      );
    }

    return MozcNativeBridge(executablePath: path);
  }

  static String _defaultExecutablePath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return _joinPath(exeDir, const [
      'ime',
      'mozc',
      'windows',
      'runtime',
      'kirakara_mozc_bridge.exe',
    ]);
  }
}

class MozcNativeBridge implements NativeImeBridge {
  const MozcNativeBridge({
    required this.executablePath,
    this.pageSize = defaultImeCandidatePageSize,
    this.timeout = const Duration(seconds: 5),
  });

  final String executablePath;
  final int pageSize;
  final Duration timeout;

  @override
  String get engineName => 'mozc';

  @override
  bool get isAvailable =>
      Platform.isWindows && File(executablePath).existsSync();

  @override
  String? get unavailableReason {
    if (isAvailable) {
      return null;
    }
    return 'Mozc helper was not found at $executablePath';
  }

  @override
  Future<void> activateSession(String sessionId) async {
    await _runJson(const ['activate']);
  }

  @override
  Future<void> deactivateSession(String sessionId) async {
    await _runJson(const ['deactivate']);
  }

  @override
  Future<NativeImeResult> compose({
    required String sessionId,
    required String rawInput,
    required int pageIndex,
  }) async {
    if (rawInput.isEmpty) {
      return const NativeImeResult(
        rawInput: '',
        preedit: '',
        candidates: [],
      );
    }

    final result = await _runJson([
      'compose',
      rawInput,
      '$pageIndex',
      '$pageSize',
    ]);
    return _fromNativeMap(result);
  }

  @override
  Future<NativeImeResult> clear(String sessionId) async {
    final result = await _runJson(const ['clear']);
    return _fromNativeMap(result);
  }

  Future<Map<String, Object?>> _runJson(List<String> arguments) async {
    if (!isAvailable) {
      throw StateError(unavailableReason ?? 'Mozc helper is unavailable');
    }

    final process = await Process.start(executablePath, arguments);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException(
          'Mozc helper timed out after ${timeout.inSeconds}s',
          timeout,
        );
      },
    );
    final stdoutText = await stdoutFuture;
    final stderrText = await stderrFuture;

    if (exitCode != 0) {
      throw StateError(
        'Mozc helper exited with code $exitCode: ${stderrText.trim()}',
      );
    }

    final decoded = _decodeJsonLine(stdoutText);
    if (decoded['ok'] == false) {
      throw StateError(
        (decoded['error'] as String?) ?? 'Unknown Mozc helper error',
      );
    }
    return decoded;
  }

  Map<String, Object?> _decodeJsonLine(String stdoutText) {
    for (final line in stdoutText.split(RegExp(r'\r?\n')).reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, Object?>();
      }
      throw StateError('Unexpected Mozc helper JSON response: $decoded');
    }
    throw StateError('Mozc helper returned no JSON output');
  }

  NativeImeResult _fromNativeMap(Map<String, Object?> result) {
    final rawInput = result['rawInput'] as String? ?? '';
    final preedit = result['preedit'] as String? ?? rawInput;
    final candidates = <NativeImeCandidate>[];
    final candidatesRaw = result['candidates'];
    if (candidatesRaw is List) {
      for (final item in candidatesRaw) {
        if (item is Map) {
          candidates.add(
            NativeImeCandidate(
              text: item['text'] as String? ?? '',
              annotation: item['annotation'] as String?,
              score: (item['score'] as num?)?.toDouble(),
            ),
          );
        }
      }
    }

    return NativeImeResult(
      rawInput: rawInput,
      preedit: preedit,
      candidates: candidates,
      pageIndex: (result['pageIndex'] as num?)?.toInt() ?? 0,
      hasPreviousPage: result['hasPreviousPage'] as bool? ?? false,
      hasNextPage: result['hasNextPage'] as bool? ?? false,
    );
  }
}

String _joinPath(String base, List<String> segments) {
  final separator = Platform.pathSeparator;
  final trimmedBase = base.endsWith(separator)
      ? base.substring(0, base.length - separator.length)
      : base;
  return ([trimmedBase, ...segments]).join(separator);
}
