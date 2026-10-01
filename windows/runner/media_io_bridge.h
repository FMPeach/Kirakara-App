#ifndef RUNNER_MEDIA_IO_BRIDGE_H_
#define RUNNER_MEDIA_IO_BRIDGE_H_

#include <flutter/binary_messenger.h>

void RegisterMediaIoBridge(flutter::BinaryMessenger* messenger);
void ShutdownMediaIoBridge();

#endif  // RUNNER_MEDIA_IO_BRIDGE_H_
