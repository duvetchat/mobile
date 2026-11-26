/// What the mobile app and the desktop do alike where the core leaves it to them (PLAN-E2E-CLIENTES.md, its conventions
/// between clients): a message's envelope as the core's encrypt takes it, what a message the core shows is drawn as, a
/// file's name and type as a client may use them, and the frames of a device's approval in the inbox, with its
/// fingerprint. Each has its cases in test/e2e/e2e-conventions.json, which the desktop's conventions.test.ts reads too.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A message's content as the core's encrypt takes it, which it writes as the envelope `{v: 1, text?, attachments?}`:
/// its text as a message's content carries it today, mentions and emojis included (`<@id>`, `<#id>`, `<:id:>`), and
/// its files (each `{id, key, sha256, name, type, size, width?, height?, duration_ms?, waveform?, thumbnail?,
/// thumbnail_ref?}`, binaries in base64). With neither it's the empty envelope of a sticker's message, the sticker in
/// the clear beside it. The core refuses an empty text: a message without one leaves it out.
Map<String, Object?> messageEnvelope(String text, List<Map<String, Object?>> attachments) => {
  if (text.isNotEmpty) 'text': text,
  if (attachments.isNotEmpty) 'attachments': attachments,
};

/// A voice note's waveform: 64 samples of a byte, each the peak of its stretch of the note.
const waveformSamples = 64;

/// What a message the core shows is drawn as.
enum Drawn { voiceNote, sticker, nothing, message }

/// What a message the core shows is drawn as: a voice note (no text, and one audio file with its waveform and duration,
/// by what its sender says of it: its player still reads the file's type from its bytes), the sticker of an empty
/// envelope, nothing for an empty envelope without a sticker, or else a message, with its text and files. Its sender
/// wrote the fields, so they're read as the convention has them, never throwing: a duration is a number, and a
/// waveform its 64 bytes in padded standard base64; anything else is a file's.
Drawn drawnAs({required String? text, required List<Map<String, Object?>> attachments, required bool sticker}) {
  final file = attachments.firstOrNull;
  final hasText = text != null && text.isNotEmpty;
  if (!hasText && file == null) return sticker ? Drawn.sticker : Drawn.nothing;
  final (type, waveform) = (file?['type'], file?['waveform']);
  final voice =
      !hasText &&
      attachments.length == 1 &&
      type is String &&
      type.startsWith('audio/') &&
      file!['duration_ms'] is num &&
      waveform is String &&
      canonicalBytes(waveform)?.length == waveformSamples;
  return voice ? Drawn.voiceNote : Drawn.message;
}

/// The bytes base64 holds, read only in the form the core and the API write it: standard, padded, and with no bit set
/// past its bytes. base64Decode takes the URL's alphabet and an escaped padding as well, which the desktop's atob
/// refuses, as that takes spaces, a missing padding and stray bits, which base64Decode refuses: in its one form, both
/// read the same bytes of the same text. Null for any other text.
Uint8List? canonicalBytes(String text) {
  try {
    final bytes = base64Decode(text);
    return base64Encode(bytes) == text ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// A thumbnail's longer side, at most: as an app makes one, and as both draw one.
const thumbnailSide = 320;

/// Whether a thumbnail's bytes are drawn: a JPEG or a PNG whose header says it's [thumbnailSide] a side at most, read
/// before anything decodes it. What its sender writes is theirs, and an 8 KiB JPEG whose header says 12000 × 12000
/// would take a bitmap of 576 MB on every visit (task 19's review, I3; the desktop's thumbnailDrawn).
bool thumbnailDrawn(Uint8List bytes) {
  final size = switch (sniffType(bytes)) {
    'image/png' when bytes.length >= 24 && ascii.decode(bytes.sublist(12, 16), allowInvalid: true) == 'IHDR' => (
      width: ByteData.sublistView(bytes).getUint32(16),
      height: ByteData.sublistView(bytes).getUint32(20),
    ),
    'image/jpeg' => _jpegSize(bytes),
    _ => null,
  };
  return size != null && size.width > 0 && size.height > 0 && max(size.width, size.height) <= thumbnailSide;
}

/// A JPEG's size, from its first frame header (SOF): its segments are each a marker, then most of them a length.
({int width, int height})? _jpegSize(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  for (var at = 2; at + 4 <= bytes.length;) {
    if (bytes[at] != 0xff) return null;
    final marker = bytes[at + 1];
    if (marker == 0xff) {
      at++; // fill
    } else if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      at += 2; // no length
    } else if (marker == 0xd9 || marker == 0xda) {
      return null; // its end, or its data, before any frame header
    } else if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
      return at + 9 <= bytes.length ? (width: view.getUint16(at + 7), height: view.getUint16(at + 5)) : null;
    } else {
      at += 2 + view.getUint16(at + 2);
    }
  }
  return null;
}

/// The most characters a file's name keeps, counted by code point.
const maxFileName = 255;

// What a name loses: control characters, the line and paragraph separators, and every format character but the
// zero-width joiner, which holds an emoji sequence together. The bidirectional controls are format characters: with
// one, an invoice named "invoice", a right-to-left override and "cod.exe" shows as "invoiceexe.doc".
final _unseen = RegExp('[\\p{Cc}\\p{Zl}\\p{Zp}]|(?!${String.fromCharCode(0x200d)})\\p{Cf}', unicode: true);
final _lone = RegExp(r'\p{Cs}', unicode: true);

// A lone surrogate, which shows as U+FFFD and is written as one in UTF-8, is made one first: halves that a hidden
// character kept apart would otherwise join into a character of their own once it goes, as U+DB40 U+200B U+DC01 joins
// into U+E0001, a hidden tag character (the desktop's visible).
String _visible(String text) => text.replaceAll(_lone, '\u{fffd}').replaceAll(_unseen, '');

/// A file's name as a client may show or use it, whoever wrote it: its last part after any / or \, without the
/// characters that hide what it is, trimmed, 255 characters at most; "file" when nothing of it is left.
String cleanName(String name) {
  final last = name.split(RegExp(r'[/\\]')).last;
  final kept = String.fromCharCodes(_visible(last).trim().runes.take(maxFileName)).trim();
  return kept.isEmpty || kept == '.' || kept == '..' ? 'file' : kept;
}

/// How much of a file both apps read to tell its type: its first 64 KiB.
const sniffPrefix = 64 << 10;
const _octetStream = 'application/octet-stream';
// The brands of an ISO media file (its `ftyp`) the clients draw; any other is a file to download.
final _brands = {
  'M4A ': 'audio/mp4',
  'qt  ': 'video/quicktime',
  'avif': 'image/avif',
  for (final brand in const [
    'isom',
    'iso2',
    'iso4',
    'iso5',
    'iso6',
    'mp41',
    'mp42',
    'avc1',
    'M4V ',
    'dash',
    'mmp4',
    '3gp4',
    '3gp5',
    '3gp6',
  ])
    brand: 'video/mp4',
};

/// A file's type, read from its first 64 KiB at most ([sniffPrefix]): one of the media both apps draw, or else
/// application/octet-stream, a file that is only ever downloaded, as a HEIC and a PDF are. What its sender says it is
/// counts for nothing: a page or an SVG that calls itself a picture is no picture.
String sniffType(Uint8List file) {
  final bytes = Uint8List.sublistView(file, 0, min(file.length, sniffPrefix));
  bool at(int offset, List<int> expected) {
    if (offset + expected.length > bytes.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (bytes[offset + i] != expected[i]) return false;
    }
    return true;
  }

  bool text(int offset, String ascii) => at(offset, ascii.codeUnits);
  if (at(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'image/png';
  if (at(0, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (text(0, 'GIF87a') || text(0, 'GIF89a')) return 'image/gif';
  if (text(0, 'RIFF') && text(8, 'WEBP')) return 'image/webp';
  if (text(0, 'RIFF') && text(8, 'WAVE')) return 'audio/wav';
  if (text(4, 'ftyp') && bytes.length >= 12) return _brands[String.fromCharCodes(bytes, 8, 12)] ?? _octetStream;
  if (at(0, const [0x1a, 0x45, 0xdf, 0xa3])) return _webmType(bytes) ?? _octetStream;
  if (text(0, 'OggS')) return 'audio/ogg';
  if (text(0, 'fLaC')) return 'audio/flac';
  if (text(0, 'ID3') || (bytes.length > 1 && bytes[0] == 0xff && const [0xfb, 0xfa, 0xf3, 0xf2].contains(bytes[1]))) {
    return 'audio/mpeg';
  }
  return _octetStream;
}

// The EBML elements a WebM's type is read from (Matroska's specification).
const _ebml = 0x1a45dfa3;
const _docType = 0x4282;
const _segment = 0x18538067;
const _tracks = 0x1654ae6b;
const _trackEntry = 0xae;
const _trackType = 0x83;
const _cluster = 0x1f43b675;

/// A WebM's type, by its tracks: audio when none is video (the desktop's voice notes), else video. Null for anything
/// else: a Matroska that isn't a WebM, or one whose tracks aren't in the bytes it has.
String? _webmType(Uint8List bytes) {
  var at = 0;
  // A variable-length integer: its length is its first byte's leading zeros, plus one; an ID keeps its marker.
  int? vint({required bool id}) {
    if (at >= bytes.length || bytes[at] == 0) return null;
    final first = bytes[at];
    final length = 9 - first.bitLength;
    if (at + length > bytes.length) return null;
    var value = id ? first : first & (0xff >> length);
    for (var i = 1; i < length; i++) {
      value = value * 256 + bytes[at + i];
    }
    at += length;
    return value;
  }

  // An element's ID and where its data ends: an unknown size (all ones) runs to the end of what there is.
  ({int id, int end})? element() {
    final id = vint(id: true);
    final size = vint(id: false);
    return id == null || size == null ? null : (id: id, end: min(at + size, bytes.length));
  }

  final header = element();
  if (header == null || header.id != _ebml) return null;
  var webm = false;
  while (at < header.end) {
    final child = element();
    if (child == null) return null;
    if (child.id == _docType) webm = child.end - at == 4 && String.fromCharCodes(bytes, at, at + 4) == 'webm';
    at = child.end;
  }
  final segment = element();
  if (!webm || segment == null || segment.id != _segment) return null;
  var audio = false;
  while (at < segment.end) {
    final child = element();
    // The tracks come before the first cluster.
    if (child == null || child.id == _cluster) break;
    while (child.id == _tracks && at < child.end) {
      final entry = element();
      if (entry == null) return null;
      while (entry.id == _trackEntry && at < entry.end) {
        final field = element();
        if (field == null) return null;
        if (field.id == _trackType && field.end == at + 1 && bytes[at] == 1) return 'video/webm';
        if (field.id == _trackType && field.end == at + 1 && bytes[at] == 2) audio = true;
        at = field.end;
      }
      at = entry.end;
    }
    at = child.end;
  }
  return audio ? 'audio/webm' : null;
}

/// A step of a device's approval.
enum ApprovalStep { commitment, offer, reveal, transfer }

/// A step of a device's approval, as one device sends it to another through the inbox: the core's bytes in base64,
/// and the new device's name, which the device approving it shows.
typedef ApprovalFrame = ({ApprovalStep step, String data, String? name});

const _frameFields = {'duvet', 'step', 'data', 'name'};

/// The most characters a device's name has, counted by code point.
const maxDeviceName = 64;

/// An approval frame as the inbox's message carries it: its JSON in UTF-8, its fields in this order, in base64.
String approvalFrameMessage(ApprovalFrame frame) => base64Encode(
  utf8.encode(jsonEncode({'duvet': 'approval', 'step': frame.step.name, 'data': frame.data, 'name': ?frame.name})),
);

/// The approval frame an inbox message is, or null, when it's a message of the core between devices
/// (receive_direct's). A frame is JSON with duvet "approval", one of the four steps, its data in base64, a name of 64
/// characters at most if any, and nothing else.
ApprovalFrame? readApprovalFrame(String message) {
  final bytes = canonicalBytes(message);
  if (bytes == null) return null;
  // A byte order mark is no JSON's, as the desktop reads it; utf8.decode would drop it.
  if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) return null;
  final Object? value;
  try {
    value = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
  if (value is! Map<String, dynamic> || value.keys.any((key) => !_frameFields.contains(key))) return null;
  final step = ApprovalStep.values.asNameMap()[value['step']];
  final data = value['data'];
  if (value['duvet'] != 'approval' || step == null) return null;
  if (data is! String || data.isEmpty || canonicalBytes(data) == null) return null;
  if (!value.containsKey('name')) return (step: step, data: data, name: null);
  // The approving device shows the name: it loses what doesn't show, as a file's name does.
  final name = value['name'];
  if (name is! String) return null;
  final shown = _visible(name).trim();
  return shown.isEmpty || shown.runes.length > maxDeviceName ? null : (step: step, data: data, name: shown);
}

final _fingerprintLabel = utf8.encode('duvet approval fingerprint v1');

/// The fingerprint of a device's approval (Ruling 35), which the approving computer's box names and the new device's
/// screen shows, for the person to compare: SHA-256 over `duvet approval fingerprint v1` and the commitment's bytes,
/// as its frame carries them, which bind all that the core certifies. Its first 8 bytes, in 16 lowercase hex digits,
/// in four groups of four.
String approvalFingerprint(List<int> commitment) {
  final digest = sha256.convert([..._fingerprintLabel, ...commitment]).bytes;
  final hex = [for (final byte in digest.take(8)) byte.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 4)} ${hex.substring(4, 8)} ${hex.substring(8, 12)} ${hex.substring(12, 16)}';
}
