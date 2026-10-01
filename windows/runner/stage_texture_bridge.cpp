#include "stage_texture_bridge.h"

#include "stage_texture_trace.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_texture_registrar.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <iterator>
#include <memory>
#include <mutex>
#include <string>
#include <variant>

namespace {

using ShowHostHandle = void*;
using ShowHostStageTextureSource = void*;
using FrameAvailableCallback = void (*)(void*, uintptr_t, uint32_t, uint32_t,
                                        uint64_t, uint64_t);

struct ShowHostStageTextureFrame {
  uintptr_t shared_handle;
  uint32_t width;
  uint32_t height;
  uint64_t generation;
  uint64_t frame_id;
};

using CreateSource = ShowHostStageTextureSource (*)(ShowHostHandle);
using DestroySource = void (*)(ShowHostStageTextureSource);
using SetSourceActive = void (*)(ShowHostStageTextureSource, bool);
using SetFrameCallback = void (*)(ShowHostStageTextureSource,
                                  FrameAvailableCallback,
                                  void*);
using SetStageDevice = bool (*)(ShowHostHandle, uintptr_t);

struct ShowTextureApi {
  HMODULE module{};
  CreateSource create_source{};
  DestroySource destroy_source{};
  SetSourceActive set_active{};
  SetFrameCallback set_callback{};
  SetStageDevice set_stage_device{};

  bool Load() {
    // Keep a loader reference independent from KirakaraShowFFI. The Dart FFI
    // owner may close and reopen its DynamicLibrary during a Show rebuild,
    // while this bridge still needs its source teardown entrypoints.
    module = LoadLibraryW(L"libshow_host.dll");
    if (!module) {
      return false;
    }
    create_source = reinterpret_cast<CreateSource>(
        GetProcAddress(module, "show_host_create_stage_texture_source"));
    destroy_source = reinterpret_cast<DestroySource>(
        GetProcAddress(module, "show_host_destroy_stage_texture_source"));
    set_active = reinterpret_cast<SetSourceActive>(
        GetProcAddress(module, "show_host_stage_texture_source_set_active"));
    set_callback = reinterpret_cast<SetFrameCallback>(GetProcAddress(
        module, "show_host_stage_texture_source_set_frame_callback"));
    set_stage_device = reinterpret_cast<SetStageDevice>(
        GetProcAddress(module, "show_host_set_stage_d3d_device"));
    if (create_source && destroy_source && set_active && set_callback &&
        set_stage_device) {
      return true;
    }
    Unload();
    return false;
  }

  void Unload() {
    create_source = nullptr;
    destroy_source = nullptr;
    set_active = nullptr;
    set_callback = nullptr;
    set_stage_device = nullptr;
    if (module) {
      FreeLibrary(module);
      module = nullptr;
    }
  }
};

int64_t ReadInt64(const flutter::EncodableValue* value,
                  const std::string& key) {
  if (!value) {
    return 0;
  }
  const auto* map = std::get_if<flutter::EncodableMap>(value);
  if (!map) {
    return 0;
  }
  const auto found = map->find(flutter::EncodableValue(key));
  if (found == map->end()) {
    return 0;
  }
  if (const auto* number = std::get_if<int64_t>(&found->second)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(&found->second)) {
    return *number;
  }
  return 0;
}

bool ReadBool(const flutter::EncodableValue* value,
              const std::string& key,
              bool fallback) {
  if (!value) {
    return fallback;
  }
  const auto* map = std::get_if<flutter::EncodableMap>(value);
  if (!map) {
    return fallback;
  }
  const auto found = map->find(flutter::EncodableValue(key));
  if (found == map->end()) {
    return fallback;
  }
  if (const auto* boolean = std::get_if<bool>(&found->second)) {
    return *boolean;
  }
  return fallback;
}

bool StageTextureTestModeEnabled() {
  wchar_t value[2]{};
  return ::GetEnvironmentVariableW(L"KIRAKARA_COMPOSITOR_TEST_MODE", value,
                                   static_cast<DWORD>(std::size(value))) == 1 &&
         value[0] == L'1';
}

}  // namespace

struct StageTextureBridge::Impl {
  explicit Impl(flutter::FlutterEngine* flutter_engine)
      : engine(flutter_engine),
        registrar(flutter_engine
                      ? FlutterDesktopRegistrarGetTextureRegistrar(
                            flutter_engine->GetRegistrarForPlugin(
                                "kirakara_stage_texture"))
                      : nullptr) {
    stage_texture_trace::RegisterProvider();
    RegisterChannel();
  }

  ~Impl() {
    BeginShutdown();
    ReleaseCurrentFrame();
    DestroySource();
    channel.reset();
    api.Unload();
    stage_texture_trace::UnregisterProvider();
  }

  void RegisterChannel() {
    if (!engine) {
      return;
    }
    channel = std::make_unique<
        flutter::MethodChannel<flutter::EncodableValue>>(
        engine->messenger(), "kirakara/stage_texture",
        &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<
                   flutter::MethodResult<flutter::EncodableValue>> result) {
          if (call.method_name() == "attach") {
            const auto host_address = ReadInt64(
                call.arguments(), "hostHandle");
            const auto id = Attach(reinterpret_cast<ShowHostHandle>(
                static_cast<intptr_t>(host_address)));
            if (id < 0) {
              result->Error("stage_texture_unavailable",
                            "Unable to attach the Unified Stage texture");
            } else {
              result->Success(flutter::EncodableValue(id));
            }
            return;
          }
          if (call.method_name() == "setActive") {
            const bool active = ReadBool(
                call.arguments(), "active", false);
            SetActive(active);
            result->Success(flutter::EncodableValue(true));
            return;
          }
          if (call.method_name() == "detach") {
            DetachSource();
            result->Success(flutter::EncodableValue(true));
            return;
          }
          if (call.method_name() == "isSupported") {
            result->Success(flutter::EncodableValue(EnsureApi()));
            return;
          }
          if (call.method_name() == "getDiagnosticsCounters") {
            const auto counters = stage_texture_trace::GetFrameCounters();
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("enabled"),
                 flutter::EncodableValue(counters.enabled)},
                {flutter::EncodableValue("textureCallbacks"),
                 flutter::EncodableValue(
                     static_cast<std::int64_t>(counters.texture_callbacks))},
                {flutter::EncodableValue("frameAvailableCalls"),
                 flutter::EncodableValue(static_cast<std::int64_t>(
                     counters.frame_available_calls))},
                {flutter::EncodableValue("textureAcquires"),
                 flutter::EncodableValue(
                     static_cast<std::int64_t>(counters.texture_acquires))},
                {flutter::EncodableValue("advancedTextureAcquires"),
                 flutter::EncodableValue(static_cast<std::int64_t>(
                     counters.advanced_texture_acquires))},
                {flutter::EncodableValue("flutterPresents"),
                 flutter::EncodableValue(
                     static_cast<std::int64_t>(counters.flutter_presents))},
                {flutter::EncodableValue("flutterPresentsWithNewAcquire"),
                 flutter::EncodableValue(static_cast<std::int64_t>(
                     counters.flutter_presents_with_new_acquire))},
                {flutter::EncodableValue("lastGeneration"),
                 flutter::EncodableValue(
                     static_cast<std::int64_t>(counters.last_generation))},
                {flutter::EncodableValue("lastFrameId"),
                 flutter::EncodableValue(
                     static_cast<std::int64_t>(counters.last_frame_id))},
                {flutter::EncodableValue("acquireSequence"),
                 flutter::EncodableValue(
                     static_cast<std::int64_t>(counters.acquire_sequence))},
                {flutter::EncodableValue("requestedActive"),
                 flutter::EncodableValue(requested_active.load())},
                {flutter::EncodableValue("active"),
                 flutter::EncodableValue(active.load())},
                {flutter::EncodableValue("windowAvailable"),
                 flutter::EncodableValue(window_available.load())},
                {flutter::EncodableValue("activityTransitionCount"),
                 flutter::EncodableValue(static_cast<std::int64_t>(
                     activity_transition_count.load()))},
            }));
            return;
          }
          if (call.method_name() == "setWindowAvailableForTest") {
            if (!StageTextureTestModeEnabled()) {
              result->Error(
                  "stage_texture_test_mode_disabled",
                  "Set KIRAKARA_COMPOSITOR_TEST_MODE=1 to change test window "
                  "availability.");
              return;
            }
            HandleWindowAvailability(
                ReadBool(call.arguments(), "available", false));
            result->Success(flutter::EncodableValue(true));
            return;
          }
          result->NotImplemented();
        });
  }

  bool EnsureApi() {
    std::lock_guard lock(source_mutex);
    if (api_loaded) {
      return api_available;
    }
    api_loaded = true;
    api_available = api.Load();
    return api_available;
  }

  bool EnsureStageDevice() {
    if (stage_device && SUCCEEDED(stage_device->GetDeviceRemovedReason())) {
      return true;
    }
    stage_device.Reset();
    if (!engine) {
      return false;
    }

    IDXGIAdapter* raw_adapter = nullptr;
    if (!engine->GetGraphicsAdapter(&raw_adapter) || !raw_adapter) {
      return false;
    }
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    adapter.Attach(raw_adapter);

    constexpr D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
    };
    D3D_FEATURE_LEVEL selected{};
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
    constexpr UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT |
                           D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    const auto result = D3D11CreateDevice(
        adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, flags, levels,
        static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION,
        stage_device.GetAddressOf(), &selected, context.GetAddressOf());
    return SUCCEEDED(result) && stage_device;
  }

  void ApplyActivityLocked(bool notify_if_already_active) {
    const bool desired = source && !shutting_down.load() &&
                         requested_active.load() && window_available.load();
    const bool changed = active.exchange(desired) != desired;
    if (source && changed) {
      api.set_active(source, desired);
      activity_transition_count.fetch_add(1);
      stage_texture_trace::SetActive(desired, texture_id.load());
    }
    const auto registered_texture_id = texture_id.load();
    if (desired && registered_texture_id >= 0 &&
        (changed || notify_if_already_active)) {
      FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
          registrar, registered_texture_id);
    }
  }

  int64_t Attach(ShowHostHandle host) {
    if (!host || !registrar || shutting_down.load()) {
      stage_texture_trace::Attach(
          reinterpret_cast<std::uint64_t>(host), -1, false);
      return -1;
    }
    if (!EnsureApi()) {
      stage_texture_trace::Attach(
          reinterpret_cast<std::uint64_t>(host), -1, false);
      return -1;
    }

    std::lock_guard lock(source_mutex);
    const auto existing_texture_id = texture_id.load();
    if (source && attached_host == host && existing_texture_id >= 0) {
      requested_active.store(true);
      ApplyActivityLocked(true);
      stage_texture_trace::Attach(
          reinterpret_cast<std::uint64_t>(host), existing_texture_id, true);
      return existing_texture_id;
    }
    if (source) {
      requested_active.store(false);
      active.store(false);
      api.set_callback(source, nullptr, nullptr);
      api.set_active(source, false);
      api.destroy_source(source);
      source = nullptr;
      attached_host = nullptr;
      ReleaseCurrentFrame();
    }

    if (!EnsureStageDevice() || !api.set_stage_device(
            host, reinterpret_cast<uintptr_t>(stage_device.Get()))) {
      stage_texture_trace::Attach(
          reinterpret_cast<std::uint64_t>(host), -1, false);
      return -1;
    }

    source = api.create_source(host);
    if (!source) {
      stage_texture_trace::Attach(
          reinterpret_cast<std::uint64_t>(host), -1, false);
      return -1;
    }
    attached_host = host;

    auto registered_texture_id = texture_id.load();
    if (registered_texture_id < 0) {
      FlutterDesktopTextureInfo texture_info{};
      texture_info.type = kFlutterDesktopGpuSurfaceTexture;
      texture_info.gpu_surface_config.struct_size =
          sizeof(FlutterDesktopGpuSurfaceTextureConfig);
      texture_info.gpu_surface_config.type =
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle;
      texture_info.gpu_surface_config.user_data = this;
      texture_info.gpu_surface_config.callback =
          [](size_t width, size_t height, void* context)
              -> const FlutterDesktopGpuSurfaceDescriptor* {
            return static_cast<Impl*>(context)->ObtainDescriptor(
                width, height);
          };
      registered_texture_id =
          FlutterDesktopTextureRegistrarRegisterExternalTexture(
          registrar, &texture_info);
      if (registered_texture_id < 0) {
        api.destroy_source(source);
        source = nullptr;
        attached_host = nullptr;
        stage_texture_trace::Attach(
            reinterpret_cast<std::uint64_t>(host), -1, false);
        return -1;
      }
      texture_id.store(registered_texture_id);
    }

    api.set_callback(source, &FrameAvailable, this);
    requested_active.store(true);
    ApplyActivityLocked(true);
    stage_texture_trace::Attach(reinterpret_cast<std::uint64_t>(host),
                                registered_texture_id, true);
    return registered_texture_id;
  }

  void SetActive(bool value) {
    std::lock_guard lock(source_mutex);
    if (!source || shutting_down.load()) {
      requested_active.store(false);
      active.store(false);
      return;
    }
    requested_active.store(value);
    ApplyActivityLocked(true);
  }

  void HandleWindowAvailability(bool available) {
    std::lock_guard lock(source_mutex);
    window_available.store(available);
    ApplyActivityLocked(false);
  }

  static void FrameAvailable(void* context,
                             uintptr_t shared_handle,
                             uint32_t width,
                             uint32_t height,
                             uint64_t generation,
                             uint64_t frame_id) {
    auto* self = static_cast<Impl*>(context);
    if (!self || !self->active.load() || self->shutting_down.load() ||
        !self->registrar || self->texture_id.load() < 0 ||
        shared_handle == 0 || width == 0 || height == 0) {
      return;
    }
    stage_texture_trace::TextureCallback(generation, frame_id);
    {
      std::lock_guard lock(self->descriptor_mutex);
      self->pending_frame = ShowHostStageTextureFrame{
          shared_handle, width, height, generation, frame_id};
      self->pending_frame_ready = true;
    }
    const auto registered_texture_id = self->texture_id.load();
    stage_texture_trace::FrameAvailable(
        generation, frame_id, registered_texture_id);
    FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
        self->registrar, registered_texture_id);
  }

  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor(
      size_t,
      size_t) {
    std::lock_guard lock(descriptor_mutex);
    if (!active.load() || shutting_down.load()) {
      return nullptr;
    }

    if (!pending_frame_ready && !descriptor.handle) {
      return nullptr;
    }
    const bool advanced = pending_frame_ready;
    if (advanced) {
      descriptor = {};
      descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
      descriptor.handle =
          reinterpret_cast<void*>(pending_frame.shared_handle);
      descriptor.width = descriptor.visible_width = pending_frame.width;
      descriptor.height = descriptor.visible_height = pending_frame.height;
      descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
      descriptor_generation = pending_frame.generation;
      descriptor_frame_id = pending_frame.frame_id;
      pending_frame_ready = false;
    }
    stage_texture_trace::TextureAcquire(
        descriptor_generation, descriptor_frame_id, advanced);
    return &descriptor;
  }

  void BeginShutdown() {
    if (shutting_down.exchange(true)) {
      return;
    }
    requested_active.store(false);
    active.store(false);
    std::lock_guard lock(source_mutex);
    if (source && api_available) {
      api.set_callback(source, nullptr, nullptr);
      api.set_active(source, false);
    }
    const auto registered_texture_id = texture_id.load();
    if (registrar && registered_texture_id >= 0) {
      FlutterDesktopTextureRegistrarUnregisterExternalTexture(
          registrar, registered_texture_id, nullptr, nullptr);
      texture_id.store(-1);
    }
  }

  void DetachSource() {
    {
      std::lock_guard lock(source_mutex);
      requested_active.store(false);
      active.store(false);
      if (source && api_available) {
        api.set_callback(source, nullptr, nullptr);
        api.set_active(source, false);
        api.destroy_source(source);
      }
      source = nullptr;
      attached_host = nullptr;
    }
    ReleaseCurrentFrame();
  }

  void ReleaseCurrentFrame() {
    std::lock_guard lock(descriptor_mutex);
    descriptor = {};
    descriptor_generation = 0;
    descriptor_frame_id = 0;
    pending_frame = {};
    pending_frame_ready = false;
  }

  void DestroySource() {
    std::lock_guard lock(source_mutex);
    if (source && api_available) {
      api.destroy_source(source);
    }
    source = nullptr;
    attached_host = nullptr;
  }

  flutter::FlutterEngine* engine{};
  FlutterDesktopTextureRegistrarRef registrar{};
  std::unique_ptr<
      flutter::MethodChannel<flutter::EncodableValue>> channel;
  ShowTextureApi api;
  bool api_loaded{};
  bool api_available{};
  ShowHostHandle attached_host{};
  ShowHostStageTextureSource source{};
  std::atomic_int64_t texture_id{-1};
  Microsoft::WRL::ComPtr<ID3D11Device> stage_device;
  std::atomic_bool requested_active{};
  std::atomic_bool active{};
  std::atomic_bool window_available{true};
  std::atomic_bool shutting_down{};
  std::atomic_uint64_t activity_transition_count{};
  std::mutex source_mutex;
  std::mutex descriptor_mutex;
  FlutterDesktopGpuSurfaceDescriptor descriptor{};
  std::uint64_t descriptor_generation{};
  std::uint64_t descriptor_frame_id{};
  ShowHostStageTextureFrame pending_frame{};
  bool pending_frame_ready{};
};

StageTextureBridge::StageTextureBridge(flutter::FlutterEngine* engine)
    : impl_(std::make_unique<Impl>(engine)) {}

StageTextureBridge::~StageTextureBridge() = default;

void StageTextureBridge::BeginShutdown() {
  if (impl_) {
    impl_->BeginShutdown();
  }
}

void StageTextureBridge::HandleWindowAvailabilityChanged(bool available) {
  if (impl_) {
    impl_->HandleWindowAvailability(available);
  }
}
