import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../domain/stage_overlay_state.dart';

final class ShowHostStageOverlayAssetNative extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int reserved;

  @Uint64()
  external int contentRevision;

  external Pointer<Utf16> cacheKey;
  external Pointer<Utf16> localPath;
}

final class ShowHostStageOverlayStateNative extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int flags;

  @Uint64()
  external int revision;

  external Pointer<Utf16> qrPayload;
  external ShowHostStageOverlayAssetNative qrDecoration;
  external Pointer<Utf16> announcementText;
  external ShowHostStageOverlayAssetNative announcementDecoration;
}

// ── C type aliases ────────────────────────────────────────────────

typedef ShowHostHandle = Pointer<Void>;

typedef CreateNative = ShowHostHandle Function();
typedef DestroyNative = Void Function(ShowHostHandle);
typedef LoadNative = Bool Function(
  ShowHostHandle,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
);
typedef LoadWithClockNative = Bool Function(
  ShowHostHandle,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Int32,
);
typedef LoadWithOptionsNative = Bool Function(
  ShowHostHandle,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Int32,
  Int32,
);
typedef PrepareNextNative = Bool Function(
  ShowHostHandle,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Int32,
);
typedef PlayNative = Void Function(ShowHostHandle);
typedef PauseNative = Void Function(ShowHostHandle);
typedef StopNative = Void Function(ShowHostHandle);
typedef ReplayNative = Void Function(ShowHostHandle);
typedef SeekNative = Void Function(ShowHostHandle, Double);
typedef SetVolumeNative = Void Function(ShowHostHandle, Int32);
typedef SetKeyNative = Void Function(ShowHostHandle, Int32);
typedef SetAudioClockOffsetNative = Void Function(ShowHostHandle, Double);
typedef SetAudioTrackNative = Bool Function(ShowHostHandle, Int32);
typedef SetStageVisibleNative = Void Function(ShowHostHandle, Bool);
typedef SetStageWindowRectNative = Void Function(
  ShowHostHandle,
  Int32,
  Int32,
  Uint32,
  Uint32,
);
typedef GetPositionNative = Double Function(ShowHostHandle);
typedef GetDurationNative = Double Function(ShowHostHandle);
typedef GetStateNative = Int Function(ShowHostHandle);
typedef IsBufferingNative = Bool Function(ShowHostHandle);
typedef GetWidthNative = Uint32 Function(ShowHostHandle);
typedef GetHeightNative = Uint32 Function(ShowHostHandle);
typedef StartCastStreamNative = Bool Function(ShowHostHandle, Uint16);
typedef GetCastStreamPortNative = Uint16 Function(ShowHostHandle);
typedef StopCastStreamNative = Void Function(ShowHostHandle);
typedef SetStageOverlayStateNative = Bool Function(
  ShowHostHandle,
  Pointer<ShowHostStageOverlayStateNative>,
);

// ── Dart function signatures ──────────────────────────────────────

typedef _Create = ShowHostHandle Function();
typedef _Destroy = void Function(ShowHostHandle);
typedef _Load = bool Function(
  ShowHostHandle,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
);
typedef _LoadWithClock = bool Function(
  ShowHostHandle,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  int,
);
typedef _LoadWithOptions = bool Function(
  ShowHostHandle,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  int,
  int,
);
typedef _PrepareNext = bool Function(
  ShowHostHandle,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  int,
);
typedef _Play = void Function(ShowHostHandle);
typedef _Pause = void Function(ShowHostHandle);
typedef _Stop = void Function(ShowHostHandle);
typedef _Replay = void Function(ShowHostHandle);
typedef _Seek = void Function(ShowHostHandle, double);
typedef _SetVolume = void Function(ShowHostHandle, int);
typedef _SetKey = void Function(ShowHostHandle, int);
typedef _SetAudioClockOffset = void Function(ShowHostHandle, double);
typedef _SetAudioTrack = bool Function(ShowHostHandle, int);
typedef _SetStageVisible = void Function(ShowHostHandle, bool);
typedef _SetStageWindowRect = void Function(
  ShowHostHandle,
  int,
  int,
  int,
  int,
);
typedef _GetPosition = double Function(ShowHostHandle);
typedef _GetDuration = double Function(ShowHostHandle);
typedef _GetState = int Function(ShowHostHandle);
typedef _IsBuffering = bool Function(ShowHostHandle);
typedef _GetWidth = int Function(ShowHostHandle);
typedef _GetHeight = int Function(ShowHostHandle);
typedef _StartCastStream = bool Function(ShowHostHandle, int);
typedef _GetCastStreamPort = int Function(ShowHostHandle);
typedef _StopCastStream = void Function(ShowHostHandle);
typedef _SetStageOverlayState = bool Function(
  ShowHostHandle,
  Pointer<ShowHostStageOverlayStateNative>,
);

final class _ShowLoadJob {
  const _ShowLoadJob({
    required this.dllPath,
    required this.handleAddress,
    required this.videoPath,
    required this.lyricPath,
    required this.vocalPath,
    required this.accompanimentPath,
    required this.clockMode,
    required this.transitionMode,
  });

  final String dllPath;
  final int handleAddress;
  final String videoPath;
  final String lyricPath;
  final String vocalPath;
  final String accompanimentPath;
  final int clockMode;
  final int transitionMode;
}

bool _invokeSynchronousShowLoad(_ShowLoadJob job) {
  final dylib = DynamicLibrary.open(job.dllPath);
  final handle = Pointer<Void>.fromAddress(job.handleAddress);
  final video = job.videoPath.toNativeUtf16();
  final lyric = job.lyricPath.toNativeUtf16();
  final vocal = job.vocalPath.toNativeUtf16();
  final accompaniment = job.accompanimentPath.toNativeUtf16();
  try {
    try {
      final loadWithOptions =
          dylib.lookupFunction<LoadWithOptionsNative, _LoadWithOptions>(
              'show_host_load_with_options');
      return loadWithOptions(
        handle,
        video,
        lyric,
        vocal,
        accompaniment,
        job.clockMode,
        job.transitionMode,
      );
    } on ArgumentError {
      try {
        final loadWithClock =
            dylib.lookupFunction<LoadWithClockNative, _LoadWithClock>(
          'show_host_load_with_clock',
        );
        return loadWithClock(
          handle,
          video,
          lyric,
          vocal,
          accompaniment,
          job.clockMode,
        );
      } on ArgumentError {
        final load = dylib.lookupFunction<LoadNative, _Load>('show_host_load');
        return load(handle, video, lyric, vocal, accompaniment);
      }
    }
  } finally {
    calloc.free(video);
    calloc.free(lyric);
    calloc.free(vocal);
    calloc.free(accompaniment);
    dylib.close();
  }
}

// ── KirakaraShowFFI ───────────────────────────────────────────────

class KirakaraShowFFI {
  factory KirakaraShowFFI({String? dllPath}) {
    final resolvedPath = dllPath ?? _defaultDllPath();
    return KirakaraShowFFI._(
      resolvedPath,
      DynamicLibrary.open(resolvedPath),
    );
  }

  KirakaraShowFFI._(this._dllPath, this._dylib) {
    _bind();
  }

  final String _dllPath;
  final DynamicLibrary _dylib;
  late final ShowHostHandle _handle;

  late final _Create _create;
  late final _Destroy _destroy;
  late final _Load _load;
  _LoadWithClock? _loadWithClock;
  _LoadWithOptions? _loadWithOptions;
  _PrepareNext? _prepareNext;
  late final _Play _play;
  late final _Pause _pause;
  late final _Stop _stop;
  _Replay? _replay;
  late final _Seek _seek;
  late final _SetVolume _setVolume;
  late final _SetKey _setKey;
  late final _SetAudioClockOffset _setAudioClockOffset;
  late final _SetAudioTrack _setAudioTrack;
  late final _SetStageVisible _setStageVisible;
  late final _SetStageWindowRect _setStageWindowRect;
  late final _GetPosition _getPosition;
  late final _GetDuration _getDuration;
  late final _GetState _getState;
  _IsBuffering? _isBuffering;
  late final _GetWidth _getWidth;
  late final _GetHeight _getHeight;
  _StartCastStream? _startCastStream;
  _GetCastStreamPort? _getCastStreamPort;
  _StopCastStream? _stopCastStream;
  _SetStageOverlayState? _setStageOverlayState;

  int _width = 0;
  int _height = 0;
  bool _disposed = false;
  int get width => _width;
  int get height => _height;
  int get nativeHandleAddress => _handle.address;

  void _bind() {
    _create = _dylib.lookupFunction<CreateNative, _Create>('show_host_create');
    _destroy =
        _dylib.lookupFunction<DestroyNative, _Destroy>('show_host_destroy');
    _load = _dylib.lookupFunction<LoadNative, _Load>('show_host_load');
    try {
      _loadWithClock =
          _dylib.lookupFunction<LoadWithClockNative, _LoadWithClock>(
              'show_host_load_with_clock');
    } on ArgumentError {
      _loadWithClock = null;
    }
    try {
      _loadWithOptions =
          _dylib.lookupFunction<LoadWithOptionsNative, _LoadWithOptions>(
        'show_host_load_with_options',
      );
    } on ArgumentError {
      _loadWithOptions = null;
    }
    try {
      _prepareNext = _dylib.lookupFunction<PrepareNextNative, _PrepareNext>(
        'show_host_prepare_next',
      );
    } on ArgumentError {
      _prepareNext = null;
    }
    _play = _dylib.lookupFunction<PlayNative, _Play>('show_host_play');
    _pause = _dylib.lookupFunction<PauseNative, _Pause>('show_host_pause');
    _stop = _dylib.lookupFunction<StopNative, _Stop>('show_host_stop');
    try {
      _replay = _dylib.lookupFunction<ReplayNative, _Replay>(
        'show_host_replay',
      );
    } on ArgumentError {
      // Pre-title Show builds do not export program-level replay.
      _replay = null;
    }
    _seek = _dylib.lookupFunction<SeekNative, _Seek>('show_host_seek');
    _setVolume = _dylib.lookupFunction<SetVolumeNative, _SetVolume>(
      'show_host_set_volume',
    );
    _setKey = _dylib.lookupFunction<SetKeyNative, _SetKey>(
      'show_host_set_key_semitones',
    );
    _setAudioClockOffset =
        _dylib.lookupFunction<SetAudioClockOffsetNative, _SetAudioClockOffset>(
      'show_host_set_audio_clock_offset',
    );
    _setAudioTrack = _dylib.lookupFunction<SetAudioTrackNative, _SetAudioTrack>(
      'show_host_set_audio_track',
    );
    _setStageVisible =
        _dylib.lookupFunction<SetStageVisibleNative, _SetStageVisible>(
      'show_host_set_stage_visible',
    );
    _setStageWindowRect =
        _dylib.lookupFunction<SetStageWindowRectNative, _SetStageWindowRect>(
            'show_host_set_stage_window_rect');
    _getPosition = _dylib.lookupFunction<GetPositionNative, _GetPosition>(
        'show_host_get_position');
    _getDuration = _dylib.lookupFunction<GetDurationNative, _GetDuration>(
        'show_host_get_duration');
    _getState =
        _dylib.lookupFunction<GetStateNative, _GetState>('show_host_get_state');
    try {
      _isBuffering = _dylib.lookupFunction<IsBufferingNative, _IsBuffering>(
        'show_host_is_buffering',
      );
    } on ArgumentError {
      _isBuffering = null;
    }
    _getWidth =
        _dylib.lookupFunction<GetWidthNative, _GetWidth>('show_host_get_width');
    _getHeight = _dylib
        .lookupFunction<GetHeightNative, _GetHeight>('show_host_get_height');
    try {
      _startCastStream =
          _dylib.lookupFunction<StartCastStreamNative, _StartCastStream>(
              'show_host_start_cast_stream');
      _stopCastStream =
          _dylib.lookupFunction<StopCastStreamNative, _StopCastStream>(
              'show_host_stop_cast_stream');
      _getCastStreamPort =
          _dylib.lookupFunction<GetCastStreamPortNative, _GetCastStreamPort>(
              'show_host_get_cast_stream_port');
    } on ArgumentError {
      _startCastStream = null;
      _getCastStreamPort = null;
      _stopCastStream = null;
    }
    try {
      _setStageOverlayState = _dylib.lookupFunction<SetStageOverlayStateNative,
          _SetStageOverlayState>('show_host_set_stage_overlay_state');
    } on ArgumentError {
      _setStageOverlayState = null;
    }

    _handle = _create();
  }

  bool load(
    String videoPath, {
    String? lyricPath,
    String? vocalPath,
    String? accompanimentPath,
    bool videoMasterClock = false,
    bool seamlessTransition = false,
  }) {
    final video = videoPath.toNativeUtf16();
    final lyric = (lyricPath ?? '').toNativeUtf16();
    final vocal = (vocalPath ?? '').toNativeUtf16();
    final accompaniment = (accompanimentPath ?? '').toNativeUtf16();
    try {
      final loadWithOptions = _loadWithOptions;
      final loadWithClock = _loadWithClock;
      final ok = loadWithOptions != null
          ? loadWithOptions(
              _handle,
              video,
              lyric,
              vocal,
              accompaniment,
              videoMasterClock ? 1 : 0,
              seamlessTransition ? 1 : 0,
            )
          : loadWithClock != null
              ? loadWithClock(
                  _handle,
                  video,
                  lyric,
                  vocal,
                  accompaniment,
                  videoMasterClock ? 1 : 0,
                )
              : _load(_handle, video, lyric, vocal, accompaniment);
      if (ok) {
        _width = _getWidth(_handle);
        _height = _getHeight(_handle);
      }
      return ok;
    } finally {
      calloc.free(video);
      calloc.free(lyric);
      calloc.free(vocal);
      calloc.free(accompaniment);
    }
  }

  /// Invokes Show's synchronous load API from an App-owned helper isolate.
  Future<bool> loadOffUiIsolate(
    String videoPath, {
    String? lyricPath,
    String? vocalPath,
    String? accompanimentPath,
    bool videoMasterClock = false,
    bool seamlessTransition = false,
  }) async {
    if (_disposed) return false;
    final job = _ShowLoadJob(
      dllPath: _dllPath,
      handleAddress: _handle.address,
      videoPath: videoPath,
      lyricPath: lyricPath ?? '',
      vocalPath: vocalPath ?? '',
      accompanimentPath: accompanimentPath ?? '',
      clockMode: videoMasterClock ? 1 : 0,
      transitionMode: seamlessTransition ? 1 : 0,
    );
    final loaded = await Isolate.run(
      () => _invokeSynchronousShowLoad(job),
    );
    if (loaded && !_disposed) {
      _width = _getWidth(_handle);
      _height = _getHeight(_handle);
    }
    return loaded;
  }

  bool prepareNext(
    String videoPath, {
    String? lyricPath,
    String? vocalPath,
    String? accompanimentPath,
    bool videoMasterClock = false,
  }) {
    final prepareNext = _prepareNext;
    if (prepareNext == null) return false;
    final video = videoPath.toNativeUtf16();
    final lyric = (lyricPath ?? '').toNativeUtf16();
    final vocal = (vocalPath ?? '').toNativeUtf16();
    final accompaniment = (accompanimentPath ?? '').toNativeUtf16();
    try {
      return prepareNext(
        _handle,
        video,
        lyric,
        vocal,
        accompaniment,
        videoMasterClock ? 1 : 0,
      );
    } finally {
      calloc.free(video);
      calloc.free(lyric);
      calloc.free(vocal);
      calloc.free(accompaniment);
    }
  }

  void play() => _play(_handle);
  void pause() => _pause(_handle);
  void stop() => _stop(_handle);
  bool replay() {
    final replay = _replay;
    if (replay == null) return false;
    replay(_handle);
    return true;
  }

  void seek(double seconds) => _seek(_handle, seconds);
  void setVolume(int volumePercent) => _setVolume(_handle, volumePercent);
  void setKeySemitones(int keySemitones) => _setKey(_handle, keySemitones);
  void setAudioClockOffset(double seconds) =>
      _setAudioClockOffset(_handle, seconds);
  bool setAudioTrack(int track) => _setAudioTrack(_handle, track);
  void setStageVisible(bool visible) => _setStageVisible(_handle, visible);
  void setStageWindowRect({
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    _setStageWindowRect(_handle, x, y, width, height);
  }

  double get position => _getPosition(_handle);
  double get duration => _getDuration(_handle);
  int get state => _getState(_handle);
  bool get isBuffering => _isBuffering?.call(_handle) ?? false;

  bool startCastStream(int port) =>
      _startCastStream?.call(_handle, port) ?? false;
  int get castStreamPort => _getCastStreamPort?.call(_handle) ?? 0;
  void stopCastStream() => _stopCastStream?.call(_handle);

  bool setStageOverlayState(StageOverlayState state) {
    final setter = _setStageOverlayState;
    if (setter == null || !state.isValid) return false;

    final native = calloc<ShowHostStageOverlayStateNative>();
    final allocations = <Pointer<Utf16>>[];
    Pointer<Utf16> allocateText(String value) {
      if (value.isEmpty) return nullptr;
      final pointer = value.toNativeUtf16();
      allocations.add(pointer);
      return pointer;
    }

    void writeAsset(
      ShowHostStageOverlayAssetNative target,
      StageOverlayAsset? asset,
    ) {
      target
        ..structSize = sizeOf<ShowHostStageOverlayAssetNative>()
        ..reserved = 0
        ..contentRevision = asset?.contentRevision ?? 0
        ..cacheKey = allocateText(asset?.cacheKey ?? '')
        ..localPath = allocateText(asset?.localPath ?? '');
    }

    try {
      final value = native.ref;
      value
        ..structSize = sizeOf<ShowHostStageOverlayStateNative>()
        ..flags =
            (state.qrVisible ? 1 : 0) | (state.announcementVisible ? 2 : 0)
        ..revision = state.revision
        ..qrPayload = allocateText(state.qrPayload)
        ..announcementText = allocateText(state.announcementText);
      writeAsset(value.qrDecoration, state.qrDecoration);
      writeAsset(
        value.announcementDecoration,
        state.announcementDecoration,
      );
      return setter(_handle, native);
    } finally {
      for (final pointer in allocations) {
        calloc.free(pointer);
      }
      calloc.free(native);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _destroy(_handle);
    _dylib.close();
  }

  static String _defaultDllPath() {
    if (Platform.isWindows) {
      final exeDir = Directory(Platform.resolvedExecutable).parent;

      // Prefer the runtime bundle selected and validated by the Windows build.
      final exePath = '${exeDir.path}\\libshow_host.dll';
      if (File(exePath).existsSync()) return exePath;

      // Last resort for explicitly managed deployments.
      return 'libshow_host.dll';
    }
    throw UnsupportedError('KirakaraShowFFI is only supported on Windows');
  }
}
