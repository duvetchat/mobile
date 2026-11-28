// Ed25519 (RFC 8032), for the fake API alone (test/support/fake_api.dart), which checks what the core signs as the
// API does: the reference algorithm of the RFC's section 6, in BigInt, slow and plain. It verifies, makes the public
// key of a seed, and signs with one, as the API signs its proposals as the groups' external sender.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _p = (BigInt.one << 255) - BigInt.from(19);
final _q = (BigInt.one << 252) + BigInt.parse('27742317777372353535851937790883648493');
final _d = (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final _sqrtM1 = BigInt.two.modPow((_p - BigInt.one) >> 2, _p);

typedef _Point = (BigInt, BigInt, BigInt, BigInt);

final _Point _base = () {
  final y = (BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p;
  final x = _recoverX(y, 0)!;
  return (x, y, BigInt.one, (x * y) % _p);
}();

_Point _add(_Point a, _Point b) {
  final pa = (a.$2 - a.$1) * (b.$2 - b.$1) % _p;
  final pb = (a.$2 + a.$1) * (b.$2 + b.$1) % _p;
  final c = BigInt.two * a.$4 * b.$4 * _d % _p;
  final d = BigInt.two * a.$3 * b.$3 % _p;
  final (e, f, g, h) = (pb - pa, d - c, d + c, pb + pa);
  return (e * f % _p, g * h % _p, f * g % _p, e * h % _p);
}

_Point _multiply(BigInt s, _Point point) {
  _Point result = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  var p = point;
  for (var k = s; k > BigInt.zero; k >>= 1) {
    if (k.isOdd) result = _add(result, p);
    p = _add(p, p);
  }
  return result;
}

bool _equal(_Point a, _Point b) =>
    (a.$1 * b.$3 - b.$1 * a.$3) % _p == BigInt.zero && (a.$2 * b.$3 - b.$2 * a.$3) % _p == BigInt.zero;

BigInt? _recoverX(BigInt y, int sign) {
  if (y >= _p) return null;
  final x2 = (y * y - BigInt.one) * (_d * y * y + BigInt.one).modInverse(_p) % _p;
  if (x2 == BigInt.zero) return sign == 1 ? null : BigInt.zero;
  var x = x2.modPow((_p + BigInt.from(3)) >> 3, _p);
  if ((x * x - x2) % _p != BigInt.zero) x = x * _sqrtM1 % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  return x;
}

BigInt _little(List<int> bytes) => bytes.reversed.fold(BigInt.zero, (value, byte) => (value << 8) | BigInt.from(byte));

Uint8List _bytes(BigInt value) =>
    Uint8List.fromList([for (var i = 0; i < 32; i++) ((value >> (8 * i)) & BigInt.from(0xff)).toInt()]);

_Point? _decompress(List<int> bytes) {
  if (bytes.length != 32) return null;
  final encoded = _little(bytes);
  final y = encoded & ((BigInt.one << 255) - BigInt.one);
  final x = _recoverX(y, (encoded >> 255).toInt());
  return x == null ? null : (x, y, BigInt.one, x * y % _p);
}

Uint8List _compress(_Point point) {
  final z = point.$3.modInverse(_p);
  final (x, y) = (point.$1 * z % _p, point.$2 * z % _p);
  return _bytes(y | (x.isOdd ? BigInt.one << 255 : BigInt.zero));
}

/// Whether [signature] is [publicKey]'s over [message]; false for a key or signature that isn't one.
bool verifyEd25519(List<int> publicKey, List<int> message, List<int> signature) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final a = _decompress(publicKey);
  final r = _decompress(signature.sublist(0, 32));
  final s = _little(signature.sublist(32));
  if (a == null || r == null || s >= _q) return false;
  final h = _little(sha512.convert([...signature.sublist(0, 32), ...publicKey, ...message]).bytes) % _q;
  return _equal(_multiply(s, _base), _add(r, _multiply(h, a)));
}

/// A seed's secret scalar, as the RFC clamps the first half of its hash.
BigInt _scalar(List<int> hash) =>
    (_little(hash.sublist(0, 32)) & ((BigInt.one << 254) - BigInt.from(8))) | (BigInt.one << 254);

/// The public key of a 32-byte seed.
Uint8List ed25519PublicKey(List<int> seed) => _compress(_multiply(_scalar(sha512.convert(seed).bytes), _base));

/// The signature of a 32-byte seed's over [message] (the RFC's section 5.1.6).
Uint8List ed25519Sign(List<int> seed, List<int> message) {
  final hash = sha512.convert(seed).bytes;
  final a = _scalar(hash);
  final publicKey = _compress(_multiply(a, _base));
  final r = _little(sha512.convert([...hash.sublist(32), ...message]).bytes) % _q;
  final rEncoded = _compress(_multiply(r, _base));
  final k = _little(sha512.convert([...rEncoded, ...publicKey, ...message]).bytes) % _q;
  return Uint8List.fromList([...rEncoded, ..._bytes((r + k * a) % _q)]);
}
