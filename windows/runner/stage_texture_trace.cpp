#include "stage_texture_trace.h"

#include <windows.h>
#include <TraceLoggingProvider.h>

#include <atomic>
#include <iterator>
#include <mutex>

TRACELOGGING_DEFINE_PROVIDER(
    g_kirakara_stage_texture_provider,
    "Kirakara.App.StageTexture",
    (0x6862b681, 0x4cdb, 0x45e5, 0x93, 0x6c, 0x05, 0xd8, 0x2d, 0x83,
     0xef, 0x9a));

namespace {

constexpr ULONGLONG kFrameKeyword = 0x1;
constexpr UCHAR kInfoLevel = 4;
constexpr UCHAR kVerboseLevel = 5;
std::mutex g_provider_mutex;
std::uint32_t g_provider_users{};
std::atomic_uint64_t g_texture_callbacks{};
std::atomic_uint64_t g_frame_available_calls{};
std::atomic_uint64_t g_texture_acquires{};
std::atomic_uint64_t g_advanced_texture_acquires{};
std::atomic_uint64_t g_flutter_presents{};
std::atomic_uint64_t g_flutter_presents_with_new_acquire{};
std::atomic_uint64_t g_last_generation{};
std::atomic_uint64_t g_last_frame_id{};
std::atomic_uint64_t g_acquire_sequence{};
std::atomic_uint64_t g_presented_acquire_sequence{};

std::uint64_t QpcNow() {
  LARGE_INTEGER value{};
  return ::QueryPerformanceCounter(&value)
             ? static_cast<std::uint64_t>(value.QuadPart)
             : 0;
}

bool ReadFrameCountersEnabled() {
  wchar_t value[8]{};
  const auto length = ::GetEnvironmentVariableW(
      L"KIRAKARA_COMPOSITOR_DIAGNOSTICS", value,
      static_cast<DWORD>(std::size(value)));
  return length == 1 && value[0] == L'1';
}

}  // namespace

namespace stage_texture_trace {

void RegisterProvider() {
  std::lock_guard lock(g_provider_mutex);
  if (g_provider_users++ == 0) {
    TraceLoggingRegister(g_kirakara_stage_texture_provider);
  }
}

void UnregisterProvider() {
  std::lock_guard lock(g_provider_mutex);
  if (g_provider_users == 0 || --g_provider_users != 0) {
    return;
  }
  TraceLoggingUnregister(g_kirakara_stage_texture_provider);
}

bool FrameCountersEnabled() {
  static const bool enabled = ReadFrameCountersEnabled();
  return enabled;
}

FrameCounters GetFrameCounters() {
  FrameCounters counters;
  counters.enabled = FrameCountersEnabled();
  counters.texture_callbacks =
      g_texture_callbacks.load(std::memory_order_relaxed);
  counters.frame_available_calls =
      g_frame_available_calls.load(std::memory_order_relaxed);
  counters.texture_acquires =
      g_texture_acquires.load(std::memory_order_relaxed);
  counters.advanced_texture_acquires =
      g_advanced_texture_acquires.load(std::memory_order_relaxed);
  counters.flutter_presents =
      g_flutter_presents.load(std::memory_order_relaxed);
  counters.flutter_presents_with_new_acquire =
      g_flutter_presents_with_new_acquire.load(std::memory_order_relaxed);
  counters.last_generation =
      g_last_generation.load(std::memory_order_relaxed);
  counters.last_frame_id = g_last_frame_id.load(std::memory_order_relaxed);
  counters.acquire_sequence =
      g_acquire_sequence.load(std::memory_order_acquire);
  return counters;
}

void Attach(std::uint64_t host_address, std::int64_t texture_id,
            bool succeeded) {
  if (!TraceLoggingProviderEnabled(
          g_kirakara_stage_texture_provider, kInfoLevel, kFrameKeyword)) {
    return;
  }
  TraceLoggingWrite(
      g_kirakara_stage_texture_provider, "Attach",
      TraceLoggingLevel(kInfoLevel),
      TraceLoggingKeyword(kFrameKeyword), TraceLoggingUInt64(QpcNow(), "Qpc"),
      TraceLoggingUInt64(host_address, "HostAddress"),
      TraceLoggingInt64(texture_id, "TextureId"),
      TraceLoggingBool(succeeded, "Succeeded"),
      TraceLoggingUInt32(::GetCurrentThreadId(), "ThreadId"));
}

void SetActive(bool active, std::int64_t texture_id) {
  if (!TraceLoggingProviderEnabled(
          g_kirakara_stage_texture_provider, kInfoLevel, kFrameKeyword)) {
    return;
  }
  TraceLoggingWrite(
      g_kirakara_stage_texture_provider, "SetActive",
      TraceLoggingLevel(kInfoLevel),
      TraceLoggingKeyword(kFrameKeyword), TraceLoggingUInt64(QpcNow(), "Qpc"),
      TraceLoggingBool(active, "Active"),
      TraceLoggingInt64(texture_id, "TextureId"),
      TraceLoggingUInt32(::GetCurrentThreadId(), "ThreadId"));
}

void TextureCallback(std::uint64_t generation, std::uint64_t frame_id) {
  if (FrameCountersEnabled()) {
    g_texture_callbacks.fetch_add(1, std::memory_order_relaxed);
  }
  if (!TraceLoggingProviderEnabled(
          g_kirakara_stage_texture_provider, kVerboseLevel, kFrameKeyword)) {
    return;
  }
  TraceLoggingWrite(
      g_kirakara_stage_texture_provider, "TextureCallback",
      TraceLoggingLevel(kVerboseLevel),
      TraceLoggingKeyword(kFrameKeyword), TraceLoggingUInt64(QpcNow(), "Qpc"),
      TraceLoggingUInt64(generation, "Generation"),
      TraceLoggingUInt64(frame_id, "FrameId"),
      TraceLoggingUInt32(::GetCurrentThreadId(), "ThreadId"));
}

void FrameAvailable(std::uint64_t generation, std::uint64_t frame_id,
                    std::int64_t texture_id) {
  if (FrameCountersEnabled()) {
    g_frame_available_calls.fetch_add(1, std::memory_order_relaxed);
  }
  if (!TraceLoggingProviderEnabled(
          g_kirakara_stage_texture_provider, kVerboseLevel, kFrameKeyword)) {
    return;
  }
  TraceLoggingWrite(
      g_kirakara_stage_texture_provider, "FrameAvailable",
      TraceLoggingLevel(kVerboseLevel),
      TraceLoggingKeyword(kFrameKeyword), TraceLoggingUInt64(QpcNow(), "Qpc"),
      TraceLoggingUInt64(generation, "Generation"),
      TraceLoggingUInt64(frame_id, "FrameId"),
      TraceLoggingInt64(texture_id, "TextureId"),
      TraceLoggingUInt32(::GetCurrentThreadId(), "ThreadId"));
}

void TextureAcquire(std::uint64_t generation, std::uint64_t frame_id,
                    bool advanced) {
  if (FrameCountersEnabled()) {
    g_texture_acquires.fetch_add(1, std::memory_order_relaxed);
    if (advanced) {
      g_advanced_texture_acquires.fetch_add(1, std::memory_order_relaxed);
      g_last_generation.store(generation, std::memory_order_relaxed);
      g_last_frame_id.store(frame_id, std::memory_order_relaxed);
      g_acquire_sequence.fetch_add(1, std::memory_order_release);
    }
  }
  if (!TraceLoggingProviderEnabled(
          g_kirakara_stage_texture_provider, kVerboseLevel, kFrameKeyword)) {
    return;
  }
  TraceLoggingWrite(
      g_kirakara_stage_texture_provider, "TextureAcquire",
      TraceLoggingLevel(kVerboseLevel),
      TraceLoggingKeyword(kFrameKeyword), TraceLoggingUInt64(QpcNow(), "Qpc"),
      TraceLoggingUInt64(generation, "Generation"),
      TraceLoggingUInt64(frame_id, "FrameId"),
      TraceLoggingBool(advanced, "Advanced"),
      TraceLoggingUInt32(::GetCurrentThreadId(), "ThreadId"));
}

void FlutterFramePresented() {
  const auto presentation_id =
      g_flutter_presents.fetch_add(1, std::memory_order_relaxed) + 1;
  const auto acquire_sequence =
      g_acquire_sequence.load(std::memory_order_acquire);
  const auto previous_acquire_sequence =
      g_presented_acquire_sequence.exchange(
          acquire_sequence, std::memory_order_acq_rel);
  const bool acquired_since_previous_present =
      acquire_sequence != previous_acquire_sequence;
  if (acquired_since_previous_present) {
    g_flutter_presents_with_new_acquire.fetch_add(
        1, std::memory_order_relaxed);
  }

  if (!TraceLoggingProviderEnabled(
          g_kirakara_stage_texture_provider, kVerboseLevel, kFrameKeyword)) {
    return;
  }
  TraceLoggingWrite(
      g_kirakara_stage_texture_provider, "FlutterFramePresented",
      TraceLoggingLevel(kVerboseLevel),
      TraceLoggingKeyword(kFrameKeyword), TraceLoggingUInt64(QpcNow(), "Qpc"),
      TraceLoggingUInt64(presentation_id, "PresentationId"),
      TraceLoggingUInt64(acquire_sequence, "AcquireSequence"),
      TraceLoggingUInt64(
          g_last_generation.load(std::memory_order_relaxed), "Generation"),
      TraceLoggingUInt64(
          g_last_frame_id.load(std::memory_order_relaxed), "FrameId"),
      TraceLoggingBool(
          acquired_since_previous_present, "AcquiredSincePreviousPresent"),
      TraceLoggingUInt32(::GetCurrentThreadId(), "ThreadId"));
}

}  // namespace stage_texture_trace
