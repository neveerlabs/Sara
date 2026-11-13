import 'package:flutter_test/flutter_test.dart';
import 'package:sara_desktop/link_preview_service.dart';

void main() {
  test('does not request invalid or non-web URLs', () async {
    final service = LinkPreviewService();

    expect(await service.load(Uri.parse('ftp://example.com/file')), isNull);
    expect(await service.load(Uri.parse('https:///missing-host')), isNull);
    expect(
      await service.loadFavicon(Uri.parse('ftp://example.com/favicon.ico')),
      isNull,
    );
  });

  test('does not fetch private-network URLs for link previews', () async {
    final service = LinkPreviewService();

    expect(
      await service.load(Uri.parse('http://127.0.0.1:8080/private')),
      isNull,
    );
    expect(await service.load(Uri.parse('http://localhost/private')), isNull);
    expect(
      await service.loadFavicon(Uri.parse('http://localhost/private')),
      isNull,
    );
  });
}
