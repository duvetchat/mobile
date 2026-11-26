/// A conversation's files (PLAN-E2E-CLIENTES.md, «Adjuntos», and its conventions between clients). Going out, each is
/// sealed by the core with a key drawn for it alone, under an ID this device gives it, beside the SHA-256 of what it
/// was (the one thing a client works out itself); its thumbnail rides in the message when it's 8 KiB or less and the
/// message holds it, else it's a file of its own, which goes up after the message's files. Coming back, a file is
/// downloaded from the API's signed URL, opened by the core and checked against what its message says of it. What a
/// sender writes of a file is theirs: its name is cleaned, its type only says how it's waited for (its bytes say what
/// it is), its size bounds what's downloaded, and a dimension, a duration or a waveform that doesn't read as one goes.
/// The desktop's engine/files.ts in Dart.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'conventions.dart';
import 'host.dart';
import 'search.dart' show DeviceSearch, devicePage, searchDevice;
import 'uuid.dart';

/// The most bytes a request to the API takes: a message's form, its sealed files and their thumbnails together.
const maxRequestBytes = 32 << 20;

/// What a file of [size] bytes is once sealed: each part of 64 KiB with its tag, and an empty file one part.
int sealedSize(int size) => size + partTag * max(1, (size + attachmentPart - 1) ~/ attachmentPart);

/// Whether a message's files can't go as they are: one past the per-file cap of where they go ([fileLimit]) once
/// sealed, or all of them past the request's 32 MiB. The API's 413 stays the last word, as only it knows the storage's
/// room.
bool tooLargeToSend(List<int> sizes, {int? fileLimit}) {
  final sealed = [for (final size in sizes) sealedSize(size)];
  if (fileLimit != null && sealed.any((size) => size > fileLimit)) return true;
  // The form's text beside the files: a message's 32 KiB of ciphertext, and its fields.
  return sealed.fold(0, (all, size) => all + size) + (40 << 10) > maxRequestBytes;
}

/// A file the person sends, as the app has it: its bytes, its name as picked, and what the app could tell of it.
class FileToSeal {
  const FileToSeal({
    required this.bytes,
    required this.name,
    this.width,
    this.height,
    this.durationMs,
    this.waveform,
    this.thumbnail,
  });

  final Uint8List bytes;
  final String name;
  final int? width;
  final int? height;
  final int? durationMs;

  /// A voice note's 64 peaks, a byte each.
  final Uint8List? waveform;

  /// Its picture's or its video's thumbnail (thumbnails.dart): a JPEG, or a PNG with transparency.
  final Uint8List? thumbnail;
}

/// A file as the core seals and opens it: its ID, its key, and its original's SHA-256 (base64) and size.
@immutable
class FileRef {
  const FileRef({required this.id, required this.key, required this.sha256, required this.size});
  final String id;
  final String key;
  final String sha256;
  final int size;

  // Never its key: a file may end up in a log.
  @override
  String toString() => 'FileRef($id)';
}

/// What a message says of a file, as a view may use it: [said] is only its sender's word on its type.
@immutable
class ShownFile extends FileRef {
  const ShownFile({
    required super.id,
    required super.key,
    required super.sha256,
    required super.size,
    required this.name,
    required this.said,
    this.width,
    this.height,
    this.durationMs,
    this.waveform,
    this.thumbnail,
    this.thumbnailRef,
  });

  /// Its name, cleaned.
  final String name;
  final String said;
  final int? width;
  final int? height;
  final int? durationMs;

  /// A voice note's 64 peaks, in base64.
  final String? waveform;

  /// Its thumbnail inside the message (8 KiB at most), in base64; or one of its own.
  final String? thumbnail;
  final FileRef? thumbnailRef;

  // Never its key nor its name: a file may end up in a log.
  @override
  String toString() => 'ShownFile($id)';
}

/// Why a file isn't shown: no URL for it, a size that isn't its own, other bytes than its sender's, bytes the core
/// didn't open, which no ask changes; or no download, which a tap asks again (task 18's review, I4).
enum FileFailure { unavailable, size, hash, download, open }

class FileError implements Exception {
  FileError(this.reason, [this.cause]);
  final FileFailure reason;
  final Object? cause;

  @override
  String toString() => "FileError: the file can't be shown: ${reason.name}";
}

/// A message whose files this device no longer has the sealed bytes of (the app started again): it can only go.
class FilesGone implements Exception {
  const FilesGone();

  @override
  String toString() => "FilesGone: this message's files aren't on this device any more";
}

/// The most a thumbnail inside a message holds (the core's).
const _maxThumbnail = 8 << 10;

/// A thumbnail's types.
const _thumbnailTypes = {'image/jpeg', 'image/png'};

/// The longest side of a picture or a video taken from what its sender says, and the longest duration: a day.
const _maxSide = 65535;
const _maxDuration = 86400000;
final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
const _octetStream = 'application/octet-stream';

String _sha256(List<int> bytes) => base64Encode(sha256.convert(bytes).bytes);
String _typeOf(Uint8List bytes) => sniffType(bytes);
bool _side(Object? value) => value is int && value > 0 && value <= _maxSide;
bool _duration(Object? value) => value is int && value >= 0 && value <= _maxDuration;

/// Bytes sealed by the core under a key and an ID of their own: what a message names them by, and what goes up.
Future<({FileRef ref, Uint8List sealed})> _sealOne(CoreHost host, Uint8List plain) async {
  final key = (await host.handle<Map<String, Object?>>({'cmd': 'attachment_key'}))['key']! as String;
  final id = uuidv7();
  final sealed = await host.sealFile(key, id, plain);
  return (ref: FileRef(id: id, key: key, sha256: _sha256(plain), size: plain.length), sealed: sealed);
}

class _Made {
  _Made(this.attachment, this.sealed, this.thumbnail);
  final Map<String, Object?> attachment;
  final Uint8List sealed;
  final Uint8List? thumbnail;
  ({String id, Uint8List sealed})? apart;
}

/// A message's files sealed: what its envelope says of each, and the bytes that go up by their IDs.
class SealedFiles {
  SealedFiles._(this._host, this._made);

  final CoreHost _host;
  final List<_Made> _made;

  /// Each file as the envelope says it (the core's `Attachment`).
  List<Map<String, Object?>> get attachments => [for (final made in _made) made.attachment];

  /// The IDs the API takes them by, in its order: the message's files, then the thumbnails of their own.
  List<String> get ids => [
    for (final made in _made) made.attachment['id']! as String,
    for (final made in _made) ?made.apart?.id,
  ];

  /// Their sealed bytes, in the IDs' order.
  List<Uint8List> get parts => [for (final made in _made) made.sealed, for (final made in _made) ?made.apart?.sealed];

  /// The largest thumbnail still inside the message, made a file of its own: false once none is left.
  Future<bool> apart() async {
    _Made? largest;
    for (final made in _made) {
      if (made.attachment['thumbnail'] == null || made.thumbnail == null) continue;
      if (largest == null || made.thumbnail!.length > largest.thumbnail!.length) largest = made;
    }
    if (largest == null) return false;
    await _toFile(largest);
    return true;
  }

  Future<void> _toFile(_Made made) async {
    final thumbnail = made.thumbnail;
    if (thumbnail == null) return;
    final (:ref, :sealed) = await _sealOne(_host, thumbnail);
    made.attachment
      ..remove('thumbnail')
      ..['thumbnail_ref'] = {'id': ref.id, 'key': ref.key, 'sha256': ref.sha256, 'size': ref.size};
    made.apart = (id: ref.id, sealed: sealed);
  }

  /// The person's files, each sealed with a key of its own under an ID this device gives it, its type read from its
  /// bytes and its name cleaned; and its thumbnail, a JPEG or a PNG of a picture's or a video's, inside the message
  /// when it's 8 KiB or less ([apart] takes one out), else a file of its own.
  static Future<SealedFiles> of(CoreHost host, List<FileToSeal> files) async {
    final made = <_Made>[];
    for (final one in files) {
      final type = _typeOf(one.bytes);
      final (:ref, :sealed) = await _sealOne(host, one.bytes);
      final attachment = <String, Object?>{
        'id': ref.id,
        'key': ref.key,
        'sha256': ref.sha256,
        'name': cleanName(one.name),
        'type': type,
        'size': ref.size,
        if (_side(one.width) && _side(one.height)) ...{'width': one.width, 'height': one.height},
        if (_duration(one.durationMs)) 'duration_ms': one.durationMs,
        if (one.waveform case final peaks? when peaks.length == waveformSamples) 'waveform': base64Encode(peaks),
      };
      final pictured = type.startsWith('image/') || type.startsWith('video/');
      final thumbnail = switch (one.thumbnail) {
        final bytes? when pictured && _thumbnailTypes.contains(_typeOf(bytes)) => bytes,
        _ => null,
      };
      made.add(_Made(attachment, sealed, thumbnail));
    }
    final sealed = SealedFiles._(host, made);
    for (final one in made) {
      final thumbnail = one.thumbnail;
      if (thumbnail == null) continue;
      if (thumbnail.length > _maxThumbnail) {
        await sealed._toFile(one);
      } else {
        one.attachment['thumbnail'] = base64Encode(thumbnail);
      }
    }
    return sealed;
  }
}

/// The bytes a base64 field holds, or null for one that doesn't read.
Uint8List? _decoded(Object? value) {
  if (value is! String) return null;
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}

/// A thumbnail's file as its message names it, when it reads as one.
FileRef? _fileRef(Object? value) {
  if (value is! Map) return null;
  final (id, key, sha, size) = (value['id'], value['key'], value['sha256'], value['size']);
  if (id is! String || !_uuid.hasMatch(id) || key is! String || sha is! String) return null;
  return size is int && size >= 0 ? FileRef(id: id, key: key, sha256: sha, size: size) : null;
}

/// A file the core shows of a message (its `messages`' attachments), as a view may use it: null for one without an
/// ID or a key. Its name is cleaned; its type is only its sender's word ([ShownFile.said]); a size is any number,
/// which openSealed bounds; its dimensions, duration and waveform only when they read as such; a thumbnail inside it
/// only of 8 KiB or less.
ShownFile? shownFile(Object? raw) {
  if (raw is! Map) return null;
  final (id, key, sha, size) = (raw['id'], raw['key'], raw['sha256'], raw['size']);
  if (id is! String || !_uuid.hasMatch(id) || key is! String || sha is! String) return null;
  if (size is! int || size < 0) return null;
  final (width, height, length) = (raw['width'], raw['height'], raw['duration_ms']);
  final waveform = raw['waveform'];
  final thumbnail = raw['thumbnail'];
  final inside = _decoded(thumbnail);
  final kept = inside != null && inside.length <= _maxThumbnail ? thumbnail as String : null;
  return ShownFile(
    id: id,
    key: key,
    sha256: sha,
    size: size,
    name: cleanName(raw['name'] is String ? raw['name']! as String : ''),
    said: raw['type'] is String ? raw['type']! as String : _octetStream,
    width: _side(width) && _side(height) ? width as int : null,
    height: _side(width) && _side(height) ? height as int : null,
    durationMs: _duration(length) ? length as int : null,
    waveform: waveform is String && _decoded(waveform)?.length == waveformSamples ? waveform : null,
    thumbnail: kept,
    thumbnailRef: kept == null ? _fileRef(raw['thumbnail_ref']) : null,
  );
}

/// How a file's sealed bytes come down ([most] of them at most, [progress] hearing how many came), and how the core
/// opens them.
typedef FileDownload = Future<Uint8List> Function(int most, void Function(int received)? progress);
typedef FileOpen =
    Future<Uint8List> Function(String key, String id, Uint8List sealed, void Function(int done)? progress);

/// A file of a message, opened and checked before anything uses it (Review Focus 7): a size no request could carry is
/// never downloaded, and the download stops past what a file of its size holds; what came must be all of it, the core
/// must open it to that many bytes, and their SHA-256 must be the one its message says. Its type is its bytes'
/// (sniffType's): a page or an SVG called a picture is application/octet-stream. [progress] hears how far it is, from
/// 0 to 1, the download and the opening together. A [FileError] says why it isn't shown.
Future<({Uint8List bytes, String type})> openSealed(
  FileRef file, {
  required FileDownload download,
  required FileOpen open,
  void Function(double share)? progress,
}) async {
  final size = file.size;
  if (size < 0 || sealedSize(size) > maxRequestBytes) throw FileError(FileFailure.size);
  final most = sealedSize(size);
  final whole = most + size;
  Uint8List sealed;
  try {
    sealed = await download(most, (received) {
      if (received > most) throw FileError(FileFailure.size);
      progress?.call(received / whole);
    });
  } on FileError {
    rethrow;
  } catch (error) {
    throw FileError(error is RangeError ? FileFailure.size : FileFailure.download, error);
  }
  if (sealed.length != most) throw FileError(FileFailure.size);
  Uint8List plain;
  try {
    plain = await open(file.key, file.id, sealed, (done) => progress?.call((most + done) / whole));
  } catch (error) {
    // The core's own word on its bytes is final; one that didn't reach it (no engine now, a closed core) isn't.
    final fromCore = error is CoreError && error.code != 'internal';
    throw FileError(fromCore ? FileFailure.open : FileFailure.download, error);
  }
  if (plain.length != size) throw FileError(FileFailure.size);
  if (_sha256(plain) != file.sha256) throw FileError(FileFailure.hash);
  return (bytes: plain, type: sniffType(plain));
}

/// What a decrypted file is drawn in.
enum DrawnIn { image, video, audio, save }

/// The types of the decrypted files the app draws, each in its widget: every one sniffType reads but bytes to save.
/// AVIF draws where Android's decoder takes it (12 and later), and a QuickTime or an HEVC video plays where the phone's
/// decoder does: one that doesn't offers its file to save instead.
const _drawn = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/avif',
  'video/mp4',
  'video/webm',
  'video/quicktime',
  'audio/mp4',
  'audio/wav',
  'audio/webm',
  'audio/ogg',
  'audio/flac',
  'audio/mpeg',
};

/// The widget a decrypted file is drawn in, by its bytes' own type (openSealed's): an Image, a video player, an audio
/// player, or else none: it's saved as bytes, never opened (Review Focus 6).
DrawnIn drawnBy(String type) {
  if (!_drawn.contains(type)) return DrawnIn.save;
  if (type.startsWith('image/')) return DrawnIn.image;
  return type.startsWith('video/') ? DrawnIn.video : DrawnIn.audio;
}

/// A GIF of the picker's as a file of its own (Ruling 12), to go sealed as any picture: its bytes, which must be a
/// GIF's, named after the last part of its URL. Null when they can't be had or aren't a GIF.
Future<({Uint8List bytes, String name})?> gifFile(String url, Future<Uint8List?> Function(String url) bytesOf) async {
  final Uint8List? bytes;
  try {
    bytes = await bytesOf(url);
  } catch (_) {
    return null;
  }
  if (bytes == null || sniffType(bytes) != 'image/gif') return null;
  final segments = Uri.tryParse(url)?.pathSegments ?? const [];
  final name = cleanName(segments.isEmpty ? '' : segments.last);
  return (bytes: bytes, name: name.toLowerCase().endsWith('.gif') ? name : '$name.gif');
}

/// The names of the files whose messages this device holds, by their IDs, a thumbnail of its own named as its file:
/// one pass of the core's search of the messages with files ([searchDevice], the one way this device's database is
/// searched), a page at a time (Ruling 31).
Future<Map<String, String>> fileNames(CoreHost host) async {
  final names = <String, String>{};
  for (var offset = 0; ; offset += devicePage) {
    final found = await searchDevice(host, DeviceSearch(has: const ['file'], offset: offset));
    for (final message in found.messages) {
      for (final raw in message.attachments) {
        final file = shownFile(raw);
        if (file == null) continue;
        names[file.id] = file.name;
        if (file.thumbnailRef case final ref?) names[ref.id] = file.name;
      }
    }
    if (found.messages.length < devicePage || offset + devicePage >= found.total) return names;
  }
}
