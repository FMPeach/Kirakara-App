import 'package:xml/xml.dart';

import 'dlna_device.dart';

class DlnaDeviceDescriptionParser {
  const DlnaDeviceDescriptionParser();

  DlnaDevice parse(
    String source, {
    required Uri location,
    required String localAddress,
    String? usn,
  }) {
    final document = XmlDocument.parse(source);
    final root = document.rootElement;
    final urlBaseText = _directText(root, 'URLBase');
    final baseUri = urlBaseText == null || urlBaseText.isEmpty
        ? location
        : Uri.parse(urlBaseText);
    final renderer = document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'device')
        .where(
          (element) => (_directText(element, 'deviceType') ?? '').contains(
            ':device:MediaRenderer:',
          ),
        )
        .firstOrNull;
    if (renderer == null) {
      throw const FormatException('UPnP device is not a MediaRenderer');
    }

    final services = _parseServices(renderer, baseUri);
    final avTransport = _bestService(services, ':service:AVTransport:');
    if (avTransport == null) {
      throw const FormatException('MediaRenderer has no AVTransport service');
    }

    final declaredUdn = (_directText(renderer, 'UDN') ?? '').trim();
    final usnId = (usn ?? '').split('::').first.trim();
    final udn = declaredUdn.isNotEmpty
        ? declaredUdn
        : usnId.toLowerCase().startsWith('uuid:')
            ? usnId
            : '';
    final id = udn.isNotEmpty
        ? udn
        : usnId.isNotEmpty
            ? usnId
            : location.toString();
    final friendlyName = (_directText(renderer, 'friendlyName') ?? '').trim();

    return DlnaDevice(
      id: id,
      udn: udn,
      friendlyName: friendlyName.isEmpty ? location.host : friendlyName,
      manufacturer: (_directText(renderer, 'manufacturer') ?? '').trim(),
      modelName: (_directText(renderer, 'modelName') ?? '').trim(),
      location: location,
      localAddress: localAddress,
      iconUrl: _parseIconUrl(renderer, baseUri),
      avTransport: avTransport,
      connectionManager: _bestService(
        services,
        ':service:ConnectionManager:',
      ),
      renderingControl: _bestService(
        services,
        ':service:RenderingControl:',
      ),
    );
  }

  static List<DlnaServiceEndpoint> _parseServices(
    XmlElement device,
    Uri baseUri,
  ) {
    final serviceList = _directElement(device, 'serviceList');
    if (serviceList == null) return const [];
    final services = <DlnaServiceEndpoint>[];
    for (final service in serviceList.childElements.where(
      (element) => element.name.local == 'service',
    )) {
      final serviceType = (_directText(service, 'serviceType') ?? '').trim();
      final controlUrl = (_directText(service, 'controlURL') ?? '').trim();
      final eventSubUrl = (_directText(service, 'eventSubURL') ?? '').trim();
      final scpdUrl = (_directText(service, 'SCPDURL') ?? '').trim();
      if (serviceType.isEmpty || controlUrl.isEmpty) continue;
      services.add(
        DlnaServiceEndpoint(
          serviceType: serviceType,
          controlUrl: _resolveDeviceUrl(baseUri, controlUrl),
          eventSubUrl: eventSubUrl.isEmpty
              ? null
              : _resolveDeviceUrl(baseUri, eventSubUrl),
          scpdUrl: scpdUrl.isEmpty ? null : _resolveDeviceUrl(baseUri, scpdUrl),
        ),
      );
    }
    return services;
  }

  static DlnaServiceEndpoint? _bestService(
    List<DlnaServiceEndpoint> services,
    String marker,
  ) {
    final matching = services
        .where((service) => service.serviceType.contains(marker))
        .toList()
      ..sort(
        (left, right) => _serviceVersion(right.serviceType).compareTo(
          _serviceVersion(left.serviceType),
        ),
      );
    return matching.isEmpty ? null : matching.first;
  }

  static int _serviceVersion(String serviceType) {
    return int.tryParse(serviceType.split(':').last) ?? 0;
  }

  static Uri? _parseIconUrl(XmlElement device, Uri baseUri) {
    final iconList = _directElement(device, 'iconList');
    if (iconList == null) return null;
    final icons = iconList.childElements
        .where((element) => element.name.local == 'icon')
        .map((icon) {
          final url = (_directText(icon, 'url') ?? '').trim();
          final width = int.tryParse(_directText(icon, 'width') ?? '') ?? 0;
          final height = int.tryParse(_directText(icon, 'height') ?? '') ?? 0;
          return (url: url, area: width * height);
        })
        .where((icon) => icon.url.isNotEmpty)
        .toList()
      ..sort((left, right) => right.area.compareTo(left.area));
    return icons.isEmpty ? null : _resolveDeviceUrl(baseUri, icons.first.url);
  }

  static Uri _resolveDeviceUrl(Uri baseUri, String value) {
    try {
      return baseUri.resolve(value);
    } on FormatException {
      // Several MStar/Myou renderers expose paths such as
      // `_urn:schemas-upnp-org:service:AVTransport_control`. The colon is
      // legal once the value is an absolute HTTP path, but makes Dart parse
      // the first segment as an invalid URI scheme. `./` preserves normal
      // relative resolution while disambiguating it as a path.
      if (!value.startsWith('/') && value.contains(':')) {
        return baseUri.resolve('./$value');
      }
      rethrow;
    }
  }

  static XmlElement? _directElement(XmlElement parent, String localName) {
    for (final child in parent.childElements) {
      if (child.name.local == localName) return child;
    }
    return null;
  }

  static String? _directText(XmlElement parent, String localName) {
    return _directElement(parent, localName)?.innerText;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
