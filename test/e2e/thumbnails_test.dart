import 'dart:typed_data';

import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/thumbnails.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

// What the app works out of a picture the person sends in a conversation (PLAN-E2E-CLIENTES.md, its conventions
// between clients): its size and its thumbnail, 320 px on its longer side at most, a JPEG, or a PNG when it has
// transparency. The desktop's thumbnails.test.ts.

/// A picture of [width] by [height], opaque or not, as a PNG's bytes.
Uint8List _picture(int width, int height, {bool seeThrough = false}) {
  final picture = img.Image(width: width, height: height, numChannels: 4);
  img.fill(picture, color: img.ColorRgba8(200, 80, 40, seeThrough ? 100 : 255));
  return img.encodePng(picture);
}

void main() {
  test(
    "a_thumbnail_is_320_px_on_its_longer_side_at_most,_in_its_picture's_proportions;_a_smaller_one_keeps_its_size",
    () {
      expect(thumbnailSide, 320);
      expect(thumbnailSize(1280, 640), (width: 320, height: 160));
      expect(thumbnailSize(480, 960), (width: 160, height: 320));
      expect(thumbnailSize(100, 50), (width: 100, height: 50));
      expect(thumbnailSize(10000, 1), (width: 320, height: 1));
      expect(thumbnailSize(0, 10), isNull);
    },
  );

  test('a_thumbnail_is_a_JPEG,_or_a_PNG_when_its_picture_has_transparency', () async {
    expect(opaque(Uint8List.fromList([1, 2, 3, 255, 4, 5, 6, 255])), isTrue);
    expect(opaque(Uint8List.fromList([1, 2, 3, 255, 4, 5, 6, 254])), isFalse);
    final solid = (await pictureFacts(_picture(640, 480)))!;
    expect((solid.width, solid.height), (640, 480));
    expect(sniffType(solid.thumbnail!), 'image/jpeg');
    final decoded = img.decodeImage(solid.thumbnail!)!;
    expect((decoded.width, decoded.height), (320, 240));
    final clear = (await pictureFacts(_picture(200, 100, seeThrough: true)))!;
    expect(sniffType(clear.thumbnail!), 'image/png');
    expect((img.decodeImage(clear.thumbnail!)!.width), 200);
    // Bytes no decoder takes give nothing.
    expect(await pictureFacts(Uint8List.fromList([1, 2, 3])), isNull);
  });
}
