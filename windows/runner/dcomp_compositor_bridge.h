#ifndef RUNNER_DCOMP_COMPOSITOR_BRIDGE_H_
#define RUNNER_DCOMP_COMPOSITOR_BRIDGE_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

#include <memory>
#include <string>

constexpr UINT kKirakaraCompositorResizeForTestMessage = WM_APP + 0x4C;
constexpr UINT kKirakaraCompositorMoveToMonitorForTestMessage = WM_APP + 0x4D;

// Opt-in bridge to the versioned Kirakara API exported only by the patched
// Flutter Engine. With the environment variable unset, this class leaves the
// stock Engine path completely untouched.
class DcompCompositorBridge {
 public:
  DcompCompositorBridge();
  ~DcompCompositorBridge();

  DcompCompositorBridge(const DcompCompositorBridge&) = delete;
  DcompCompositorBridge& operator=(const DcompCompositorBridge&) = delete;

  // Resolves and validates the custom Engine API, then arms exactly the next
  // view creation. Returns false only for an explicit opt-in that cannot be
  // honored; an unset/stock backend returns true without doing anything.
  bool PrepareNextView(HWND top_level_window, std::string* error);

  // Binds diagnostics to the view created after PrepareNextView and registers
  // the Dart diagnostics channel.
  bool Attach(flutter::FlutterEngine* engine, std::string* error);

  void CancelPreparedView();
  void Shutdown();

  // Applies a bounded resize previously requested through the test-only Dart
  // channel. This runs from the window message loop after the method response
  // has returned, so Dart can produce the corresponding resize frame.
  bool HandleTestResizeMessage(int32_t width_delta, int32_t height_delta);

  // Centers the test window on an enumerated monitor. A per-monitor-aware
  // window receives WM_DPICHANGED and applies the OS recommended bounds.
  bool HandleTestMoveToMonitorMessage(int32_t monitor_index);

  // Updates whether the top-level window can currently display composition.
  // The requested Stage activity is retained while the window is minimized,
  // the user session is locked, or the machine is suspended, then restored
  // without rebuilding the Show host or HWND.
  void HandleWindowAvailabilityChanged(bool available);

  // Records whether the Runner successfully subscribed to this session's
  // lock/unlock messages so diagnostics can distinguish a tested route from
  // an unavailable OS notification source.
  void SetSessionNotificationsRegistered(bool registered);

  bool enabled() const { return enabled_; }

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  bool enabled_ = false;
};

// Reports a hard opt-in startup failure both to the debugger and to the user.
void ReportDcompCompositorStartupError(HWND owner, const std::string& error);

#endif  // RUNNER_DCOMP_COMPOSITOR_BRIDGE_H_
