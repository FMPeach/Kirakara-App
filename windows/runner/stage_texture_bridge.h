#ifndef RUNNER_STAGE_TEXTURE_BRIDGE_H_
#define RUNNER_STAGE_TEXTURE_BRIDGE_H_

#include <flutter/flutter_engine.h>

#include <memory>

class StageTextureBridge {
 public:
  explicit StageTextureBridge(flutter::FlutterEngine* engine);
  ~StageTextureBridge();

  StageTextureBridge(const StageTextureBridge&) = delete;
  StageTextureBridge& operator=(const StageTextureBridge&) = delete;

  void BeginShutdown();
  void HandleWindowAvailabilityChanged(bool available);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_STAGE_TEXTURE_BRIDGE_H_
