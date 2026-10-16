#include "dlna_discovery_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <oleauto.h>
#include <upnp.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodCall = flutter::MethodCall<EncodableValue>;
using MethodResult = flutter::MethodResult<EncodableValue>;
using Microsoft::WRL::ComPtr;

enum class DiscoveryEventKind {
  kDeviceAdded,
  kDeviceRemoved,
};

struct DiscoveryEvent {
  DiscoveryEventKind kind;
  uint64_t generation = 0;
  std::string location;
  std::string usn;
};

struct DiscoveryState {
  std::mutex mutex;
  HWND message_window = nullptr;
  uint64_t active_generation = 0;
  bool active = false;
  bool dispatch_posted = false;
  std::vector<DiscoveryEvent> events;
};

std::string BstrToUtf8(BSTR value) {
  if (!value) {
    return {};
  }
  const auto length = static_cast<int>(::SysStringLen(value));
  if (length == 0) {
    return {};
  }
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, value, length, nullptr, 0,
                                         nullptr, nullptr);
  if (size <= 0) {
    return {};
  }
  std::string result(static_cast<size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, 0, value, length, result.data(), size,
                            nullptr, nullptr) <= 0) {
    return {};
  }
  return result;
}

std::string ReadDeviceUdn(IUPnPDevice* device) {
  if (!device) {
    return {};
  }
  BSTR value = nullptr;
  const HRESULT status = device->get_UniqueDeviceName(&value);
  if (FAILED(status) || !value) {
    if (value) {
      ::SysFreeString(value);
    }
    return {};
  }
  const std::string result = BstrToUtf8(value);
  ::SysFreeString(value);
  return result;
}

std::string ReadDocumentUrlFrom(IUPnPDevice* device) {
  if (!device) {
    return {};
  }
  ComPtr<IUPnPDeviceDocumentAccess> document_access;
  if (FAILED(device->QueryInterface(IID_PPV_ARGS(&document_access)))) {
    return {};
  }
  BSTR value = nullptr;
  const HRESULT status = document_access->GetDocumentURL(&value);
  if (FAILED(status) || !value) {
    if (value) {
      ::SysFreeString(value);
    }
    return {};
  }
  const std::string result = BstrToUtf8(value);
  ::SysFreeString(value);
  return result;
}

std::string ReadDeviceDocumentUrl(IUPnPDevice* device) {
  auto location = ReadDocumentUrlFrom(device);
  if (!location.empty() || !device) {
    return location;
  }

  ComPtr<IUPnPDevice> root_device;
  if (SUCCEEDED(device->get_RootDevice(&root_device)) && root_device) {
    location = ReadDocumentUrlFrom(root_device.Get());
  }
  return location;
}

void QueueEvent(const std::shared_ptr<DiscoveryState>& state,
                DiscoveryEvent event) {
  HWND message_window = nullptr;
  bool should_post = false;
  {
    std::scoped_lock lock(state->mutex);
    if (!state->active ||
        event.generation != state->active_generation) {
      return;
    }
    state->events.push_back(std::move(event));
    if (!state->dispatch_posted && state->message_window) {
      state->dispatch_posted = true;
      message_window = state->message_window;
      should_post = true;
    }
  }
  if (should_post &&
      !::PostMessageW(message_window, kKirakaraDlnaDiscoveryEventMessage, 0,
                      0)) {
    std::scoped_lock lock(state->mutex);
    state->dispatch_posted = false;
  }
}

class UpnpDeviceFinderCallback final : public IUPnPDeviceFinderCallback {
 public:
  UpnpDeviceFinderCallback(std::shared_ptr<DiscoveryState> state,
                           uint64_t generation)
      : state_(std::move(state)), generation_(generation) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,
                                           void** object) override {
    if (!object) {
      return E_POINTER;
    }
    *object = nullptr;
    if (::IsEqualIID(iid, IID_IUnknown) ||
        ::IsEqualIID(iid, IID_IUPnPDeviceFinderCallback)) {
      *object = static_cast<IUPnPDeviceFinderCallback*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return ++reference_count_;
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG remaining = --reference_count_;
    if (remaining == 0) {
      delete this;
    }
    return remaining;
  }

  HRESULT STDMETHODCALLTYPE DeviceAdded(LONG,
                                        IUPnPDevice* device) override {
    if (!device) {
      return E_POINTER;
    }
    const auto location = ReadDeviceDocumentUrl(device);
    if (location.empty()) {
      return S_OK;
    }
    QueueEvent(state_, DiscoveryEvent{
                           DiscoveryEventKind::kDeviceAdded,
                           generation_,
                           location,
                           ReadDeviceUdn(device),
                       });
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DeviceRemoved(LONG, BSTR udn) override {
    const auto value = BstrToUtf8(udn);
    if (!value.empty()) {
      QueueEvent(state_, DiscoveryEvent{
                             DiscoveryEventKind::kDeviceRemoved,
                             generation_,
                             {},
                             value,
                         });
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE SearchComplete(LONG) override {
    // The asynchronous search remains subscribed after its initial sweep. It
    // is explicitly cancelled when Kirakara's 40-second session ends.
    return S_OK;
  }

 private:
  ~UpnpDeviceFinderCallback() = default;

  std::atomic<ULONG> reference_count_{1};
  std::shared_ptr<DiscoveryState> state_;
  const uint64_t generation_;
};

class DlnaDiscoveryBridge {
 public:
  DlnaDiscoveryBridge(flutter::BinaryMessenger* messenger,
                      HWND message_window)
      : state_(std::make_shared<DiscoveryState>()),
        channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            messenger, "kirakara/dlna_discovery",
            &flutter::StandardMethodCodec::GetInstance())) {
    state_->message_window = message_window;
    channel_->SetMethodCallHandler(
        [this](const MethodCall& call, std::unique_ptr<MethodResult> result) {
          if (call.method_name() == "startDiscovery") {
            result->Success(EncodableValue(Start()));
            return;
          }
          if (call.method_name() == "stopDiscovery") {
            Stop();
            result->Success();
            return;
          }
          result->NotImplemented();
        });
  }

  ~DlnaDiscoveryBridge() {
    Shutdown();
  }

  bool Start() {
    Stop();

    uint64_t generation = 0;
    {
      std::scoped_lock lock(state_->mutex);
      generation = ++state_->active_generation;
      state_->active = true;
      state_->events.clear();
      state_->dispatch_posted = false;
    }

    HRESULT result = ::CoCreateInstance(
        CLSID_UPnPDeviceFinder, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&device_finder_));
    if (FAILED(result)) {
      Deactivate(generation);
      return false;
    }

    callback_.Attach(new UpnpDeviceFinderCallback(state_, generation));
    BSTR type_uri = ::SysAllocString(
        L"urn:schemas-upnp-org:device:MediaRenderer:1");
    if (!type_uri) {
      Deactivate(generation);
      ResetComObjects();
      return false;
    }
    result = device_finder_->CreateAsyncFind(type_uri, 0, callback_.Get(),
                                             &find_data_);
    ::SysFreeString(type_uri);
    if (FAILED(result)) {
      Deactivate(generation);
      ResetComObjects();
      return false;
    }

    search_active_ = true;
    result = device_finder_->StartAsyncFind(find_data_);
    if (FAILED(result)) {
      Deactivate(generation);
      ResetComObjects();
      return false;
    }
    return true;
  }

  void Stop() {
    {
      std::scoped_lock lock(state_->mutex);
      state_->active = false;
      ++state_->active_generation;
      state_->events.clear();
      state_->dispatch_posted = false;
    }
    ResetComObjects();
  }

  void DispatchEvents() {
    std::vector<DiscoveryEvent> events;
    {
      std::scoped_lock lock(state_->mutex);
      state_->dispatch_posted = false;
      if (!state_->active) {
        state_->events.clear();
        return;
      }
      events.swap(state_->events);
    }

    for (const auto& event : events) {
      EncodableMap arguments;
      arguments.emplace(EncodableValue("usn"), EncodableValue(event.usn));
      if (event.kind == DiscoveryEventKind::kDeviceAdded) {
        arguments.emplace(EncodableValue("location"),
                          EncodableValue(event.location));
        channel_->InvokeMethod(
            "onDeviceAdded",
            std::make_unique<EncodableValue>(std::move(arguments)));
      } else {
        channel_->InvokeMethod(
            "onDeviceRemoved",
            std::make_unique<EncodableValue>(std::move(arguments)));
      }
    }
  }

  void Shutdown() {
    Stop();
    {
      std::scoped_lock lock(state_->mutex);
      state_->message_window = nullptr;
    }
    channel_.reset();
  }

 private:
  void Deactivate(uint64_t generation) {
    std::scoped_lock lock(state_->mutex);
    if (state_->active_generation == generation) {
      state_->active = false;
      state_->events.clear();
      state_->dispatch_posted = false;
    }
  }

  void ResetComObjects() {
    if (search_active_ && device_finder_) {
      device_finder_->CancelAsyncFind(find_data_);
    }
    search_active_ = false;
    find_data_ = 0;
    callback_.Reset();
    device_finder_.Reset();
  }

  std::shared_ptr<DiscoveryState> state_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  ComPtr<IUPnPDeviceFinder> device_finder_;
  ComPtr<IUPnPDeviceFinderCallback> callback_;
  LONG find_data_ = 0;
  bool search_active_ = false;
};

std::unique_ptr<DlnaDiscoveryBridge> g_dlna_discovery_bridge;

}  // namespace

void RegisterDlnaDiscoveryBridge(flutter::BinaryMessenger* messenger,
                                 HWND message_window) {
  g_dlna_discovery_bridge =
      std::make_unique<DlnaDiscoveryBridge>(messenger, message_window);
}

void DispatchDlnaDiscoveryEvents() {
  if (g_dlna_discovery_bridge) {
    g_dlna_discovery_bridge->DispatchEvents();
  }
}

void ShutdownDlnaDiscoveryBridge() {
  g_dlna_discovery_bridge.reset();
}
