/// The CBOR the core writes its signed objects in (PLAN-E2E-API.md, its formats), read only to tell which device a
/// certificate is for, as the inbox names a message's sender by its device, and which device an approval's QR names,
/// as the phone that scans it asks its person about that device: the core checks every signature, and reads the QR
/// itself. The fake API reads it too.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One CBOR value, as the core writes them: definite lengths, text keys, no tags; null for anything else.
Object? cbor(Uint8List bytes) {
  var at = 0;
  Uint8List take(int n) {
    if (n < 0 || at + n > bytes.length) throw const FormatException('cut short');
    return Uint8List.sublistView(bytes, at, at += n);
  }

  int uint(int info) {
    if (info < 24) return info;
    if (info > 27) throw const FormatException('no definite length');
    return take(1 << (info - 24)).fold(0, (value, byte) => value * 256 + byte);
  }

  Object? item(int depth) {
    if (depth > 32) throw const FormatException('nested too deep');
    final head = take(1)[0];
    final info = head & 31;
    switch (head >> 5) {
      case 0:
        return uint(info);
      case 1:
        return -1 - uint(info);
      case 2:
        return Uint8List.fromList(take(uint(info)));
      case 3:
        return utf8.decode(take(uint(info)));
      case 4:
        return [for (var n = uint(info); n > 0; n--) item(depth + 1)];
      case 5:
        final map = <String, Object?>{};
        for (var n = uint(info); n > 0; n--) {
          final key = item(depth + 1);
          if (key is! String || map.containsKey(key)) throw const FormatException('not a text key, or one twice');
          map[key] = item(depth + 1);
        }
        return map;
      case 7:
        if (info == 20 || info == 21) return info == 21;
        if (info == 22) return null;
    }
    throw const FormatException('not a value the core writes');
  }

  try {
    final value = item(0);
    return at == bytes.length ? value : null;
  } on FormatException {
    return null;
  }
}

Map<String, Object?>? asMap(Object? value) => value is Map<String, Object?> ? value : null;

Uint8List? asBytes(Object? value, [int? length]) =>
    value is Uint8List && (length == null || value.length == length) ? value : null;

/// A UUID the core writes as its 16 bytes, in text.
String? asUuid(Object? value) {
  final bytes = asBytes(value, 16);
  if (bytes == null) return null;
  final hex = [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

/// The device a certificate names (its signed object in base64, `{body, sig}`, its body's `device`), or null: read,
/// never checked, as the core checks it.
String? certificateDevice(String certificate) {
  final Uint8List signed;
  try {
    signed = base64Decode(certificate);
  } on FormatException {
    return null;
  }
  final body = asBytes(asMap(cbor(signed))?['body']);
  return body == null ? null : asUuid(asMap(cbor(body))?['device']);
}

/// A signed device list's version and the devices it names, in its order (its signed object in base64, `{body, sig}`,
/// its body's `version` and `devices`), or null: read, never checked, as the core checks it.
({int version, List<String> devices})? deviceListOf(String list) {
  final Uint8List signed;
  try {
    signed = base64Decode(list);
  } on FormatException {
    return null;
  }
  final body = asBytes(asMap(cbor(signed))?['body']);
  final fields = body == null ? null : asMap(cbor(body));
  final (version, devices) = (fields?['version'], fields?['devices']);
  if (version is! int || devices is! List) return null;
  final ids = [for (final device in devices) asUuid(device)];
  return ids.contains(null) ? null : (version: version, devices: ids.cast<String>());
}

/// The device an approval's QR names (the core's `qr` in base64, its `device`), or null: read only to ask the person
/// about that device before the core approves it, never checked, as the core reads the QR itself as it approves.
String? qrDevice(String qr) {
  final Uint8List bytes;
  try {
    bytes = base64Decode(qr);
  } on FormatException {
    return null;
  }
  return asUuid(asMap(cbor(bytes))?['device']);
}

/// The devices a signed device list names, in its order, or null ([deviceListOf]).
List<String>? listDevices(String list) => deviceListOf(list)?.devices;
