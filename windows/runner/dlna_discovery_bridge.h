#ifndef RUNNER_DLNA_DISCOVERY_BRIDGE_H_
#define RUNNER_DLNA_DISCOVERY_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

constexpr UINT kKirakaraDlnaDiscoveryEventMessage = WM_APP + 0x4F;

void RegisterDlnaDiscoveryBridge(flutter::BinaryMessenger* messenger,
                                 HWND message_window);
void DispatchDlnaDiscoveryEvents();
void ShutdownDlnaDiscoveryBridge();

#endif  // RUNNER_DLNA_DISCOVERY_BRIDGE_H_
