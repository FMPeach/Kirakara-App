import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kirakara_app/services/cast_service.dart';
import 'package:kirakara_app/services/dlna/dlna_control_point.dart';
import 'package:kirakara_app/services/dlna/dlna_device.dart';
import 'package:kirakara_app/services/dlna/dlna_device_description_parser.dart';
import 'package:kirakara_app/services/dlna/dlna_discovery_service.dart';
import 'package:kirakara_app/services/dlna/dlna_http_client.dart';
import 'package:kirakara_app/services/display_manager.dart';
import 'package:kirakara_app/services/kirakara_show_service.dart';
import 'package:kirakara_app/services/lan_address_resolver.dart';
import 'package:kirakara_app/services/native_window_service.dart';
import 'package:kirakara_app/services/playback_service.dart';
import 'package:kirakara_app/services/queue_service.dart';

void main() {
  group('SSDP discovery protocol', () {
    test('builds a standards-shaped M-SEARCH request', () {
      final request = DlnaDiscoveryService.buildSearchRequest(
        'urn:schemas-upnp-org:device:MediaRenderer:1',
      );

      expect(request, startsWith('M-SEARCH * HTTP/1.1\r\n'));
      expect(request, contains('HOST: 239.255.255.250:1900\r\n'));
      expect(request, contains('MAN: "ssdp:discover"\r\n'));
      expect(request, contains('MX: 2\r\n'));
      expect(request, endsWith('\r\n\r\n'));
    });

    test('parses response headers case-insensitively', () {
      final headers = DlnaDiscoveryService.parseResponseHeaders(
        'HTTP/1.1 200 OK\r\n'
        'LOCATION: http://192.168.1.20:1400/device.xml\r\n'
        'UsN: uuid:renderer::upnp:rootdevice\r\n\r\n',
      );

      expect(headers['location'], 'http://192.168.1.20:1400/device.xml');
      expect(headers['usn'], 'uuid:renderer::upnp:rootdevice');
    });

    test('targets a renderer directly without changing multicast defaults', () {
      final request = DlnaDiscoveryService.buildSearchRequest(
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        host: '192.168.254.7:1900',
      );

      expect(request, contains('HOST: 192.168.254.7:1900\r\n'));
      expect(request, contains('MAN: "ssdp:discover"\r\n'));
    });
  });

  group('device description', () {
    test('finds an embedded renderer and resolves service URLs', () {
      const source = '''
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <URLBase>http://192.168.1.20:1400/base/</URLBase>
          <device>
            <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
            <friendlyName>Container</friendlyName>
            <deviceList>
              <device>
                <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
                <friendlyName>客厅电视</friendlyName>
                <manufacturer>Example</manufacturer>
                <modelName>Renderer X</modelName>
                <UDN>uuid:renderer-1</UDN>
                <serviceList>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                    <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
                    <controlURL>/upnp/control/avtransport</controlURL>
                    <eventSubURL>/upnp/event/avtransport</eventSubURL>
                    <SCPDURL>/avtransport.xml</SCPDURL>
                  </service>
                  <service>
                    <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                    <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
                    <controlURL>connection/control</controlURL>
                    <eventSubURL>connection/event</eventSubURL>
                    <SCPDURL>connection.xml</SCPDURL>
                  </service>
                </serviceList>
              </device>
            </deviceList>
          </device>
        </root>
      ''';

      final device = const DlnaDeviceDescriptionParser().parse(
        source,
        location: Uri.parse('http://192.168.1.20:1400/device.xml'),
        localAddress: '192.168.1.10',
      );

      expect(device.id, 'uuid:renderer-1');
      expect(device.udn, 'uuid:renderer-1');
      expect(device.friendlyName, '客厅电视');
      expect(device.detailLabel, 'Example · Renderer X');
      expect(
        device.avTransport.controlUrl.toString(),
        'http://192.168.1.20:1400/upnp/control/avtransport',
      );
      expect(
        device.avTransport.eventSubUrl.toString(),
        'http://192.168.1.20:1400/upnp/event/avtransport',
      );
      expect(
        device.avTransport.scpdUrl.toString(),
        'http://192.168.1.20:1400/avtransport.xml',
      );
      expect(
        device.connectionManager?.controlUrl.toString(),
        'http://192.168.1.20:1400/base/connection/control',
      );
      expect(
        device.connectionManager?.eventSubUrl.toString(),
        'http://192.168.1.20:1400/base/connection/event',
      );
      expect(
        device.connectionManager?.scpdUrl.toString(),
        'http://192.168.1.20:1400/base/connection.xml',
      );
    });

    test('rejects a device without MediaRenderer', () {
      expect(
        () => const DlnaDeviceDescriptionParser().parse(
          '<root><device><deviceType>urn:test:device:Other:1</deviceType>'
          '</device></root>',
          location: Uri.parse('http://192.168.1.20/device.xml'),
          localAddress: '192.168.1.10',
        ),
        throwsFormatException,
      );
    });
  });

  group('explicit renderer fallback', () {
    test('loads a complete Pure K description URL and logs its route',
        () async {
      final logs = <String>[];
      final service = DlnaDiscoveryService(
        localInterfaceResolver: () async => const LanAddressCandidate(
          interfaceName: 'Ethernet',
          address: '192.168.16.170',
        ),
        descriptionLoader: (location, localAddress) async {
          expect(
            location,
            Uri.parse('http://192.168.254.7:49152/description.xml'),
          );
          expect(localAddress, '192.168.16.170');
          return _pureKDescription;
        },
        unicastSearch: (_, __, ___) =>
            throw StateError('manual URL must not send SSDP'),
        logger: logs.add,
      );

      final device = await service.resolveManualRenderer(
        '  http://192.168.254.7:49152/description.xml  ',
      );

      expect(device.friendlyName, '纯K-K08');
      expect(device.udn, 'uuid:pure-k-k08');
      expect(device.manufacturer, 'dolphinstar');
      expect(device.modelName, 'Myou Media Renderer');
      expect(
        device.avTransport.controlUrl,
        Uri.parse(
          'http://192.168.254.7:49152/'
          '_urn:schemas-upnp-org:service:AVTransport_control',
        ),
      );
      expect(
        device.renderingControl?.controlUrl,
        Uri.parse(
          'http://192.168.254.7:49152/'
          '_urn:schemas-upnp-org:service:RenderingControl_control',
        ),
      );
      expect(
        device.connectionManager?.controlUrl,
        Uri.parse(
          'http://192.168.254.7:49152/'
          '_urn:schemas-upnp-org:service:ConnectionManager_control',
        ),
      );
      expect(
        device.avTransport.eventSubUrl,
        Uri.parse(
          'http://192.168.254.7:49152/'
          '_urn:schemas-upnp-org:service:AVTransport_event',
        ),
      );
      expect(
        device.avTransport.scpdUrl,
        Uri.parse(
          'http://192.168.254.7:49152/'
          '_urn:schemas-upnp-org:service:AVTransport_scpd.xml',
        ),
      );
      expect(logs.single, contains('source=manual-url'));
      expect(logs.single, contains('discoverySource=manual-url'));
      expect(
        logs.single,
        contains(r'sourceInterface="Ethernet (192.168.16.170)"'),
      );
      expect(logs.single, contains(r'friendlyName="纯K-K08"'));
      expect(logs.single, contains(r'UDN="uuid:pure-k-k08"'));
      expect(logs.single, contains(r'manufacturer="dolphinstar"'));
      expect(logs.single, contains(r'modelName="Myou Media Renderer"'));
      expect(
        logs.single,
        contains(
          r'avTransport="http://192.168.254.7:49152/_urn:schemas-upnp-org:service:AVTransport_control"',
        ),
      );
    });

    test('uses directed SSDP for a bare renderer IP', () async {
      final logs = <String>[];
      final service = DlnaDiscoveryService(
        localInterfaceResolver: () async => const LanAddressCandidate(
          interfaceName: 'Wi-Fi',
          address: '192.168.16.170',
        ),
        unicastSearch: (target, localAddress, responseWindow) async {
          expect(target.address, '192.168.254.7');
          expect(localAddress, '192.168.16.170');
          expect(responseWindow, const Duration(milliseconds: 25));
          return [
            DlnaSsdpResponse(
              location: Uri.parse(
                'http://192.168.254.7:49152/description.xml',
              ),
              usn: 'uuid:pure-k-k08::upnp:rootdevice',
            ),
          ];
        },
        descriptionLoader: (_, __) async => _pureKDescriptionWithoutUdn,
        logger: logs.add,
      );

      final device = await service.resolveManualRenderer(
        '192.168.254.7',
        responseWindow: const Duration(milliseconds: 25),
      );

      expect(device.udn, 'uuid:pure-k-k08');
      expect(logs.single, contains('source=ssdp-unicast'));
      expect(logs.single, contains('discoverySource=ssdp'));
    });

    test('scans only the fixed Pure K /24 endpoint with bounded concurrency',
        () async {
      final requested = <Uri>[];
      final logs = <String>[];
      var activeRequests = 0;
      var maximumActiveRequests = 0;
      final service = DlnaDiscoveryService(
        localInterfaceResolver: () async => const LanAddressCandidate(
          interfaceName: 'Ethernet',
          address: '192.168.16.170',
        ),
        timedDescriptionLoader: (location, localAddress, timeout) async {
          requested.add(location);
          expect(localAddress, '192.168.16.170');
          expect(timeout, const Duration(milliseconds: 400));
          activeRequests++;
          if (activeRequests > maximumActiveRequests) {
            maximumActiveRequests = activeRequests;
          }
          try {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            if (location.host == '192.168.254.6') {
              return _pureKDescription
                  .replaceFirst('纯K-K08', '纯K-K07')
                  .replaceFirst('uuid:pure-k-k08', 'uuid:pure-k-k07');
            }
            if (location.host == '192.168.254.7') {
              return _pureKDescription;
            }
            throw TimeoutException('expected inactive Pure K address');
          } finally {
            activeRequests--;
          }
        },
        logger: logs.add,
      );

      final devices = await service.discoverPureKRenderers();

      expect(requested, hasLength(254));
      expect(
        requested.map((uri) => uri.host).toSet(),
        {
          for (var suffix = 1; suffix <= 254; suffix++) '192.168.254.$suffix',
        },
      );
      expect(
        requested.every(
          (uri) =>
              uri.scheme == 'http' &&
              uri.port == 49152 &&
              uri.path == '/description.xml' &&
              !uri.hasQuery &&
              !uri.hasFragment,
        ),
        isTrue,
      );
      expect(maximumActiveRequests, inInclusiveRange(2, 24));
      expect(
        devices.map((device) => device.friendlyName).toSet(),
        {'纯K-K07', '纯K-K08'},
      );
      expect(
        logs.where((line) => line.contains('source=purek-http')),
        hasLength(2),
      );
      expect(
        logs.last,
        allOf(
          contains('discoverySource=purek-http'),
          contains('candidates=254'),
          contains('renderers=2'),
          contains('concurrency=24'),
          contains('timeoutMs=400'),
        ),
      );
    });

    test('asks for a full URL when directed SSDP has no response', () async {
      final service = DlnaDiscoveryService(
        localInterfaceResolver: () async => const LanAddressCandidate(
          interfaceName: 'Ethernet',
          address: '192.168.16.170',
        ),
        unicastSearch: (_, __, ___) async => const [],
        descriptionLoader: (_, __) =>
            throw StateError('description must not be fetched'),
        logger: (_) {},
      );

      await expectLater(
        service.resolveManualRenderer('192.168.254.7'),
        throwsA(
          isA<DlnaDiscoveryException>().having(
            (error) => error.message,
            'message',
            contains('完整 description URL'),
          ),
        ),
      );
    });

    test('deduplicates by UDN before falling back to URL and IP', () {
      final automatic = _device(
        location: 'http://192.168.31.214/device.xml',
        udn: 'uuid:renderer',
      );
      final manual = _device(
        location: 'http://192.168.254.7:49152/description.xml',
        udn: 'UUID:RENDERER',
      );
      final merged = DlnaDiscoveryService.deduplicateDevices([
        automatic,
        manual,
      ]);

      expect(merged, hasLength(1));
      expect(merged.single.location, manual.location);

      final distinctUdns = DlnaDiscoveryService.deduplicateDevices([
        _device(location: 'http://192.168.1.20/a.xml', udn: 'uuid:a'),
        _device(location: 'http://192.168.1.20/b.xml', udn: 'uuid:b'),
      ]);
      expect(distinctUdns, hasLength(2));

      final sameUrlWithoutUdn = DlnaDiscoveryService.deduplicateDevices([
        _device(location: 'http://192.168.1.30/device.xml', udn: ''),
        _device(location: 'http://192.168.1.30/device.xml', udn: ''),
      ]);
      expect(sameUrlWithoutUdn, hasLength(1));

      final sameIpWithoutUdn = DlnaDiscoveryService.deduplicateDevices([
        _device(location: 'http://192.168.1.40:8000/a.xml', udn: ''),
        _device(location: 'http://192.168.1.40:9000/b.xml', udn: ''),
      ]);
      expect(sameIpWithoutUdn, hasLength(1));
    });
  });

  group('SOAP control', () {
    test('escapes transport arguments in the envelope', () {
      final envelope = DlnaControlPoint.buildSoapEnvelope(
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        action: 'SetAVTransportURI',
        arguments: const {
          'InstanceID': '0',
          'CurrentURI': 'http://192.168.1.10/stage.ts?a=1&b=2',
          'CurrentURIMetaData': '<item>歌名</item>',
        },
      );

      expect(envelope, contains('<u:SetAVTransportURI'));
      expect(envelope, contains('a=1&amp;b=2'));
      expect(envelope, contains('&lt;item&gt;歌名&lt;/item&gt;'));
    });

    test('extracts UPnP error details', () {
      const fault = '''
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body><s:Fault><detail><UPnPError>
            <errorCode>714</errorCode>
            <errorDescription>Illegal MIME-type</errorDescription>
          </UPnPError></detail></s:Fault></s:Body>
        </s:Envelope>
      ''';
      expect(
        DlnaControlPoint.parseSoapFault(fault),
        '714 · Illegal MIME-type',
      );
    });

    test('chooses a declared MPEG-TS protocol without copying a profile', () {
      expect(
        DlnaControlPoint.chooseMpegTsProtocolInfo(const [
          'http-get:*:video/vnd.dlna.mpeg-tts:DLNA.ORG_PN=AVC_TS_MP_HD_AAC_T',
          'http-get:*:video/mpeg:*',
        ]),
        'http-get:*:video/mpeg:*',
      );
      expect(
        DlnaControlPoint.chooseMpegTsProtocolInfo(const []),
        'http-get:*:video/MP2T:*',
      );
    });

    test('only accepts physical LAN HTTP URLs', () {
      expect(
        () => DlnaHttpClient.validateLanUri(
          Uri.parse('http://8.8.8.8/device.xml'),
        ),
        throwsFormatException,
      );
      expect(
        () => DlnaHttpClient.validateLanUri(
          Uri.parse('http://192.168.1.20/device.xml'),
        ),
        returnsNormally,
      );
    });
  });

  group('CastService state machine', () {
    test('manual renderer joins the normal list and Cast control path',
        () async {
      final automatic = _device(
        location: 'http://192.168.31.214/device.xml',
        udn: 'uuid:renderer',
      );
      final manual = _device(
        location: 'http://192.168.254.7:49152/description.xml',
        udn: 'uuid:renderer',
      );
      final discovery = _FakeDiscoveryService(
        [automatic],
        manualResult: manual,
      );
      final control = _FakeControlPoint();
      final show = _FakeShowService();
      final service = CastService(
        discoveryService: discovery,
        controlPoint: control,
      );
      addTearDown(service.dispose);

      await service.enableCastMode();
      final added = await service.addManualRenderer(
        'http://192.168.254.7:49152/description.xml',
      );
      expect(added, same(manual));
      expect(service.devices, [manual]);

      await service.refreshDevices();
      expect(service.devices, [manual]);

      await service.connectToDevice(service.devices.single, show);
      expect(service.isCasting, isTrue);
      expect(control.lastDevice, same(manual));
      expect(show.startCalls, 1);
    });

    test('Pure K results merge with SSDP and wait for explicit selection',
        () async {
      final ssdpK07 = _device(
        location: 'http://192.168.16.50/device.xml',
        udn: 'uuid:pure-k-k07',
        friendlyName: '纯K-K07',
      );
      final pureKK07 = _device(
        location: 'http://192.168.254.6:49152/description.xml',
        udn: 'uuid:pure-k-k07',
        friendlyName: '纯K-K07',
      );
      final pureKK08 = _device(
        location: 'http://192.168.254.7:49152/description.xml',
        udn: 'uuid:pure-k-k08',
        friendlyName: '纯K-K08',
      );
      final discovery = _FakeDiscoveryService(
        [ssdpK07],
        pureKResult: [pureKK07, pureKK08],
      );
      final control = _FakeControlPoint();
      final show = _FakeShowService();
      final service = CastService(
        discoveryService: discovery,
        controlPoint: control,
      );
      addTearDown(service.dispose);

      await service.enableCastMode(includePureK: true);

      expect(discovery.pureKDiscoveryCalls, 1);
      expect(service.devices, hasLength(2));
      expect(
        service.devices
            .singleWhere((device) => device.udn == 'uuid:pure-k-k07')
            .location,
        pureKK07.location,
      );
      expect(service.state, CastState.idle);
      expect(control.lastDevice, isNull);
      expect(show.startCalls, 0);

      final selected = service.devices.singleWhere(
        (device) => device.udn == 'uuid:pure-k-k08',
      );
      await service.connectToDevice(selected, show);
      expect(control.lastDevice, same(pureKK08));
      expect(show.startCalls, 1);
    });

    test('connects and disconnects without disabling wireless mode', () async {
      final device = _device();
      final discovery = _FakeDiscoveryService([device]);
      final control = _FakeControlPoint();
      final show = _FakeShowService();
      final service = CastService(
        discoveryService: discovery,
        controlPoint: control,
      );
      addTearDown(service.dispose);

      await service.enableCastMode();
      expect(service.isEnabled, isTrue);
      expect(service.devices, [device]);

      final gate = Completer<void>();
      control.connectGate = gate;
      final connecting = service.connectToDevice(device, show);
      await Future<void>.delayed(Duration.zero);

      expect(service.state, CastState.searching);
      expect(service.activeDevice, device);
      expect(show.startCalls, 1);
      expect(
          control.lastStreamUri,
          Uri.parse(
            'http://192.168.31.99:14000/cast/stage.ts',
          ));

      gate.complete();
      await connecting;
      expect(service.isCasting, isTrue);
      expect(service.mpegTsUrl, control.lastStreamUri.toString());

      await service.connectToDevice(device, show);
      expect(service.state, CastState.idle);
      expect(service.isEnabled, isTrue);
      expect(service.activeDevice, isNull);
      expect(control.stopCalls, 1);
      expect(show.stopCalls, greaterThanOrEqualTo(2));

      await service.disableCastMode(showService: show);
      expect(service.isEnabled, isFalse);
      expect(service.devices, isEmpty);
    });

    test('rolls back the native stream when the receiver rejects control',
        () async {
      final device = _device();
      final control = _FakeControlPoint()
        ..connectError = const DlnaSoapException(
          action: 'SetAVTransportURI',
          statusCode: 500,
          message: '714 · Illegal MIME-type',
        );
      final show = _FakeShowService();
      final service = CastService(
        discoveryService: _FakeDiscoveryService([device]),
        controlPoint: control,
      );
      addTearDown(service.dispose);

      await service.enableCastMode();
      await expectLater(
        service.connectToDevice(device, show),
        throwsA(isA<DlnaSoapException>()),
      );

      expect(service.state, CastState.idle);
      expect(service.isEnabled, isTrue);
      expect(service.activeDevice, isNull);
      expect(service.mpegTsUrl, isNull);
      expect(service.lastError, contains('Illegal MIME-type'));
      expect(show.startCalls, 1);
      expect(show.stopCalls, greaterThanOrEqualTo(2));
    });

    test('cleans up locally when the receiver stops the transport', () async {
      final device = _device();
      final control = _FakeControlPoint()
        ..transportStates.addAll(const [
          DlnaTransportState.playing,
          DlnaTransportState.stopped,
          DlnaTransportState.stopped,
        ]);
      final show = _FakeShowService();
      final service = CastService(
        discoveryService: _FakeDiscoveryService([device]),
        controlPoint: control,
        receiverMonitorInterval: const Duration(milliseconds: 5),
      );
      addTearDown(service.dispose);

      await service.enableCastMode();
      await service.connectToDevice(device, show);
      expect(service.isCasting, isTrue);

      for (var i = 0; i < 40 && service.isCasting; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(service.state, CastState.idle);
      expect(service.isEnabled, isTrue);
      expect(service.activeDevice, isNull);
      expect(service.mpegTsUrl, isNull);
      expect(service.lastError, contains('已断开'));
      expect(show.stopCalls, greaterThanOrEqualTo(2));
    });

    test('keeps casting when transport monitoring is unsupported', () async {
      final device = _device();
      final control = _FakeControlPoint()
        ..transportError = const DlnaSoapException(
          action: 'GetTransportInfo',
          statusCode: 500,
          message: '401 · Invalid Action',
        );
      final show = _FakeShowService();
      final service = CastService(
        discoveryService: _FakeDiscoveryService([device]),
        controlPoint: control,
        receiverMonitorInterval: const Duration(milliseconds: 5),
      );
      addTearDown(service.dispose);

      await service.enableCastMode();
      await service.connectToDevice(device, show);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(service.isCasting, isTrue);
      expect(service.activeDevice, device);
      expect(service.lastError, isNull);
    });
  });

  test('display selection survives refresh while the display remains',
      () async {
    final native = _FakeNativeWindowService([
      _display('primary', primary: true, left: 0),
      _display('second', left: 1920),
      _display('third', left: 3840),
    ]);
    final manager = DisplayManager(nativeWindowService: native);
    await manager.detectDisplays();
    manager.selectStageDisplay('third');

    expect(manager.stageDisplay?.id, 'third');
    await manager.detectDisplays();
    expect(manager.stageDisplay?.id, 'third');

    native.displays = [
      _display('primary', primary: true, left: 0),
      _display('second', left: 1920),
    ];
    await manager.detectDisplays();
    expect(manager.stageDisplay?.id, 'second');
  });
}

Map<String, Object?> _display(
  String id, {
  bool primary = false,
  required int left,
}) {
  return {
    'id': id,
    'name': id,
    'isPrimary': primary,
    'left': left,
    'top': 0,
    'width': 1920,
    'height': 1080,
  };
}

class _FakeNativeWindowService extends NativeWindowService {
  _FakeNativeWindowService(this.displays);

  List<Map<String, Object?>> displays;

  @override
  Future<List<Map<String, Object?>>> getDisplays() async => displays;
}

DlnaDevice _device({
  String location = 'http://192.168.31.214/device.xml',
  String udn = 'uuid:renderer',
  String friendlyName = '测试电视',
}) {
  return DlnaDevice(
    id: udn.isEmpty ? location : udn,
    udn: udn,
    friendlyName: friendlyName,
    manufacturer: 'Example',
    modelName: 'Renderer',
    location: Uri.parse(location),
    localAddress: '192.168.31.99',
    avTransport: DlnaServiceEndpoint(
      serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
      controlUrl: Uri.parse('http://192.168.31.214/avtransport'),
    ),
  );
}

class _FakeDiscoveryService extends DlnaDiscoveryService {
  _FakeDiscoveryService(
    this.result, {
    this.manualResult,
    this.pureKResult = const [],
  });

  final List<DlnaDevice> result;
  final DlnaDevice? manualResult;
  final List<DlnaDevice> pureKResult;
  int pureKDiscoveryCalls = 0;

  @override
  Future<List<DlnaDevice>> discover({
    Duration responseWindow = const Duration(milliseconds: 2600),
  }) async {
    return result;
  }

  @override
  Future<List<DlnaDevice>> discoverPureKRenderers({
    int concurrency = 24,
    Duration requestTimeout = const Duration(milliseconds: 400),
  }) async {
    pureKDiscoveryCalls++;
    return pureKResult;
  }

  @override
  Future<DlnaDevice> resolveManualRenderer(
    String input, {
    Duration responseWindow = const Duration(milliseconds: 1800),
  }) async {
    final result = manualResult;
    if (result == null) {
      throw StateError('No manual renderer configured for this test');
    }
    return result;
  }
}

class _FakeControlPoint extends DlnaControlPoint {
  Completer<void>? connectGate;
  Object? connectError;
  DlnaDevice? lastDevice;
  Uri? lastStreamUri;
  int stopCalls = 0;
  final List<DlnaTransportState> transportStates = [];
  Object? transportError;

  @override
  Future<void> setTransportUriAndPlay(
    DlnaDevice device,
    Uri streamUri, {
    String title = 'Kira Karaoke',
  }) async {
    lastDevice = device;
    lastStreamUri = streamUri;
    final error = connectError;
    if (error != null) throw error;
    await connectGate?.future;
  }

  @override
  Future<void> stop(DlnaDevice device) async {
    stopCalls++;
  }

  @override
  Future<DlnaTransportState> getTransportState(DlnaDevice device) async {
    final error = transportError;
    if (error != null) throw error;
    if (transportStates.isEmpty) return DlnaTransportState.playing;
    return transportStates.removeAt(0);
  }
}

class _FakeShowService extends KirakaraShowService {
  _FakeShowService()
      : super(
          playbackService: PlaybackService(queueService: QueueService()),
        );

  int startCalls = 0;
  int stopCalls = 0;

  @override
  bool startCastStream(int port) {
    startCalls++;
    return true;
  }

  @override
  int get castStreamPort => 14000;

  @override
  void stopCastStream() {
    stopCalls++;
  }
}

const _pureKDescription = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>纯K-K08</friendlyName>
    <manufacturer>dolphinstar</manufacturer>
    <modelName>Myou Media Renderer</modelName>
    <UDN>uuid:pure-k-k08</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>_urn:schemas-upnp-org:service:AVTransport_control</controlURL>
        <eventSubURL>_urn:schemas-upnp-org:service:AVTransport_event</eventSubURL>
        <SCPDURL>_urn:schemas-upnp-org:service:AVTransport_scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>_urn:schemas-upnp-org:service:RenderingControl_control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>_urn:schemas-upnp-org:service:ConnectionManager_control</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

const _pureKDescriptionWithoutUdn = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>纯K-K08</friendlyName>
    <manufacturer>dolphinstar</manufacturer>
    <modelName>Myou Media Renderer</modelName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>_urn:schemas-upnp-org:service:AVTransport_control</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';
