import 'dart:typed_data';

// Ogg Opus as Android's MediaMuxer writes it (the voice recorder, on Android 10 and later): each page carries its
// packet's start as its granule position instead of its end (RFC 7845), and the last page doesn't end the stream. The
// app and Chromium play such a file; Firefox rejects it, so the web app couldn't play a voice note sent from a phone.

final List<int> _crcTable = List<int>.generate(256, (i) {
  var r = i << 24;
  for (var j = 0; j < 8; j++) {
    r = (r & 0x80000000) != 0 ? ((r << 1) ^ 0x04c11db7) & 0xffffffff : (r << 1) & 0xffffffff;
  }
  return r;
});

/// An Ogg page's CRC (polynomial 0x04c11db7, no reflection), of the page with its CRC field zeroed.
int oggCrc(Uint8List bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc = ((crc << 8) & 0xffffffff) ^ _crcTable[((crc >> 24) ^ b) & 0xff];
  }
  return crc;
}

/// How many samples, at 48 kHz, an Opus packet decodes to, from its TOC byte (RFC 6716, 3.1).
int opusSamples(Uint8List packet) {
  final config = packet[0] >> 3;
  // A frame's length, in tenths of a millisecond.
  final tenths = config < 12
      ? const [100, 200, 400, 600][config % 4]
      : config < 16
      ? const [100, 200][config % 2]
      : const [25, 50, 100, 200][config % 4];
  final code = packet[0] & 3;
  final frames = code == 0
      ? 1
      : code < 3
      ? 2
      : packet.length > 1
      ? packet[1] & 0x3f
      : 0;
  return frames * tenths * 48 ~/ 10;
}

/// The recording with each page's granule position at the end of the last packet it completes (pre-skip included, -1
/// on a page that completes none), the last page ending the stream, and the CRCs computed again; null when it isn't
/// one whole Ogg Opus stream.
Uint8List? repairOggOpus(Uint8List input) {
  final data = Uint8List.fromList(input);
  final view = ByteData.sublistView(data);
  final pages = <({int at, int length, int completes, int samples})>[];
  final packet = <int>[];
  var packets = 0;
  var pos = 0;
  while (pos < data.length) {
    if (pos + 27 > data.length || view.getUint32(pos, Endian.little) != 0x5367674f) return null; // "OggS"
    if (pages.isNotEmpty && view.getUint32(pos + 14, Endian.little) != view.getUint32(14, Endian.little)) return null;
    final segments = data[pos + 26];
    if (pos + 27 + segments > data.length) return null;
    var body = pos + 27 + segments;
    var end = body;
    for (var i = 0; i < segments; i++) {
      end += data[pos + 27 + i];
    }
    if (end > data.length) return null;
    var completes = 0;
    var samples = 0;
    for (var i = 0; i < segments; i++) {
      final size = data[pos + 27 + i];
      packet.addAll(Uint8List.sublistView(data, body, body + size));
      body += size;
      if (size < 255) {
        final bytes = Uint8List.fromList(packet);
        if (packets == 0 && String.fromCharCodes(bytes.take(8)) != 'OpusHead') return null;
        if (packets >= 2 && bytes.isNotEmpty) samples += opusSamples(bytes);
        packets++;
        completes++;
        packet.clear();
      }
    }
    pages.add((at: pos, length: end - pos, completes: completes, samples: samples));
    pos = end;
  }
  if (packets < 3) return null;
  var total = 0;
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    total += page.samples;
    view.setInt64(page.at + 6, page.completes == 0 ? -1 : total, Endian.little);
    if (i == pages.length - 1) data[page.at + 5] |= 4;
    view.setUint32(page.at + 22, 0, Endian.little);
    view.setUint32(page.at + 22, oggCrc(Uint8List.sublistView(data, page.at, page.at + page.length)), Endian.little);
  }
  return data;
}
