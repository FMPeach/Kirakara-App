import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kirakara_app/data/catalog/catalog_client.dart';
import 'package:kirakara_app/data/catalog/catalog_endpoint_selector.dart';

void main() {
  final primary = Uri.parse('https://song.kirakara.moe/');
  final fallback = Uri.parse('http://localhost:7392/');

  test('selects and caches the public HTTPS endpoint when available', () async {
    final requests = <Uri>[];
    final selector = CatalogEndpointSelector(
      primaryBaseUrl: primary,
      fallbackBaseUrl: fallback,
      probeClientFactory: () => MockClient((request) async {
        requests.add(request.url);
        return http.Response('[]', 200);
      }),
    );

    expect(await selector.resolve(), primary);
    expect(await selector.resolve(), primary);
    expect(selector.activeBaseUrl, primary);
    expect(requests, hasLength(1));
    expect(requests.single.path, '/api/catalog/artists');
    expect(requests.single.queryParameters['r'], isNotEmpty);
  });

  test('falls back to the localhost development server', () async {
    final requests = <Uri>[];
    final selector = CatalogEndpointSelector(
      primaryBaseUrl: primary,
      fallbackBaseUrl: fallback,
      probeClientFactory: () => MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == primary.host) {
          throw const SocketException('public endpoint unavailable');
        }
        return http.Response('[]', 200);
      }),
    );

    expect(await selector.resolve(), fallback);
    expect(selector.activeBaseUrl, fallback);
    expect(requests.map((uri) => uri.host), <String>[
      'song.kirakara.moe',
      'localhost',
    ]);
  });

  test('catalog fetch retries the whole manifest against localhost', () async {
    final fetched = <Uri>[];
    final selector = CatalogEndpointSelector(
      primaryBaseUrl: primary,
      fallbackBaseUrl: fallback,
      probeClientFactory: () => MockClient(
        (request) async => http.Response('[]', 200),
      ),
    );
    final client = HttpCatalogClient(
      baseUrl: primary,
      endpointSelector: selector,
      httpClient: MockClient((request) async {
        fetched.add(request.url);
        if (request.url.host == primary.host &&
            request.url.path == '/api/catalog/songs') {
          return http.Response('temporarily unavailable', 503);
        }
        final body =
            request.url.path == '/api/catalog/categories' ? '{}' : '[]';
        return http.Response(body, 200);
      }),
    );
    addTearDown(client.dispose);

    final manifest = await client.fetchManifest();

    expect(manifest.songs, isEmpty);
    expect(selector.activeBaseUrl, fallback);
    expect(
      fetched.where((uri) => uri.host == 'localhost').map((uri) => uri.path),
      containsAll(<String>[
        '/api/catalog/artists',
        '/api/catalog/songs',
        '/api/catalog/categories',
        '/api/catalog/rankings',
      ]),
    );
  });
}
