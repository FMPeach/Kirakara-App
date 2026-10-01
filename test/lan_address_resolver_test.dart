import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/lan_address_resolver.dart';

void main() {
  test('prefers physical Wi-Fi over virtual private adapters', () {
    final selected = LanAddressResolver.selectIpv4(const [
      LanAddressCandidate(
        interfaceName: 'VMware Network Adapter VMnet8',
        address: '192.168.195.1',
      ),
      LanAddressCandidate(
        interfaceName: 'Mihomo',
        address: '198.18.0.1',
      ),
      LanAddressCandidate(
        interfaceName: 'WLAN',
        address: '192.168.31.99',
      ),
    ]);

    expect(selected, '192.168.31.99');
  });

  test('rejects VPN, tunnel, benchmark, and link-local addresses', () {
    expect(
      LanAddressResolver.rankCandidate(
        interfaceName: 'Radmin VPN',
        address: '26.117.242.26',
      ),
      -1,
    );
    expect(
      LanAddressResolver.rankCandidate(
        interfaceName: 'WLAN',
        address: '198.18.0.1',
      ),
      -1,
    );
    expect(
      LanAddressResolver.rankCandidate(
        interfaceName: 'Ethernet',
        address: '169.254.112.28',
      ),
      -1,
    );
  });

  test('supports common Android physical interface names', () {
    expect(
      LanAddressResolver.rankCandidate(
        interfaceName: 'wlan0',
        address: '10.0.0.28',
      ),
      300,
    );
    expect(
      LanAddressResolver.rankCandidate(
        interfaceName: 'eth0',
        address: '172.20.0.8',
      ),
      300,
    );
  });

  test('returns null when only virtual candidates remain', () {
    final selected = LanAddressResolver.selectIpv4(const [
      LanAddressCandidate(
        interfaceName: 'Meta Tunnel',
        address: '198.18.0.1',
      ),
      LanAddressCandidate(
        interfaceName: 'VMware Network Adapter VMnet1',
        address: '192.168.128.1',
      ),
    ]);

    expect(selected, isNull);
  });
}
