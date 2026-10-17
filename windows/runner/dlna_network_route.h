#ifndef RUNNER_DLNA_NETWORK_ROUTE_H_
#define RUNNER_DLNA_NETWORK_ROUTE_H_

#include <optional>
#include <string>

std::optional<std::string> ResolveDlnaLocalAddress(const std::string& host);

#endif  // RUNNER_DLNA_NETWORK_ROUTE_H_
