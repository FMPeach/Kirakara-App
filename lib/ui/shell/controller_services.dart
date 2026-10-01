import '../../engine/stage_renderer.dart';
import '../../services/bilibili_account_service.dart';
import '../../services/cast_service.dart';
import '../../services/display_manager.dart';
import '../../services/kirakara_show_service.dart';
import '../../services/lan_server.dart';
import '../../services/playback_asset_cache.dart';
import '../../services/playback_service.dart';
import '../../services/playback_slot_manager.dart';
import '../../services/queue_service.dart';
import '../../services/search_service.dart';
import '../../services/settings_service.dart';

class ControllerServices {
  const ControllerServices({
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
}
