import 'package:flutter/widgets.dart';

import 'windows_compositor/real_stage_compositor_harness.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RealStageCompositorHarness());
}
