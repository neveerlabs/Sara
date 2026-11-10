import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sara_desktop/image_barcode_scanner.dart';
import 'package:zxing_lib/src/barcode_format.dart';
import 'package:zxing_lib/src/qrcode/qrcode_writer.dart';

void main() {
  test('scans a QR code from an image file', () async {
    final matrix = QRCodeWriter().encode(
      'sara barcode test',
      BarcodeFormat.qrCode,
      240,
      240,
    );
    final image = img.Image(
      width: matrix.width,
      height: matrix.height,
      numChannels: 3,
    );
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        final value = matrix.get(x, y) ? 0 : 255;
        image.setPixelRgb(x, y, value, value, value);
      }
    }

    final directory = await Directory.systemTemp.createTemp('sara-barcode-');
    final imageFile = File('${directory.path}/barcode.png');
    await imageFile.writeAsBytes(img.encodePng(image));
    addTearDown(() => directory.delete(recursive: true));

    expect(
      await const ImageBarcodeScanner().scanFile(imageFile.path),
      'qrCode: sara barcode test',
    );
  });
}
