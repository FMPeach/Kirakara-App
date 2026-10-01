#include "dcomp_compositor_bridge.h"

#include <d3d11.h>
#include <dxgi.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <wrl/client.h>
#include <wtsapi32.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <mutex>
#include <optional>
#include <sstream>
#include <utility>
#include <vector>

#include "kirakara_flutter_compositor_api.h"
#include "show_host_stage_visual_api.h"

namespace {

using EncodableValue = flutter::EncodableValue;
using MethodCall = flutter::MethodCall<EncodableValue>;
using MethodResult = flutter::MethodResult<EncodableValue>;

constexpr wchar_t kBackendEnvironment[] = L"KIRAKARA_COMPOSITOR_BACKEND";
constexpr wchar_t kTestModeEnvironment[] = L"KIRAKARA_COMPOSITOR_TEST_MODE";
constexpr char kChannelName[] = "kirakara/dcomp_compositor";

std::string ReadBackendEnvironment() {
  const DWORD required =
      ::GetEnvironmentVariableW(kBackendEnvironment, nullptr, 0);
  if (required == 0) {
    return {};
  }

  std::wstring wide(required, L'\0');
  const DWORD written = ::GetEnvironmentVariableW(
      kBackendEnvironment, wide.data(), static_cast<DWORD>(wide.size()));
  if (written == 0 || written >= wide.size()) {
    return {};
  }
  wide.resize(written);

  const int utf8_size = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), static_cast<int>(wide.size()),
      nullptr, 0, nullptr, nullptr);
  if (utf8_size <= 0) {
    return {};
  }
  std::string value(utf8_size, '\0');
  ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                        static_cast<int>(wide.size()), value.data(), utf8_size,
                        nullptr, nullptr);
  std::transform(
      value.begin(), value.end(), value.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

bool LoadedEngineHasKirakaraCompositorApi() {
  const HMODULE engine_module = ::GetModuleHandleW(L"flutter_windows.dll");
  return engine_module &&
         ::GetProcAddress(engine_module,
                          KIRAKARA_FLUTTER_COMPOSITOR_EXPORT_NAME) != nullptr;
}

std::wstring Utf8ToWide(const std::string &value) {
  if (value.empty()) {
    return {};
  }
  const int size =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return L"The compositor returned an error that could not be decoded.";
  }
  std::wstring result(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), size);
  return result;
}

bool CompositorTestModeEnabled() {
  wchar_t value[2]{};
  return ::GetEnvironmentVariableW(kTestModeEnvironment, value,
                                   static_cast<DWORD>(std::size(value))) == 1 &&
         value[0] == L'1';
}

struct TopLevelWindowCounts {
  uint32_t total = 0;
  uint32_t visible = 0;
  uint32_t visible_interactive = 0;
};

struct TestResizeDelta {
  int32_t width = 0;
  int32_t height = 0;
};

TopLevelWindowCounts CountCurrentProcessTopLevelWindows() {
  struct CountContext {
    DWORD process_id;
    TopLevelWindowCounts counts;
  } context{::GetCurrentProcessId(), {}};
  ::EnumWindows(
      [](HWND window, LPARAM parameter) -> BOOL {
        auto *context = reinterpret_cast<CountContext *>(parameter);
        DWORD process_id = 0;
        ::GetWindowThreadProcessId(window, &process_id);
        if (process_id == context->process_id) {
          ++context->counts.total;
          if (::IsWindowVisible(window)) {
            ++context->counts.visible;
            const LONG_PTR extended_style =
                ::GetWindowLongPtrW(window, GWL_EXSTYLE);
            if ((extended_style & WS_EX_TOOLWINDOW) == 0 &&
                ::GetWindow(window, GW_OWNER) == nullptr) {
              ++context->counts.visible_interactive;
            }
          }
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&context));
  return context.counts;
}

struct MonitorRecord {
  HMONITOR handle = nullptr;
  RECT bounds{};
  RECT work_area{};
  bool primary = false;
  UINT dpi = 0;
};

std::vector<MonitorRecord> EnumerateMonitors() {
  std::vector<MonitorRecord> monitors;
  ::EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM parameter) -> BOOL {
        auto *values =
            reinterpret_cast<std::vector<MonitorRecord> *>(parameter);
        MONITORINFO info{};
        info.cbSize = sizeof(info);
        if (!::GetMonitorInfoW(monitor, &info)) {
          return TRUE;
        }
        values->push_back(MonitorRecord{
            monitor,
            info.rcMonitor,
            info.rcWork,
            (info.dwFlags & MONITORINFOF_PRIMARY) != 0,
            FlutterDesktopGetDpiForMonitor(monitor),
        });
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&monitors));
  return monitors;
}

flutter::EncodableList
MonitorValues(const std::vector<MonitorRecord> &monitors) {
  flutter::EncodableList values;
  for (size_t index = 0; index < monitors.size(); ++index) {
    const auto &monitor = monitors[index];
    values.emplace_back(flutter::EncodableMap{
        {EncodableValue("index"), EncodableValue(static_cast<int32_t>(index))},
        {EncodableValue("primary"), EncodableValue(monitor.primary)},
        {EncodableValue("left"), EncodableValue(monitor.bounds.left)},
        {EncodableValue("top"), EncodableValue(monitor.bounds.top)},
        {EncodableValue("right"), EncodableValue(monitor.bounds.right)},
        {EncodableValue("bottom"), EncodableValue(monitor.bounds.bottom)},
        {EncodableValue("dpi"),
         EncodableValue(static_cast<int32_t>(monitor.dpi))},
        {EncodableValue("scalePercent"),
         EncodableValue(static_cast<int32_t>(
             (static_cast<uint64_t>(monitor.dpi) * 100u + 48u) / 96u))},
    });
  }
  return values;
}

std::optional<int32_t> ReadTestMonitorIndex(const EncodableValue *arguments) {
  if (!arguments) {
    return std::nullopt;
  }
  int64_t index = -1;
  if (const auto *int32_value = std::get_if<int32_t>(arguments)) {
    index = *int32_value;
  } else if (const auto *int64_value = std::get_if<int64_t>(arguments)) {
    index = *int64_value;
  } else {
    return std::nullopt;
  }
  if (index < 0 || index > 63) {
    return std::nullopt;
  }
  return static_cast<int32_t>(index);
}

std::optional<uint32_t> ReadTestStallDuration(const EncodableValue *arguments) {
  if (!arguments) {
    return std::nullopt;
  }
  int64_t duration = 0;
  if (const auto *int32_value = std::get_if<int32_t>(arguments)) {
    duration = *int32_value;
  } else if (const auto *int64_value = std::get_if<int64_t>(arguments)) {
    duration = *int64_value;
  } else {
    return std::nullopt;
  }
  if (duration < 1 || duration > 2000) {
    return std::nullopt;
  }
  return static_cast<uint32_t>(duration);
}

std::optional<TestResizeDelta>
ReadTestResizeDelta(const EncodableValue *arguments) {
  const auto *map =
      arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
  if (!map) {
    return std::nullopt;
  }
  auto read_delta = [map](const char *key) -> std::optional<int32_t> {
    const auto found = map->find(EncodableValue(std::string(key)));
    if (found == map->end()) {
      return std::nullopt;
    }
    int64_t value = 0;
    if (const auto *int32_value = std::get_if<int32_t>(&found->second)) {
      value = *int32_value;
    } else if (const auto *int64_value = std::get_if<int64_t>(&found->second)) {
      value = *int64_value;
    } else {
      return std::nullopt;
    }
    if (value < -512 || value > 512) {
      return std::nullopt;
    }
    return static_cast<int32_t>(value);
  };

  const auto width = read_delta("widthDelta");
  const auto height = read_delta("heightDelta");
  if (!width || !height || (*width == 0 && *height == 0)) {
    return std::nullopt;
  }
  return TestResizeDelta{*width, *height};
}

const flutter::EncodableMap *ReadArgumentMap(const EncodableValue *arguments) {
  return arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
}

std::optional<int64_t> ReadMapInteger(const EncodableValue *arguments,
                                      const char *key) {
  const auto *map = ReadArgumentMap(arguments);
  if (!map) {
    return std::nullopt;
  }
  const auto found = map->find(EncodableValue(std::string(key)));
  if (found == map->end()) {
    return std::nullopt;
  }
  if (const auto *value = std::get_if<int64_t>(&found->second)) {
    return *value;
  }
  if (const auto *value = std::get_if<int32_t>(&found->second)) {
    return static_cast<int64_t>(*value);
  }
  return std::nullopt;
}

std::optional<double> ReadMapNumber(const EncodableValue *arguments,
                                    const char *key) {
  const auto *map = ReadArgumentMap(arguments);
  if (!map) {
    return std::nullopt;
  }
  const auto found = map->find(EncodableValue(std::string(key)));
  if (found == map->end()) {
    return std::nullopt;
  }
  if (const auto *value = std::get_if<double>(&found->second)) {
    return *value;
  }
  if (const auto *value = std::get_if<int64_t>(&found->second)) {
    return static_cast<double>(*value);
  }
  if (const auto *value = std::get_if<int32_t>(&found->second)) {
    return static_cast<double>(*value);
  }
  return std::nullopt;
}

std::optional<bool> ReadMapBoolean(const EncodableValue *arguments,
                                   const char *key) {
  const auto *map = ReadArgumentMap(arguments);
  if (!map) {
    return std::nullopt;
  }
  const auto found = map->find(EncodableValue(std::string(key)));
  if (found == map->end()) {
    return std::nullopt;
  }
  if (const auto *value = std::get_if<bool>(&found->second)) {
    return *value;
  }
  return std::nullopt;
}

std::optional<std::string> ReadMapString(const EncodableValue *arguments,
                                         const char *key) {
  const auto *map = ReadArgumentMap(arguments);
  if (!map) {
    return std::nullopt;
  }
  const auto found = map->find(EncodableValue(std::string(key)));
  if (found == map->end()) {
    return std::nullopt;
  }
  if (const auto *value = std::get_if<std::string>(&found->second)) {
    return *value;
  }
  return std::nullopt;
}

std::string ResultName(int32_t result) {
  switch (result) {
  case kKirakaraFlutterCompositorSuccess:
    return "success";
  case kKirakaraFlutterCompositorInvalidArgument:
    return "invalid_argument";
  case kKirakaraFlutterCompositorVersionMismatch:
    return "version_mismatch";
  case kKirakaraFlutterCompositorBusy:
    return "busy";
  case kKirakaraFlutterCompositorUnavailable:
    return "unavailable";
  case kKirakaraFlutterCompositorViewNotConfigured:
    return "view_not_configured";
  case kKirakaraFlutterCompositorFrameDropped:
    return "frame_dropped";
  case kKirakaraFlutterCompositorOperationFailed:
    return "operation_failed";
  default:
    return "unknown(" + std::to_string(result) + ")";
  }
}

std::string StageVisualResultName(int32_t result) {
  switch (result) {
  case SHOW_HOST_STAGE_VISUAL_SUCCESS:
    return "success";
  case SHOW_HOST_STAGE_VISUAL_INVALID_ARGUMENT:
    return "invalid_argument";
  case SHOW_HOST_STAGE_VISUAL_VERSION_MISMATCH:
    return "version_mismatch";
  case SHOW_HOST_STAGE_VISUAL_UNAVAILABLE:
    return "unavailable";
  default:
    return "unknown(" + std::to_string(result) + ")";
  }
}

std::string HexHresult(int32_t value) {
  std::ostringstream stream;
  stream << "0x" << std::hex << std::uppercase << static_cast<uint32_t>(value);
  return stream.str();
}

EncodableValue
DiagnosticsValue(const KirakaraFlutterCompositorDiagnostics &diagnostics) {
  return EncodableValue(flutter::EncodableMap{
      {EncodableValue("active"), EncodableValue(diagnostics.active != 0)},
      {EncodableValue("abiVersion"),
       EncodableValue(static_cast<int32_t>(diagnostics.abi_version))},
      {EncodableValue("patchsetVersion"),
       EncodableValue(static_cast<int32_t>(diagnostics.patchset_version))},
      {EncodableValue("capabilities"),
       EncodableValue(static_cast<int64_t>(diagnostics.capabilities))},
      {EncodableValue("topLevelWindow"),
       EncodableValue(static_cast<int64_t>(diagnostics.top_level_window))},
      {EncodableValue("width"),
       EncodableValue(static_cast<int32_t>(diagnostics.width))},
      {EncodableValue("height"),
       EncodableValue(static_cast<int32_t>(diagnostics.height))},
      {EncodableValue("initializationHresult"),
       EncodableValue(diagnostics.initialization_hresult)},
      {EncodableValue("lastStagePresentHresult"),
       EncodableValue(diagnostics.last_stage_present_hresult)},
      {EncodableValue("lastStagePacingStatus"),
       EncodableValue(diagnostics.last_stage_pacing_status)},
      {EncodableValue("lastResizeHresult"),
       EncodableValue(diagnostics.last_resize_hresult)},
      {EncodableValue("flutterPresentCount"),
       EncodableValue(static_cast<int64_t>(diagnostics.flutter_present_count))},
      {EncodableValue("stagePresentCount"),
       EncodableValue(static_cast<int64_t>(diagnostics.stage_present_count))},
      {EncodableValue("stageWaitWakeCount"),
       EncodableValue(static_cast<int64_t>(diagnostics.stage_wait_wake_count))},
      {EncodableValue("stageDeviceRemovedCount"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.stage_device_removed_count))},
      {EncodableValue("stageOccludedCount"),
       EncodableValue(static_cast<int64_t>(diagnostics.stage_occluded_count))},
      {EncodableValue("surfaceResizeCount"),
       EncodableValue(static_cast<int64_t>(diagnostics.surface_resize_count))},
      {EncodableValue("compositionTreeCommitCount"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.composition_tree_commit_count))},
      {EncodableValue("lastStageResourceHresult"),
       EncodableValue(diagnostics.last_stage_resource_hresult)},
      {EncodableValue("stageFrameSubmitCount"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.stage_frame_submit_count))},
      {EncodableValue("stageFrameCoalescedCount"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.stage_frame_coalesced_count))},
      {EncodableValue("stageFrameStaleCount"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.stage_frame_stale_count))},
      {EncodableValue("stageHandleDuplicateFailureCount"),
       EncodableValue(static_cast<int64_t>(
           diagnostics.stage_handle_duplicate_failure_count))},
      {EncodableValue("stageResourceOpenFailureCount"),
       EncodableValue(static_cast<int64_t>(
           diagnostics.stage_resource_open_failure_count))},
      {EncodableValue("stageAcquireBusyCount"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.stage_acquire_busy_count))},
      {EncodableValue("stageDetachCount"),
       EncodableValue(static_cast<int64_t>(diagnostics.stage_detach_count))},
      {EncodableValue("stageGeometryUpdateCount"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.stage_geometry_update_count))},
      {EncodableValue("stageResourceGeneration"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.stage_resource_generation))},
      {EncodableValue("stageContentGeneration"),
       EncodableValue(
           static_cast<int64_t>(diagnostics.stage_content_generation))},
      {EncodableValue("stageFrameId"),
       EncodableValue(static_cast<int64_t>(diagnostics.stage_frame_id))},
  });
}

} // namespace

struct DcompCompositorBridge::Impl {
  bool ResolveApi(std::string *error) {
    const HMODULE engine_module = ::GetModuleHandleW(L"flutter_windows.dll");
    if (!engine_module) {
      *error = "KIRAKARA_COMPOSITOR_BACKEND=" + backend +
               " was requested, but flutter_windows.dll is not loaded.";
      return false;
    }

    const auto get_api =
        reinterpret_cast<FlutterDesktopKirakaraCompositorGetApiProc>(
            ::GetProcAddress(engine_module,
                             KIRAKARA_FLUTTER_COMPOSITOR_EXPORT_NAME));
    if (!get_api) {
      *error = "KIRAKARA_COMPOSITOR_BACKEND=" + backend +
               " requires the Kirakara patched Flutter Engine, but its "
               "versioned API export is missing. The selected DLL is likely "
               "the stock Engine.";
      return false;
    }

    api = {};
    api.struct_size = sizeof(api);
    const int32_t result =
        get_api(KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION, &api);
    if (result != kKirakaraFlutterCompositorSuccess) {
      *error = "The Kirakara Flutter Engine rejected compositor ABI " +
               std::to_string(KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION) + ": " +
               ResultName(result) + ".";
      return false;
    }

    if (api.struct_size != sizeof(api) ||
        api.abi_version != KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION ||
        api.patchset_version != KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_VERSION ||
        !api.patchset_revision || !api.engine_revision ||
        std::strcmp(api.patchset_revision,
                    KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_REVISION) != 0 ||
        std::strcmp(api.engine_revision,
                    KIRAKARA_FLUTTER_COMPOSITOR_ENGINE_REVISION) != 0 ||
        !api.prepare_next_view || !api.cancel_prepared_view ||
        !api.get_view_diagnostics || !api.submit_stage_frame ||
        !api.set_stage_geometry || !api.detach_stage) {
      std::ostringstream stream;
      stream << "Kirakara Flutter Engine metadata mismatch. Expected ABI "
             << KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION << ", patchset "
             << KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_VERSION << " ("
             << KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_REVISION << "), engine "
             << KIRAKARA_FLUTTER_COMPOSITOR_ENGINE_REVISION << ". Got ABI "
             << api.abi_version << ", patchset " << api.patchset_version << " ("
             << (api.patchset_revision ? api.patchset_revision : "null")
             << "), engine "
             << (api.engine_revision ? api.engine_revision : "null") << ".";
      *error = stream.str();
      return false;
    }
    return true;
  }

  bool Prepare(HWND top_level_window, std::string *error) {
    KirakaraFlutterCompositorConfig config{};
    config.struct_size = sizeof(config);
    config.abi_version = KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION;
    config.patchset_version = KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_VERSION;
    config.flags =
        (backend == "synthetic" ? kKirakaraFlutterCompositorSyntheticStage
                                : kKirakaraFlutterCompositorExternalStage) |
        kKirakaraFlutterCompositorRequireComposition;
    config.top_level_window = reinterpret_cast<uintptr_t>(top_level_window);

    const int32_t result = api.prepare_next_view(&config);
    if (result != kKirakaraFlutterCompositorSuccess) {
      *error = "The Kirakara Flutter Engine could not prepare the " + backend +
               " DirectComposition view: " + ResultName(result) + ".";
      return false;
    }
    window = top_level_window;
    prepared = true;
    return true;
  }

  bool EnsureShowApi(std::string *error) {
    if (show_api_available) {
      return true;
    }

    // Hold an independent loader reference for as long as any resolved API
    // pointer or Stage source can be used. KirakaraShowFFI may close and reopen
    // its DynamicLibrary while rebuilding Show; GetModuleHandle alone would
    // leave these pointers targeting an unloaded DLL during that transition.
    HMODULE module = ::LoadLibraryW(L"libshow_host.dll");
    if (!module) {
      *error = "The composed Stage backend could not load libshow_host.dll. "
               "Create the Show host before attaching its Stage Visual.";
      return false;
    }

    const auto get_api = reinterpret_cast<ShowHostGetStageVisualApiProc>(
        ::GetProcAddress(module, SHOW_HOST_STAGE_VISUAL_EXPORT_NAME));
    const auto set_stage_device =
        reinterpret_cast<ShowHostSetStageD3dDeviceProc>(
            ::GetProcAddress(module, "show_host_set_stage_d3d_device"));
    if (!get_api || !set_stage_device) {
      ::FreeLibrary(module);
      *error = "libshow_host.dll does not export the required versioned Stage "
               "Visual API and D3D device binding entrypoint.";
      return false;
    }

    ShowHostStageVisualApi resolved{};
    resolved.struct_size = sizeof(resolved);
    const int32_t api_result =
        get_api(SHOW_HOST_STAGE_VISUAL_ABI_VERSION, &resolved);
    constexpr uint64_t kRequiredCapabilities =
        SHOW_HOST_STAGE_VISUAL_CAP_NT_HANDLE |
        SHOW_HOST_STAGE_VISUAL_CAP_KEYED_MUTEX |
        SHOW_HOST_STAGE_VISUAL_CAP_LATEST_FRAME |
        SHOW_HOST_STAGE_VISUAL_CAP_NONBLOCKING_PRODUCER;
    const bool reserved_zero =
        std::all_of(std::begin(resolved.reserved), std::end(resolved.reserved),
                    [](uint64_t value) { return value == 0; });
    if (api_result != SHOW_HOST_STAGE_VISUAL_SUCCESS ||
        resolved.struct_size != sizeof(resolved) ||
        resolved.abi_version != SHOW_HOST_STAGE_VISUAL_ABI_VERSION ||
        (resolved.capabilities & kRequiredCapabilities) !=
            kRequiredCapabilities ||
        !resolved.protocol_revision ||
        std::strcmp(resolved.protocol_revision,
                    SHOW_HOST_STAGE_VISUAL_PROTOCOL_REVISION) != 0 ||
        !resolved.create_source || !resolved.destroy_source ||
        !resolved.set_active || !resolved.set_frame_callback ||
        !resolved.get_stats || !reserved_zero) {
      ::FreeLibrary(module);
      *error = "The Show Stage Visual API is incompatible. Expected ABI " +
               std::to_string(SHOW_HOST_STAGE_VISUAL_ABI_VERSION) +
               " and protocol " + SHOW_HOST_STAGE_VISUAL_PROTOCOL_REVISION +
               ", got " + StageVisualResultName(api_result) + ".";
      return false;
    }

    show_module = module;
    show_api = resolved;
    show_set_stage_device = set_stage_device;
    show_api_available = true;
    return true;
  }

  bool EnsureShowStageDevice(std::string *error) {
    if (show_stage_device &&
        SUCCEEDED(show_stage_device->GetDeviceRemovedReason())) {
      return true;
    }
    show_stage_device.Reset();
    if (!flutter_engine) {
      *error = "The composed Stage backend has no Flutter Engine adapter.";
      return false;
    }

    IDXGIAdapter *raw_adapter = nullptr;
    if (!flutter_engine->GetGraphicsAdapter(&raw_adapter) || !raw_adapter) {
      *error = "The Flutter graphics adapter is unavailable.";
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
    constexpr UINT flags =
        D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    const HRESULT result = ::D3D11CreateDevice(
        adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, flags, levels,
        static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION,
        show_stage_device.GetAddressOf(), &selected, context.GetAddressOf());
    if (FAILED(result) || !show_stage_device) {
      *error = "Could not create the Show Stage producer device on Flutter's "
               "DXGI adapter (HRESULT " +
               HexHresult(result) + ").";
      return false;
    }
    return true;
  }

  static void StageFrameAvailable(void *context,
                                  const ShowHostStageVisualFrame *frame) {
    auto *self = static_cast<Impl *>(context);
    if (!self || !frame ||
        self->shutting_down.load(std::memory_order_acquire) ||
        !self->stage_active.load(std::memory_order_acquire) || !self->view) {
      return;
    }
    const bool reserved_zero =
        std::all_of(std::begin(frame->reserved), std::end(frame->reserved),
                    [](uint64_t value) { return value == 0; });
    if (frame->struct_size != sizeof(*frame) ||
        frame->abi_version != SHOW_HOST_STAGE_VISUAL_ABI_VERSION ||
        (frame->flags & ~SHOW_HOST_STAGE_VISUAL_FRAME_RESOURCE_CHANGED) != 0 ||
        frame->sync_type != SHOW_HOST_STAGE_VISUAL_SYNC_KEYED_MUTEX ||
        frame->shared_nt_handle == 0 || frame->width == 0 ||
        frame->height == 0 || frame->reserved0 != 0 || !reserved_zero) {
      self->stage_callback_rejected_count.fetch_add(1,
                                                    std::memory_order_relaxed);
      self->last_stage_submit_result.store(
          kKirakaraFlutterCompositorInvalidArgument, std::memory_order_relaxed);
      return;
    }

    KirakaraFlutterCompositorStageFrame engine_frame{};
    engine_frame.struct_size = sizeof(engine_frame);
    engine_frame.abi_version = KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION;
    engine_frame.patchset_version =
        KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_VERSION;
    engine_frame.flags =
        (frame->flags & SHOW_HOST_STAGE_VISUAL_FRAME_RESOURCE_CHANGED) != 0
            ? kKirakaraFlutterCompositorStageResourceChanged
            : 0;
    engine_frame.shared_nt_handle = frame->shared_nt_handle;
    engine_frame.width = frame->width;
    engine_frame.height = frame->height;
    engine_frame.dxgi_format = frame->dxgi_format;
    engine_frame.sync_type = kKirakaraFlutterCompositorStageSyncKeyedMutex;
    engine_frame.resource_generation = frame->resource_generation;
    engine_frame.content_generation = frame->content_generation;
    engine_frame.frame_id = frame->frame_id;
    engine_frame.consumer_acquire_key = frame->consumer_acquire_key;
    engine_frame.consumer_release_key = frame->consumer_release_key;

    const int32_t result = self->api.submit_stage_frame(
        reinterpret_cast<uintptr_t>(self->view), &engine_frame);
    self->stage_callback_count.fetch_add(1, std::memory_order_relaxed);
    self->last_stage_submit_result.store(result, std::memory_order_relaxed);
    if (result != kKirakaraFlutterCompositorSuccess &&
        result != kKirakaraFlutterCompositorFrameDropped) {
      self->stage_callback_rejected_count.fetch_add(1,
                                                    std::memory_order_relaxed);
    }
  }

  void ReleaseStageSource() {
    std::scoped_lock lock(stage_source_mutex);
    stage_requested_active.store(false, std::memory_order_release);
    stage_active.store(false, std::memory_order_release);
    if (stage_source && show_api_available) {
      show_api.set_frame_callback(stage_source, nullptr, nullptr);
      show_api.set_active(stage_source, false);
      show_api.destroy_source(stage_source);
    }
    stage_source = nullptr;
    attached_show_host = nullptr;
    if (view && api.detach_stage) {
      api.detach_stage(reinterpret_cast<uintptr_t>(view));
    }
  }

  bool AttachStage(ShowHostHandle host, std::string *error) {
    if (backend != "composed" || !host || !view ||
        shutting_down.load(std::memory_order_acquire)) {
      *error = "The composed Stage source received an invalid Show host.";
      return false;
    }
    if (!EnsureShowApi(error) || !EnsureShowStageDevice(error)) {
      return false;
    }

    if (!show_set_stage_device(
            host, reinterpret_cast<uintptr_t>(show_stage_device.Get()))) {
      *error = "Show rejected the D3D11 producer device selected from "
               "Flutter's DXGI adapter.";
      return false;
    }
    ShowHostStageVisualSource source = nullptr;
    const int32_t result = show_api.create_source(host, &source);
    if (result != SHOW_HOST_STAGE_VISUAL_SUCCESS || !source) {
      *error = "Show could not create the Stage Visual source: " +
               StageVisualResultName(result) + ".";
      return false;
    }
    show_api.set_active(source, false);

    // Prepare the replacement source completely before disturbing the
    // currently visible one. If any preparation step above fails, the old
    // source and Visual remain intact.
    std::scoped_lock lock(stage_source_mutex);
    if (shutting_down.load(std::memory_order_acquire)) {
      show_api.destroy_source(source);
      *error = "The composed Stage backend is shutting down.";
      return false;
    }
    const bool old_requested =
        stage_requested_active.load(std::memory_order_acquire);
    const bool old_active =
        stage_active.exchange(false, std::memory_order_acq_rel);
    if (stage_source) {
      show_api.set_active(stage_source, false);
    }
    const int32_t detach_result =
        api.detach_stage(reinterpret_cast<uintptr_t>(view));
    if (detach_result != kKirakaraFlutterCompositorSuccess) {
      if (stage_source && old_active) {
        stage_active.store(true, std::memory_order_release);
        show_api.set_active(stage_source, true);
      }
      stage_requested_active.store(old_requested, std::memory_order_release);
      show_api.destroy_source(source);
      *error = "The Engine could not transactionally replace the Stage "
               "Visual: " +
               ResultName(detach_result) + ".";
      return false;
    }
    if (stage_source) {
      show_api.set_frame_callback(stage_source, nullptr, nullptr);
      show_api.destroy_source(stage_source);
    }
    stage_source = source;
    attached_show_host = host;
    stage_requested_active.store(false, std::memory_order_release);
    show_api.set_frame_callback(stage_source, &StageFrameAvailable, this);
    return true;
  }

  bool ApplyStageActivityLocked(std::string *error) {
    const bool should_be_active =
        stage_requested_active.load(std::memory_order_acquire) &&
        window_available.load(std::memory_order_acquire) &&
        stage_geometry_visible.load(std::memory_order_acquire);
    const bool was_active = stage_active.load(std::memory_order_acquire);
    if (was_active == should_be_active) {
      return true;
    }

    if (should_be_active) {
      // Publish the callback eligibility before enabling Show so an immediate
      // producer callback cannot be mistaken for a stale frame.
      stage_active.store(true, std::memory_order_release);
      show_api.set_active(stage_source, true);
      stage_activity_transition_count.fetch_add(1,
                                                std::memory_order_relaxed);
      last_stage_activity_result.store(kKirakaraFlutterCompositorSuccess,
                                       std::memory_order_relaxed);
      return true;
    }

    // Prevent any racing producer callback from submitting before asking Show
    // to stop this preview source. Show playback and physical/Cast outputs are
    // intentionally unaffected by this preview-only activity bit.
    stage_active.store(false, std::memory_order_release);
    show_api.set_active(stage_source, false);
    const int32_t result = api.detach_stage(reinterpret_cast<uintptr_t>(view));
    stage_activity_transition_count.fetch_add(1, std::memory_order_relaxed);
    last_stage_activity_result.store(result, std::memory_order_relaxed);
    if (result != kKirakaraFlutterCompositorSuccess) {
      *error = "The Engine could not detach the Stage Visual: " +
               ResultName(result) + ".";
      return false;
    }
    return true;
  }

  bool SetStageActive(bool active, std::string *error) {
    std::scoped_lock lock(stage_source_mutex);
    if (!stage_source || !show_api_available || !view ||
        shutting_down.load(std::memory_order_acquire)) {
      *error = "No composed Stage Visual source is attached.";
      return false;
    }
    stage_requested_active.store(active, std::memory_order_release);
    return ApplyStageActivityLocked(error);
  }

  bool SetWindowAvailability(bool available, std::string *error) {
    std::scoped_lock lock(stage_source_mutex);
    window_available.store(available, std::memory_order_release);
    if (!stage_source || !show_api_available || !view ||
        shutting_down.load(std::memory_order_acquire)) {
      return true;
    }
    return ApplyStageActivityLocked(error);
  }

  bool SetStageGeometry(const EncodableValue *arguments, std::string *error) {
    const auto visible = ReadMapBoolean(arguments, "visible");
    const auto x = ReadMapNumber(arguments, "x");
    const auto y = ReadMapNumber(arguments, "y");
    const auto width = ReadMapNumber(arguments, "width");
    const auto height = ReadMapNumber(arguments, "height");
    const auto fit = ReadMapString(arguments, "fit");
    if (!visible || !x || !y || !width || !height || !fit) {
      *error = "Stage geometry requires visible, x, y, width, height and fit.";
      return false;
    }
    uint32_t fit_value = kKirakaraFlutterCompositorStageFitContain;
    if (*fit == "cover") {
      fit_value = kKirakaraFlutterCompositorStageFitCover;
    } else if (*fit == "fill") {
      fit_value = kKirakaraFlutterCompositorStageFitFill;
    } else if (*fit != "contain") {
      *error = "Unsupported Stage fit '" + *fit + "'.";
      return false;
    }

    KirakaraFlutterCompositorStageGeometry geometry{};
    geometry.struct_size = sizeof(geometry);
    geometry.abi_version = KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION;
    geometry.patchset_version = KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_VERSION;
    geometry.visible = *visible ? 1u : 0u;
    geometry.x = static_cast<float>(*x);
    geometry.y = static_cast<float>(*y);
    geometry.width = static_cast<float>(*width);
    geometry.height = static_cast<float>(*height);
    geometry.fit = fit_value;
    const int32_t result =
        api.set_stage_geometry(reinterpret_cast<uintptr_t>(view), &geometry);
    if (result != kKirakaraFlutterCompositorSuccess) {
      *error =
          "The Engine rejected Stage geometry: " + ResultName(result) + ".";
      return false;
    }
    std::scoped_lock lock(stage_source_mutex);
    stage_geometry_visible.store(*visible, std::memory_order_release);
    if (!stage_source || !show_api_available || !view ||
        shutting_down.load(std::memory_order_acquire)) {
      return true;
    }
    return ApplyStageActivityLocked(error);
  }

  EncodableValue StageDiagnosticsValue(std::string *error) const {
    KirakaraFlutterCompositorDiagnostics engine_diagnostics{};
    if (!ReadDiagnostics(&engine_diagnostics, error)) {
      return EncodableValue();
    }
    flutter::EncodableMap values{
        {EncodableValue("engine"), DiagnosticsValue(engine_diagnostics)},
        {EncodableValue("attached"), EncodableValue(stage_source != nullptr)},
        {EncodableValue("active"),
         EncodableValue(stage_active.load(std::memory_order_acquire))},
        {EncodableValue("requestedActive"),
         EncodableValue(
             stage_requested_active.load(std::memory_order_acquire))},
        {EncodableValue("windowAvailable"),
         EncodableValue(window_available.load(std::memory_order_acquire))},
        {EncodableValue("geometryVisible"),
         EncodableValue(
             stage_geometry_visible.load(std::memory_order_acquire))},
        {EncodableValue("activityTransitionCount"),
         EncodableValue(static_cast<int64_t>(
             stage_activity_transition_count.load(std::memory_order_relaxed)))},
        {EncodableValue("lastActivityTransitionResult"),
         EncodableValue(
             last_stage_activity_result.load(std::memory_order_relaxed))},
        {EncodableValue("callbackCount"),
         EncodableValue(static_cast<int64_t>(
             stage_callback_count.load(std::memory_order_relaxed)))},
        {EncodableValue("callbackRejectedCount"),
         EncodableValue(static_cast<int64_t>(
             stage_callback_rejected_count.load(std::memory_order_relaxed)))},
        {EncodableValue("lastSubmitResult"),
         EncodableValue(
             last_stage_submit_result.load(std::memory_order_relaxed))},
    };
    if (stage_source && show_api_available) {
      ShowHostStageVisualStats stats{};
      stats.struct_size = sizeof(stats);
      stats.abi_version = SHOW_HOST_STAGE_VISUAL_ABI_VERSION;
      const int32_t result = show_api.get_stats(stage_source, &stats);
      if (result != SHOW_HOST_STAGE_VISUAL_SUCCESS) {
        *error = "Show Stage Visual diagnostics failed: " +
                 StageVisualResultName(result) + ".";
        return EncodableValue();
      }
      values.emplace(
          EncodableValue("show"),
          EncodableValue(flutter::EncodableMap{
              {EncodableValue("lastHresult"),
               EncodableValue(stats.last_hresult)},
              {EncodableValue("publishedFrames"),
               EncodableValue(static_cast<int64_t>(stats.published_frames))},
              {EncodableValue("producerBusyDrops"),
               EncodableValue(static_cast<int64_t>(stats.producer_busy_drops))},
              {EncodableValue("callbackCount"),
               EncodableValue(static_cast<int64_t>(stats.callback_count))},
              {EncodableValue("resourceRecreations"),
               EncodableValue(
                   static_cast<int64_t>(stats.resource_recreations))},
              {EncodableValue("resourceGeneration"),
               EncodableValue(static_cast<int64_t>(stats.resource_generation))},
              {EncodableValue("contentGeneration"),
               EncodableValue(static_cast<int64_t>(stats.content_generation))},
              {EncodableValue("frameId"),
               EncodableValue(static_cast<int64_t>(stats.frame_id))},
          }));
    }
    return EncodableValue(values);
  }

  bool Attach(flutter::FlutterEngine *engine, std::string *error) {
    prepared = false;
    if (!engine) {
      *error =
          "The " + backend + " DirectComposition view has no Flutter Engine.";
      return false;
    }
    flutter_engine = engine;
    const FlutterDesktopPluginRegistrarRef registrar =
        engine->GetRegistrarForPlugin("kirakara_dcomp_compositor");
    view =
        registrar ? FlutterDesktopPluginRegistrarGetView(registrar) : nullptr;
    if (!view) {
      *error = "The " + backend +
               " DirectComposition view reference is unavailable.";
      return false;
    }

    KirakaraFlutterCompositorDiagnostics diagnostics{};
    if (!ReadDiagnostics(&diagnostics, error)) {
      return false;
    }
    constexpr uint64_t kBaseCapabilities =
        kKirakaraFlutterCompositorDirectComposition |
        kKirakaraFlutterCompositorPremultipliedAlpha |
        kKirakaraFlutterCompositorIndependentStageProducer |
        kKirakaraFlutterCompositorInPlaceResize;
    const uint64_t required_capabilities =
        backend == "synthetic"
            ? kBaseCapabilities |
                  kKirakaraFlutterCompositorSyntheticStageProducer |
                  kKirakaraFlutterCompositorCompositorClockPacing
            : kBaseCapabilities |
                  kKirakaraFlutterCompositorExternalStageConsumer |
                  kKirakaraFlutterCompositorNtHandle |
                  kKirakaraFlutterCompositorKeyedMutex |
                  kKirakaraFlutterCompositorLatestFrame |
                  kKirakaraFlutterCompositorEventDrivenConsumer |
                  kKirakaraFlutterCompositorStageFitAndClip;
    if (!diagnostics.active ||
        (diagnostics.capabilities & required_capabilities) !=
            required_capabilities) {
      *error = "The patched Engine created a view, but the required " +
               backend +
               " DirectComposition capabilities are not active (init "
               "HRESULT " +
               HexHresult(diagnostics.initialization_hresult) + ").";
      return false;
    }

    channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        engine->messenger(), kChannelName,
        &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const MethodCall &call,
                                         std::unique_ptr<MethodResult> result) {
      if (call.method_name() == "attachStage") {
        if (backend != "composed") {
          result->Error("dcomp_stage_backend_unavailable",
                        "The active compositor backend is not composed.");
          return;
        }
        const auto host = ReadMapInteger(call.arguments(), "hostHandle");
        std::string error;
        if (!host || *host == 0 ||
            !AttachStage(
                reinterpret_cast<ShowHostHandle>(static_cast<intptr_t>(*host)),
                &error)) {
          result->Error("dcomp_stage_attach_failed", error);
          return;
        }
        result->Success(EncodableValue(flutter::EncodableMap{
            {EncodableValue("backend"), EncodableValue("composed")},
            {EncodableValue("protocol"),
             EncodableValue(SHOW_HOST_STAGE_VISUAL_PROTOCOL_REVISION)},
        }));
        return;
      }
      if (call.method_name() == "setStageActive") {
        const auto active = ReadMapBoolean(call.arguments(), "active");
        if (backend != "composed") {
          result->Error("dcomp_stage_backend_unavailable",
                        "The active compositor backend is not composed.");
          return;
        }
        if (!active) {
          result->Error("dcomp_stage_invalid_activity",
                        "Stage activity requires a boolean active value.");
          return;
        }
        std::string error;
        if (!SetStageActive(*active, &error)) {
          result->Error("dcomp_stage_activity_failed", error);
          return;
        }
        result->Success(EncodableValue(true));
        return;
      }
      if (call.method_name() == "setStageGeometry") {
        if (backend != "composed") {
          result->Error("dcomp_stage_backend_unavailable",
                        "The active compositor backend is not composed.");
          return;
        }
        std::string error;
        if (!SetStageGeometry(call.arguments(), &error)) {
          result->Error("dcomp_stage_geometry_failed", error);
          return;
        }
        result->Success(EncodableValue(true));
        return;
      }
      if (call.method_name() == "detachStage") {
        if (backend != "composed") {
          result->Error("dcomp_stage_backend_unavailable",
                        "The active compositor backend is not composed.");
          return;
        }
        ReleaseStageSource();
        result->Success(EncodableValue(true));
        return;
      }
      if (call.method_name() == "getStageDiagnostics") {
        std::string error;
        const EncodableValue values = StageDiagnosticsValue(&error);
        if (!error.empty()) {
          result->Error("dcomp_stage_diagnostics_unavailable", error);
          return;
        }
        result->Success(values);
        return;
      }
      if (call.method_name() == "getDiagnostics") {
        KirakaraFlutterCompositorDiagnostics diagnostics{};
        std::string error;
        if (!ReadDiagnostics(&diagnostics, &error)) {
          result->Error("dcomp_diagnostics_unavailable", error);
          return;
        }
        result->Success(DiagnosticsValue(diagnostics));
        return;
      }
      if (call.method_name() == "getBackendInfo") {
        const auto top_level_windows = CountCurrentProcessTopLevelWindows();
        const auto monitor_records = EnumerateMonitors();
        const auto monitors = MonitorValues(monitor_records);
        const HMONITOR current_monitor =
            ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
        int32_t current_monitor_index = -1;
        for (size_t index = 0; index < monitor_records.size(); ++index) {
          if (monitor_records[index].handle == current_monitor) {
            current_monitor_index = static_cast<int32_t>(index);
            break;
          }
        }
        const UINT window_dpi = FlutterDesktopGetDpiForHWND(window);
        const DPI_AWARENESS_CONTEXT window_dpi_context =
            ::GetWindowDpiAwarenessContext(window);
        const DPI_AWARENESS window_dpi_awareness =
            ::GetAwarenessFromDpiAwarenessContext(window_dpi_context);
        const bool window_is_per_monitor_v2 =
            ::AreDpiAwarenessContextsEqual(
                window_dpi_context,
                DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != FALSE;
        result->Success(EncodableValue(flutter::EncodableMap{
            {EncodableValue("backend"), EncodableValue(backend)},
            {EncodableValue("backendSelection"),
             EncodableValue(backend_selection)},
            {EncodableValue("abiVersion"),
             EncodableValue(static_cast<int32_t>(api.abi_version))},
            {EncodableValue("patchsetVersion"),
             EncodableValue(static_cast<int32_t>(api.patchset_version))},
            {EncodableValue("patchsetRevision"),
             EncodableValue(std::string(api.patchset_revision))},
            {EncodableValue("engineRevision"),
             EncodableValue(std::string(api.engine_revision))},
            {EncodableValue("processTopLevelWindowCount"),
             EncodableValue(static_cast<int32_t>(top_level_windows.total))},
            {EncodableValue("visibleTopLevelWindowCount"),
             EncodableValue(static_cast<int32_t>(top_level_windows.visible))},
            {EncodableValue("visibleInteractiveTopLevelWindowCount"),
             EncodableValue(static_cast<int32_t>(
                 top_level_windows.visible_interactive))},
            {EncodableValue("topLevelWindow"),
             EncodableValue(
                 static_cast<int64_t>(reinterpret_cast<uintptr_t>(window)))},
            {EncodableValue("windowDpi"),
             EncodableValue(static_cast<int32_t>(window_dpi))},
            {EncodableValue("windowScalePercent"),
             EncodableValue(static_cast<int32_t>(
                 (static_cast<uint64_t>(window_dpi) * 100u + 48u) / 96u))},
            {EncodableValue("windowDpiAwareness"),
             EncodableValue(static_cast<int32_t>(window_dpi_awareness))},
            {EncodableValue("windowIsPerMonitorV2"),
             EncodableValue(window_is_per_monitor_v2)},
            {EncodableValue("windowIsVisible"),
             EncodableValue(::IsWindowVisible(window) != FALSE)},
            {EncodableValue("windowIsMinimized"),
             EncodableValue(::IsIconic(window) != FALSE)},
            {EncodableValue("windowIsMaximized"),
             EncodableValue(::IsZoomed(window) != FALSE)},
            {EncodableValue("sessionNotificationsRegistered"),
             EncodableValue(session_notifications_registered.load(
                 std::memory_order_acquire))},
            {EncodableValue("monitorCount"),
             EncodableValue(static_cast<int32_t>(monitors.size()))},
            {EncodableValue("currentMonitorIndex"),
             EncodableValue(current_monitor_index)},
            {EncodableValue("monitors"), EncodableValue(monitors)},
        }));
        return;
      }
      if (call.method_name() == "setWindowShowStateForTest") {
        if (!CompositorTestModeEnabled()) {
          result->Error(
              "dcomp_test_mode_disabled",
              "Set KIRAKARA_COMPOSITOR_TEST_MODE=1 to change the probe "
              "window state.");
          return;
        }
        const auto state = ReadMapString(call.arguments(), "state");
        WPARAM command = 0;
        if (state && *state == "minimized") {
          command = SC_MINIMIZE;
        } else if (state && *state == "maximized") {
          command = SC_MAXIMIZE;
        } else if (state && *state == "restored") {
          command = SC_RESTORE;
        } else {
          result->Error(
              "dcomp_invalid_test_window_state",
              "Test window state must be minimized, maximized, or restored.");
          return;
        }
        if (!window || !::IsWindow(window) ||
            !::PostMessageW(window, WM_SYSCOMMAND, command, 0)) {
          result->Error("dcomp_test_window_state_unavailable",
                        "Could not queue the compositor window state change.");
          return;
        }
        result->Success();
        return;
      }
      if (call.method_name() == "postLifecycleSignalForTest") {
        if (!CompositorTestModeEnabled()) {
          result->Error(
              "dcomp_test_mode_disabled",
              "Set KIRAKARA_COMPOSITOR_TEST_MODE=1 to post a lifecycle "
              "signal to the probe window.");
          return;
        }
        const auto signal = ReadMapString(call.arguments(), "signal");
        UINT message = 0;
        WPARAM parameter = 0;
        if (signal && *signal == "sessionLock") {
          message = WM_WTSSESSION_CHANGE;
          parameter = WTS_SESSION_LOCK;
        } else if (signal && *signal == "sessionUnlock") {
          message = WM_WTSSESSION_CHANGE;
          parameter = WTS_SESSION_UNLOCK;
        } else if (signal && *signal == "powerSuspend") {
          message = WM_POWERBROADCAST;
          parameter = PBT_APMSUSPEND;
        } else if (signal && *signal == "powerResume") {
          message = WM_POWERBROADCAST;
          parameter = PBT_APMRESUMEAUTOMATIC;
        } else if (signal && *signal == "displayChange") {
          message = WM_DISPLAYCHANGE;
        } else {
          result->Error(
              "dcomp_invalid_test_lifecycle_signal",
              "Lifecycle signal must be sessionLock, sessionUnlock, "
              "powerSuspend, powerResume, or displayChange.");
          return;
        }
        if (!window || !::IsWindow(window) ||
            !::PostMessageW(window, message, parameter, 0)) {
          result->Error("dcomp_test_lifecycle_signal_unavailable",
                        "Could not queue the compositor lifecycle signal.");
          return;
        }
        result->Success();
        return;
      }
      if (call.method_name() == "stallPlatformThreadForTest") {
        if (!CompositorTestModeEnabled()) {
          result->Error(
              "dcomp_test_mode_disabled",
              "Set KIRAKARA_COMPOSITOR_TEST_MODE=1 to use the bounded "
              "platform-thread stall probe.");
          return;
        }
        const auto duration = ReadTestStallDuration(call.arguments());
        if (!duration) {
          result->Error("dcomp_invalid_test_duration",
                        "The test stall must be 1 to 2000 milliseconds.");
          return;
        }
        KirakaraFlutterCompositorDiagnostics before{};
        KirakaraFlutterCompositorDiagnostics after{};
        std::string error;
        if (!ReadDiagnostics(&before, &error)) {
          result->Error("dcomp_diagnostics_unavailable", error);
          return;
        }
        // This is reachable only in explicit compositor test mode. It
        // deliberately blocks the Flutter platform thread once so the
        // independent Stage producer can be measured during the stall.
        ::Sleep(*duration);
        if (!ReadDiagnostics(&after, &error)) {
          result->Error("dcomp_diagnostics_unavailable", error);
          return;
        }
        result->Success(EncodableValue(flutter::EncodableMap{
            {EncodableValue("durationMilliseconds"),
             EncodableValue(static_cast<int32_t>(*duration))},
            {EncodableValue("stagePresentDelta"),
             EncodableValue(static_cast<int64_t>(after.stage_present_count -
                                                 before.stage_present_count))},
            {EncodableValue("stageWaitWakeDelta"),
             EncodableValue(static_cast<int64_t>(
                 after.stage_wait_wake_count - before.stage_wait_wake_count))},
            {EncodableValue("flutterPresentDelta"),
             EncodableValue(static_cast<int64_t>(
                 after.flutter_present_count - before.flutter_present_count))},
            {EncodableValue("before"), DiagnosticsValue(before)},
            {EncodableValue("after"), DiagnosticsValue(after)},
        }));
        return;
      }
      if (call.method_name() == "resizeWindowByForTest") {
        if (!CompositorTestModeEnabled()) {
          result->Error(
              "dcomp_test_mode_disabled",
              "Set KIRAKARA_COMPOSITOR_TEST_MODE=1 to resize the probe "
              "window.");
          return;
        }
        const auto delta = ReadTestResizeDelta(call.arguments());
        if (!delta) {
          result->Error("dcomp_invalid_test_resize",
                        "Test resize deltas must be -512 to 512 logical "
                        "pixels and cannot both be zero.");
          return;
        }
        if (!window || !::IsWindow(window) ||
            !::PostMessageW(
                window, kKirakaraCompositorResizeForTestMessage,
                static_cast<WPARAM>(static_cast<intptr_t>(delta->width)),
                static_cast<LPARAM>(static_cast<intptr_t>(delta->height)))) {
          result->Error("dcomp_test_resize_unavailable",
                        "Could not queue the synthetic compositor resize.");
          return;
        }
        result->Success();
        return;
      }
      if (call.method_name() == "moveWindowToMonitorForTest") {
        if (!CompositorTestModeEnabled()) {
          result->Error("dcomp_test_mode_disabled",
                        "Set KIRAKARA_COMPOSITOR_TEST_MODE=1 to move the probe "
                        "window between monitors.");
          return;
        }
        const auto monitor_index = ReadTestMonitorIndex(call.arguments());
        const auto monitors = EnumerateMonitors();
        if (!monitor_index ||
            static_cast<size_t>(*monitor_index) >= monitors.size()) {
          result->Error("dcomp_invalid_test_monitor",
                        "The requested test monitor index is unavailable.");
          return;
        }
        if (!window || !::IsWindow(window) ||
            !::PostMessageW(window,
                            kKirakaraCompositorMoveToMonitorForTestMessage,
                            static_cast<WPARAM>(*monitor_index), 0)) {
          result->Error("dcomp_test_monitor_move_unavailable",
                        "Could not queue the synthetic compositor monitor "
                        "move.");
          return;
        }
        result->Success();
        return;
      }
      if (call.method_name() == "closeWindowForTest") {
        if (!CompositorTestModeEnabled()) {
          result->Error(
              "dcomp_test_mode_disabled",
              "Set KIRAKARA_COMPOSITOR_TEST_MODE=1 to close the probe window.");
          return;
        }
        if (!window || !::IsWindow(window)) {
          result->Error("dcomp_test_window_unavailable",
                        "The synthetic compositor test window is unavailable.");
          return;
        }
        result->Success();
        ::PostMessageW(window, WM_CLOSE, 0, 0);
        return;
      }
      result->NotImplemented();
    });
    return true;
  }

  bool ReadDiagnostics(KirakaraFlutterCompositorDiagnostics *diagnostics,
                       std::string *error) const {
    *diagnostics = {};
    diagnostics->struct_size = sizeof(*diagnostics);
    diagnostics->abi_version = KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION;
    diagnostics->patchset_version =
        KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_VERSION;
    const int32_t result = api.get_view_diagnostics(
        reinterpret_cast<uintptr_t>(view), diagnostics);
    if (result != kKirakaraFlutterCompositorSuccess) {
      *error =
          "Kirakara compositor diagnostics failed: " + ResultName(result) + ".";
      return false;
    }
    if (diagnostics->struct_size != sizeof(*diagnostics) ||
        diagnostics->abi_version != KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION ||
        diagnostics->patchset_version !=
            KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_VERSION) {
      *error = "Kirakara compositor diagnostics returned incompatible "
               "version metadata.";
      return false;
    }
    return true;
  }

  void Shutdown() {
    if (shutting_down.exchange(true, std::memory_order_acq_rel)) {
      return;
    }
    if (backend == "composed") {
      ReleaseStageSource();
    }
    show_stage_device.Reset();
    show_set_stage_device = nullptr;
    show_api = {};
    show_api_available = false;
    if (show_module) {
      ::FreeLibrary(show_module);
    }
    show_module = nullptr;
    flutter_engine = nullptr;
  }

  KirakaraFlutterCompositorApi api{};
  std::string backend;
  std::string backend_selection;
  flutter::FlutterEngine *flutter_engine{};
  FlutterDesktopViewRef view{};
  HWND window{};
  bool prepared{};
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  HMODULE show_module{};
  bool show_api_available{};
  ShowHostStageVisualApi show_api{};
  ShowHostSetStageD3dDeviceProc show_set_stage_device{};
  ShowHostHandle attached_show_host{};
  ShowHostStageVisualSource stage_source{};
  Microsoft::WRL::ComPtr<ID3D11Device> show_stage_device;
  std::atomic_bool stage_requested_active{};
  std::atomic_bool stage_active{};
  std::atomic_bool window_available{true};
  std::atomic_bool stage_geometry_visible{true};
  std::atomic_bool shutting_down{};
  std::atomic_bool session_notifications_registered{};
  std::atomic_uint64_t stage_activity_transition_count{};
  std::atomic_int32_t last_stage_activity_result{
      kKirakaraFlutterCompositorSuccess};
  std::atomic_uint64_t stage_callback_count{};
  std::atomic_uint64_t stage_callback_rejected_count{};
  std::atomic_int32_t last_stage_submit_result{
      kKirakaraFlutterCompositorSuccess};
  std::mutex stage_source_mutex;
};

DcompCompositorBridge::DcompCompositorBridge()
    : impl_(std::make_unique<Impl>()) {}

DcompCompositorBridge::~DcompCompositorBridge() { Shutdown(); }

bool DcompCompositorBridge::PrepareNextView(HWND top_level_window,
                                             std::string *error) {
  const std::string configured_backend = ReadBackendEnvironment();
  const bool explicitly_selected = !configured_backend.empty();
  const std::string backend = explicitly_selected
                                  ? configured_backend
                                  : (LoadedEngineHasKirakaraCompositorApi()
                                         ? "composed"
                                         : "external_texture");
  if (backend == "stock" || backend == "external_texture") {
    return true;
  }
  if (backend != "synthetic" && backend != "composed") {
    *error = "Unsupported KIRAKARA_COMPOSITOR_BACKEND='" + backend +
             "'. Expected stock, external_texture, synthetic, or composed.";
    return false;
  }
  enabled_ = true;
  impl_->backend = backend;
  impl_->backend_selection =
      explicitly_selected ? "environment" : "custom-engine-default";
  if (!top_level_window || !::IsWindow(top_level_window)) {
    *error = "The " + backend +
             " DirectComposition backend requires a valid top-level HWND.";
    return false;
  }
  return impl_->ResolveApi(error) && impl_->Prepare(top_level_window, error);
}

bool DcompCompositorBridge::Attach(flutter::FlutterEngine *engine,
                                   std::string *error) {
  return !enabled_ || impl_->Attach(engine, error);
}

void DcompCompositorBridge::CancelPreparedView() {
  if (impl_ && impl_->prepared && impl_->api.cancel_prepared_view) {
    impl_->api.cancel_prepared_view();
    impl_->prepared = false;
  }
}

void DcompCompositorBridge::Shutdown() {
  if (!impl_) {
    return;
  }
  CancelPreparedView();
  impl_->Shutdown();
  impl_->channel.reset();
  impl_->view = nullptr;
  impl_->window = nullptr;
}

bool DcompCompositorBridge::HandleTestResizeMessage(int32_t width_delta,
                                                    int32_t height_delta) {
  if (!enabled_ || !CompositorTestModeEnabled() || !impl_ ||
      !impl_->window ||
      !::IsWindow(impl_->window) || width_delta < -512 || width_delta > 512 ||
      height_delta < -512 || height_delta > 512 ||
      (width_delta == 0 && height_delta == 0)) {
    return false;
  }

  RECT bounds{};
  if (!::GetWindowRect(impl_->window, &bounds)) {
    return false;
  }
  const int64_t width = static_cast<int64_t>(bounds.right) - bounds.left +
                        static_cast<int64_t>(width_delta);
  const int64_t height = static_cast<int64_t>(bounds.bottom) - bounds.top +
                         static_cast<int64_t>(height_delta);
  if (width < 320 || height < 240 || width > 16384 || height > 16384) {
    return false;
  }
  return ::SetWindowPos(impl_->window, nullptr, 0, 0, static_cast<int>(width),
                        static_cast<int>(height),
                        SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER) != FALSE;
}

bool DcompCompositorBridge::HandleTestMoveToMonitorMessage(
    int32_t monitor_index) {
  if (!enabled_ || !CompositorTestModeEnabled() || !impl_ ||
      !impl_->window ||
      !::IsWindow(impl_->window) || ::IsZoomed(impl_->window) ||
      monitor_index < 0) {
    return false;
  }
  const auto monitors = EnumerateMonitors();
  if (static_cast<size_t>(monitor_index) >= monitors.size()) {
    return false;
  }

  RECT bounds{};
  if (!::GetWindowRect(impl_->window, &bounds)) {
    return false;
  }
  const LONG width = bounds.right - bounds.left;
  const LONG height = bounds.bottom - bounds.top;
  const RECT &work_area = monitors[monitor_index].work_area;
  const LONG available_width = work_area.right - work_area.left;
  const LONG available_height = work_area.bottom - work_area.top;
  const int x =
      work_area.left + std::max<LONG>(0, (available_width - width) / 2);
  const int y =
      work_area.top + std::max<LONG>(0, (available_height - height) / 2);
  return ::SetWindowPos(impl_->window, nullptr, x, y, 0, 0,
                        SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER) != FALSE;
}

void DcompCompositorBridge::HandleWindowAvailabilityChanged(bool available) {
  if (!enabled_ || !impl_ || impl_->backend != "composed") {
    return;
  }
  std::string error;
  if (!impl_->SetWindowAvailability(available, &error) && !error.empty()) {
    const std::string diagnostic =
        "Kirakara compositor lifecycle transition failed: " + error + "\n";
    ::OutputDebugStringA(diagnostic.c_str());
  }
}

void DcompCompositorBridge::SetSessionNotificationsRegistered(
    bool registered) {
  if (!enabled_ || !impl_) {
    return;
  }
  impl_->session_notifications_registered.store(registered,
                                                std::memory_order_release);
}

void ReportDcompCompositorStartupError(HWND owner, const std::string &error) {
  const std::string debug_message =
      "Kirakara DirectComposition startup failed: " + error + "\n";
  ::OutputDebugStringA(debug_message.c_str());
  const std::wstring wide_error = Utf8ToWide(error);
  const std::wstring message =
      L"Kirakara DirectComposition 合成器启动失败。\n\n" + wide_error +
      L"\n\n请确认 App、Engine DLL 与补丁版本完全匹配。";
  ::MessageBoxW(owner, message.c_str(), L"Kirakara compositor error",
                MB_OK | MB_ICONERROR);
}
