import 'package:flutter/widgets.dart';

import '../screens/controller_screen.dart';
import 'controller_services.dart';

class ControllerShell extends StatelessWidget {
  const ControllerShell({
    super.key,
    required this.services,
  });

  final ControllerServices services;

  @override
  Widget build(BuildContext context) {
    return ControllerScreen(
      searchService: services.searchService,
      queueService: services.queueService,
      playbackService: services.playbackService,
      assetCache: services.assetCache,
      slotManager: services.slotManager,
      settingsService: services.settingsService,
      bilibiliAccountService: services.bilibiliAccountService,
      displayManager: services.displayManager,
      kirakaraShowService: services.kirakaraShowService,
      castService: services.castService,
      lanServer: services.lanServer,
      stageRenderer: services.stageRenderer,
    );
  }
}
