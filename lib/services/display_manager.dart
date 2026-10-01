import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_window_service.dart';

enum DisplayMode {
  singleScreen,
  dualScreen,
  previewWindow,
}

class DisplayInfo {
  const DisplayInfo({
    required this.id,
    required this.name,
    required this.isPrimary,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String id;
  final String name;
  final bool isPrimary;
  final int left;
  final int top;
  final int width;
  final int height;

  bool get isValidStageTarget => width > 0 && height > 0;

  String get sizeLabel => '${width}x$height';

  static DisplayInfo primaryFallback() {
    return const DisplayInfo(
      id: 'primary',
      name: '主控屏',
      isPrimary: true,
      left: 0,
      top: 0,
      width: 1920,
      height: 1080,
    );
  }

  static DisplayInfo fromNativeMap(Map<String, Object?> map, int index) {
    int readInt(String key, int fallback) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.round();
      return fallback;
    }

    final rawId = map['id']?.toString();
    final rawName = map['name']?.toString();
    final isPrimary = map['isPrimary'] == true;
    return DisplayInfo(
      id: rawId == null || rawId.isEmpty ? 'display-$index' : rawId,
      name: rawName == null || rawName.isEmpty
          ? (isPrimary ? '主控屏' : '显示器 $index')
          : rawName,
      isPrimary: isPrimary,
      left: readInt('left', 0),
      top: readInt('top', 0),
      width: readInt('width', 0),
      height: readInt('height', 0),
    );
  }
}

class DisplayManager extends ChangeNotifier {
  DisplayManager({
    NativeWindowService nativeWindowService = const NativeWindowService(),
  })  : _nativeWindowService = nativeWindowService,
        _displays = [DisplayInfo.primaryFallback()];

  final NativeWindowService _nativeWindowService;

  List<DisplayInfo> _displays;
  DisplayMode _mode = DisplayMode.singleScreen;
  bool _stagePreviewVisible = false;
  String? _selectedStageDisplayId;

  // ── 热插拔检测 ─────────────────────────────────────────────────
  Timer? _hotPlugDebounce;
  bool _hadStageDisplay = false;

  /// 第二屏从无到有时触发（热插拔插入后自动开双屏）。
  VoidCallback? onStageDisplayAttached;

  List<DisplayInfo> get displays => List.unmodifiable(_displays);
  List<DisplayInfo> get stageDisplays => List.unmodifiable(
        _displays.where(
          (display) => !display.isPrimary && display.isValidStageTarget,
        ),
      );
  DisplayMode get mode => _mode;
  bool get hasPhysicalStageDisplay => stageDisplays.isNotEmpty;
  bool get stagePreviewVisible => _stagePreviewVisible;
  DisplayInfo get controllerDisplay => _displays.firstWhere(
        (display) => display.isPrimary,
        orElse: () => _displays.first,
      );
  DisplayInfo? get stageDisplay {
    final candidates = stageDisplays;
    if (candidates.isEmpty) return null;
    final selectedId = _selectedStageDisplayId;
    if (selectedId != null) {
      for (final display in candidates) {
        if (display.id == selectedId) return display;
      }
    }
    return candidates.first;
  }

  Future<void> detectDisplays() async {
    final nativeDisplays = await _nativeWindowService.getDisplays();
    final displays = <DisplayInfo>[];
    for (var i = 0; i < nativeDisplays.length; i++) {
      final display = DisplayInfo.fromNativeMap(nativeDisplays[i], i + 1);
      if (display.isValidStageTarget) displays.add(display);
    }
    _displays = displays.isEmpty ? [DisplayInfo.primaryFallback()] : displays;
    final candidates = stageDisplays;
    if (candidates.isEmpty) {
      _selectedStageDisplayId = null;
    } else if (!candidates.any(
      (display) => display.id == _selectedStageDisplayId,
    )) {
      _selectedStageDisplayId = candidates.first.id;
    }
    if (_mode == DisplayMode.dualScreen && !hasPhysicalStageDisplay) {
      _mode = DisplayMode.singleScreen;
    }
    _hadStageDisplay = hasPhysicalStageDisplay;
    notifyListeners();
  }

  void selectStageDisplay(String displayId) {
    for (final display in stageDisplays) {
      if (display.id != displayId) continue;
      if (_selectedStageDisplayId == display.id) return;
      _selectedStageDisplayId = display.id;
      notifyListeners();
      return;
    }
  }

  Future<void> openStageWindow({bool preview = true}) async {
    _stagePreviewVisible = preview;
    _mode = preview ? DisplayMode.previewWindow : DisplayMode.dualScreen;
    notifyListeners();
  }

  Future<void> closeStageWindow() async {
    _stagePreviewVisible = false;
    _mode = DisplayMode.singleScreen;
    notifyListeners();
  }

  Future<void> savePreference(DisplayMode mode) async {
    _mode = mode;
    notifyListeners();
  }

  // ── 热插拔 ──────────────────────────────────────────────────────

  /// 启动显示器热插拔监听。应在 App 初始化后调用一次。
  void startHotPlugDetection() {
    _nativeWindowService.setDisplayChangeHandler(_onNativeDisplayChange);
  }

  void _onNativeDisplayChange() {
    // WM_DISPLAYCHANGE 可能连续触发多次（分辨率协商过程），debounce 800ms
    _hotPlugDebounce?.cancel();
    _hotPlugDebounce = Timer(const Duration(milliseconds: 800), () async {
      final wasPresent = _hadStageDisplay;
      await detectDisplays();
      // 第二屏从无到有 → 通知 App 自动开双屏
      if (!wasPresent && hasPhysicalStageDisplay) {
        onStageDisplayAttached?.call();
      }
    });
  }

  @override
  void dispose() {
    _hotPlugDebounce?.cancel();
    super.dispose();
  }
}
