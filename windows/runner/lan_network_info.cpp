#include "lan_network_info.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <roapi.h>
#include <netlistmgr.h>
#include <windows.networking.connectivity.h>
#include <wrl/client.h>
#include <wrl/wrappers/corewrappers.h>

#include <vector>

namespace {

struct AdapterInfo { GUID id{}; bool wifi{}; };
std::optional<AdapterInfo> AdapterForAddress(const std::string& address) {
  IN_ADDR wanted{};
  if (InetPtonA(AF_INET, address.c_str(), &wanted) != 1) return std::nullopt;
  ULONG size = 16 * 1024;
  std::vector<unsigned char> bytes(size);
  auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(bytes.data());
  auto error = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST |
      GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, nullptr, adapters, &size);
  if (error == ERROR_BUFFER_OVERFLOW) {
    bytes.resize(size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(bytes.data());
    error = GetAdaptersAddresses(AF_INET, GAA_FLAG_SKIP_ANYCAST |
        GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, nullptr, adapters, &size);
  }
  if (error != NO_ERROR) return std::nullopt;
  for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
    for (auto* unicast = adapter->FirstUnicastAddress; unicast; unicast = unicast->Next) {
      if (!unicast->Address.lpSockaddr || unicast->Address.lpSockaddr->sa_family != AF_INET) continue;
      const auto* current = reinterpret_cast<const sockaddr_in*>(unicast->Address.lpSockaddr);
      if (current->sin_addr.s_addr != wanted.s_addr || !adapter->AdapterName) continue;
      const std::string raw = adapter->AdapterName;
      const std::wstring name(raw.begin(), raw.end());
      GUID id{};
      if (SUCCEEDED(CLSIDFromString(name.c_str(), &id))) return AdapterInfo{id, adapter->IfType == IF_TYPE_IEEE80211};
    }
  }
  return std::nullopt;
}

struct RuntimeApartment {
  HRESULT result{RoInitialize(RO_INIT_MULTITHREADED)};
  RuntimeApartment() {
    if (result == RPC_E_CHANGED_MODE) result = RoInitialize(RO_INIT_SINGLETHREADED);
  }
  ~RuntimeApartment() { if (SUCCEEDED(result)) RoUninitialize(); }
};

std::string ToUtf8(const wchar_t* text, UINT32 length) {
  if (!text || !length) return {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, text, static_cast<int>(length), nullptr, 0, nullptr, nullptr);
  if (bytes <= 0) return {};
  std::string result(static_cast<std::size_t>(bytes), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, static_cast<int>(length), result.data(), bytes, nullptr, nullptr);
  return result;
}

std::optional<std::string> SystemNetworkName(const GUID& adapter) {
  using Microsoft::WRL::ComPtr;
  ComPtr<INetworkListManager> manager;
  ComPtr<IEnumNetworkConnections> connections;
  if (FAILED(CoCreateInstance(CLSID_NetworkListManager, nullptr, CLSCTX_ALL,
      IID_PPV_ARGS(&manager))) || FAILED(manager->GetNetworkConnections(&connections))) return std::nullopt;
  for (;;) {
    ComPtr<INetworkConnection> connection;
    ULONG fetched{};
    if (connections->Next(1, &connection, &fetched) != S_OK || !fetched) break;
    GUID id{}; VARIANT_BOOL connected{};
    if (FAILED(connection->GetAdapterId(&id)) || !IsEqualGUID(adapter, id)
        || FAILED(connection->get_IsConnected(&connected)) || !connected) continue;
    ComPtr<INetwork> network;
    BSTR value{};
    if (FAILED(connection->GetNetwork(&network))) continue;
    const auto result = network->GetName(&value);
    const auto name = SUCCEEDED(result) ? ToUtf8(value, SysStringLen(value)) : std::string{};
    SysFreeString(value);
    if (!name.empty()) return name;
  }
  return std::nullopt;
}

}  // namespace

std::optional<LanNetworkInfo> ReadLanNetworkInfo(const std::string& ipv4) {
  const auto adapter = AdapterForAddress(ipv4);
  if (!adapter) return std::nullopt;
  RuntimeApartment apartment;
  if (FAILED(apartment.result)) return std::nullopt;
  const auto system_name = SystemNetworkName(adapter->id);
  if (!adapter->wifi && system_name) return LanNetworkInfo{*system_name, false};
  using namespace ABI::Windows::Networking::Connectivity;
  using Microsoft::WRL::ComPtr;
  using Microsoft::WRL::Wrappers::HString;
  using Microsoft::WRL::Wrappers::HStringReference;
  ComPtr<INetworkInformationStatics> information;
  ComPtr<ABI::Windows::Foundation::Collections::IVectorView<ConnectionProfile*>> profiles;
  if (FAILED(RoGetActivationFactory(HStringReference(
          RuntimeClass_Windows_Networking_Connectivity_NetworkInformation).Get(),
          IID_PPV_ARGS(&information))) || FAILED(information->GetConnectionProfiles(&profiles))) return std::nullopt;
  UINT32 count{};
  if (FAILED(profiles->get_Size(&count))) return std::nullopt;
  for (UINT32 index = 0; index < count; ++index) {
    ComPtr<IConnectionProfile> profile;
    ComPtr<INetworkAdapter> network;
    GUID id{};
    NetworkConnectivityLevel level{};
    if (FAILED(profiles->GetAt(index, &profile))
        || FAILED(profile->get_NetworkAdapter(&network)) || !network
        || FAILED(network->get_NetworkAdapterId(&id)) || !IsEqualGUID(id, adapter->id)
        || FAILED(profile->GetNetworkConnectivityLevel(&level)) || level == NetworkConnectivityLevel_None) continue;
    ComPtr<IConnectionProfile2> extended;
    ComPtr<IWlanConnectionProfileDetails> details;
    boolean wifi{};
    HString name;
    if (SUCCEEDED(profile.As(&extended)) && SUCCEEDED(extended->get_IsWlanConnectionProfile(&wifi)) && wifi
        && SUCCEEDED(extended->get_WlanConnectionProfileDetails(&details)) && details) {
      // SSID-only API: no BSSID, network scan or location permission request.
      static_cast<void>(details->GetConnectedSsid(name.GetAddressOf()));
    }
    if (name.Length() == 0 && system_name) return LanNetworkInfo{*system_name, wifi != 0};
    if (name.Length() == 0) static_cast<void>(profile->get_ProfileName(name.ReleaseAndGetAddressOf()));
    UINT32 length{};
    const auto* text = name.GetRawBuffer(&length);
    if (!length) continue;
    auto utf8 = ToUtf8(text, length);
    if (utf8.empty()) continue;
    return LanNetworkInfo{std::move(utf8), wifi != 0};
  }
  return std::nullopt;
}
