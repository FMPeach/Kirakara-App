import 'package:flutter/widgets.dart';

import 'windows_compositor/synthetic_compositor_harness.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SyntheticCompositorHarness());
}
