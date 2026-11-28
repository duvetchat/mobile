// Seeded inputs for the fuzz tests (PLAN-E2E-CLIENTES.md, «Lo que el paso 5 revisa»): a PRNG of its own, and bytes,
// text, JSON, base64 and CBOR as another device or the server could write them, valid and mutated. The desktop's
// testing/fuzz.ts in Dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// How many inputs each reader takes: DUVET_FUZZ_RUNS for a long run (a [per]th of them for a reader whose input
/// costs more, as a file written and read again), else what CI runs.
int runs(int ci, {int per = 1}) => switch (int.tryParse(Platform.environment['DUVET_FUZZ_RUNS'] ?? '')) {
  final int long => long ~/ per,
  null => ci,
};

/// Whether this is a long run, whose tests take hours rather than seconds.
final longRun = Platform.environment['DUVET_FUZZ_RUNS'] != null;

/// The seed of every generator: DUVET_FUZZ_SEED for another run, else CI's.
final seed = int.tryParse(Platform.environment['DUVET_FUZZ_SEED'] ?? '') ?? 0x5eed;

/// The most one input may take a reader: every reader here is linear in what it reads.
const budget = Duration(milliseconds: 250);

/// What [read] answers, failing past the [budget], with the input it took ([input], made only then). An input past it
/// is read once more: a loaded machine's pause comes once, and a reader slow on an input is slow each time it reads it.
T timed<T>(T Function() read, Object? Function() input) {
  (T, Duration) once() {
    final watch = Stopwatch()..start();
    final answer = read();
    return (answer, watch.elapsed);
  }

  var (answer, took) = once();
  if (took > budget) (answer, took) = once();
  if (took > budget) fail('took ${took.inMilliseconds} ms on ${shown(input())}');
  return answer;
}

/// [timed] for a reader that waits, [most] an input: one past it is read once more, as [timed]'s are.
Future<T> timedAsync<T>(Future<T> Function() read, Object? Function() input, {Duration most = budget}) async {
  Future<(T, Duration)> once() async {
    final watch = Stopwatch()..start();
    final answer = await read();
    return (answer, watch.elapsed);
  }

  var (answer, took) = await once();
  if (took > most) (answer, took) = await once();
  if (took > most) fail('took ${took.inMilliseconds} ms on ${shown(input())}');
  return answer;
}

/// An input as a failure names it: bytes in base64, anything else as JSON, 300 characters at most.
String shown(Object? input) {
  final text = switch (input) {
    final Uint8List bytes => 'bytes ${base64Encode(bytes)}',
    _ => jsonEncode(input, toEncodable: (value) => value is Uint8List ? base64Encode(value) : '$value'),
  };
  return text.length > 300 ? '${text.substring(0, 300)}…' : text;
}

/// mulberry32: small, fast, and the desktop's sequence for the same seed.
class Random {
  Random(int seed) : _state = seed & 0xffffffff;
  int _state;

  static int _imul(int a, int b) => (a * b) & 0xffffffff;

  int u32() {
    _state = (_state + 0x6d2b79f5) & 0xffffffff;
    var t = _imul(_state ^ (_state >> 15), 1 | _state);
    t = ((t + _imul(t ^ (t >> 7), 61 | t)) & 0xffffffff) ^ t;
    return (t ^ (t >> 14)) & 0xffffffff;
  }

  /// An integer in [0, below).
  int nextInt(int below) => (u32() * below) >> 32;

  bool chance([double p = 0.5]) => u32() / 4294967296 < p;

  T pick<T>(List<T> items) => items[nextInt(items.length)];

  /// A length up to a little past [most]: mostly small, at times at an edge of it.
  int size(int most) {
    if (chance(0.15)) return pick([0, 1, 2, most - 1, most, most + 1].where((n) => n >= 0).toList());
    return chance(0.7) ? nextInt(min(most, 32) + 1) : nextInt(most + 2);
  }

  Uint8List bytes(int length) => Uint8List.fromList([for (var i = 0; i < length; i++) u32() & 0xff]);

  /// A UUID's text, lowercase, as the API writes one.
  String uuid() {
    final hex = [for (final byte in bytes(16)) byte.toRadixString(16).padLeft(2, '0')].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

List<int> _span(int from, int to) => [for (var c = from; c <= to; c++) c];

/// Code points by kind: what names, frames and JSON hold, the hidden ones above all, and their neighbours.
final codePoints = <String, List<int>>{
  'ascii': _span(0x20, 0x7e),
  'controls': [..._span(0, 0x1f), ..._span(0x7f, 0x9f)],
  'separators': [0x2f, 0x5c],
  'dots': [0x2e, 0x20],
  'spaces': [0xa0, 0x1680, ..._span(0x2000, 0x200a), 0x202f, 0x205f, 0x3000],
  'lines': [0x2028, 0x2029, 0x0a, 0x0d],
  // Every format character, as Unicode 16 has them.
  'format': [
    ...[0xad, ..._span(0x600, 0x605), 0x61c, 0x6dd, 0x70f, 0x890, 0x891, 0x8e2, 0x180e, ..._span(0x200b, 0x200f)],
    ...[..._span(0x202a, 0x202e), ..._span(0x2060, 0x2064), ..._span(0x2066, 0x206f), 0xfeff, ..._span(0xfff9, 0xfffb)],
    ...[0x110bd, 0x110cd, ..._span(0x13430, 0x1343f), ..._span(0x1bca0, 0x1bca3), ..._span(0x1d173, 0x1d17a)],
    ...[0xe0001, ..._span(0xe0020, 0xe007f)],
  ],
  'joiner': [0x200d],
  'surrogates': [0xd800, 0xdb40, 0xdbff, 0xdc00, 0xdc01, 0xdfff],
  'emoji': [..._span(0x1f600, 0x1f64f), 0x2764, 0xfe0f, 0x1f3fb],
  'marks': _span(0x300, 0x36f),
  'letters': [..._span(0x5d0, 0x5ea), ..._span(0x627, 0x64a), ..._span(0x430, 0x44f), ..._span(0x4e00, 0x4e3f)],
  'odd': [0xfffd, 0xfffe, 0xffff, 0x10ffff, 0x1fffe],
};
final _kinds = codePoints.keys.toList();

/// Text of up to a little past [most] code points, of a few kinds at once, at times of any code point: a surrogate's
/// a lone half.
String text(Random rng, [int most = 24]) {
  final kinds = [for (var n = 1 + rng.nextInt(3); n > 0; n--) rng.pick(_kinds)];
  final out = StringBuffer();
  for (var n = rng.size(most); n > 0; n--) {
    out.writeCharCode(rng.chance(0.1) ? rng.nextInt(0x110000) : rng.pick(codePoints[rng.pick(kinds)]!));
  }
  return out.toString();
}

final _lone = RegExp(r'\p{Cs}', unicode: true);

/// [value] as UTF-8 can hold it: each lone surrogate U+FFFD, as utf8.encode writes one.
String wellFormed(String value) => value.replaceAll(_lone, '\u{fffd}');

/// Whether [value] holds no lone surrogate.
bool isWellFormed(String value) => !_lone.hasMatch(value);

/// Standard base64, padded, as the core and the API write it.
String base64(List<int> bytes) => base64Encode(bytes);

/// Whether [value] is base64 as the core and the API write it: what base64Encode writes again of what it holds.
bool canonical(String value) {
  try {
    return base64Encode(base64Decode(value)) == value;
  } on FormatException {
    return false;
  }
}

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/// The bytes' base64 as one writer or another could put it: canonical, or without its padding, with a space or a line
/// break in it, in the URL's alphabet, with stray bits in its last character, with its padding escaped, cut, or padded
/// once too many.
String base64As(Random rng, List<int> bytes) {
  final canonical = base64(bytes);
  final bare = canonical.replaceAll(RegExp(r'=+$'), '');
  final padding = canonical.length - bare.length;
  switch (rng.nextInt(10)) {
    case 0:
      return bare;
    case 1:
      final at = rng.nextInt(canonical.length + 1);
      return canonical.substring(0, at) + rng.pick([' ', '\n', '\r\n', '\t']) + canonical.substring(at);
    case 2:
      return canonical.replaceAllMapped(RegExp('.{76}'), (m) => '${m[0]}\n');
    case 3:
      return canonical.replaceAll('+', '-').replaceAll('/', '_');
    case 4:
      if (padding == 0) return canonical;
      // The last character's bits past the bytes, which a canonical writer leaves at zero.
      final at = canonical.length - padding - 1;
      final stray = padding == 2 ? 1 + rng.nextInt(15) : 1 + rng.nextInt(3);
      final changed = _alphabet[(_alphabet.indexOf(canonical[at]) | stray) & 63];
      return canonical.substring(0, at) + changed + '=' * padding;
    case 5:
      return canonical.replaceAll('=', '%3D');
    case 6:
      return canonical.substring(0, (canonical.length - 1 - rng.nextInt(3)).clamp(0, canonical.length));
    case 7:
      return '$canonical=';
    default:
      return canonical;
  }
}

/// [value] in each other form base64 takes that the core and the API never write: unpadded, with a space, a line
/// break at its end, in the URL's alphabet, its padding escaped, with stray bits, cut.
List<String> notCanonical(String value) {
  final bare = value.replaceAll(RegExp(r'=+$'), '');
  final padding = value.length - bare.length;
  final last = value.length - padding - 1;
  return [
    if (padding > 0) bare,
    ' $value',
    '$value\n',
    if (value.contains(RegExp('[+/]'))) value.replaceAll('+', '-').replaceAll('/', '_'),
    if (padding > 0) value.replaceAll('=', '%3D'),
    if (padding > 0 && last >= 0)
      value.substring(0, last) + _alphabet[(_alphabet.indexOf(value[last]) | 1) & 63] + '=' * padding,
    if (value.length > 1) value.substring(0, value.length - 1),
  ];
}

const _interesting = [0x00, 0x01, 0x7f, 0x80, 0xfe, 0xff, 0x18, 0x19, 0x1a, 0x1b, 0x1f, 0x3b, 0x5b, 0x7b, 0x9b, 0xbb];

/// The bytes changed a few times over: bits flipped, bytes set, put in, taken out, repeated, cut, or another's spliced.
Uint8List mutate(Random rng, List<int> input, [List<List<int>> others = const []]) {
  var bytes = [...input];
  for (var rounds = 1 + rng.nextInt(4); rounds > 0; rounds--) {
    final at = rng.nextInt(bytes.length + 1);
    switch (rng.nextInt(9)) {
      case 0:
        if (at < bytes.length) bytes[at] ^= 1 << rng.nextInt(8);
      case 1:
        if (at < bytes.length) bytes[at] = rng.pick(_interesting);
      case 2:
        bytes.insertAll(at, rng.bytes(1 + rng.nextInt(8)));
      case 3:
        bytes.removeRange(at, min(bytes.length, at + 1 + rng.nextInt(8)));
      case 4:
        bytes.insertAll(at, bytes.sublist(at, min(bytes.length, at + 1 + rng.nextInt(16))));
      case 5:
        bytes = bytes.sublist(0, at);
      case 6:
        bytes.addAll(rng.bytes(1 + rng.nextInt(16)));
      case 7:
        if (others.isEmpty) break;
        final other = rng.pick(others);
        final from = rng.nextInt(other.length + 1);
        final cut = min(bytes.length, at + rng.nextInt(8));
        bytes.replaceRange(at, cut, other.sublist(from, min(other.length, from + 1 + rng.nextInt(32))));
      default:
        // A length that lies: big-endian bytes in place, as CBOR, EBML and image headers hold their counts.
        for (var i = 0; i < 1 + rng.nextInt(8) && at + i < bytes.length; i++) {
          bytes[at + i] = rng.chance() ? 0xff : rng.u32() & 0xff;
        }
    }
  }
  return Uint8List.fromList(bytes);
}

/// Text changed a few times over, by UTF-16 unit: text put in, taken out, repeated, or the rest cut.
String mutateText(Random rng, String input) {
  var out = input;
  for (var rounds = 1 + rng.nextInt(3); rounds > 0; rounds--) {
    final at = rng.nextInt(out.length + 1);
    switch (rng.nextInt(4)) {
      case 0:
        out = out.substring(0, at) + text(rng, 4) + out.substring(at);
      case 1:
        out = out.substring(0, at) + out.substring(min(out.length, at + 1 + rng.nextInt(4)));
      case 2:
        out = out.substring(0, at) + out.substring(at, min(out.length, at + 1 + rng.nextInt(8))) + out.substring(at);
      default:
        out = out.substring(0, at);
    }
  }
  return out;
}

const _keys = ['duvet', 'step', 'data', 'name', 'id', 'type', 'seq', 'entry', '', '__proto__', 'constructor'];

/// Numbers at the edges a reader may trip on: doubles, past 2^53, negative.
const numbers = <num>[0, -0.0, 1, -1, 0.5, 1 << 31, 1 << 32, (1 << 53) - 1, (1 << 53) + 2, -(1 << 53), 1e300];

/// A JSON value of any kind, nested up to [depth]: numbers at their edges, text of every kind, keys that trip readers.
Object? json(Random rng, [int depth = 3]) => switch (rng.nextInt(depth > 0 ? 8 : 6)) {
  0 => null,
  1 => rng.chance(),
  2 => rng.pick(numbers),
  3 => rng.nextInt(1000),
  4 || 5 => text(rng),
  6 => [for (var n = rng.nextInt(4); n > 0; n--) json(rng, depth - 1)],
  _ => {
    for (var n = rng.nextInt(5); n > 0; n--) rng.chance(0.7) ? rng.pick(_keys) : text(rng, 6): json(rng, depth - 1),
  },
};

/// A value's CBOR as the core writes it: definite lengths, each head at its shortest, or wider where [wide] says.
Uint8List cborBytes(Object? value, [Random? wide]) {
  final out = BytesBuilder();
  void head(int major, int n) {
    final shortest = n < 24 ? 0 : (n < 0x100 ? 1 : (n < 0x10000 ? 2 : (n < 1 << 32 ? 4 : 8)));
    final width = wide != null && wide.chance(0.2)
        ? wide.pick([1, 2, 4, 8].where((w) => w >= shortest).toList())
        : shortest;
    if (width == 0) return out.addByte(major << 5 | n);
    out.addByte(major << 5 | (24 + const {1: 0, 2: 1, 4: 2, 8: 3}[width]!));
    out.add(bigEndian(n, width));
  }

  void write(Object? v) {
    switch (v) {
      case final int n:
        n >= 0 ? head(0, n) : head(1, -1 - n);
      case null:
        out.addByte(0xf6);
      case final bool b:
        out.addByte(b ? 0xf5 : 0xf4);
      case final String s:
        final bytes = utf8.encode(s);
        head(3, bytes.length);
        out.add(bytes);
      case final Uint8List bytes:
        head(2, bytes.length);
        out.add(bytes);
      case final List<Object?> list:
        head(4, list.length);
        list.forEach(write);
      case final Map<String, Object?> map:
        head(5, map.length);
        map.forEach((key, item) {
          write(key);
          write(item);
        });
      default:
        throw ArgumentError.value(v, 'value', 'not a value the core writes');
    }
  }

  write(value);
  return out.takeBytes();
}

const _cborKeys = ['body', 'sig', 'device', 'devices', 'version', 'v', 'user'];

/// A CBOR value the core could write, nested up to [depth]: whole numbers, text, bytes, lists, maps.
Object? cborValue(Random rng, [int depth = 3]) {
  switch (rng.nextInt(depth > 0 ? 9 : 7)) {
    case 0:
      return rng.pick([0, 23, 24, 255, 256, 65535, 65536, (1 << 32) - 1, 1 << 32, (1 << 53) - 1, (1 << 62) + 1]);
    case 1:
      return -1 - rng.pick([0, 23, 24, 255, 256, 65535, 1 << 32, (1 << 53) - 2, (1 << 62) + 1]);
    case 2:
      return rng.chance();
    case 3:
      return null;
    case 4:
      return wellFormed(text(rng, 8));
    case 5:
    case 6:
      return rng.bytes(rng.pick([0, 1, 16, 23, 24, 32, 64]));
    case 7:
      return [for (var n = rng.nextInt(4); n > 0; n--) cborValue(rng, depth - 1)];
    default:
      return <String, Object?>{
        for (var n = rng.nextInt(4); n > 0; n--)
          rng.chance() ? rng.pick(_cborKeys) : wellFormed(text(rng, 6)): cborValue(rng, depth - 1),
      };
  }
}

/// How deep a value's lists and maps go: 1 for one holding no other, 0 for anything else.
int cborDepth(Object? value) => switch (value) {
  final List<Object?> list => 1 + list.map(cborDepth).fold(0, (a, b) => a > b ? a : b),
  final Map<String, Object?> map => 1 + map.values.map(cborDepth).fold(0, (a, b) => a > b ? a : b),
  _ => 0,
};

/// Every length a value holds: its texts' in UTF-8, its bytes', its lists' and its maps'.
List<int> cborLengths(Object? value) => switch (value) {
  final String s => [utf8.encode(s).length],
  final Uint8List bytes => [bytes.length],
  final List<Object?> list => [list.length, for (final item in list) ...cborLengths(item)],
  final Map<String, Object?> map => [map.length, for (final item in map.values) ...cborLengths(item)],
  _ => const [],
};

/// Bytes put together.
Uint8List concat(List<List<int>> parts) => Uint8List.fromList([for (final part in parts) ...part]);

/// [value]'s [width] bytes, big-endian.
List<int> bigEndian(int value, int width) => [for (var i = width - 1; i >= 0; i--) (value >> (8 * i)) & 0xff];
