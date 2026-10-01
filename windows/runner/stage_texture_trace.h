#ifndef RUNNER_STAGE_TEXTURE_TRACE_H_
#define RUNNER_STAGE_TEXTURE_TRACE_H_

#include <cstdint>

namespace stage_texture_trace {

struct FrameCounters {
  bool enabled{};
  std::uint64_t texture_callbacks{};
  std::uint64_t frame_available_calls{};
  std::uint64_t texture_acquires{};
  std::uint64_t advanced_texture_acquires{};
  std::uint64_t flutter_presents{};
  std::uint64_t flutter_presents_with_new_acquire{};
  std::uint64_t last_generation{};
  std::uint64_t last_frame_id{};
  std::uint64_t acquire_sequence{};
};

void RegisterProvider();
void UnregisterProvider();

bool FrameCountersEnabled();
FrameCounters GetFrameCounters();

void Attach(std::uint64_t host_address, std::int64_t texture_id,
            bool succeeded);
void SetActive(bool active, std::int64_t texture_id);
void TextureCallback(std::uint64_t generation, std::uint64_t frame_id);
void FrameAvailable(std::uint64_t generation, std::uint64_t frame_id,
                    std::int64_t texture_id);
void TextureAcquire(std::uint64_t generation, std::uint64_t frame_id,
                    bool advanced);
void FlutterFramePresented();

}  // namespace stage_texture_trace

#endif  // RUNNER_STAGE_TEXTURE_TRACE_H_
