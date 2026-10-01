#ifndef RUNNER_WINDOW_BRIDGE_H_
#define RUNNER_WINDOW_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

void RegisterWindowBridge(flutter::BinaryMessenger* messenger, HWND flutter_view);

/// 显示器热插拔时从 C++ → Dart 发送通知。
void NotifyDisplayChange();

#endif  // RUNNER_WINDOW_BRIDGE_H_
