import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing_lib/src/binary_bitmap.dart';
import 'package:zxing_lib/src/common/binarizer/hybrid_binarizer.dart';
import 'package:zxing_lib/src/decode_hint.dart';
import 'package:zxing_lib/src/multi_format_reader.dart';
import 'package:zxing_lib/src/not_found_exception.dart';
import 'package:zxing_lib/src/rgb_luminance_source.dart';

class ImageBarcodeScanner {
  const ImageBarcodeScanner();

  static const int _maxFileBytes = 14 * 1024 * 1024;
  static const int _maxPixels = 20 * 1000 * 1000;

  Future<String?> scanFile(String filePath) async {
    final file = File(filePath);
    final size = await file.length();
    if (size > _maxFileBytes) {
      throw const FormatException('Image exceeds the 14 MB scan limit.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxFileBytes) {
      throw const FormatException('Image exceeds the 14 MB scan limit.');
    }
    return Isolate.run(() => _decode(bytes));
  }

  static String? _decode(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('The selected file is not a readable image.');
    }
    final oriented = img.bakeOrientation(decoded);
    if (oriented.width * oriented.height > _maxPixels) {
      throw const FormatException('Image dimensions exceed the scan limit.');
    }
    final rgba = oriented.convert(numChannels: 4);
    final pixelBytes = rgba.getBytes(order: img.ChannelOrder.rgba);
    final pixels = Int32List(oriented.width * oriented.height);
    for (var index = 0; index < pixels.length; index++) {
      final offset = index * 4;
      pixels[index] = 0xff000000 |
          (pixelBytes[offset] << 16) |
          (pixelBytes[offset + 1] << 8) |
          pixelBytes[offset + 2];
    }
    final source = RGBLuminanceSource(
      oriented.width,
      oriented.height,
      pixels,
    );
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    try {
      final result = MultiFormatReader().decode(
        bitmap,
        const DecodeHint(tryHarder: true, alsoInverted: true),
      );
      return '${result.barcodeFormat.name}: ${result.text}';
    } on NotFoundException {
      return null;
    }
  }
}
