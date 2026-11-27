import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:duvet/data/links.dart' show isDuvetId;
import 'package:duvet/data/models.dart' show ConversationTarget, RoomTarget;
import 'package:duvet/e2e/cbor.dart';
import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/inbox.dart';
import 'package:duvet/e2e/push_decrypt.dart' show pushedEntry;
import 'package:duvet/e2e/store.dart';
import 'package:duvet/e2e/sync.dart';
import 'package:duvet/push/push_message.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/engines.dart' show MemoryStore, TestClock, engineClient, fakeRouter;
import '../support/fuzz.dart';

// Step 5's fuzzing (PLAN-E2E-CLIENTES.md, «Lo que el paso 5 revisa»): what the app reads on its own, of another
// person's device or of the server, whatever it holds. Each reader answers its refusal and never throws, ends within
// the budget (250 ms an input), and what it answers keeps its invariants. Most take hand-picked inputs first (the edges
// of each reader, and where Dart reads otherwise than the desktop's JavaScript), then a fixed seed's: a few thousand a
// reader in CI, DUVET_FUZZ_RUNS for a long run (DUVET_FUZZ_SEED for another seed). The desktop's fuzz.test.ts in Dart;
// its hand-picked inputs are the corpus's, which fuzz_corpus_test.dart holds these readers to.

/// A run's time: a long run's takes hours.
final _timeout = longRun ? Timeout.none : const Timeout(Duration(minutes: 2));

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
// Every hidden character, an expression of this test's own: the reader's is its own.
final _hidden = RegExp('[\\p{Cc}\\p{Zl}\\p{Zp}]|(?!\u{200d})\\p{Cf}', unicode: true);
const _octet = 'application/octet-stream';
const _types = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/avif',
  'audio/wav',
  'audio/mp4',
  'audio/ogg',
  'audio/flac',
  'audio/mpeg',
  'audio/webm',
  'video/mp4',
  'video/quicktime',
  'video/webm',
  _octet,
};

/// The most JavaScript's numbers hold exactly, which the desktop counts with.
const _safe = (1 << 53) - 1;

bool _count(Object? value) => value is int && value >= 0 && value <= _safe;

/// A name as it shows once its hidden characters go, or null when nothing of it is left or it's past [most].
String? _shown(String name, int most) {
  final shown = wellFormed(name).replaceAll(_hidden, '').trim();
  return shown.isEmpty || shown.runes.length > most ? null : shown;
}

// What a device's name may not look like (mobile#353), beside the fingerprint and the code the approving device says
// to compare and to type: a fingerprint's two groups of four hex digits apart by anything but a letter or a digit, and
// a code's six digits that no letter or digit touches.
final _likeFingerprint = RegExp(r'[0-9a-f]{4}[^\p{L}\p{N}]+[0-9a-f]{4}', caseSensitive: false, unicode: true);
final _likeCode = RegExp(r'(?<![\p{L}\p{N}])\p{Nd}{6}(?![\p{L}\p{N}])', unicode: true);

/// A device's name as the approving device shows it, or null for one it doesn't show.
String? _deviceName(String name) => switch (_shown(name, maxDeviceName)) {
  final shown? when !_likeFingerprint.hasMatch(shown) && !_likeCode.hasMatch(shown) => shown,
  _ => null,
};

/// Base64 of text in UTF-8.
String _utf8(String text) => base64(utf8.encode(text));

// ---------------------------------------------------------------------------------------------------------------
// Approval frames.

/// A frame's message as another device, or anyone, may write it: its fields each as the convention has them or not,
/// at times another, its JSON at times changed, its base64 at times in another form; and the frame the reader makes of
/// it, when all of it is as the convention has it.
(String, ApprovalFrame?) _frameOf(Random rng) {
  final fields = <String, Object?>{};
  var whole = true;
  if (rng.chance(0.9)) {
    fields['duvet'] = 'approval';
  } else {
    whole = false;
    if (rng.chance()) fields['duvet'] = rng.chance() ? 'Approval' : json(rng, 1);
  }
  final step = rng.pick(ApprovalStep.values);
  if (rng.chance(0.9)) {
    fields['step'] = step.name;
  } else {
    whole = false;
    fields['step'] = rng.chance() ? step.name.toUpperCase() : json(rng, 1);
  }
  final bytes = rng.bytes(1 + rng.nextInt(rng.chance(0.05) ? 6000 : 64));
  final data = base64(bytes);
  final given = rng.chance(0.8) ? data : (rng.chance(0.7) ? base64As(rng, bytes) : json(rng, 1));
  fields['data'] = given;
  if (given != data) whole = false;
  String? name;
  if (rng.chance(0.6)) {
    final written = rng.chance(0.9) ? text(rng, rng.pick([8, 64, 80])) : json(rng, 1);
    fields['name'] = written;
    name = written is String ? _deviceName(written) : null;
    if (name == null) whole = false;
  }
  if (rng.chance(0.05)) {
    fields[rng.pick(['id', 'Duvet', 'names', ''])] = json(rng, 1);
    whole = false;
  }
  var encoded = utf8.encode(jsonEncode(fields));
  if (rng.chance(0.1)) {
    final changed = mutate(rng, encoded);
    if (base64(changed) != base64(encoded)) whole = false;
    encoded = changed;
  }
  if (rng.chance(0.03)) {
    encoded = Uint8List.fromList([0xef, 0xbb, 0xbf, ...encoded]);
    whole = false;
  }
  var message = base64(encoded);
  if (rng.chance(0.15)) {
    final other = base64As(rng, encoded);
    if (other != message) whole = false;
    message = other;
  }
  if (rng.chance(0.05)) {
    final changed = mutateText(rng, message);
    if (changed != message) whole = false;
    message = changed;
  }
  return (message, whole ? (step: step, data: data, name: name) : null);
}

List<String> _pickedFrames() {
  const frame = (step: ApprovalStep.offer, data: 'b2Y=', name: null);
  String named(String name) => approvalFrameMessage((step: ApprovalStep.offer, data: 'b2Y=', name: name));
  return [
    approvalFrameMessage(frame),
    ...notCanonical(approvalFrameMessage(frame)),
    ...notCanonical(named('???')),
    named('Ana\u{db40}\u{200b}\u{dc01}'),
    named('x' * maxDeviceName),
    named('x' * (maxDeviceName + 1)),
    named('\u{1f600}' * maxDeviceName),
    named('Ana\u{85}'),
    named('\u{200b}\u{202e}'),
    named('\u{feff}Ana'),
    named(''),
    // Shaped like a fingerprint or a code, which it would stand beside, or not: a phone's model keeps its digits.
    named('ab12 cd34'),
    named('AB12-CD34 phone'),
    named('Code 123456'),
    named('\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}'),
    named('22041219NY'),
    named('Pixel 8 Pro'),
    // Dart reads a duplicate key as its last, as JSON.parse does.
    _utf8('{"duvet":"approval","step":"offer","step":"reveal","data":"b2Y="}'),
    _utf8('{"duvet":"approval","step":"offer","data":"b2Y=","name":null}'),
    _utf8('{"duvet":"approval","step":"offer","data":"b2Y=","name":5}'),
    _utf8('{"duvet":"approval","step":"offer","data":["b2Y="]}'),
    _utf8('\u{feff}{"duvet":"approval","step":"offer","data":"b2Y="}'),
    _utf8('{"duvet":"approval","step":"offer","data":"b2Y=","x":1}'),
    // What would take a reader long: deep JSON, and a big message.
    _utf8('[' * 100000),
    _utf8('${'[' * 50000}${']' * 50000}'),
    approvalFrameMessage((step: ApprovalStep.transfer, data: base64(Uint8List(1 << 20)), name: null)),
    'A' * (4 << 20),
    base64([0xc3, 0x28]),
    '',
  ];
}

// ---------------------------------------------------------------------------------------------------------------
// Files' types and images.

/// An EBML element: its ID (its marker kept), its size as a variable-length integer at its shortest, then its data.
Uint8List _ebml(int id, List<int> data) {
  var width = 1;
  while (data.length >= (1 << (7 * width)) - 1) {
    width++;
  }
  final size = bigEndian(data.length, width);
  size[0] |= 0x80 >> (width - 1);
  return concat([bigEndian(id, id > 0xffffff ? 4 : (id > 0xffff ? 3 : (id > 0xff ? 2 : 1))), size, data]);
}

Uint8List _webmHeader(String docType) => _ebml(
  0x1a45dfa3,
  concat([
    _ebml(0x4286, [1]),
    _ebml(0x4282, ascii.encode(docType)),
  ]),
);

Uint8List _tracksOf(List<int> types) => _ebml(
  0x1654ae6b,
  concat([
    for (final type in types)
      _ebml(
        0xae,
        concat([
          _ebml(0xd7, [1]),
          _ebml(0x83, [type]),
          _ebml(0x86, ascii.encode('V_VP8')),
        ]),
      ),
  ]),
);

/// A WebM's header and segment, its tracks of the types picked, and the type its tracks make it.
(Uint8List, String) _webm(Random rng) {
  final docType = rng.chance(0.85) ? 'webm' : rng.pick(['matroska', 'webmx', 'web', '']);
  final types = [
    for (var n = rng.nextInt(4); n > 0; n--) rng.pick([1, 2, 17, 18, 3]),
  ];
  final info = _ebml(0x1549a966, rng.bytes(rng.nextInt(20)));
  final cluster = _ebml(0x1f43b675, rng.bytes(rng.nextInt(40)));
  final clusterFirst = rng.chance(0.15);
  final body = clusterFirst ? concat([info, cluster, _tracksOf(types)]) : concat([info, _tracksOf(types), cluster]);
  // MediaRecorder's segment has no size: all ones of 8 bytes, which runs to the end.
  final unsized = concat([
    [0x18, 0x53, 0x80, 0x67, 0x01, ...List.filled(7, 0xff)],
    body,
  ]);
  final segment = rng.chance(0.3) ? unsized : _ebml(0x18538067, body);
  final tracked = types.contains(1) ? 'video/webm' : (types.contains(2) ? 'audio/webm' : _octet);
  return (concat([_webmHeader(docType), segment]), docType != 'webm' || clusterFirst ? _octet : tracked);
}

Uint8List _brand(String name) => concat([
  [0, 0, 0, 20],
  ascii.encode('ftyp'),
  ascii.encode(name),
  List.filled(8, 0),
]);

/// The starts of the files both apps tell apart, and of some they don't.
final _magics = <List<int>>[
  [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  [0xff, 0xd8, 0xff],
  ascii.encode('GIF89a'),
  ascii.encode('GIF87a'),
  [...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBP')],
  [...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WAVE')],
  _brand('isom'),
  _brand('M4A '),
  _brand('qt  '),
  _brand('avif'),
  _brand('heic'),
  [0x1a, 0x45, 0xdf, 0xa3],
  ascii.encode('OggS'),
  ascii.encode('fLaC'),
  ascii.encode('ID3'),
  [0xff, 0xfb],
  ascii.encode('%PDF-1.7'),
  ascii.encode('<svg'),
];

int _sideOf(Random rng, int most) => rng.pick([0, 1, 240, 320, 321, rng.nextInt(400), most, rng.nextInt(most + 1)]);

/// A PNG's signature and header, of the size given.
Uint8List _png(int width, int height, [List<int> tail = const []]) => concat([
  [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13],
  ascii.encode('IHDR'),
  bigEndian(width, 4),
  bigEndian(height, 4),
  [8, 6, 0, 0, 0, 0, 0, 0, 0],
  tail,
]);

/// A JPEG's start, the segments given, then a frame header of the size given.
Uint8List _jpeg(int width, int height, [List<int> before = const [], int frame = 0xc0]) => Uint8List.fromList([
  0xff,
  0xd8,
  ...before,
  0xff,
  frame,
  0,
  17,
  8,
  ...bigEndian(height, 2),
  ...bigEndian(width, 2),
  3,
]);

/// A JPEG's segments up to its first frame header, as encoders and editors put them, and the size that header says.
(Uint8List, int, int) _jpegOf(Random rng) {
  final before = <int>[];
  for (var n = rng.nextInt(5); n > 0; n--) {
    final data = rng.bytes(rng.nextInt(30));
    List<int> segment(int marker) => [0xff, marker, ...bigEndian(data.length + 2, 2), ...data];
    before.addAll(switch (rng.nextInt(4)) {
      0 => [0xff], // a fill byte before the next marker
      1 => [
        0xff,
        rng.pick([0x01, 0xd0, 0xd3, 0xd7, 0xd8]),
      ],
      2 => segment(0xe0 + rng.nextInt(16)),
      _ => segment(rng.pick([0xc4, 0xc8, 0xcc, 0xdb, 0xdd, 0xfe])),
    });
  }
  final (width, height) = (_sideOf(rng, 65535), _sideOf(rng, 65535));
  final frame = rng.pick([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
  return (concat([_jpeg(width, height, before, frame), rng.bytes(9)]), width, height);
}

bool _drawnAt(int width, int height) => width > 0 && height > 0 && max(width, height) <= thumbnailSide;

// ---------------------------------------------------------------------------------------------------------------
// CBOR.

/// A signed object as the core writes one, `{body, sig}`, its body the value's CBOR.
Uint8List _signed(Object? body) => cborBytes(<String, Object?>{'body': cborBytes(body), 'sig': Uint8List(64)});

/// Lists or maps in each other, [levels] of them, a map's under the key "a", an empty list innermost.
Uint8List _deep(int levels, bool Function() list) => concat([
  for (var n = levels - 1; n > 0; n--) list() ? [0x81] : [0xa1, 0x61, 0x61],
  [0x80],
]);

final _id = Uint8List.fromList(List.generate(16, (i) => i + 1));

/// What the hand-picked CBOR is: its bytes and whether the reader reads it.
List<(Uint8List, bool)> _pickedCbor() {
  Uint8List big(int head, int first) => Uint8List.fromList([head, first, 0, 0, 0, 0, 0, 0, 0]);
  Uint8List of(List<int> bytes) => Uint8List.fromList(bytes);
  return [
    (of([0x9a, 0x05, 0xf5, 0xe1, 0x00]), false),
    // Lengths of 2^63 or more, which Dart's integers hold as below 0: an empty list or map, read as such.
    (big(0x9b, 0x80), false),
    (big(0xbb, 0x80), false),
    (of([0x9b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), false),
    // A length just below 2^63, which past where the reader is wraps below 0: a cut it never sees.
    for (final head in [0x5b, 0x7b, 0x9b, 0xbb]) (of([head, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), false),
    (of([0x82, 0x5b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf7]), false),
    (of([0x9b, 0, 0, 0, 0, 0, 0, 0, 0]), true),
    (_deep(33, () => true), true),
    (_deep(34, () => true), false),
    (_deep(33, () => false), true),
    (_deep(34, () => false), false),
    (_deep(100000, () => true), false),
    // A text's byte order mark, which the core keeps: {"<mark>a": 1, "a": 2} has two keys.
    (of([0xa1, 0x64, 0xef, 0xbb, 0xbf, 0x61, 0x01]), true),
    (of([0xa2, 0x64, 0xef, 0xbb, 0xbf, 0x61, 0x01, 0x61, 0x61, 0x02]), true),
    (of([0xa2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02]), false),
    (of([0xa1, 0x01, 0x02]), false),
    (of([0xc0, 0x00]), false),
    (of([0xf9, 0x00, 0x00]), false),
    (of([0xf7]), false),
    (of([0x9f, 0xff]), false),
    (of([0x62, 0xc3, 0x28]), false),
    (of([0x63, 0xed, 0xa0, 0x80]), false),
    (of([0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), true),
    (of([0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]), true),
    (of([]), false),
  ];
}

/// The hand-picked signed objects and commitments, in base64: as the core writes them, in other forms, of other
/// bodies, a list whose devices say 2^63 of them, and a device under a key with a byte order mark.
List<String> _pickedSigned() {
  final certificate = base64(_signed(<String, Object?>{'device': _id}));
  String list(Map<String, Object?> body) => base64(_signed(body));
  final commitment = base64(cborBytes(<String, Object?>{'device': _id}));
  final wrapped = concat([
    [0xa2, 0x67],
    ascii.encode('devices'),
    [0x9b, 0x80, 0, 0, 0, 0, 0, 0, 0, 0x67],
    ascii.encode('version'),
    [1],
  ]);
  return [
    certificate,
    ...notCanonical(certificate),
    list({
      'devices': [_id],
      'version': 1,
    }),
    list({
      'devices': [
        for (var i = 0; i < 20; i++) Uint8List.fromList([for (final byte in _id) byte ^ i]),
      ],
      'version': 7,
    }),
    list({
      'devices': [_id],
    }),
    list({
      'devices': [_id],
      'version': '1',
    }),
    list({
      'devices': [Uint8List.sublistView(_id, 1)],
      'version': 1,
    }),
    base64(cborBytes(<String, Object?>{'body': wrapped})),
    commitment,
    ...notCanonical(commitment),
    base64(_signed(<String, Object?>{'\u{feff}device': _id})),
  ];
}

// ---------------------------------------------------------------------------------------------------------------
// Entries.

const _when = '2026-11-26T10:00:00Z';

/// A DM_MESSAGE_CREATE's message as the API sends an encrypted one.
Map<String, Object?> _messageOf(Random rng) => {
  'id': rng.uuid(),
  'conversation_id': rng.uuid(),
  'author_id': rng.uuid(),
  'content': null,
  'type': 0,
  'created_at': _when,
  'updated_at': _when,
  'attachments': <Object?>[],
  'reactions': <Object?>[],
  'embeds': <Object?>[],
  'sticker_attachment_id': null,
  'ciphertext': base64(rng.bytes(rng.nextInt(48))),
  'seq': rng.nextInt(1000),
  'sent_at': 1763150000000 + rng.nextInt(1000000),
  'generation': rng.nextInt(4),
  'epoch': rng.nextInt(50),
  'sender_device_id': rng.uuid(),
  if (rng.chance(0.3)) 'mentions': [for (var n = rng.nextInt(3); n > 0; n--) rng.uuid()],
  if (rng.chance(0.3)) 'referenced_message': {'type': 0, 'message_id': rng.chance(0.9) ? rng.uuid() : null},
};

/// An MLS event's data as the API sends one, its entry with its data (none at times, past 16 KiB).
Map<String, Object?> _mlsEventOf(Random rng, String type) {
  final entry = <String, Object?>{
    'seq': rng.nextInt(1000),
    'kind': rng.pick(['commit', 'welcome', 'proposal', 'message', 'edit', 'delete']),
    'data': rng.chance(0.8) ? base64(rng.bytes(rng.nextInt(48))) : null,
    'sent_at': 1763150000000,
    'generation': rng.nextInt(4),
    'epoch': rng.nextInt(50),
    'message_id': rng.uuid(),
    'sender_user': rng.uuid(),
    'sender_device': rng.uuid(),
    if (rng.chance(0.1)) 'statement': base64(rng.bytes(8)),
    if (rng.chance(0.1)) 'deleted': rng.chance(),
    if (rng.chance(0.2)) 'mentions': [for (var n = rng.nextInt(3); n > 0; n--) rng.uuid()],
    if (rng.chance(0.2)) 'reply_to': rng.uuid(),
  };
  return switch (type) {
    'DM_MESSAGE_UPDATE' => {'id': rng.uuid(), 'conversation_id': rng.uuid(), 'edited_at': _when, 'entry': entry},
    'DM_MESSAGE_DELETE' => {'id': rng.uuid(), 'conversation_id': rng.uuid(), 'entry': rng.chance(0.9) ? entry : null},
    _ => {
      'conversation_id': rng.uuid(),
      'generation': rng.nextInt(4),
      'epoch': rng.nextInt(50),
      'entry': entry,
      'devices': <Object?>[],
    },
  };
}

/// What the server may send in a field instead: a number at an edge, of another kind, or none.
Object? _edgeOf(Random rng) => rng.pick<Object?>([
  '5',
  -1,
  1.5,
  null,
  1 << 53,
  _safe,
  (1 << 63) - 1,
  -(1 << 62),
  '',
  <Object?>[],
  <String, Object?>{},
  json(rng, 1),
]);

/// The event as the gateway's client reads it, or null for one it drops: its listener catches what its models throw.
duvet.GatewayEventPayload? _payloadOf(Map<String, Object?> event) {
  try {
    return duvet.GatewayEnvelope.fromJson({'op': 0, 's': 1, 'event': 'payload', 'd': event}).d;
  } catch (_) {
    return null;
  }
}

/// The entry an MLS event's entry is as the core takes it: its own fields, those the core reads, none it didn't carry.
Map<String, Object?> _ownFields(Map<String, Object?> entry) => {
  'seq': entry['seq'],
  'kind': entry['kind'],
  'data': entry['data'],
  'sent_at': entry['sent_at'],
  'message_id': ?entry['message_id'],
  'sender_user': ?entry['sender_user'],
  'sender_device': ?entry['sender_device'],
  'statement': ?entry['statement'],
  if (entry['deleted'] == true) 'deleted': true,
  if (entry['mentions'] case final List<Object?> mentions when mentions.isNotEmpty) 'mentions': mentions,
  'reply_to': ?entry['reply_to'],
};

// ---------------------------------------------------------------------------------------------------------------
// Pushes.

const _pushTypes = ['message', 'encrypted_message', 'signed_out', 'call', 'call_end'];

/// Numbers as text, as an FCM data message carries them, at the edges Dart's int.tryParse and DateTime meet.
const _numbers = [
  '0',
  '7',
  '1794702917695',
  '8640000000000000',
  '8640000000000001',
  '-8640000000000001',
  '99999999999999999',
  '9223372036854775807',
  '9223372036854775808',
  '-9223372036854775808',
  ' 5 ',
  '+5',
  '0x10',
  '1e3',
  '5.0',
  '',
  'soon',
];

/// A push's data as the API sends each type: strings only, then changed as anyone may.
Map<String, dynamic> _pushOf(Random rng) {
  final type = rng.pick(_pushTypes);
  final ids = [for (var n = 0; n < 5; n++) rng.uuid()];
  final data = <String, dynamic>{
    'type': type,
    ...switch (type) {
      'message' => {
        'message_id': ids[0],
        'author_id': ids[1],
        'author_name': text(rng, 12),
        'author_avatar': rng.chance() ? '' : ids[2],
        'place': text(rng, 20),
        'text': text(rng, rng.pick([20, 2100])),
        'sent_at': '${1794702917695 + rng.nextInt(1000)}',
        if (rng.chance(0.8)) ...{'space_id': ids[3], 'room_id': ids[4]} else 'conversation_id': ids[3],
      },
      'encrypted_message' => {
        'message_id': ids[0],
        'author_id': ids[1],
        'author_name': text(rng, 12),
        'author_avatar': '',
        'place': text(rng, 20),
        'sent_at': '1794702917695',
        'conversation_id': ids[2],
        'seq': '${rng.nextInt(1000)}',
        if (rng.chance(0.8)) 'entry': jsonEncode(_mlsEventOf(rng, 'MLS_COMMIT')['entry']),
      },
      'call' => {
        'conversation_id': ids[0],
        'initiator_id': ids[1],
        'initiator_name': text(rng, 12),
        'initiator_avatar': '',
        'place': text(rng, 20),
        'started_at': '1794702917695',
        'ring_until': '1794702947695',
      },
      'call_end' => {'conversation_id': ids[0], 'started_at': '1794702917695'},
      _ => const <String, dynamic>{},
    },
  };
  for (var n = rng.nextInt(4); n > 0; n--) {
    final keys = data.keys.toList();
    final key = rng.chance(0.9) && keys.isNotEmpty ? rng.pick(keys) : rng.pick(['type', 'seq', 'entry', 'x']);
    switch (rng.nextInt(6)) {
      case 0:
        data.remove(key);
      case 1:
        data[key] = rng.pick(_numbers);
      case 2:
        data[key] = json(rng, 1);
      case 3:
        data[key] = text(rng, rng.pick([8, 300]));
      case 4:
        if (data[key] case final String value) data[key] = mutateText(rng, value);
      default:
        data[key] = rng.pick([..._pushTypes, 'MESSAGE', '']);
    }
  }
  return data;
}

String? _field(Map<String, dynamic> data, String key) => data[key] is String ? data[key] as String : null;

// ---------------------------------------------------------------------------------------------------------------
// The inbox's routing.

/// A core of its own for the inbox's routing: each receive_direct gets an outcome picked, every refusal the inbox reads
/// among them, and what it got is kept; it observes whatever it's given.
class _RoutingCore implements CoreHost {
  _RoutingCore(this.rng, {this.takesAll = false});
  final Random rng;

  /// Whether it takes every message, as a core that knows them all.
  final bool takesAll;
  final directs = <String>[];

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    if (command['cmd'] == 'observe_user') return <String, Object?>{} as T;
    expect(command['cmd'], 'receive_direct');
    directs.add(command['message']! as String);
    return switch (takesAll ? 11 : rng.nextInt(12)) {
      0 => throw CoreError(rng.pick(['internal', 'storage', 'locked'])),
      1 => throw CoreError('not_found', what: 'code'),
      2 => throw CoreError('bad_command', field: 'history_key'),
      3 => throw CoreError('needs_identities', users: [rng.uuid()]),
      4 => throw CoreError('rule_violation', rule: 'removed_device_listed'),
      5 => throw CoreError('decrypt_failed'),
      6 => throw CoreError('bad_command', field: 'message'),
      7 => throw StateError('the core went'),
      _ =>
        <String, Object?>{
              'type': rng.pick(['rotation.transfer', 'catch_up.key', 'other']),
            }
            as T,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// An inbox message's text as another device, or the server, may send it: an approval frame, whole or not, or else.
String _inboxText(Random rng) => switch (rng.nextInt(5)) {
  0 || 1 => _frameOf(rng).$1,
  2 => base64(rng.bytes(rng.size(200))),
  3 => base64As(rng, rng.bytes(rng.size(64))),
  _ => text(rng, 40),
};

/// A server's inbox for the routing's fuzzer: its messages in order, each from the user or another, and what the API
/// answers of them, of identities, and of clearing them.
class _Inbox {
  _Inbox(this.rng, this.user) {
    for (var n = lies ? 100 + rng.nextInt(150) : rng.nextInt(250); n > 0; n--) {
      messages.add({
        'id': '0193a4b2-0000-7000-8000-${(messages.length + 1).toString().padLeft(12, '0')}',
        'from_user_id': rng.chance(0.6) ? user : rng.pick(others),
        'from_device_id': rng.pick(devices),
        'message': _inboxText(rng),
        'created_at': '2026-11-26T10:00:00Z',
      });
    }
  }

  final Random rng;
  final String user;

  /// A server that lies: each page the first of its messages, whatever the read is after, and nothing cleared; a full
  /// page each time, every message of which the core takes, so only the round's own end ends it.
  late final lies = rng.chance(0.1);
  late final others = [for (var n = 0; n < 3; n++) rng.uuid()];
  late final devices = [for (var n = 0; n < 4; n++) rng.uuid()];
  final messages = <Map<String, Object?>>[];
  final pages = <List<String>>[];
  final cleared = <String>[];

  late final client = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/devices/@me/inbox')) {
      if (request.method == 'DELETE') {
        final through = request.url.queryParameters['through']!;
        cleared.add(through);
        if (!lies) messages.removeWhere((m) => (m['id']! as String).compareTo(through) <= 0);
        return http.Response('', 204);
      }
      // One that lies gives up past its third page, as the round would otherwise never end, and the fuzzer with it.
      if (lies && pages.length >= 3) return http.Response('{"error":"enough"}', 500, headers: _json);
      final after = lies ? null : request.url.queryParameters['after'];
      final page = [
        for (final m in messages)
          if (after == null || (m['id']! as String).compareTo(after) > 0) m,
      ].take(100).toList();
      pages.add([for (final m in page) m['id']! as String]);
      return http.Response(jsonEncode(page), 200, headers: _json);
    }
    if (path.endsWith('/identity')) {
      // The user's served identity, or a refusal: the certificates name the user's devices, at times not.
      return switch (lies ? 4 : rng.nextInt(5)) {
        0 => http.Response('{"error":"not found"}', 404),
        1 => http.Response('{"error":"down"}', 500),
        _ => http.Response(
          jsonEncode({
            'user_id': path.split('/')[3],
            'identity_key': base64(rng.bytes(32)),
            'device_list': base64(rng.bytes(40)),
            'device_list_version': 1,
            'certificates': [
              for (final device in devices)
                rng.chance(0.7) ? base64(_signed({'device': _uuidBytes(device)})) : base64As(rng, rng.bytes(30)),
            ],
            'active': true,
            'changed_at': '2026-11-26T10:00:00Z',
          }),
          200,
          headers: _json,
        ),
      };
    }
    if (path.endsWith('/users/identities')) return http.Response('[]', 200);
    return http.Response('{"error":"no such route"}', 404);
  });
}

/// What the API answers in, as its JSON's text is UTF-8.
const _json = {'content-type': 'application/json; charset=utf-8'};

Uint8List _uuidBytes(String id) => Uint8List.fromList([
  for (var at = 0; at < 32; at += 2) int.parse(id.replaceAll('-', '').substring(at, at + 2), radix: 16),
]);

// ---------------------------------------------------------------------------------------------------------------

void main() {
  test('an approval frame in the inbox', () {
    final rng = Random(seed + 1);
    final picked = _pickedFrames();
    for (var n = 0; n < picked.length + runs(4000); n++) {
      final (message, made) = n < picked.length ? (picked[n], null) : _frameOf(rng);
      final frame = timed(() => readApprovalFrame(message), () => message);
      // A frame written whole is read as it was written.
      if (made != null) expect(frame, made, reason: shown(message));
      if (frame == null) continue;
      // Its message and its data are base64 in its one form, the data not empty; its name, kept, shows whole.
      expect(canonical(message), isTrue, reason: shown(message));
      expect(frame.data.isNotEmpty && canonical(frame.data), isTrue, reason: shown(message));
      if (frame.name case final name?) {
        expect(_hidden.hasMatch(name) || !isWellFormed(name) || name != name.trim(), isFalse, reason: shown(message));
        expect(name.runes.length, inInclusiveRange(1, maxDeviceName), reason: shown(message));
        expect(_likeFingerprint.hasMatch(name) || _likeCode.hasMatch(name), isFalse, reason: shown(message));
      }
      // A frame it reads writes back to the same frame.
      expect(readApprovalFrame(approvalFrameMessage(frame)), frame, reason: shown(message));
    }
  }, timeout: _timeout);

  test("a file's name", () {
    final rng = Random(seed + 2);
    final picked = [
      ...['invoice\u{db40}\u{200b}\u{dc01}.pdf', 'a\u{d800}b', '\u{dc00}', 'Ana\u{85}', '\u{85}file', 'x\u{180e}y'],
      ...['\u{e0001}a\u{e0020}\u{e007f}b', '\u{200d}', 'a\u{200d}b', '\u{feff}name', '\u{fffe}\u{10ffff}', ' . '],
      ...['...', 'a/..', '..\\', 'x' * maxFileName, 'x' * (maxFileName + 1), '\u{1f600}' * (maxFileName + 1)],
      ...[' ${'x' * (maxFileName - 1)} y', 'a\u{a0}', '\u{3000}a\u{3000}', '\u{2028}', 'a\\b/c', '/', ''],
      // What would take a reader long: a long name, of hidden characters and joiners above all.
      '\u{200b}\u{200d}' * 200000,
      '${'/' * 100000}x',
      '\u{d800}' * 200000,
    ];
    for (var n = 0; n < picked.length + runs(4000); n++) {
      final name = n < picked.length
          ? picked[n]
          : (rng.chance(0.3) ? mutateText(rng, text(rng, 300)) : text(rng, rng.pick([8, 60, 300])));
      final clean = timed(() => cleanName(name), () => name);
      // No separator, no hidden character, well formed and trimmed, 1 to 255 code points, never "", "." or "..".
      expect(
        clean.contains(RegExp(r'[/\\]')) || _hidden.hasMatch(clean) || !isWellFormed(clean) || clean != clean.trim(),
        isFalse,
        reason: shown(name),
      );
      expect(clean.runes.length, inInclusiveRange(1, maxFileName), reason: shown(name));
      expect(const ['', '.', '..'], isNot(contains(clean)), reason: shown(name));
      // Cleaned once is clean.
      expect(cleanName(clean), clean, reason: shown(name));
    }
  }, timeout: _timeout);

  test("a file's type, by its bytes", () {
    final rng = Random(seed + 3);
    final header = _webmHeader('webm');
    // A segment whose size is a byte of all ones, which is 127 bytes, not the end: tracks past them aren't read.
    Uint8List short(Uint8List tracks, int before) => concat([
      header,
      [0x18, 0x53, 0x80, 0x67, 0xff],
      if (before > 0) _ebml(0xec, Uint8List(before)),
      tracks,
    ]);
    final picked = <(Uint8List, String?)>[
      (
        concat([
          header,
          _ebml(0x18538067, _tracksOf([2])),
        ]),
        'audio/webm',
      ),
      (
        concat([
          header,
          _ebml(0x18538067, _tracksOf([1, 2])),
        ]),
        'video/webm',
      ),
      (
        concat([
          header,
          _ebml(0x18538067, _tracksOf([17])),
        ]),
        _octet,
      ),
      (
        concat([
          _webmHeader('matroska'),
          _ebml(0x18538067, _tracksOf([1])),
        ]),
        _octet,
      ),
      (short(_tracksOf([2]), 0), 'audio/webm'),
      (short(_tracksOf([2]), 130), _octet),
      (header, _octet),
      // A segment and tracks whose sizes say all of 2^56, and elements whose IDs are 8 bytes: Dart holds them exactly.
      (
        concat([
          header,
          [0x18, 0x53, 0x80, 0x67, 0x01, ...List.filled(7, 0xff)],
          _tracksOf([2]),
        ]),
        'audio/webm',
      ),
      (
        concat([
          header,
          [0x18, 0x53, 0x80, 0x67, 0x01, ...List.filled(7, 0xff), 0x01, ...List.filled(7, 0xff)],
        ]),
        null,
      ),
      // A file past what both apps read, whose type is only in its first 64 KiB.
      (concat([ascii.encode('OggS'), Uint8List(sniffPrefix)]), 'audio/ogg'),
      (concat([Uint8List(sniffPrefix), ascii.encode('OggS')]), _octet),
      (Uint8List(8 << 20), _octet),
    ];
    for (var n = 0; n < picked.length + runs(4000); n++) {
      Uint8List bytes;
      String? expected;
      if (n < picked.length) {
        (bytes, expected) = picked[n];
      } else {
        switch (rng.nextInt(5)) {
          case 0:
            (bytes, expected) = _webm(rng);
          case 1:
            bytes = mutate(rng, _webm(rng).$1);
          case 2:
            bytes = mutate(rng, concat([rng.pick(_magics), rng.bytes(rng.nextInt(64))]));
          case 3:
            bytes = concat([rng.pick(_magics), rng.bytes(rng.nextInt(32))]);
          default:
            bytes = rng.bytes(rng.size(64));
        }
      }
      final type = timed(() => sniffType(bytes), () => bytes);
      expect(_types, contains(type), reason: shown(bytes));
      if (expected != null) expect(type, expected, reason: shown(bytes));
      // Only the first 64 KiB decide: what comes past them changes nothing. (Zeros put after a shorter file are bytes
      // of its first 64 KiB, which may: a WebM cut inside a track entry reads as its tracks, and as a file with a zero
      // byte, no element, after it.)
      if (bytes.length > sniffPrefix) {
        expect(sniffType(Uint8List.sublistView(bytes, 0, sniffPrefix)), type);
      } else if (rng.chance(0.1)) {
        final whole = concat([bytes, Uint8List(sniffPrefix - bytes.length)]);
        expect(sniffType(concat([whole, rng.bytes(64)])), sniffType(whole), reason: shown(bytes));
      }
    }
  }, timeout: _timeout);

  test('whether a thumbnail is drawn, by its header', () {
    final rng = Random(seed + 4);
    const app = [0xff, 0xe0, 0, 4, 0, 0];
    final picked = <(Uint8List, bool?)>[
      (_png(thumbnailSide, thumbnailSide), true),
      (_png(thumbnailSide + 1, 1), false),
      (_png(0, 10), false),
      (_png(0xffffffff, 1), false),
      (Uint8List.sublistView(_png(10, 10), 0, 23), false),
      (_jpeg(thumbnailSide, 240), true),
      (_jpeg(12000, 12000), false),
      (_jpeg(320, 240, [0xff, 0xff, 0xd0, ...app]), true),
      (_jpeg(320, 0), false),
      (Uint8List.sublistView(_jpeg(320, 240), 0, 10), false),
      (Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xff]), false),
      (Uint8List.fromList([0xff, 0xd8, 0xff, 0xda, 0, 2]), false),
      (_jpeg(64, 64, [], 0xc4), false),
      // Fill bytes all the way: a reader that takes each in turn ends with them.
      (
        concat([
          [0xff, 0xd8],
          List.filled(1 << 20, 0xff),
        ]),
        false,
      ),
      // Segments whose lengths say past the end.
      (
        concat([
          [0xff, 0xd8, 0xff, 0xe0, 0xff, 0xff],
          Uint8List(100),
        ]),
        false,
      ),
    ];
    for (var n = 0; n < picked.length + runs(4000); n++) {
      Uint8List bytes;
      bool? expected;
      if (n < picked.length) {
        (bytes, expected) = picked[n];
      } else {
        switch (rng.nextInt(4)) {
          case 0:
            final (width, height) = (_sideOf(rng, 0xffffffff), _sideOf(rng, 0xffffffff));
            (bytes, expected) = (_png(width, height, rng.bytes(rng.nextInt(20))), _drawnAt(width, height));
          case 1:
            final (made, width, height) = _jpegOf(rng);
            (bytes, expected) = (made, _drawnAt(width, height));
          case 2:
            bytes = mutate(rng, rng.chance() ? _png(_sideOf(rng, 400), _sideOf(rng, 400)) : _jpegOf(rng).$1);
          default:
            bytes = concat([rng.pick(_magics), rng.bytes(rng.size(64))]);
        }
      }
      final drawn = timed(() => thumbnailDrawn(bytes), () => bytes);
      if (expected != null) expect(drawn, expected, reason: shown(bytes));
      // Only a JPEG's or a PNG's header draws one.
      if (drawn) expect(const ['image/jpeg', 'image/png'], contains(sniffType(bytes)));
    }
  }, timeout: _timeout);

  test('what a message the core shows is drawn as', () {
    final rng = Random(seed + 5);
    Map<String, Object?> file() => {
      if (rng.chance(0.9)) 'type': rng.chance(0.7) ? rng.pick(['audio/ogg', 'audio/webm', 'audio']) : json(rng, 1),
      if (rng.chance(0.8)) 'duration_ms': rng.chance(0.8) ? rng.pick(<Object?>[0, 1500, -1, 1.5]) : json(rng, 1),
      if (rng.chance(0.8))
        'waveform': rng.chance(0.85)
            ? base64As(rng, rng.bytes(rng.pick([waveformSamples, waveformSamples, waveformSamples - 1, 0, 65])))
            : json(rng, 1),
      if (rng.chance(0.2)) json(rng, 0).toString(): json(rng, 1),
    };
    for (var n = 0; n < runs(4000); n++) {
      final text = rng.pick<String?>([null, '', 'hi', ' ']);
      final attachments = [
        for (var count = rng.pick([0, 1, 1, 1, 2]); count > 0; count--) file(),
      ];
      final sticker = rng.chance();
      final drawn = timed(
        () => drawnAs(text: text, attachments: attachments, sticker: sticker),
        () => {'text': text, 'attachments': attachments},
      );
      // The convention's own reading: a voice note only of no text, one audio file, a numeric duration and its 64
      // samples in base64's one form; the sticker or nothing only without text or file.
      final empty = text == null || text.isEmpty;
      final one = attachments.length == 1 ? attachments.single : null;
      final waveform = one?['waveform'];
      final voice =
          empty &&
          one != null &&
          one['type'] is String &&
          (one['type']! as String).startsWith('audio/') &&
          one['duration_ms'] is num &&
          waveform is String &&
          canonical(waveform) &&
          base64Decode(waveform).length == waveformSamples;
      final expected = empty && attachments.isEmpty
          ? (sticker ? Drawn.sticker : Drawn.nothing)
          : (voice ? Drawn.voiceNote : Drawn.message);
      expect(drawn, expected, reason: shown({'text': text, 'attachments': attachments, 'sticker': sticker}));
    }
  }, timeout: _timeout);

  test('the CBOR of a certificate, a device list or a commitment', () {
    final rng = Random(seed + 6);
    final picked = _pickedCbor();
    final pool = [for (final object in _pickedSigned()) ?canonicalBytes(object)];
    const unwritten = [0x1c, 0x1f, 0x3f, 0x5f, 0x7f, 0x9f, 0xbf, 0xc0, 0xd8, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xff, 0xe0];
    const kinds = ['value', 'value', 'mutated', 'seed', 'lying', 'deep', 'unwritten', 'bytes'];
    for (var n = 0; n < picked.length + runs(4000); n++) {
      final how = n < picked.length ? 'picked' : rng.pick(kinds);
      late Uint8List bytes;
      Object? value;
      var hasValue = false;
      bool? read;
      switch (how) {
        case 'picked':
          (bytes, read) = picked[n];
        case 'value':
          value = cborValue(rng);
          hasValue = true;
          bytes = cborBytes(value, rng);
        case 'mutated':
          bytes = mutate(rng, rng.chance() ? rng.pick(pool) : cborBytes(cborValue(rng)), pool);
        case 'seed':
          bytes = rng.pick(pool);
        case 'lying':
          // Bytes, a text, a list or a map of a length of 4 or 8 bytes, past 2^63 at times, and little after it.
          final wide = rng.chance();
          final length = wide
              ? [
                  rng.pick([0xff, 0x7f, 0x80, rng.nextInt(256)]),
                  ...rng.bytes(7),
                ]
              : rng.bytes(4).toList();
          bytes = concat([
            [
              rng.pick([0x40, 0x60, 0x80, 0xa0]) | (wide ? 27 : 26),
            ],
            length,
            rng.bytes(rng.nextInt(16)),
          ]);
        case 'deep':
          // Lists or maps in each other, at times past the reader's 33 levels.
          final levels = 28 + rng.nextInt(10);
          bytes = _deep(levels, rng.chance);
          read = levels <= 33;
        case 'unwritten':
          bytes = concat([
            [rng.pick(unwritten)],
            rng.bytes(rng.nextInt(9)),
          ]);
          read = false;
        default:
          bytes = rng.bytes(rng.size(64));
      }
      final result = timed(() => cbor(bytes), () => Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, 300)));
      if (read != null) expect(result != null, read, reason: shown(bytes));
      if (hasValue) expect(result, value, reason: shown(bytes));
      if (result == null) continue;
      // Lists and maps 33 deep at most, and no length past what its bytes hold.
      expect(cborDepth(result), lessThanOrEqualTo(33));
      expect(cborLengths(result).fold(0, max), lessThanOrEqualTo(bytes.length), reason: shown(bytes));
      // Read again from its own CBOR, it's the same value.
      expect(cbor(cborBytes(result)), result, reason: shown(bytes));
    }
  }, timeout: _timeout);

  test('which device a certificate, a commitment or a QR names, and which devices a list names', () {
    final rng = Random(seed + 7);
    final picked = _pickedSigned();
    final pool = [for (final object in picked) ?canonicalBytes(object)];
    (String, Uint8List) made() {
      final devices = [for (var n = rng.nextInt(21); n > 0; n--) rng.chance(0.95) ? rng.bytes(16) : cborValue(rng, 1)];
      switch (rng.nextInt(3)) {
        case 0:
          final device = rng.chance(0.9) ? rng.bytes(16) : cborValue(rng, 1);
          return ('certificate', _signed(<String, Object?>{'user': rng.bytes(16), 'device': device}));
        case 1:
          final body = <String, Object?>{'devices': devices};
          if (rng.chance(0.8)) body['version'] = rng.chance(0.9) ? rng.nextInt(1000) : cborValue(rng, 1);
          return ('list', _signed(body));
        default:
          return ('commitment', cborBytes(<String, Object?>{'v': 1, 'device': rng.bytes(16)}));
      }
    }

    for (var n = 0; n < picked.length + runs(4000); n++) {
      String given;
      if (n < picked.length) {
        given = picked[n];
      } else {
        final bytes = rng.chance(0.6) ? made().$2 : mutate(rng, rng.pick(pool), pool);
        given = rng.chance(0.8) ? base64(bytes) : base64As(rng, bytes);
      }
      final (device, list, committed, scanned) = timed(
        () => (certificateDevice(given), deviceListOf(given), commitmentDevice(given), qrDevice(given)),
        () => given,
      );
      for (final id in [?device, ?committed, ?scanned, ...?list?.devices]) {
        expect(id, matches(_uuid), reason: given);
      }
      // A list names its devices only with its version, a whole number.
      expect(listDevices(given), list?.devices);
      // Read only of base64 as the API and the core write it, which both apps decode alike.
      if (device != null || list != null || committed != null || scanned != null) {
        expect(canonical(given), isTrue, reason: given);
      }
    }
  }, timeout: _timeout);

  test('a file of a message, as its sender wrote it', () {
    final rng = Random(seed + 8);
    Map<String, Object?> ref() => {
      'id': rng.uuid(),
      'key': base64(rng.bytes(32)),
      'sha256': base64(rng.bytes(32)),
      'size': rng.nextInt(1000000),
    };
    Map<String, Object?> raw() => {
      ...ref(),
      'name': text(rng, 60),
      'type': rng.pick<Object?>(['image/png', 'audio/ogg', text(rng, 10)]),
      'size': rng.pick([0, 1, 1024, 1 << 31, _safe, (1 << 63) - 1]),
      if (rng.chance()) ...{
        'width': rng.pick([1, 320, 65535, 65536, 0]),
        'height': rng.pick([1, 240, 65535, 65536]),
      },
      if (rng.chance(0.3)) 'duration_ms': rng.pick([0, 1500, 86400000, 86400001]),
      if (rng.chance(0.3)) 'waveform': base64As(rng, rng.bytes(rng.pick([64, 64, 63, 65, 0]))),
      if (rng.chance(0.3)) 'thumbnail': base64As(rng, rng.bytes(rng.pick([0, 100, 8192, 8193]))),
      if (rng.chance(0.3)) 'thumbnail_ref': rng.chance(0.8) ? ref() : json(rng, 1),
    };
    const fields = ['id', 'key', 'sha256', 'name', 'type', 'size', 'width', 'height', 'duration_ms', 'waveform'];
    for (var n = 0; n < runs(3000); n++) {
      final Object? file = rng.chance(0.05) ? json(rng) : raw();
      if (file is Map<String, Object?> && rng.chance()) {
        for (final key in [...fields, 'thumbnail']) {
          final roll = rng.nextInt(100);
          if (roll < 8) {
            file.remove(key);
          } else if (roll < 16) {
            file[key] = json(rng, 1);
          }
        }
      }
      final got = timed(() => shownFile(file), () => file);
      final at = file is Map ? file : const <String, Object?>{};
      final (id, key, sha256, size) = (at['id'], at['key'], at['sha256'], at['size']);
      final reads =
          file is Map &&
          id is String &&
          _uuid.hasMatch(id) &&
          key is String &&
          sha256 is String &&
          size is int &&
          size >= 0;
      expect(got != null, reads, reason: shown(file));
      if (got == null) continue;
      // Each field is the sender's own, or none: never one the file didn't carry.
      expect((got.id, got.key, got.sha256, got.size), (id, key, sha256, size));
      expect(got.name, cleanName(at['name'] is String ? at['name']! as String : ''));
      expect(got.said, at['type'] is String ? at['type'] : _octet);
      expect(got.width == null, got.height == null);
      if (got.width != null) {
        expect((got.width, got.height), (at['width'], at['height']));
        expect([got.width!, got.height!].every((side) => side >= 1 && side <= 65535), isTrue);
      }
      if (got.durationMs != null) {
        expect(got.durationMs, at['duration_ms']);
        expect(got.durationMs, inInclusiveRange(0, 86400000));
      }
      if (got.waveform case final waveform?) {
        expect(waveform, at['waveform']);
        expect(canonical(waveform) && base64Decode(waveform).length == waveformSamples, isTrue, reason: waveform);
      }
      if (got.thumbnail case final thumbnail?) {
        expect(thumbnail, at['thumbnail']);
        expect(canonical(thumbnail) && base64Decode(thumbnail).length <= 8 << 10, isTrue, reason: thumbnail);
      }
      // A thumbnail of its own only where none is inside, an empty one too, and of 512 KiB at most (mobile#356): one
      // that reads as one within it, where none is inside, is kept as it came.
      final theirs = at['thumbnail_ref'];
      final refReads =
          theirs is Map &&
          theirs['id'] is String &&
          _uuid.hasMatch(theirs['id']! as String) &&
          theirs['key'] is String &&
          theirs['sha256'] is String &&
          theirs['size'] is int &&
          (theirs['size']! as int) >= 0 &&
          (theirs['size']! as int) <= maxThumbnailFile;
      expect(got.thumbnailRef != null, got.thumbnail == null && refReads, reason: shown(file));
      if ((got.thumbnailRef, theirs) case (final ref?, final Map theirs)) {
        expect(
          (ref.id, ref.key, ref.sha256, ref.size),
          (theirs['id'], theirs['key'], theirs['sha256'], theirs['size']),
        );
      }
    }
  }, timeout: _timeout);

  test("an event's entry, and a message's", () {
    final rng = Random(seed + 9);
    const events = [
      'DM_MESSAGE_CREATE',
      'MLS_COMMIT',
      'MLS_WELCOME',
      'MLS_PROPOSAL',
      'DM_MESSAGE_UPDATE',
      'DM_MESSAGE_DELETE',
    ];
    const messageKeys = ['id', 'conversation_id', 'author_id', 'ciphertext', 'seq', 'sent_at', 'generation', 'epoch'];
    final ids = [for (var i = 0; i < 5; i++) '0193a4b2-0000-7000-8000-00000000000$i'];
    final message = {..._messageOf(rng), 'conversation_id': ids[1], 'seq': 5};
    final mls = {..._mlsEventOf(rng, 'MLS_COMMIT'), 'conversation_id': ids[1]};
    Map<String, Object?> event(String type, Map<String, Object?> data) => {'type': type, 'data': data};
    final picked = [
      event('DM_MESSAGE_CREATE', message),
      for (final number in [-1, 1 << 53, _safe, (1 << 63) - 1])
        for (final field in ['seq', 'generation', 'epoch', 'sent_at'])
          event('DM_MESSAGE_CREATE', {...message, field: number}),
      event('DM_MESSAGE_CREATE', {...message}..remove('sent_at')),
      event('DM_MESSAGE_CREATE', {...message, 'conversation_id': ''}),
      event('DM_MESSAGE_CREATE', {...message, 'mentions': <Object?>[]}),
      event('MLS_COMMIT', mls),
      event('MLS_COMMIT', {...mls, 'conversation_id': ''}),
      event('MLS_COMMIT', {...mls, 'generation': -1}),
      event('MLS_COMMIT', {...mls, 'generation': 1 << 53}),
      event('MLS_COMMIT', {
        ...mls,
        'entry': {...mls['entry']! as Map, 'seq': -1},
      }),
      event('MLS_COMMIT', {
        ...mls,
        'entry': {...mls['entry']! as Map, 'seq': 1 << 53},
      }),
      event('DM_MESSAGE_UPDATE', {'id': ids[0], 'conversation_id': '', 'edited_at': _when, 'entry': mls['entry']}),
      event('DM_MESSAGE_DELETE', {
        'id': ids[0],
        'conversation_id': ids[1],
        'entry': {...mls['entry']! as Map, 'seq': -1},
      }),
    ];
    for (var n = 0; n < picked.length + runs(4000); n++) {
      final Map<String, Object?> given;
      if (n < picked.length) {
        given = picked[n];
      } else {
        final type = rng.chance(0.05) ? rng.pick(['DEVICE_ADD', 'READY', 'KEY_PACKAGES_LOW']) : rng.pick(events);
        Object? data = type == 'DM_MESSAGE_CREATE' ? _messageOf(rng) : _mlsEventOf(rng, type);
        // What the server may send instead: a field gone, or of another kind; or data that isn't an object.
        if (rng.chance(0.05)) {
          data = json(rng, 1);
        } else if (data is Map<String, Object?> && rng.chance(0.6)) {
          final entry = data['entry'];
          final inEntry = type != 'DM_MESSAGE_CREATE' && rng.chance() && entry is Map<String, Object?>;
          final target = inEntry ? entry : data;
          final keys = inEntry
              ? const ['seq', 'kind', 'sent_at', 'generation', 'epoch', 'mentions', 'deleted', 'data']
              : [...messageKeys, 'sender_device_id', 'entry', 'mentions', 'referenced_message'];
          final key = rng.pick(keys);
          if (rng.chance(0.4)) {
            target.remove(key);
          } else {
            target[key] = _edgeOf(rng);
          }
        }
        given = {'type': type, 'data': data};
      }
      final payload = _payloadOf(given);
      final carried = payload == null ? null : timed(() => carriedEntry(payload), () => given);
      final (type, data) = (given['type'], given['data']);
      if (carried == null || data is! Map<String, Object?>) {
        expect(carried, isNull);
        continue;
      }
      final d = data;
      if (type == 'DM_MESSAGE_CREATE') {
        // A message reads as an entry only with its conversation, its numbers and its time, as the API sends them.
        expect(d['conversation_id'], isNot(''));
        expect([d['seq'], d['generation'], d['epoch']].every(_count), isTrue, reason: shown(given));
        expect((d['sent_at']! as int).abs(), lessThanOrEqualTo(_safe));
        // Its number, kind, sender, device and message ID are the message's own, and nothing it didn't carry.
        final reply = d['referenced_message'] is Map ? (d['referenced_message']! as Map)['message_id'] : null;
        final mentions = d['mentions'];
        expect(carried.conversation, d['conversation_id']);
        expect(carried.generation, isNull);
        expect(carried.entry, {
          'seq': d['seq'],
          'kind': 'message',
          'data': d['ciphertext'],
          'sent_at': d['sent_at'],
          'message_id': d['id'],
          'sender_user': d['author_id'],
          'sender_device': ?d['sender_device_id'],
          if (mentions is List && mentions.isNotEmpty) 'mentions': mentions,
          'reply_to': ?reply,
        }, reason: shown(given));
      } else if (events.contains(type)) {
        final entry = d['entry']! as Map<String, Object?>;
        final mls = (type! as String).startsWith('MLS_');
        expect(d['conversation_id'], isNot(''));
        expect(_count(entry['seq']), isTrue, reason: shown(given));
        if (mls) expect(_count(d['generation']), isTrue, reason: shown(given));
        // The event's own entry, of its own conversation, and its generation where it gives one.
        expect(carried.conversation, d['conversation_id']);
        expect(carried.generation, mls ? d['generation'] : null);
        expect(carried.entry, _ownFields(entry), reason: shown(given));
      } else {
        fail('${shown(given)} carried an entry');
      }
    }
  }, timeout: _timeout);

  test("a push's data, as FCM hands it over", () {
    final rng = Random(seed + 10);
    final picked = <Map<String, dynamic>>[
      for (final field in ['sent_at', 'started_at', 'ring_until', 'seq'])
        for (final number in _numbers)
          for (final type in _pushTypes)
            {..._pushOf(Random(field.length + number.length)), 'type': type, field: number},
      {'type': 'encrypted_message', 'entry': '[' * 4000},
      {'type': 'encrypted_message', 'entry': '{"seq":${'1' * 4000}}'},
    ];
    for (var n = 0; n < picked.length + runs(4000); n++) {
      final data = n < picked.length ? picked[n] : _pushOf(rng);
      final push = timed(() => Push.fromData(data), () => data);
      // A number as the API writes it: decimal digits alone.
      int? millis(String key) => switch (_field(data, key)) {
        final String digits when RegExp(r'^[0-9]+$').hasMatch(digits) => int.tryParse(digits),
        _ => null,
      };
      bool aTime(int? ms) => ms != null && ms.abs() <= 8640000000000000;
      switch (push) {
        case null:
          continue;
        case MessagePush():
          // Its IDs and time are the data's own; a room's, as the API words it, with its text.
          expect(data['type'], 'message');
          expect(isDuvetId(push.messageId) && push.messageId == data['message_id'], isTrue);
          expect(push.authorId, data['author_id']);
          expect(aTime(millis('sent_at')), isTrue, reason: shown(data));
          expect(push.sentAt.millisecondsSinceEpoch, millis('sent_at'));
          expect(push.target, isA<RoomTarget>(), reason: "a conversation's message of this type is no push");
          expect(push.text, _field(data, 'text') ?? '');
          // Its data again reads as the same push.
          expect(Push.fromData(push.toData()), isA<MessagePush>().having((p) => p.toData(), 'data', push.toData()));
          final kept = MessagePush.kept({...push.toData(), 'conversation_id': data['message_id']})!;
          expect(kept.target, isA<ConversationTarget>());
          expect(kept.text, '');
        case EncryptedMessagePush():
          expect(data['type'], 'encrypted_message');
          expect(isDuvetId(push.messageId) && isDuvetId(push.conversationId), isTrue);
          expect(
            (push.messageId, push.conversationId, push.authorId),
            (data['message_id'], data['conversation_id'], data['author_id']),
          );
          expect(push.seq, millis('seq'));
          expect(aTime(millis('sent_at')), isTrue, reason: shown(data));
          expect(push.sentAt.millisecondsSinceEpoch, millis('sent_at'));
          // Its entry is the JSON object it carried, or none.
          final carried = _field(data, 'entry');
          Object? decoded;
          try {
            decoded = carried == null ? null : jsonDecode(carried);
          } on FormatException {
            decoded = null;
          }
          expect(push.entry, decoded is Map ? decoded : null);
          // What it shows is the device's text, never the server's.
          final shownText = push.shown({push.messageId: text(rng, 3000)});
          expect(shownText.text.runes.length, lessThanOrEqualTo(2000));
        case CallPush():
          expect(data['type'], 'call');
          expect(isDuvetId(push.conversationId) && isDuvetId(push.initiatorId), isTrue);
          expect([millis('started_at'), millis('ring_until')].every(aTime), isTrue, reason: shown(data));
          expect(push.startedAt.millisecondsSinceEpoch, millis('started_at'));
          expect(push.ringUntil.millisecondsSinceEpoch, millis('ring_until'));
        case CallEndPush():
          expect(data['type'], 'call_end');
          expect(isDuvetId(push.conversationId), isTrue);
          expect(push.startedAt, millis('started_at') ?? 0);
        case SignedOutPush():
          expect(data['type'], 'signed_out');
      }
    }
  }, timeout: _timeout);

  test("a conversation's text, as its notification words it", () {
    final rng = Random(seed + 11);
    final picked = [
      '||' * 100000,
      '||x' * 50000,
      '<@${'a' * 200000}>',
      '\n' * 100000,
      '<:0193a4b2-0000-7000-8000-000000000000:>' * 5000,
      '',
    ];
    for (var n = 0; n < picked.length + runs(4000); n++) {
      final given = n < picked.length
          ? picked[n]
          : rng.chance(0.5)
          ? mutateText(rng, '${text(rng, 40)} <@${rng.uuid()}> ||${text(rng, 20)}|| <#${rng.uuid()}> <:${rng.uuid()}:>')
          : text(rng, rng.pick([40, 2500]));
      final worded = timed(() => pushText(given), () => given);
      if (worded == null) continue;
      expect(worded, isNotEmpty);
      expect(worded.runes.length, lessThanOrEqualTo(2000));
      expect(worded, worded.trim());
    }
  }, timeout: _timeout);

  test("a push's entry, as the core takes it", () {
    final rng = Random(seed + 12);
    for (var n = 0; n < runs(4000); n++) {
      final entry = {...(_mlsEventOf(rng, 'MLS_COMMIT')['entry']! as Map<String, Object?>)};
      if (rng.chance(0.7)) entry['kind'] = 'message';
      final seq = rng.chance(0.8) ? entry['seq']! as int : rng.nextInt(1000);
      final message = rng.chance(0.8) ? entry['message_id']! as String : rng.uuid();
      for (var changes = rng.nextInt(3); changes > 0; changes--) {
        final key = rng.pick(['seq', 'kind', 'data', 'sent_at', 'generation', 'epoch', 'message_id', 'mentions']);
        if (rng.chance(0.4)) {
          entry.remove(key);
        } else {
          entry[key] = _edgeOf(rng);
        }
      }
      // As the push carries it: the queue's JSON in a string, at times not JSON, its number a string too.
      final carried = rng.chance(0.1) ? mutateText(rng, jsonEncode(entry)) : jsonEncode(entry);
      final push = Push.fromData({
        'type': 'encrypted_message',
        'message_id': message,
        'author_id': rng.uuid(),
        'conversation_id': rng.uuid(),
        'sent_at': '1794702917695',
        'seq': rng.chance(0.95) ? '$seq' : rng.pick(_numbers),
        'entry': carried,
      });
      if (push is! EncryptedMessagePush) continue;
      final taken = timed(() => pushedEntry(push.entry, push.seq, push.messageId), () => carried);
      if (taken == null) continue;
      // Only its own message's entry, with the push's number, each field its own.
      expect((taken['kind'], taken['seq'], taken['message_id']), ('message', push.seq, push.messageId));
      expect(taken, _ownFields(push.entry!), reason: carried);
    }
  }, timeout: _timeout);

  test("the inbox's routing: an approval frame to its flow, anything else to the core", () async {
    final rng = Random(seed + 13);
    // What waits for the next round is logged: not here, a few hundred times over.
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() => debugPrint = print);
    const user = '0193a4b2-0000-7000-8000-0000000000aa';
    var read = 0;
    for (var round = 0; read < runs(1500); round++) {
      final inbox = _Inbox(rng, user);
      final core = _RoutingCore(rng, takesAll: inbox.lies);
      final store = MemoryStore();
      final engine = E2EEngine(
        host: core,
        api: duvet.E2eApi(
          duvet.RestClient(inbox.client, router: fakeRouter, token: 'token', duvetClient: engineClient),
        ),
        events: const Stream.empty(),
        store: store,
        clock: TestClock(),
        user: user,
        deviceName: 'Pixel 8 Pro',
        registered: (_) {},
      );
      final given = [...inbox.messages];
      final watch = Stopwatch()..start();
      final rotated = await takeInbox(engine, {}, null, null, (received) async {
        if (!inbox.lies && rng.chance(0.05)) throw StateError('the record refused it');
      });
      // A round of 250 messages at most, each read in well under the budget.
      expect(watch.elapsed, lessThan(budget * 20), reason: 'round $round');
      expect(rotated, isA<bool>());
      read += inbox.pages.fold(0, (sum, page) => sum + page.length) + 1;
      // No approval frame reaches the core: what does is a message of the inbox, as it came.
      final texts = {for (final m in given) m['message']! as String};
      for (final direct in core.directs) {
        expect(readApprovalFrame(direct), isNull, reason: direct);
        expect(texts, contains(direct));
      }
      // The record keeps the user's own frames alone, each once.
      final kept = [
        for (final m in (store.read(keptApprovals) as List?) ?? const <Object?>[]) (m! as Map).cast<String, Object?>(),
      ];
      for (final m in kept) {
        expect(m['from_user_id'], user);
        expect(readApprovalFrame(m['message']! as String), isNotNull);
      }
      expect({for (final m in kept) m['id']}, hasLength(kept.length));
      // The inbox is cleared once a page at most, through a message of that page, each further on; a server that
      // sends the same page again whatever is asked ends the round at it.
      expect(inbox.cleared.length, lessThanOrEqualTo(inbox.pages.length));
      for (final (at, through) in inbox.cleared.indexed) {
        expect(inbox.pages.any((page) => page.contains(through)), isTrue);
        if (at > 0) expect(through.compareTo(inbox.cleared[at - 1]), greaterThan(0));
      }
      if (inbox.lies) expect(inbox.pages.length, lessThanOrEqualTo(2));
    }
  }, timeout: _timeout);

  test("the engine's record, as the file it reads holds it", () async {
    final rng = Random(seed + 14);
    // What doesn't read is logged as it's taken for an empty record: not here, a few hundred times over.
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    addTearDown(() => debugPrint = print);
    final folder = await Directory.systemTemp.createTemp('duvet-fuzz-record');
    addTearDown(() => folder.delete(recursive: true));
    const user = '0193a4b2-0000-7000-8000-0000000000aa';
    final file = File('${folder.path}/e2e/$user/client.json');
    await file.parent.create(recursive: true);
    final keys = [...deviceRecord, externalSender];
    for (var n = 0; n < runs(50, per: 1000); n++) {
      final record = {
        for (final key in keys)
          if (rng.chance(0.3)) key: json(rng, 2),
      };
      final whole = rng.nextInt(4) == 0;
      final bytes = whole
          ? utf8.encode(jsonEncode(record))
          : switch (rng.nextInt(3)) {
              0 => mutate(rng, utf8.encode(jsonEncode(record))),
              1 => rng.bytes(rng.size(64)),
              _ => Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode(jsonEncode(record))]),
            };
      await file.writeAsBytes(bytes);
      // It opens whatever the file holds, a file that doesn't read as an empty record, and reads each key.
      final store = await timedAsync(() => pushRecord(user, folder: () async => folder), () => bytes);
      final read = {for (final key in keys) key: store.read(key)};
      if (whole) expect(read, {for (final key in keys) key: record[key]});
      // What it writes it reads again, and the file is the JSON of a record.
      await store.write(keptDevice, rng.uuid());
      final again = await pushRecord(user, folder: () async => folder);
      expect(again.read(keptDevice), store.read(keptDevice));
      expect(jsonDecode(await file.readAsString()), isA<Map<String, Object?>>());
    }
  }, timeout: _timeout);
}
