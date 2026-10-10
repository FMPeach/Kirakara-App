import 'dart:async';

import 'package:http/http.dart' as http;

import 'catalog_urls.dart';

typedef CatalogProbeClientFactory = http.Client Function();

/// Selects one catalog origin for the current App session.
///
/// The public HTTPS endpoint is preferred. The local development server is
/// selected only when the public catalog endpoint cannot return a valid
/// response. Relative media URLs use the same selected origin.
class CatalogEndpointSelector {
  CatalogEndpointSelector({
    required Uri primaryBaseUrl,
    Uri? fallbackBaseUrl,
    this.probeTimeout = const Duration(seconds: 10),
    CatalogProbeClientFactory? probeClientFactory,
  })  : primaryBaseUrl = _normalizeBaseUrl(primaryBaseUrl),
        fallbackBaseUrl =
            fallbackBaseUrl == null ? null : _normalizeBaseUrl(fallbackBaseUrl),
        _probeClientFactory = probeClientFactory ?? http.Client.new,
        _activeBaseUrl = _normalizeBaseUrl(primaryBaseUrl);

  final Uri primaryBaseUrl;
  final Uri? fallbackBaseUrl;
  final Duration probeTimeout;
  final CatalogProbeClientFactory _probeClientFactory;

  Uri _activeBaseUrl;
  bool _selected = false;
  Future<Uri>? _pendingSelection;

  Uri get activeBaseUrl => _activeBaseUrl;

  Future<Uri> resolve() {
    if (_selected) return Future<Uri>.value(_activeBaseUrl);
    final pending = _pendingSelection;
    if (pending != null) return pending;

    late final Future<Uri> selection;
    selection = _selectAvailableEndpoint().whenComplete(() {
      if (identical(_pendingSelection, selection)) {
        _pendingSelection = null;
      }
    });
    _pendingSelection = selection;
    return selection;
  }

  /// Tries the development endpoint after a selected public endpoint fails
  /// while fetching the complete catalog.
  Future<Uri?> tryFallbackAfter(Uri failedBaseUrl) async {
    final fallback = fallbackBaseUrl;
    if (fallback == null ||
        _sameBaseUrl(failedBaseUrl, fallback) ||
        !_sameBaseUrl(failedBaseUrl, primaryBaseUrl)) {
      return null;
    }
    try {
      await _probe(fallback);
      _activate(fallback);
      return fallback;
    } on Object {
      return null;
    }
  }

  Future<Uri> _selectAvailableEndpoint() async {
    final candidates = <Uri>[
      primaryBaseUrl,
      if (fallbackBaseUrl != null &&
          !_sameBaseUrl(primaryBaseUrl, fallbackBaseUrl!))
        fallbackBaseUrl!,
    ];
    final failures = <String>[];
    for (final candidate in candidates) {
      try {
        await _probe(candidate);
        _activate(candidate);
        return candidate;
      } on Object catch (error) {
        failures.add('$candidate: $error');
      }
    }
    throw CatalogEndpointUnavailableException(failures);
  }

  Future<void> _probe(Uri baseUrl) async {
    final client = _probeClientFactory();
    try {
      final uri = baseUrl.resolveUri(CatalogUrls.artists).replace(
        queryParameters: <String, String>{
          'r': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );
      final response = await client.get(uri).timeout(probeTimeout);
      if (response.statusCode != 200) {
        throw CatalogEndpointProbeException(uri, response.statusCode);
      }
    } finally {
      client.close();
    }
  }

  void _activate(Uri baseUrl) {
    _activeBaseUrl = _normalizeBaseUrl(baseUrl);
    _selected = true;
  }

  static Uri _normalizeBaseUrl(Uri uri) {
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw ArgumentError.value(uri, 'uri', 'Expected an HTTP(S) base URL');
    }
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path, query: null, fragment: null);
  }

  static bool _sameBaseUrl(Uri left, Uri right) =>
      _normalizeBaseUrl(left) == _normalizeBaseUrl(right);
}

class CatalogEndpointProbeException implements Exception {
  const CatalogEndpointProbeException(this.uri, this.statusCode);

  final Uri uri;
  final int statusCode;

  @override
  String toString() => 'GET $uri returned HTTP $statusCode';
}

class CatalogEndpointUnavailableException implements Exception {
  const CatalogEndpointUnavailableException(this.failures);

  final List<String> failures;

  @override
  String toString() =>
      'No catalog endpoint is available (${failures.join('; ')})';
}
