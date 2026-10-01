#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

class StageTextureBridge;
class DcompCompositorBridge;
struct FlutterPresentTraceState;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void ArmFlutterPresentTrace();
  void UpdateCompositorWindowAvailability();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<DcompCompositorBridge> dcomp_compositor_bridge_;
  std::unique_ptr<StageTextureBridge> stage_texture_bridge_;
  std::shared_ptr<FlutterPresentTraceState> flutter_present_trace_state_;
  bool compositor_window_minimized_ = false;
  bool compositor_power_suspended_ = false;
  bool compositor_session_locked_ = false;
  bool session_notifications_registered_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
