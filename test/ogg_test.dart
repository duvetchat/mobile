import 'dart:convert';
import 'dart:typed_data';

import 'package:duvet/data/ogg.dart';
import 'package:flutter_test/flutter_test.dart';

const _serial = 0x4244293a;

/// A page with the given segment sizes and body, its CRC computed.
Uint8List _rawPage(int flags, int granule, int seq, List<int> segments, List<int> body, {int serial = _serial}) {
  final bytes = Uint8List(27 + segments.length + body.length);
  final view = ByteData.sublistView(bytes);
  bytes.setAll(0, ascii.encode('OggS'));
  bytes[5] = flags;
  view.setInt64(6, granule, Endian.little);
  view.setUint32(14, serial, Endian.little);
  view.setUint32(18, seq, Endian.little);
  bytes[26] = segments.length;
  bytes.setAll(27, segments);
  bytes.setAll(27 + segments.length, body);
  view.setUint32(22, oggCrc(bytes), Endian.little);
  return bytes;
}

/// A page that holds whole packets.
Uint8List _page(int flags, int granule, int seq, List<List<int>> packets, {int serial = _serial}) => _rawPage(
  flags,
  granule,
  seq,
  [
    for (final p in packets) ...[...List.filled(p.length ~/ 255, 255), p.length % 255],
  ],
  [for (final p in packets) ...p],
  serial: serial,
);

Uint8List _file(List<Uint8List> pages) => Uint8List.fromList([for (final p in pages) ...p]);

/// Each page's flags, granule position and whether its CRC verifies.
List<({int flags, int granule, bool crcOk})> _pagesOf(Uint8List data) {
  final view = ByteData.sublistView(data);
  final pages = <({int flags, int granule, bool crcOk})>[];
  for (var pos = 0; pos < data.length;) {
    final segments = data[pos + 26];
    var length = 27 + segments;
    for (var i = 0; i < segments; i++) {
      length += data[pos + 27 + i];
    }
    final copy = Uint8List.fromList(data.sublist(pos, pos + length));
    ByteData.sublistView(copy).setUint32(22, 0, Endian.little);
    pages.add((
      flags: data[pos + 5],
      granule: view.getInt64(pos + 6, Endian.little),
      crcOk: oggCrc(copy) == view.getUint32(pos + 22, Endian.little),
    ));
    pos += length;
  }
  return pages;
}

// OpusHead: version 1, mono, 312 samples of pre-skip, 48 kHz, no gain, mapping family 0.
final _head = [...ascii.encode('OpusHead'), 1, 1, 0x38, 0x01, 0x80, 0xbb, 0, 0, 0, 0, 0];
final _tags = [...ascii.encode('OpusTags'), 4, 0, 0, 0, ...ascii.encode('test'), 0, 0, 0, 0];
// A 20 ms CELT fullband packet (TOC config 31, one frame): 960 samples.
const _frame = [0xf8, 1, 2, 3];

void main() {
  test('a recording\'s pages get their packets\' ends, and its last page ends the stream', () {
    // As Android's MediaMuxer writes them: each page carries its packet's start.
    final android = _file([
      _page(2, 0, 0, [_head]),
      _page(0, 0, 1, [_tags]),
      _page(0, 0, 2, [_frame]),
      _page(0, 960, 3, [_frame]),
      _page(0, 1920, 4, [_frame]),
    ]);
    final pages = _pagesOf(repairOggOpus(android)!);
    expect(pages.map((p) => p.granule), [0, 0, 960, 1920, 2880]);
    expect(pages.map((p) => p.flags), [2, 0, 0, 0, 4]);
    expect(pages.every((p) => p.crcOk), isTrue);
    // The recording stays as it was.
    expect(_pagesOf(android).map((p) => p.granule), [0, 0, 0, 960, 1920]);
  });

  test('a page that completes no packet gets -1, and the page that completes it counts it', () {
    final long = List<int>.filled(300, 7)..[0] = 0xf8;
    final repaired = repairOggOpus(
      _file([
        _page(2, 0, 0, [_head]),
        _page(0, 0, 1, [_tags]),
        _rawPage(0, 0, 2, [255], long.sublist(0, 255)),
        _rawPage(1, 0, 3, [45, 4], [...long.sublist(255), ..._frame]),
      ]),
    );
    expect(_pagesOf(repaired!).map((p) => p.granule), [0, 0, -1, 1920]);
  });

  test('anything but one whole Ogg Opus stream isn\'t repaired', () {
    expect(repairOggOpus(Uint8List.fromList(ascii.encode('RIFF....WAVEfmt '))), isNull);
    // Headers alone.
    expect(
      repairOggOpus(
        _file([
          _page(2, 0, 0, [_head]),
          _page(0, 0, 1, [_tags]),
        ]),
      ),
      isNull,
    );
    // Ogg Vorbis.
    expect(
      repairOggOpus(
        _file([
          _page(2, 0, 0, [
            [1, ...ascii.encode('vorbis')],
          ]),
          _page(0, 0, 1, [_tags]),
          _page(0, 0, 2, [_frame]),
        ]),
      ),
      isNull,
    );
    // Two streams.
    expect(
      repairOggOpus(
        _file([
          _page(2, 0, 0, [_head]),
          _page(0, 0, 1, [_tags]),
          _page(0, 0, 2, [_frame], serial: _serial + 1),
        ]),
      ),
      isNull,
    );
    // Cut short.
    final headers = _file([
      _page(2, 0, 0, [_head]),
      _page(0, 0, 1, [_tags]),
    ]);
    expect(repairOggOpus(Uint8List.sublistView(headers, 0, 40)), isNull);
  });

  test('a packet\'s samples at 48 kHz come from its TOC byte', () {
    expect(opusSamples(Uint8List.fromList([0xf8])), 960); // CELT 20 ms, one frame
    expect(opusSamples(Uint8List.fromList([0xe0])), 120); // CELT 2.5 ms
    expect(opusSamples(Uint8List.fromList([0x68])), 960); // hybrid 20 ms
    expect(opusSamples(Uint8List.fromList([0x18])), 2880); // SILK 60 ms
    expect(opusSamples(Uint8List.fromList([0x09])), 1920); // SILK 20 ms, two frames
    expect(opusSamples(Uint8List.fromList([0x0b, 0x03])), 2880); // SILK 20 ms, three frames (code 3)
  });
}
