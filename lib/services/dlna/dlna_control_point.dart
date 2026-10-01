import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'dlna_device.dart';
import 'dlna_http_client.dart';

class DlnaSoapException implements Exception {
  const DlnaSoapException({
    required this.action,
    required this.statusCode,
    required this.message,
  });

  final String action;
  final int statusCode;
  final String message;

  @override
  String toString() => '$action failed ($statusCode): $message';
}

enum DlnaTransportState {
  playing,
  paused,
  transitioning,
  stopped,
  noMedia,
  unknown,
}

class DlnaControlPoint {
  const DlnaControlPoint();

  Future<void> setTransportUriAndPlay(
    DlnaDevice device,
    Uri streamUri, {
    String title = 'Kira Karaoke',
  }) async {
    DlnaHttpClient.validateLanUri(streamUri);
    var protocolInfo = 'http-get:*:video/MP2T:*';
    try {
      protocolInfo = chooseMpegTsProtocolInfo(
        await getSinkProtocolInfo(device),
      );
    } catch (_) {
      // ConnectionManager is optional in practice and often incomplete.
    }
    try {
      await stop(device);
    } catch (_) {
      // A stopped or freshly booted renderer may reject a redundant Stop.
    }

    final metadata = buildDidlMetadata(
      streamUri,
      title: title,
      protocolInfo: protocolInfo,
    );
    try {
      await _invoke(
        device,
        device.avTransport,
        'SetAVTransportURI',
        {
          'InstanceID': '0',
          'CurrentURI': streamUri.toString(),
          'CurrentURIMetaData': metadata,
        },
      );
    } on DlnaSoapException {
      // Several older renderers accept the transport URI but reject metadata.
      await _invoke(
        device,
        device.avTransport,
        'SetAVTransportURI',
        {
          'InstanceID': '0',
          'CurrentURI': streamUri.toString(),
          'CurrentURIMetaData': '',
        },
      );
    }
    await _invoke(
      device,
      device.avTransport,
      'Play',
      const {'InstanceID': '0', 'Speed': '1'},
    );
  }

  Future<void> stop(DlnaDevice device) {
    return _invoke(
      device,
      device.avTransport,
      'Stop',
      const {'InstanceID': '0'},
    );
  }

  Future<DlnaTransportState> getTransportState(DlnaDevice device) async {
    final response = await _invoke(
      device,
      device.avTransport,
      'GetTransportInfo',
      const {'InstanceID': '0'},
    );
    final document = XmlDocument.parse(response);
    final value = document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'CurrentTransportState')
        .map((element) => element.innerText.trim())
        .firstOrNull;
    return parseTransportState(value);
  }

  static DlnaTransportState parseTransportState(String? value) {
    switch (value?.trim().toUpperCase()) {
      case 'PLAYING':
        return DlnaTransportState.playing;
      case 'PAUSED_PLAYBACK':
      case 'PAUSED_RECORDING':
        return DlnaTransportState.paused;
      case 'TRANSITIONING':
        return DlnaTransportState.transitioning;
      case 'STOPPED':
        return DlnaTransportState.stopped;
      case 'NO_MEDIA_PRESENT':
        return DlnaTransportState.noMedia;
      default:
        return DlnaTransportState.unknown;
    }
  }

  Future<List<String>> getSinkProtocolInfo(DlnaDevice device) async {
    final endpoint = device.connectionManager;
    if (endpoint == null) return const [];
    final response =
        await _invoke(device, endpoint, 'GetProtocolInfo', const {});
    final document = XmlDocument.parse(response);
    final sink = document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'Sink')
        .map((element) => element.innerText)
        .firstOrNull;
    if (sink == null || sink.trim().isEmpty) return const [];
    return sink.split(',').map((entry) => entry.trim()).toList();
  }

  Future<String> _invoke(
    DlnaDevice device,
    DlnaServiceEndpoint endpoint,
    String action,
    Map<String, String> arguments,
  ) async {
    DlnaHttpClient.validateLanUri(endpoint.controlUrl);
    final client = DlnaHttpClient.create(device.localAddress);
    try {
      final body = buildSoapEnvelope(
        serviceType: endpoint.serviceType,
        action: action,
        arguments: arguments,
      );
      final encodedBody = utf8.encode(body);
      final request = await client.postUrl(endpoint.controlUrl);
      request.headers.contentType = ContentType(
        'text',
        'xml',
        charset: 'utf-8',
      );
      request.headers.set(
        'SOAPACTION',
        '"${endpoint.serviceType}#$action"',
      );
      request.headers.set(HttpHeaders.connectionHeader, 'close');
      // DLNA/UPnP SOAP must be sent with an explicit Content-Length. Dart's
      // HttpClient otherwise falls back to Transfer-Encoding: chunked, which
      // simple renderers (e.g. macast's CherryPy handler) reject with a 500
      // "KeyError: 'Content-Length'" crash.
      request.contentLength = encodedBody.length;
      request.add(encodedBody);
      final response = await request.close();
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DlnaSoapException(
          action: action,
          statusCode: response.statusCode,
          message: parseSoapFault(responseBody),
        );
      }
      return responseBody;
    } finally {
      client.close(force: true);
    }
  }

  static String buildSoapEnvelope({
    required String serviceType,
    required String action,
    required Map<String, String> arguments,
  }) {
    final argumentXml = arguments.entries
        .map(
          (entry) => '<${entry.key}>${_xmlText(entry.value)}</${entry.key}>',
        )
        .join();
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="${_xmlText(serviceType)}">'
        '$argumentXml</u:$action></s:Body></s:Envelope>';
  }

  static String chooseMpegTsProtocolInfo(Iterable<String> sinkEntries) {
    const preferredMimeTypes = <String>[
      'video/mp2t',
      'video/mpeg',
      'video/vnd.dlna.mpeg-tts',
    ];
    final mimeTypes = sinkEntries
        .map((entry) => entry.split(':'))
        .where((parts) => parts.length >= 4)
        .where((parts) => parts[0].toLowerCase() == 'http-get')
        .map((parts) => parts[2].trim())
        .toList();
    for (final preferred in preferredMimeTypes) {
      for (final mimeType in mimeTypes) {
        if (mimeType.toLowerCase() == preferred) {
          return 'http-get:*:$mimeType:*';
        }
      }
    }
    return 'http-get:*:video/MP2T:*';
  }

  static String buildDidlMetadata(
    Uri streamUri, {
    required String title,
    String protocolInfo = 'http-get:*:video/MP2T:*',
  }) {
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="0" restricted="1">'
        '<dc:title>${_xmlText(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="${_xmlText(protocolInfo)}">'
        '${_xmlText(streamUri.toString())}</res>'
        '</item></DIDL-Lite>';
  }

  static String parseSoapFault(String source) {
    try {
      final document = XmlDocument.parse(source);
      final code = document.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'errorCode')
          .map((element) => element.innerText.trim())
          .firstOrNull;
      final description = document.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'errorDescription')
          .map((element) => element.innerText.trim())
          .firstOrNull;
      if (code != null || description != null) {
        return [code, description]
            .whereType<String>()
            .where((part) => part.isNotEmpty)
            .join(' · ');
      }
    } catch (_) {
      // Fall through to a compact raw response below.
    }
    final compact = source.replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.isEmpty ? 'Unknown UPnP SOAP error' : compact;
  }

  static String _xmlText(String value) =>
      XmlText(value).toXmlString().replaceAll('>', '&gt;');
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
