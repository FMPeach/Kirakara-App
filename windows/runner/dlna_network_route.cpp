#include "dlna_network_route.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>

std::optional<std::string> ResolveDlnaLocalAddress(const std::string& host) {
  // A route query needs neither administrator rights nor probe traffic.
  SOCKADDR_INET destination{};
  destination.si_family = AF_INET;
  if (::InetPtonA(AF_INET, host.c_str(), &destination.Ipv4.sin_addr) != 1) {
    return std::nullopt;
  }

  MIB_IPFORWARD_ROW2 route{};
  SOCKADDR_INET source{};
  if (::GetBestRoute2(nullptr, 0, nullptr, &destination, 0, &route, &source) !=
          NO_ERROR ||
      source.si_family != AF_INET) {
    return std::nullopt;
  }

  char address[INET_ADDRSTRLEN]{};
  if (!::InetNtopA(AF_INET, &source.Ipv4.sin_addr, address, sizeof(address))) {
    return std::nullopt;
  }
  return std::string(address);
}
