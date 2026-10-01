import 'dart:async' show Timer;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart'
    show Ticker, TickerCallback, TickerProvider;
import 'package:qr_flutter/qr_flutter.dart';

import '../../domain/media_asset.dart';
import '../../domain/playback_state.dart';
import '../../domain/queue_item.dart';
import '../../domain/song.dart';
import '../../engine/stage_renderer.dart';
import '../../services/bilibili_account_service.dart';
import '../../services/cast_service.dart';
import '../../services/dlna/dlna_device.dart';
import '../../services/display_manager.dart';
import '../../services/kirakara_show_service.dart';
import '../../services/lan_server.dart';
import '../../services/native_window_service.dart';
import '../../services/playback_asset_cache.dart';
import '../../services/playback_service.dart';
import '../../services/playback_slot.dart';
import '../../services/playback_slot_manager.dart';
import '../../services/queue_service.dart';
import '../../services/search_service.dart';
import '../../services/settings_service.dart';
import '../browse/browse_mode.dart';
import '../theme/kirakara_theme.dart';
import '../theme/layout_tokens.dart';
import '../widgets/kira_design_canvas.dart';
import '../widgets/ktv_button.dart';
import 'browse_screen.dart';
import '../stage/stage_preview_host.dart';

part '../controller/widgets/top_bar.dart';
part '../controller/home/home_screen.dart';
part '../controller/widgets/bottom_bar.dart';
part '../controller/widgets/settings_dialog.dart';
part '../controller/widgets/dialog_widgets.dart';
part '../controller/widgets/output_dialog.dart';

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({
    super.key,
    required this.searchService,
    required this.queueService,
    required this.playbackService,
    required this.assetCache,
    required this.slotManager,
    required this.settingsService,
    required this.bilibiliAccountService,
    required this.displayManager,
    required this.kirakaraShowService,
    required this.castService,
    required this.lanServer,
    required this.stageRenderer,
  });

  final SearchService searchService;
  final QueueService queueService;
  final PlaybackService playbackService;
  final PlaybackAssetCache assetCache;
  final PlaybackSlotManager slotManager;
  final SettingsService settingsService;
  final BilibiliAccountService bilibiliAccountService;
  final DisplayManager displayManager;
  final KirakaraShowService kirakaraShowService;
  final CastService castService;
  final LanServer lanServer;
  final StageRenderer stageRenderer;

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  final NativeWindowService _nativeWindowService = const NativeWindowService();
  BrowseMode? _browseMode;
  String _browseInitialQuery = '';
  int _browseSerial = 0;
  bool _controllerFullscreen = false;

  @override
  void initState() {
    super.initState();
    _startLanServer();
    _loadControllerFullscreenState();
  }

  Future<void> _loadControllerFullscreenState() async {
    final fullscreen = await _nativeWindowService.isControllerFullscreen();
    if (!mounted) return;
    setState(() => _controllerFullscreen = fullscreen);
  }

  Future<void> _startLanServer() async {
    try {
      await widget.lanServer.start();
      if (!mounted) {
        return;
      }
      setState(() {});
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: KiraDesignCanvas(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: KiraColors.bg,
            // A full-screen gaussian blur (large blurRadius) is very expensive
            // on low-end iGPUs (1130G7). Keep the flat backdrop and let each
            // panel repaint lazily instead of blurring the whole screen each
            // frame.
          ),
          child: Column(
            children: [
              // Each panel listens only to the services it actually needs, so
              // a high-frequency notification (playback tick / cast state /
              // buffering) can no longer rebuild the entire screen.
              ListenableBuilder(
                listenable: Listenable.merge([
                  widget.playbackService,
                  widget.castService,
                  widget.kirakaraShowService,
                  widget.settingsService,
                  widget.displayManager,
                ]),
                builder: (context, _) => _TopBar(
                  customAnnouncement: widget.settingsService.customAnnouncement,
                  playbackService: widget.playbackService,
                  isLoading: widget.kirakaraShowService.isLoading,
                  isBuffering: widget.kirakaraShowService.isBuffering,
                  showSearch: _browseMode == null,
                  controllerFullscreen: _controllerFullscreen,
                  isCasting: widget.castService.isCasting,
                  announcementMotion:
                      widget.displayManager.mode == DisplayMode.dualScreen
                          ? _AnnouncementMotion.lowMotionHardCut
                          : widget.castService.state != CastState.idle
                              ? _AnnouncementMotion.lowMotionFade
                              : _AnnouncementMotion.marquee,
                  onSearchTap: () => _runSearch(''),
                  onQr: _showQrDialog,
                  onSettings: _showSettingsDialog,
                  onFullscreen: _toggleControllerFullscreen,
                  onCast: _showCastDialog,
                ),
              ),
              Expanded(
                child: _browseMode == null
                    ? Padding(
                        padding: KiraLayout.pagePadding,
                        child: Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: ListenableBuilder(
                                listenable: Listenable.merge([
                                  widget.playbackService,
                                  widget.castService,
                                ]),
                                builder: (context, _) => _LeftPane(
                                  playbackService: widget.playbackService,
                                  castService: widget.castService,
                                  stageRenderer: widget.stageRenderer,
                                ),
                              ),
                            ),
                            const SizedBox(width: KiraLayout.sectionGap),
                            Expanded(
                              flex: 1,
                              child: _RightPane(
                                onPanel: _showPanel,
                              ),
                            ),
                          ],
                        ),
                      )
                    : BrowseScreen(
                        key: ValueKey(_browseSerial),
                        searchService: widget.searchService,
                        bilibiliAccountService: widget.bilibiliAccountService,
                        initialMode: _browseMode!,
                        initialQuery: _browseInitialQuery,
                        onExit: _closeBrowsePage,
                        onAddSong: _addSong,
                        onBumpSong: _bumpSong,
                      ),
              ),
              ListenableBuilder(
                listenable: Listenable.merge([
                  widget.playbackService,
                  widget.castService,
                  widget.queueService,
                ]),
                builder: (context, _) => _BottomBar(
                  playbackService: widget.playbackService,
                  queueService: widget.queueService,
                  castService: widget.castService,
                  onQueue: _showQueueDialog,
                  onAfterQueueChanged: () {
                    widget.playbackService.refreshUpNext();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runSearch(String query) async {
    setState(() {
      _browseMode = BrowseMode.songs;
      _browseInitialQuery = query.trim();
      _browseSerial++;
    });
  }

  void _addSong(Song song) {
    if (widget.playbackService.state.currentItem == null) {
      _startSongAfterFrame(song);
    } else {
      widget.queueService.addSong(song);
      widget.playbackService.refreshUpNext();
    }
  }

  void _bumpSong(Song song) {
    if (widget.playbackService.state.currentItem == null) {
      _startSongAfterFrame(song);
    } else {
      widget.queueService.bumpToNext(song);
      widget.playbackService.refreshUpNext();
    }
  }

  void _startSongAfterFrame(Song song) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.playbackService.state.currentItem != null) return;
      widget.playbackService.setCurrentSong(song, startPlaying: true);
    });
  }

  void _showPanel(String title) {
    final mode = switch (title) {
      '歌名点歌' => BrowseMode.songs,
      '歌手点歌' => BrowseMode.artists,
      '分类点歌' => BrowseMode.categories,
      '外链点歌' => BrowseMode.externalLink,
      '排行榜' => BrowseMode.ranking,
      _ => null,
    };

    if (mode == null) {
      _showControllerDialog<void>(
        builder: (context) {
          return _KiraDialog(
            title: title,
            width: 500,
            child: Text(
              '$title 后续会接入对应的列表、排序和加入队列流程。',
              style: const TextStyle(
                color: KiraColors.muted,
                height: 1.6,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
        },
      );
      return;
    }

    setState(() {
      _browseMode = mode;
      _browseInitialQuery = '';
      _browseSerial++;
    });
  }

  void _closeBrowsePage() {
    setState(() {
      _browseMode = null;
      _browseInitialQuery = '';
    });
  }

  _SlotProgress _slotProgressForSong(
    Song song,
    PlaybackSlot? activeSlot, {
    required bool isCurrent,
  }) {
    // 当前播放中且 active slot 匹配且有有效数据
    if (isCurrent &&
        activeSlot?.songId == song.id &&
        activeSlot!.downloadTotal > 0) {
      final slot = activeSlot;
      return _SlotProgress(
        state: slot.state,
        downloaded: slot.downloadedBytes,
        total: slot.downloadTotal,
        complete: slot.downloadComplete,
      );
    }
    // 从缓存获取进度
    final progress = widget.assetCache.songProgress(song);
    if (progress.complete) {
      return _SlotProgress(
        state: SlotState.ready,
        downloaded: progress.downloaded,
        total: progress.total,
        complete: true,
      );
    }
    if (progress.total > 0 || progress.downloaded > 0) {
      return _SlotProgress(
        state: SlotState.preparing,
        downloaded: progress.downloaded,
        total: progress.total,
        complete: false,
      );
    }
    return const _SlotProgress(
      state: SlotState.empty,
      downloaded: 0,
      total: 0,
      complete: false,
    );
  }

  void _retryQueueItem(QueueItem item) {
    widget.assetCache.resetFailuresForSong(item.song);
    widget.queueService.retry(item.id);
    if (widget.playbackService.state.currentItem == null) {
      widget.playbackService.next();
    } else {
      widget.playbackService.refreshUpNext();
    }
  }

  void _showQueueDialog() {
    _showControllerDialog<void>(
      builder: (context) {
        return AnimatedBuilder(
          animation: Listenable.merge([
            widget.queueService,
            widget.playbackService,
            widget.assetCache,
            widget.slotManager,
          ]),
          builder: (context, _) {
            final currentItem = widget.playbackService.state.currentItem;
            final queueItems = widget.queueService.items;
            final activeSlot = widget.slotManager.activeSlot;
            return _KiraDialog(
              title: '点歌列表',
              width: 680,
              child: SizedBox(
                height: 420,
                child: Column(
                  children: [
                    // ── 正在播放 ──
                    if (currentItem != null) ...[
                      _QueueItemRow(
                        index: 0,
                        song: currentItem.song,
                        subtitle:
                            '${currentItem.song.artist?.name ?? '未知'} · 正在播放',
                        isCurrent: true,
                        progress: widget.assetCache.progressForSong(
                          currentItem.song,
                        ),
                        slotProgress: _slotProgressForSong(
                          currentItem.song,
                          activeSlot,
                          isCurrent: true,
                        ),
                        failed: false,
                        onRetry: null,
                        onBump: null,
                        onDelete: null,
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Text(
                              '下一首',
                              style: TextStyle(
                                color: KiraColors.muted,
                                fontSize: 13,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Divider(height: 1, color: KiraColors.line),
                            ),
                          ],
                        ),
                      ),
                    ],
                    // ── 队列 ──
                    Expanded(
                      child: queueItems.isEmpty
                          ? const Center(
                              child: Text(
                                '队列为空，去点一首歌吧',
                                style: TextStyle(
                                  color: KiraColors.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: queueItems.length,
                              itemBuilder: (context, index) {
                                final item = queueItems[index];
                                final progress = widget.assetCache
                                    .progressForSong(item.song);
                                final failed = widget.queueService.isFailed(
                                      item.id,
                                    ) ||
                                    progress.hasFailed;
                                return _QueueItemRow(
                                  index: index + 1,
                                  song: item.song,
                                  subtitle:
                                      '${item.song.artist?.name ?? '未知'} · ${item.song.category}',
                                  isCurrent: false,
                                  progress: progress,
                                  slotProgress: _slotProgressForSong(
                                    item.song,
                                    activeSlot,
                                    isCurrent: false,
                                  ),
                                  failed: failed,
                                  onRetry: failed
                                      ? () => _retryQueueItem(item)
                                      : null,
                                  onBump: failed
                                      ? null
                                      : () {
                                          widget.queueService.bumpItemToNext(
                                            item.id,
                                          );
                                          widget.playbackService
                                              .refreshUpNext();
                                        },
                                  onDelete: failed
                                      ? null
                                      : () {
                                          widget.queueService.remove(item.id);
                                          widget.playbackService
                                              .refreshUpNext();
                                        },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showQrDialog() {
    _showControllerDialog<void>(
      builder: (context) {
        final uri = widget.lanServer.localUri;
        return _KiraDialog(
          title: '手机点歌',
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (uri != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: QrImageView(
                    data: uri.toString(),
                    version: QrVersions.auto,
                    size: 210,
                    backgroundColor: Colors.white,
                  ),
                )
              else
                Container(
                  width: 210,
                  height: 210,
                  decoration: BoxDecoration(
                    color: KiraColors.surface2,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child:
                        Icon(Icons.wifi_off, size: 48, color: KiraColors.muted),
                  ),
                ),
              const SizedBox(height: 18),
              Text(
                uri?.toString() ?? '未检测到局域网 — 请检查网络设置',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: KiraColors.amber,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '手机连接同一 WiFi / 局域网后扫码即可点歌',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: KiraColors.muted,
                  height: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleControllerFullscreen() async {
    final next = !_controllerFullscreen;
    final ok = await _nativeWindowService.setControllerFullscreen(next);
    if (!mounted) return;
    setState(() => _controllerFullscreen = ok ? next : _controllerFullscreen);
  }

  void _showCastDialog() {
    _showControllerDialog<void>(
      builder: (context) => _OutputDialog(
        displayManager: widget.displayManager,
        castService: widget.castService,
        settingsService: widget.settingsService,
        onDualChanged: _setDualOutputEnabled,
        onCastChanged: _setCastModeEnabled,
        onDisplaySelected: _selectStageDisplay,
        onRefreshDisplays: _refreshDisplays,
        onCastDevicePressed: _toggleCastDevice,
      ),
    );
  }

  Future<void> _setDualOutputEnabled(bool enabled) async {
    if (!enabled) {
      await _closeStageOutput();
      return;
    }
    if (widget.castService.isEnabled) {
      await widget.castService.disableCastMode(
        showService: widget.kirakaraShowService,
      );
    }
    await _openPhysicalStageOutput();
  }

  Future<void> _setCastModeEnabled(bool enabled) async {
    if (!enabled) {
      await widget.castService.disableCastMode(
        showService: widget.kirakaraShowService,
      );
      return;
    }
    if (_hasStageOutput) await _closeStageOutput();
    await widget.castService.enableCastMode(
      includePureK: widget.settingsService.dlnaDeepSearchEnabled,
    );
  }

  Future<void> _selectStageDisplay(DisplayInfo display) async {
    widget.displayManager.selectStageDisplay(display.id);
    if (widget.displayManager.mode == DisplayMode.dualScreen) {
      _applyPhysicalDisplayRect(display);
    }
  }

  Future<void> _toggleCastDevice(DlnaDevice device) async {
    if (_hasStageOutput) await _closeStageOutput();
    await widget.castService.connectToDevice(
      device,
      widget.kirakaraShowService,
    );
  }

  void _applyPhysicalDisplayRect(DisplayInfo display) {
    widget.kirakaraShowService.setStageWindowRect(
      x: display.left,
      y: display.top,
      width: display.width,
      height: display.height,
    );
  }

  Future<void> _openPhysicalStageOutput() async {
    if (widget.castService.isEnabled ||
        widget.castService.state != CastState.idle) {
      _showStageOutputLeaseSnackBar();
      return;
    }
    final display = widget.displayManager.stageDisplay;
    if (display == null) return;
    _applyPhysicalDisplayRect(display);
    await widget.displayManager.openStageWindow(preview: false);
    widget.kirakaraShowService.setStageWindowVisible(true);
  }

  Future<void> _closeStageOutput() async {
    await widget.displayManager.closeStageWindow();
    widget.kirakaraShowService.setStageWindowVisible(false);
  }

  bool get _hasStageOutput =>
      widget.displayManager.mode == DisplayMode.dualScreen ||
      widget.displayManager.mode == DisplayMode.previewWindow;

  void _showStageOutputLeaseSnackBar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无线投屏正在占用显示输出，请先停止投屏')),
    );
  }

  Future<void> _refreshDisplays() async {
    await widget.displayManager.detectDisplays();
    final display = widget.displayManager.stageDisplay;
    if (display == null &&
        widget.displayManager.mode == DisplayMode.singleScreen) {
      widget.kirakaraShowService.setStageWindowVisible(false);
    } else if (display != null &&
        widget.displayManager.mode == DisplayMode.dualScreen) {
      _applyPhysicalDisplayRect(display);
    }
  }

  void _showSettingsDialog() {
    _showControllerDialog<void>(
      builder: (context) {
        return _SettingsDialog(
          settingsService: widget.settingsService,
          assetCache: widget.assetCache,
          lanServer: widget.lanServer,
        );
      },
    );
  }

  Future<T?> _showControllerDialog<T>({
    required WidgetBuilder builder,
  }) {
    return showDialog<T>(
      context: context,
      builder: builder,
    );
  }
}
