import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

class LinkPreview {
  const LinkPreview({
    required this.uri,
    required this.title,
    required this.description,
    this.siteName,
    this.imageBytes,
    this.faviconBytes,
    this.videoUri,
  });

  final Uri uri;
  final String title;
  final String? description;
  final String? siteName;
  final Uint8List? imageBytes;
  final Uint8List? faviconBytes;
  final Uri? videoUri;
}

class LinkPreviewService {
  static const _requestTimeout = Duration(seconds: 8);
  static const _maxHtmlBytes = 1024 * 1024;
  static const _maxFaviconBytes = 512 * 1024;
  static const _maxImageBytes = 5 * 1024 * 1024;

  Future<LinkPreview?> load(Uri uri) async {
    try {
      if (!_isValidPreviewUri(uri)) return null;
      final response = await _fetch(uri, _maxHtmlBytes);
      if (response == null) return null;
      if (response.contentType?.toLowerCase().startsWith('image/') ?? false) {
        if (response.bytes.isEmpty) return null;
        return LinkPreview(
          uri: response.uri,
          title: response.uri.host,
          description: null,
          imageBytes: response.bytes,
          faviconBytes: response.bytes,
        );
      }
      if (!(response.contentType?.toLowerCase().contains('text/html') ??
          false)) {
        return null;
      }

      final document = html.parse(response.text);
      final faviconBytes = await _loadFaviconFromDocument(
        response.uri,
        document,
      );
      final pageTitle = _firstText([
        document
            .querySelector('meta[property="og:title"]')
            ?.attributes['content'],
        document
            .querySelector('meta[name="twitter:title"]')
            ?.attributes['content'],
        document.querySelector('title')?.text,
      ]);
      final siteName = _firstText([
        document
            .querySelector('meta[property="og:site_name"]')
            ?.attributes['content'],
        document
            .querySelector('meta[name="application-name"]')
            ?.attributes['content'],
      ]);
      final description = _firstText([
        document
            .querySelector('meta[property="og:description"]')
            ?.attributes['content'],
        document
            .querySelector('meta[name="description"]')
            ?.attributes['content'],
        document
            .querySelector('meta[name="twitter:description"]')
            ?.attributes['content'],
      ]);
      final imageUrl = _firstText([
        document
            .querySelector('meta[property="og:image"]')
            ?.attributes['content'],
        document
            .querySelector('meta[property="og:video:poster"]')
            ?.attributes['content'],
        document
            .querySelector('meta[name="twitter:image"]')
            ?.attributes['content'],
      ]);
      Uint8List? imageBytes;
      if (imageUrl != null) {
        final imageUri = response.uri.resolve(imageUrl);
        final image = await _fetch(imageUri, _maxImageBytes);
        if (image?.contentType?.toLowerCase().startsWith('image/') ?? false) {
          imageBytes = image!.bytes;
        }
      }
      final videoUrl = _firstText([
        document
            .querySelector('meta[property="og:video:secure_url"]')
            ?.attributes['content'],
        document
            .querySelector('meta[property="og:video:url"]')
            ?.attributes['content'],
        document
            .querySelector('meta[property="og:video"]')
            ?.attributes['content'],
      ]);
      Uri? videoUri;
      if (videoUrl != null) {
        final candidate = response.uri.resolve(videoUrl);
        if (await _isPublicHttpUri(candidate) &&
            await _isDirectVideo(candidate)) {
          videoUri = candidate;
        }
      }
      if (pageTitle == null &&
          siteName == null &&
          description == null &&
          imageBytes == null &&
          faviconBytes == null &&
          videoUri == null) {
        return null;
      }
      return LinkPreview(
        uri: response.uri,
        title: pageTitle ?? response.uri.host,
        description: description,
        siteName: siteName,
        imageBytes: imageBytes,
        faviconBytes: faviconBytes,
        videoUri: videoUri,
      );
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    } on HandshakeException {
      return null;
    } on TimeoutException {
      return null;
    } on _PreviewFetchException {
      return null;
    }
  }

  Future<Uint8List?> loadFavicon(Uri pageUri) async {
    try {
      if (!_isValidPreviewUri(pageUri)) return null;
      final response = await _fetch(pageUri, _maxHtmlBytes);
      if (response == null) return null;
      if (response.contentType?.toLowerCase().startsWith('image/') ?? false) {
        return response.bytes;
      }
      if (!(response.contentType?.toLowerCase().contains('text/html') ??
          false)) {
        return null;
      }
      return await _loadFaviconFromDocument(
        response.uri,
        html.parse(response.text),
      );
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    } on HandshakeException {
      return null;
    } on TimeoutException {
      return null;
    } on _PreviewFetchException {
      return null;
    }
  }

  Future<Uint8List?> _loadFaviconFromDocument(
    Uri pageUri,
    dom.Document document,
  ) async {
    final iconUrls = <String>[];
    for (final link in document.querySelectorAll('link[rel][href]')) {
      final relTokens = (link.attributes['rel'] ?? '').toLowerCase().split(
        RegExp(r'\s+'),
      );
      if (relTokens.contains('icon') ||
          relTokens.any((token) => token.startsWith('apple-touch-icon'))) {
        final href = link.attributes['href'];
        if (href != null && href.isNotEmpty) iconUrls.add(href);
      }
    }
    iconUrls.add('/favicon.ico');

    final visited = <String>{};
    for (final iconUrl in iconUrls) {
      try {
        final iconUri = pageUri.resolve(iconUrl);
        if (!visited.add(iconUri.toString())) continue;
        final response = await _fetch(iconUri, _maxFaviconBytes);
        if (response?.contentType?.toLowerCase().startsWith('image/') ??
            false) {
          return response!.bytes;
        }
      } on SocketException {
        continue;
      } on HttpException {
        continue;
      } on FormatException {
        continue;
      } on HandshakeException {
        continue;
      } on TimeoutException {
        continue;
      } on _PreviewFetchException {
        continue;
      }
    }
    return null;
  }

  Future<_FetchedResponse?> _fetch(Uri initialUri, int maxBytes) async {
    var uri = initialUri;
    for (var redirects = 0; redirects <= 3; redirects++) {
      if (!await _isPublicHttpUri(uri)) return null;
      final client = HttpClient()..connectionTimeout = _requestTimeout;
      try {
        final request = await client.getUrl(uri).timeout(_requestTimeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'SaraDesktop/1.0');
        final response = await request.close().timeout(_requestTimeout);
        if (_isRedirect(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || redirects == 3) return null;
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300)
          return null;
        final bytes = BytesBuilder(copy: false);
        var length = 0;
        await for (final chunk in response.timeout(_requestTimeout)) {
          length += chunk.length;
          if (length > maxBytes) throw const _PreviewFetchException();
          bytes.add(chunk);
        }
        final responseBytes = bytes.takeBytes();
        if (responseBytes.isEmpty) return null;
        return _FetchedResponse(
          uri: uri,
          contentType: response.headers.contentType?.mimeType,
          bytes: responseBytes,
        );
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  bool _isValidPreviewUri(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.port > 0 &&
      uri.port <= 65535;

  Future<bool> _isPublicHttpUri(Uri uri) async {
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.host.endsWith('.local')) {
      return false;
    }

    final normalizedHost = uri.host.toLowerCase().replaceFirst(
      RegExp(r'\.$'),
      '',
    );
    if (normalizedHost == 'localhost' ||
        normalizedHost.endsWith('.localhost')) {
      return false;
    }
    final addresses = await InternetAddress.lookup(
      normalizedHost,
    ).timeout(_requestTimeout);
    return addresses.isNotEmpty && addresses.every(_isPublicAddress);
  }

  Future<bool> _isDirectVideo(Uri uri) async {
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      final request = await client.headUrl(uri).timeout(_requestTimeout);
      request.followRedirects = false;
      final response = await request.close().timeout(_requestTimeout);
      final contentType = response.headers.contentType?.mimeType.toLowerCase();
      return response.statusCode >= 200 &&
          response.statusCode < 300 &&
          (contentType?.startsWith('video/') == true ||
              contentType == 'application/vnd.apple.mpegurl' ||
              contentType == 'application/x-mpegurl');
    } finally {
      client.close(force: true);
    }
  }

  bool _isPublicAddress(InternetAddress address) {
    if (address.type == InternetAddressType.IPv4) {
      final parts = address.rawAddress;
      final a = parts[0];
      final b = parts[1];
      return a != 0 &&
          a != 10 &&
          a != 127 &&
          a < 224 &&
          !(a == 100 && b >= 64 && b <= 127) &&
          !(a == 169 && b == 254) &&
          !(a == 172 && b >= 16 && b <= 31) &&
          !(a == 192 && (b == 0 || b == 168)) &&
          !(a == 198 && (b == 18 || b == 19));
    }
    final bytes = address.rawAddress;
    final isUnspecified = bytes.every((byte) => byte == 0);
    final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    return !address.isLoopback &&
        !address.isLinkLocal &&
        !isUnspecified &&
        !isUniqueLocal &&
        bytes[0] != 0xff &&
        !address.address.toLowerCase().startsWith('::ffff:');
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static String? _firstText(Iterable<String?> values) {
    for (final value in values) {
      final text = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }
}

class _FetchedResponse {
  const _FetchedResponse({
    required this.uri,
    required this.contentType,
    required this.bytes,
  });

  final Uri uri;
  final String? contentType;
  final Uint8List bytes;

  String get text => utf8.decode(bytes, allowMalformed: true);
}

class _PreviewFetchException implements Exception {
  const _PreviewFetchException();
}
