import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/catalog/catalog_client.dart';
import '../data/local_db/local_database.dart';
import '../engine/kirakara_stage_renderer.dart';
import '../engine/stage_renderer.dart';
import '../services/bilibili_account_service.dart';
import '../services/cast_service.dart';
import '../services/display_manager.dart';
import '../services/kirakara_show_service.dart';
import '../services/lan_server.dart';
import '../services/playback_asset_cache.dart';
import '../services/playback_service.dart';
import '../services/playback_slot_manager.dart';
import '../services/queue_service.dart';
import '../services/search_service.dart';
import '../services/settings_service.dart';
import '../ui/shell/controller_services.dart';
import '../ui/shell/controller_shell.dart';
import '../ui/theme/kirakara_theme.dart';

class KirakaraApp extends StatefulWidget {
  const KirakaraApp({
    super.key,
    required this.databasePath,
    this.cacheDirectoryPath,
    this.settingsFilePath,
    this.lanServerBindAddress,
  });

  final String databasePath;
  final String? cacheDirectoryPath;
  final String? settingsFilePath;
  final InternetAddress? lanServerBindAddress;

  @override
  State<KirakaraApp> createState() => _KirakaraAppState();
}

class _KirakaraAppState extends State<KirakaraApp> {
  late final LocalDatabase _localDb;
  late final HttpCatalogClient _catalogClient;
  late final SearchService searchService;
  late final QueueService queueService;
  late final PlaybackService playbackService;
  late final DisplayManager displayManager;
  late final CastService castService;
  late final LanServer lanServer;
  late final PlaybackAssetCache _assetCache;
  late final PlaybackSlotManager _slotManager;
  late final SettingsService settingsService;
  late final BilibiliAccountService bilibiliAccountService;
  late final KirakaraShowService kirakaraShowService;
  late final StageRenderer stageRenderer;

  @override
  void initState() {
    super.initState();
    _localDb = LocalDatabase(dbPath: widget.databasePath);
    _localDb.open(); // 同步打开，确保 SearchService 可用
    _catalogClient = HttpCatalogClient(
      baseUrl: Uri.parse('http://localhost:7392'),
    );
    final cacheRoot = Directory(
      widget.cacheDirectoryPath ??
          p.join(Directory.systemTemp.path, 'Kirakara_Cache'),
    );
    _assetCache = PlaybackAssetCache(
      baseUrl: 'http://localhost:7392',
      cacheRoot: cacheRoot,
    );

    // 先用 fallback 数据初始化 SearchService，等同步完成后再刷新
    searchService = SearchService(db: _localDb);
    queueService = QueueService();

    playbackService = PlaybackService(
      queueService: queueService,
    );
    playbackService.refreshUpNext();
    _slotManager = PlaybackSlotManager(
      queueService: queueService,
      assetCache: _assetCache,
      onQueueAvailabilityChanged: playbackService.refreshUpNext,
    );
    final settingsFilePath =
        widget.settingsFilePath ?? p.join(cacheRoot.path, 'settings.json');
    settingsService = SettingsService(
      initialCacheDirectoryPath: cacheRoot.path,
      settingsFilePath: settingsFilePath,
    )..addListener(_applySettings);
    unawaited(settingsService.load());
    bilibiliAccountService = BilibiliAccountService(
      sessionFilePath: p.join(
        p.dirname(settingsFilePath),
        'bilibili_session.json',
      ),
    );
    unawaited(bilibiliAccountService.load());
    kirakaraShowService = KirakaraShowService(
      playbackService: playbackService,
      assetCache: _assetCache,
      slotManager: _slotManager,
    )..start();
    displayManager = DisplayManager();
    castService = CastService();
    lanServer = LanServer(
      queueService: queueService,
      searchService: searchService,
      playbackService: playbackService,
      bilibiliAccountService: bilibiliAccountService,
      bindAddress: widget.lanServerBindAddress,
    );
    stageRenderer = KirakaraStageRenderer(showService: kirakaraShowService);
    // 热插拔：插入第二屏后自动开双屏
    displayManager.onStageDisplayAttached = _onStageDisplayHotPlugged;
    unawaited(_initializeDisplayOutput());
    // 启动后开始监听 WM_DISPLAYCHANGE
    displayManager.startHotPlugDetection();
    unawaited(_syncCatalog());
  }

  Future<void> _syncCatalog() async {
    try {
      final manifest = await _catalogClient.fetchManifest();
      _localDb.replaceAll(manifest);
      searchService.labelMaps = manifest.labelMaps;
      searchService.invalidateCache();
      if (mounted) {
        setState(() {
          // SearchService 下次读取 featuredSongs 时自动从 DB 取
        });
      }
    } catch (e) {
      debugPrint('Catalog sync failed; keeping the local catalog index: $e');
    }
  }

  void _applySettings() {
    _slotManager.setPrefetchLookahead(settingsService.prefetchLookahead);
  }

  Future<void> _initializeDisplayOutput() async {
    await displayManager.detectDisplays();
    if (!mounted) return;

    final stageDisplay = displayManager.stageDisplay;
    if (stageDisplay == null) {
      kirakaraShowService.setStageWindowVisible(false);
      return;
    }

    kirakaraShowService.setStageWindowRect(
      x: stageDisplay.left,
      y: stageDisplay.top,
      width: stageDisplay.width,
      height: stageDisplay.height,
    );
    await displayManager.openStageWindow(preview: false);
    kirakaraShowService.setStageWindowVisible(true);
  }

  /// 热插拔：第二屏从无到有时自动开双屏（和启动时逻辑一致）。
  Future<void> _onStageDisplayHotPlugged() async {
    if (!mounted) return;
    // 投屏占用时不抢
    if (castService.isEnabled) return;
    final stageDisplay = displayManager.stageDisplay;
    if (stageDisplay == null) return;

    kirakaraShowService.setStageWindowRect(
      x: stageDisplay.left,
      y: stageDisplay.top,
      width: stageDisplay.width,
      height: stageDisplay.height,
    );
    await displayManager.openStageWindow(preview: false);
    kirakaraShowService.setStageWindowVisible(true);
  }

  @override
  void dispose() {
    castService.dispose();
    unawaited(kirakaraShowService.dispose());
    playbackService.disposeService();
    lanServer.stop();
    _slotManager.dispose();
    displayManager.dispose();
    settingsService
      ..removeListener(_applySettings)
      ..dispose();
    bilibiliAccountService.dispose();
    _assetCache.clear();
    _assetCache.dispose();
    _catalogClient.dispose();
    _localDb.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Kira Karaoke',
      theme: buildKirakaraTheme(),
      home: ControllerShell(
        services: ControllerServices(
          searchService: searchService,
          queueService: queueService,
          playbackService: playbackService,
          assetCache: _assetCache,
          slotManager: _slotManager,
          settingsService: settingsService,
          bilibiliAccountService: bilibiliAccountService,
          displayManager: displayManager,
          kirakaraShowService: kirakaraShowService,
          castService: castService,
          lanServer: lanServer,
          stageRenderer: stageRenderer,
        ),
      ),
    );
  }
}
