import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/dlna/dlna_discovery_service.dart';
import 'package:kirakara_app/services/dlna/windows_upnp_discovery_bridge.dart';
import 'package:kirakara_app/services/lan_address_resolver.dart';

class _NoSystemDiscovery implements DlnaSystemDiscovery {
  @override
  Future<bool> start({
    required DlnaSystemDeviceAdded onDeviceAdded,
    required DlnaSystemDeviceRemoved onDeviceRemoved,
  }) async =>
      false;

  @override
  Future<void> stop() async {}
}

// Opt-in real Winsock regression. Use a local LAN IPv4 that already permits
// the test executable through the firewall; this test never changes settings.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final address = Platform.environment['KIRAKARA_SSDP_TEST_ADDRESS'];
  final enabled = Platform.isWindows && address != null;

  for (final lateSearch in [false, true]) {
    test('local SSDP announcement, late search=$lateSearch', () async {
      final local = InternetAddress(address!);
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final nic = interfaces.singleWhere(
        (nic) => nic.addresses.any((ip) => ip.address == address),
      );
      final http = await HttpServer.bind(local, 0);
      addTearDown(() => http.close(force: true));
      final udn = 'uuid:kirakara-local-test-${http.port}';
      final location = Uri.parse('http://$address:${http.port}/device.xml');
      var descriptionReads = 0;
      final httpListener = http.listen((request) async {
        descriptionReads++;
        request.response.headers.contentType =
            ContentType('text', 'xml', charset: 'utf-8');
        request.response.write('''
<root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>Local SSDP test</friendlyName><UDN>$udn</UDN><serviceList><service>
<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><controlURL>/av/control</controlURL>
</service></serviceList></device></root>''');
        await request.response.close();
      });
      addTearDown(httpListener.cancel);
      final sender = await RawDatagramSocket.bind(local, 0);
      addTearDown(sender.close);
      sender.setRawOption(RawSocketOption(
        RawSocketOption.levelIPv4, 9,
        local.rawAddress, // IP_MULTICAST_IF, Winsock
      ));
      sender.multicastHops = 2;
      void announce(String state) {
        sender.send(
          ascii.encode('NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
              'NT: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
              'NTS: ssdp:$state\r\nUSN: $udn::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
              'LOCATION: $location\r\nCACHE-CONTROL: max-age=60\r\n'
              'SERVER: Windows/10.0 UPnP/1.0 KirakaraTest/1.0\r\n\r\n'),
          InternetAddress('239.255.255.250'),
          1900,
        );
      }

      if (lateSearch) {
        announce('alive');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      final logs = <String>[];
      final service = DlnaDiscoveryService(
        systemDiscovery: _NoSystemDiscovery(),
        targetAddressResolver: (_) async => address,
        localInterfacesResolver: () async => [
          DlnaDiscoveryInterface(
            candidate:
                LanAddressCandidate(interfaceName: nic.name, address: address),
            networkInterface: nic,
          )
        ],
        logger: logs.add,
      );
      addTearDown(service.cancelDiscovery);
      final found = Completer<void>();
      final removed = Completer<void>();
      var deviceCallbacks = 0;
      var removalCallbacks = 0;
      final scan = service.discover(
        responseWindow: const Duration(seconds: 6),
        onDevice: (device) {
          deviceCallbacks++;
          if (device.udn == udn && !found.isCompleted) found.complete();
        },
        onDeviceRemoved: (usn) {
          removalCallbacks++;
          if (usn.startsWith(udn) && !removed.isCompleted) removed.complete();
        },
      );
      try {
        // Repeat a bounded number of times to avoid socket-startup races.
        for (var i = 0; i < 4 && !found.isCompleted; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          announce('alive');
        }
        await found.future.timeout(const Duration(seconds: 3));
        expect(descriptionReads, 1);
        expect(logs.any((line) => line.contains('source=ssdp-notify')), isTrue);
        expect(
            logs.any((line) => line.contains('source=windows-upnp')), isFalse);
        for (var i = 0; i < 3 && !removed.isCompleted; i++) {
          announce('byebye');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await removed.future.timeout(const Duration(seconds: 2));
      } finally {
        // Cover both explicit cancellation and the normal search timeout.
        if (!lateSearch || !removed.isCompleted) service.cancelDiscovery();
        await scan;
      }
      final completedCounts = [
        descriptionReads,
        deviceCallbacks,
        removalCallbacks
      ];
      announce('alive');
      announce('byebye');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect([descriptionReads, deviceCallbacks, removalCallbacks],
          completedCounts,
          reason: 'A finished refresh must no longer receive advertisements.');
    },
        skip: enabled
            ? false
            : 'Set KIRAKARA_SSDP_TEST_ADDRESS on Windows to opt in.');
  }
}
