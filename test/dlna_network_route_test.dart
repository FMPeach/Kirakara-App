import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/dlna/dlna_discovery_service.dart';
import 'package:kirakara_app/services/lan_address_resolver.dart';

void main() {
  test('description and renderer retain the target route, not the first LAN',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType('application', 'xml');
      request.response.write('''
        <root><device>
          <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
          <friendlyName>Routed renderer</friendlyName>
          <UDN>uuid:routed-renderer</UDN>
          <serviceList><service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
            <controlURL>/control</controlURL>
          </service></serviceList>
        </device></root>
      ''');
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    final task = await Socket.startConnect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final location =
        Uri.parse('http://192.168.254.31:${server.port}/device.xml');
    var connections = 0;
    final service = DlnaDiscoveryService(
      localInterfaceResolver: () async => const LanAddressCandidate(
        interfaceName: 'First Ethernet adapter',
        address: '10.0.0.10',
      ),
      targetAddressResolver: (target) async {
        expect(target, location);
        return '192.168.16.170';
      },
      logger: (_) {},
    );

    // Map only this known fixture endpoint to the local test server. Verify the
    // production HTTP client binds the route supplied for that renderer.
    final device = await IOOverrides.runZoned(
      () => service.resolveManualRenderer(location.toString()),
      socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) async {
        expect(host, location.host);
        expect(port, server.port);
        expect((sourceAddress as InternetAddress).address, '192.168.16.170');
        connections++;
        return task;
      },
    );
    expect(connections, 1);
    expect(device.localAddress, '192.168.16.170');
    expect(device.udn, 'uuid:routed-renderer');
    expect(device.avTransport.controlUrl,
        Uri.parse('http://192.168.254.31:${server.port}/control'));
  });
}
