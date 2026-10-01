import 'dart:convert';
import 'dart:io';

class DlnaHttpClient {
  DlnaHttpClient._();

  static HttpClient create(
    String localAddress, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final sourceAddress = InternetAddress(localAddress);
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = timeout;
    client.idleTimeout = timeout;
    client.userAgent = 'Kirakara/0.1 UPnP/1.1';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != null || proxyPort != null) {
        return Future.error(
          StateError('DLNA traffic must not use a proxy'),
        );
      }
      if (uri.scheme.toLowerCase() != 'http') {
        return Future.error(
          UnsupportedError('Only LAN HTTP endpoints are supported'),
        );
      }
      return Socket.startConnect(
        uri.host,
        uri.hasPort ? uri.port : 80,
        sourceAddress: sourceAddress,
      );
    };
    return client;
  }

  static Future<String> getText(
    Uri uri, {
    required String localAddress,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _validateLanUri(uri);
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    final client = create(localAddress, timeout: timeout);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.headers
            .set(HttpHeaders.acceptHeader, 'text/xml, application/xml');
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            'UPnP description returned HTTP ${response.statusCode}',
            uri: uri,
          );
        }
        return body;
      })()
          .timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  static void validateLanUri(Uri uri) => _validateLanUri(uri);

  static void _validateLanUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'http' || uri.host.isEmpty) {
      throw FormatException('Invalid LAN HTTP URL: $uri');
    }
    final address = InternetAddress.tryParse(uri.host);
    if (address == null || address.type != InternetAddressType.IPv4) {
      throw FormatException('DLNA URL must use an IPv4 LAN address: $uri');
    }
    final parts = address.address.split('.').map(int.parse).toList();
    final privateAddress = parts[0] == 10 ||
        (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) ||
        (parts[0] == 192 && parts[1] == 168) ||
        (parts[0] == 169 && parts[1] == 254);
    if (!privateAddress) {
      throw FormatException('DLNA URL is outside the physical LAN: $uri');
    }
  }
}
