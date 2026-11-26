/// What the app works out of a picture the person sends in a conversation (PLAN-E2E-CLIENTES.md, its conventions
/// between clients): its size and its thumbnail, 320 px on its longer side at most, a JPEG, or a PNG when it has
/// transparency, made off the UI isolate. The engine seals the file and what's said of it (files.dart). The desktop's
/// thumbnails.ts in Dart.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// A thumbnail's longer side, at most.
const thumbnailSide = 320;

/// A thumbnail's size: its picture's proportions, its longer side at most [thumbnailSide]; null for no picture.
({int width, int height})? thumbnailSize(int width, int height) {
  if (width <= 0 || height <= 0) return null;
  final scale = min(1.0, thumbnailSide / max(width, height));
  return (width: max(1, (width * scale).round()), height: max(1, (height * scale).round()));
}

/// Whether RGBA pixels have no transparency: a JPEG holds them.
bool opaque(Uint8List rgba) {
  for (var at = 3; at < rgba.length; at += 4) {
    if (rgba[at] != 255) return false;
  }
  return true;
}

/// A picture's size and thumbnail.
typedef PictureFacts = ({int width, int height, Uint8List? thumbnail});

/// A picture's size and thumbnail (its first frame, a GIF's), or null when no decoder takes its bytes.
// shortcut: no video's first frame (video_player hands out no picture of one): a video goes without a thumbnail, its
// tile showing the play mark until it's downloaded; upgrade with a frame grabber the app takes on.
Future<PictureFacts?> pictureFacts(Uint8List bytes) => compute(_facts, bytes);

PictureFacts? _facts(Uint8List bytes) {
  final img.Image? picture;
  try {
    // Its first frame alone: a GIF's others are never drawn here.
    picture = img.decodeImage(bytes, frame: 0);
  } catch (_) {
    return null;
  }
  if (picture == null) return null;
  final size = thumbnailSize(picture.width, picture.height);
  if (size == null) return null;
  final small = img.copyResize(
    picture,
    width: size.width,
    height: size.height,
    interpolation: img.Interpolation.average,
  );
  final rgba = small.convert(format: img.Format.uint8, numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  final thumbnail = opaque(rgba) ? img.encodeJpg(small, quality: 70) : img.encodePng(small);
  return (width: picture.width, height: picture.height, thumbnail: thumbnail);
}
