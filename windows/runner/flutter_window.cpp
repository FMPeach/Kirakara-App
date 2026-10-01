#include "flutter_window.h"

#include <atomic>
#include <optional>
#include <wtsapi32.h>

#include "dcomp_compositor_bridge.h"
#include "flutter/generated_plugin_registrant.h"
#include "ime_bridge.h"
#include "media_io_bridge.h"
#include "stage_texture_bridge.h"
#include "stage_texture_trace.h"
#include "window_bridge.h"

namespace {

constexpr UINT kArmFlutterPresentTraceMessage = WM_APP + 0x4B;

}  // namespace

struct FlutterPresentTraceState {
  std::atomic_bool enabled{true};
  std::atomic_bool callback_pending{};
  std::atomic<HWND> window{};
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  dcomp_compositor_bridge_ = std::make_unique<DcompCompositorBridge>();
  std::string compositor_error;
  if (!dcomp_compositor_bridge_->PrepareNextView(GetHandle(),
                                                 &compositor_error)) {
    ReportDcompCompositorStartupError(GetHandle(), compositor_error);
    return false;
  }

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    dcomp_compositor_bridge_->CancelPreparedView();
    return false;
  }
  if (!dcomp_compositor_bridge_->Attach(flutter_controller_->engine(),
                                        &compositor_error)) {
    ReportDcompCompositorStartupError(GetHandle(), compositor_error);
    flutter_controller_.reset();
    return false;
  }
  session_notifications_registered_ =
      ::WTSRegisterSessionNotification(GetHandle(),
                                       NOTIFY_FOR_THIS_SESSION) != FALSE;
  if (dcomp_compositor_bridge_->enabled()) {
    dcomp_compositor_bridge_->SetSessionNotificationsRegistered(
        session_notifications_registered_);
  }
  UpdateCompositorWindowAvailability();
  RegisterPlugins(flutter_controller_->engine());
  RegisterImeBridge(flutter_controller_->engine()->messenger());
  RegisterMediaIoBridge(flutter_controller_->engine()->messenger());
  RegisterWindowBridge(flutter_controller_->engine()->messenger(),
                       flutter_controller_->view()->GetNativeWindow());
  stage_texture_bridge_ = std::make_unique<StageTextureBridge>(
      flutter_controller_->engine());
  UpdateCompositorWindowAvailability();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  if (stage_texture_trace::FrameCountersEnabled()) {
    flutter_present_trace_state_ =
        std::make_shared<FlutterPresentTraceState>();
    flutter_present_trace_state_->window.store(
        GetHandle(), std::memory_order_release);
  }
  const auto window = GetHandle();
  const auto trace_state = flutter_present_trace_state_;
  flutter_controller_->engine()->SetNextFrameCallback([window, trace_state]() {
    ::ShowWindow(window, SW_SHOWNORMAL);
    if (trace_state && trace_state->enabled.load(std::memory_order_acquire)) {
      stage_texture_trace::FlutterFramePresented();
      const auto trace_window =
          trace_state->window.load(std::memory_order_acquire);
      if (trace_window) {
        ::PostMessageW(trace_window, kArmFlutterPresentTraceMessage, 0, 0);
      }
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (session_notifications_registered_) {
    ::WTSUnRegisterSessionNotification(GetHandle());
    session_notifications_registered_ = false;
    if (dcomp_compositor_bridge_) {
      dcomp_compositor_bridge_->SetSessionNotificationsRegistered(false);
    }
  }
  if (flutter_present_trace_state_) {
    flutter_present_trace_state_->enabled.store(
        false, std::memory_order_release);
    flutter_present_trace_state_->window.store(
        nullptr, std::memory_order_release);
  }
  ShutdownMediaIoBridge();
  if (stage_texture_bridge_) {
    stage_texture_bridge_->BeginShutdown();
  }
  if (dcomp_compositor_bridge_) {
    dcomp_compositor_bridge_->Shutdown();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  stage_texture_bridge_ = nullptr;
  dcomp_compositor_bridge_ = nullptr;
  flutter_present_trace_state_.reset();

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kArmFlutterPresentTraceMessage) {
    ArmFlutterPresentTrace();
    return 0;
  }
  if (message == kKirakaraCompositorResizeForTestMessage) {
    if (dcomp_compositor_bridge_) {
      dcomp_compositor_bridge_->HandleTestResizeMessage(
          static_cast<int32_t>(static_cast<intptr_t>(wparam)),
          static_cast<int32_t>(static_cast<intptr_t>(lparam)));
    }
    return 0;
  }
  if (message == kKirakaraCompositorMoveToMonitorForTestMessage) {
    if (dcomp_compositor_bridge_) {
      dcomp_compositor_bridge_->HandleTestMoveToMonitorMessage(
          static_cast<int32_t>(wparam));
    }
    return 0;
  }

  // Lifecycle state must be observed even when Flutter's top-level window
  // handler consumes the corresponding message below.
  switch (message) {
    case WM_SIZE:
      compositor_window_minimized_ = wparam == SIZE_MINIMIZED;
      UpdateCompositorWindowAvailability();
      break;
    case WM_SHOWWINDOW:
      UpdateCompositorWindowAvailability();
      break;
    case WM_POWERBROADCAST:
      if (wparam == PBT_APMSUSPEND) {
        compositor_power_suspended_ = true;
        UpdateCompositorWindowAvailability();
      } else if (wparam == PBT_APMRESUMEAUTOMATIC ||
                 wparam == PBT_APMRESUMECRITICAL ||
                 wparam == PBT_APMRESUMESUSPEND) {
        compositor_power_suspended_ = false;
        UpdateCompositorWindowAvailability();
      }
      break;
    case WM_WTSSESSION_CHANGE:
      if (wparam == WTS_SESSION_LOCK) {
        compositor_session_locked_ = true;
        UpdateCompositorWindowAvailability();
      } else if (wparam == WTS_SESSION_UNLOCK) {
        compositor_session_locked_ = false;
        UpdateCompositorWindowAvailability();
      }
      break;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DISPLAYCHANGE:
      // 显示器热插拔：通知 Dart 端重新枚举显示器
      NotifyDisplayChange();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::UpdateCompositorWindowAvailability() {
  const HWND window = GetHandle();
  const bool available = window && ::IsWindowVisible(window) &&
                         !compositor_window_minimized_ &&
                         !compositor_power_suspended_ &&
                         !compositor_session_locked_;
  if (dcomp_compositor_bridge_ && dcomp_compositor_bridge_->enabled()) {
    dcomp_compositor_bridge_->HandleWindowAvailabilityChanged(available);
  }
  if (stage_texture_bridge_) {
    stage_texture_bridge_->HandleWindowAvailabilityChanged(available);
  }
}

void FlutterWindow::ArmFlutterPresentTrace() {
  const auto trace_state = flutter_present_trace_state_;
  if (!trace_state ||
      !trace_state->enabled.load(std::memory_order_acquire) ||
      !flutter_controller_ ||
      trace_state->callback_pending.exchange(
          true, std::memory_order_acq_rel)) {
    return;
  }
  flutter_controller_->engine()->SetNextFrameCallback([trace_state]() {
    trace_state->callback_pending.store(false, std::memory_order_release);
    if (!trace_state->enabled.load(std::memory_order_acquire)) {
      return;
    }
    // The stock Windows embedder invokes this callback only after a successful
    // SwapBuffers, then posts it back to the platform thread. Re-arm through a
    // window message so the client wrapper can clear its one-shot callback
    // before the next one is installed. This waits for frames; it never
    // schedules a frame, polls, or starts a timer.
    stage_texture_trace::FlutterFramePresented();
    const auto window = trace_state->window.load(std::memory_order_acquire);
    if (window) {
      ::PostMessageW(window, kArmFlutterPresentTraceMessage, 0, 0);
    }
  });
}
