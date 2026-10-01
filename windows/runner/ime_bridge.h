#ifndef RUNNER_IME_BRIDGE_H_
#define RUNNER_IME_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <string>

void RegisterImeBridge(flutter::BinaryMessenger* messenger);
bool RunImeBridgeSelfTest(const std::wstring& output_path);

#endif  // RUNNER_IME_BRIDGE_H_
