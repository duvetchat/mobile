import 'dart:math';

final _random = Random.secure();

/// A UUIDv7 (RFC 9562): the time it was made in Unix milliseconds, its first 48 bits, then its version and random
/// bits. The IDs the client mints itself are these, a device's and a file's, so they sort by when they were made, as
/// the API's own IDs do (PLAN-E2E-CLIENTES.md, its conventions between clients).
String uuidv7([int? now]) {
  final bytes = List.generate(16, (_) => _random.nextInt(256));
  for (var i = 5, ms = now ?? DateTime.now().millisecondsSinceEpoch; i >= 0; i--, ms ~/= 256) {
    bytes[i] = ms % 256;
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
