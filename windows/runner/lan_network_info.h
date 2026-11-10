#pragma once
#include <optional>
#include <string>

struct LanNetworkInfo {
  std::string name;
  bool wifi{};
};

// Resolve the profile belonging to the actual phone-order IPv4 adapter.
std::optional<LanNetworkInfo> ReadLanNetworkInfo(const std::string& ipv4);
