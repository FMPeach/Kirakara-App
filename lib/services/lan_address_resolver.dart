import 'dart:io';

class LanAddressCandidate {
  const LanAddressCandidate({
    required this.interfaceName,
    required this.address,
  });

  final String interfaceName;
  final String address;
}

/// Selects an IPv4 address that belongs to a real LAN interface.
///
/// Cast and phone control must advertise the same physical Wi-Fi/Ethernet
/// route. Virtual adapters are deliberately ignored even when they own a
/// private-looking address.
class LanAddressResolver {
  static const _virtualNameTokens = <String>[
    'virtual',
    'vmware',
    'vmnet',
    'virtualbox',
    'hyper-v',
    'vethernet',
    'veth',
    'wsl',
    'docker',
    'vpn',
    'radmin',
    'mihomo',
    'meta tunnel',
    'tun',
    'tap',
    'tunnel',
    'loopback',
    'bluetooth',
    'tailscale',
    'zerotier',
    'wireguard',
    'hamachi',
    'teredo',
    '6to4',
    'ip-https',
    'miniport',
    'wi-fi direct',
    'wifi direct',
    '本地连接*',
    '内核调试器',
  ];

  static const _physicalNameTokens = <String>[
    'wi-fi',
    'wifi',
    'wireless',
    'wlan',
    'ethernet',
    '以太网',
  ];

  static Future<String?> detectIpv4() async {
    return (await detectIpv4Candidate())?.address;
  }

  static Future<LanAddressCandidate?> detectIpv4Candidate() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      return selectIpv4Candidate(
        interfaces.expand(
          (interface) => interface.addresses.map(
            (address) => LanAddressCandidate(
              interfaceName: interface.name,
              address: address.address,
            ),
          ),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static String? selectIpv4(Iterable<LanAddressCandidate> candidates) {
    return selectIpv4Candidate(candidates)?.address;
  }

  static LanAddressCandidate? selectIpv4Candidate(
    Iterable<LanAddressCandidate> candidates,
  ) {
    final ranked = <({LanAddressCandidate candidate, int score})>[];
    for (final candidate in candidates) {
      final score = rankCandidate(
        interfaceName: candidate.interfaceName,
        address: candidate.address,
      );
      if (score < 0) continue;
      ranked.add((candidate: candidate, score: score));
    }
    ranked.sort((left, right) {
      final scoreOrder = right.score.compareTo(left.score);
      if (scoreOrder != 0) return scoreOrder;
      final nameOrder = left.candidate.interfaceName.compareTo(
        right.candidate.interfaceName,
      );
      if (nameOrder != 0) return nameOrder;
      return left.candidate.address.compareTo(right.candidate.address);
    });
    return ranked.isEmpty ? null : ranked.first.candidate;
  }

  /// Returns a deterministic preference score, or -1 for a rejected adapter.
  static int rankCandidate({
    required String interfaceName,
    required String address,
  }) {
    final octets = _parseIpv4(address);
    if (octets == null || _isRejectedAddress(octets)) return -1;

    final normalizedName = interfaceName.toLowerCase();
    if (_virtualNameTokens.any(normalizedName.contains)) return -1;

    final physicalName = _physicalNameTokens.any(normalizedName.contains) ||
        RegExp(r'^(en|eth|wlan)\d+$').hasMatch(normalizedName);
    final privateAddress = _isPrivateAddress(octets);

    // Prefer a named physical adapter first, then an RFC1918 address. Some
    // Android vendors expose generic interface names, so private addresses
    // remain a valid fallback.
    return (physicalName ? 200 : 0) + (privateAddress ? 100 : 0);
  }

  static List<int>? _parseIpv4(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      octets.add(value);
    }
    return octets;
  }

  static bool _isRejectedAddress(List<int> ip) {
    final first = ip[0];
    final second = ip[1];
    return first == 0 ||
        first == 127 ||
        first >= 224 ||
        (first == 169 && second == 254) ||
        (first == 198 && (second == 18 || second == 19)) ||
        (first == 100 && second >= 64 && second <= 127);
  }

  static bool _isPrivateAddress(List<int> ip) {
    return ip[0] == 10 ||
        (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) ||
        (ip[0] == 192 && ip[1] == 168);
  }
}
