/// The files of conversations this device opened (PLAN-E2E-CLIENTES.md, «Adjuntos»; Ruling 19): decrypted into a
/// temporary folder of the app's own, e2e-media, as video_player and just_audio take a file, [maxDecrypted] of them,
/// the file drawn longest ago let go of first, and every file of a message as the message is deleted, each one's copy
/// deleted as it goes. The app's engine empties it as it starts: a run that ended left what it had there. A file is
/// downloaded from its signed URL, opened by the core and checked (files.dart's openSealed) once, whoever asks: two
/// chats showing a message share it. A file is what its message says of it, its ID with its key, SHA-256 and size,
/// never its ID alone: any member can write another's ID in an envelope, and one message never shows or blocks
/// another's file (task 18's review, I1); its copy is named by a hash of those, never by anything its sender wrote
/// (Review Focus 7). Four come down at once, a tap's first (I5). One let go of for room isn't fetched again by itself,
/// as the view still showing it would fetch it in turn and let another go: a tap does, and so does it after a download
/// that failed, which is never final (I4). The desktop's decrypted-files.svelte.ts, with a folder.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'files.dart';
import 'uuid.dart';

/// How much the folder holds: 256 MiB, the desktop's cap.
const maxDecrypted = 256 << 20;

/// How many files come down and open at once: each holds its sealed bytes a few times over while it does.
const openingMost = 4;

/// How many sealed bytes come down at once, beside the count: four of a bucket's large files would hold hundreds of MB
/// (task 19's review, M7). A file past it comes down alone.
const openingBytesMost = 64 << 20;

/// Where a file is: on its way (how far, from 0 to 1), here (its copy, and its bytes' type), not shown (why), or let go
/// of for room.
@immutable
sealed class FileState {
  const FileState();
}

class FileLoading extends FileState {
  const FileLoading(this.progress);
  final double progress;
}

class FileReady extends FileState {
  const FileReady(this.path, this.type, this.size);

  /// Its decrypted copy, in the folder.
  final String path;

  /// Its bytes' own type (sniffType's).
  final String type;
  final int size;
}

class FileFailed extends FileState {
  const FileFailed(this.reason);
  final FileFailure reason;
}

class FileGone extends FileState {
  const FileGone();
}

/// How a file's sealed bytes come down from its signed URL, how this device's core opens them, and what counts a file
/// that didn't open (decision 40).
abstract interface class FileOpener {
  Future<Uint8List> download(String id, String url, int most, void Function(int received)? progress);
  Future<Uint8List> open(String key, String id, Uint8List sealed, void Function(int done)? progress);
  void failed();
}

/// What no ask changes: other bytes than the message says, too many of them, or none the core opens.
const _final = {FileFailure.hash, FileFailure.size, FileFailure.open};
const _unavailable = FileFailed(FileFailure.unavailable);

class _Entry {
  _Entry(this.serial, this.messages, this.used, this.bytes);

  /// Which of its place's entries it is: its copy's name has it, so one let go of never deletes a later one's.
  final int serial;
  FileState state = const FileLoading(0);

  /// The messages that asked for it, which take it along as they're all deleted.
  final Set<String> messages;

  /// When it was last drawn or asked for: the one drawn longest ago goes first.
  int used;
  Future<FileState>? work;

  /// Its place among those that open files, while it waits for one: true once it has it, false when it's given up.
  Completer<bool>? place;

  /// Its sealed bytes, which it holds while it comes down.
  final int bytes;
}

class DecryptedFiles extends ChangeNotifier {
  DecryptedFiles({this.limit = maxDecrypted, this.inFlight = openingBytesMost, Future<Directory> Function()? folder})
    : _folder = folder ?? _temporary,
      // A test's folder alone has no share_plus folder beside it, nor the app's cache folder around it.
      _shared = folder == null ? _sharePlus : null,
      _cache = folder == null ? getTemporaryDirectory : null;

  /// How many sealed bytes come down at once ([openingBytesMost]).
  final int inFlight;

  /// The app's: the repository gives it its opener as its engine starts (lib/data/duvet_repository.dart).
  static DecryptedFiles instance = DecryptedFiles();

  static Future<Directory> _temporary() async => Directory('${(await getTemporaryDirectory()).path}/e2e-media');

  /// Where share_plus copies each file it shares (its Share.kt's cacheDir/share_plus), which it empties only as its
  /// next share starts: a decrypted file shared stays there in the clear (step 5's review, I3).
  static Future<Directory> _sharePlus() async => Directory('${(await getTemporaryDirectory()).path}/share_plus');

  final int limit;
  final Future<Directory> Function() _folder;
  final Future<Directory> Function()? _shared;

  /// The app's cache folder, where the pickers copy what they hand over and the recorder writes a voice note
  /// (mobile#365).
  final Future<Directory> Function()? _cache;

  /// The cache folder's paths as the start's emptying found them, as path_provider names it and as its links lead
  /// (file_picker hands over a canonical path): none before it, when nothing is taken in or let go of.
  var _cachePaths = const <String>[];
  final _files = <String, _Entry>{};
  final _waiting = <_Entry>[];
  FileOpener? _opener;
  var _clock = 0;
  var _serial = 0;
  var _used = 0;
  var _opening = 0;
  var _openingBytes = 0;

  /// How many bytes of decrypted files the folder holds.
  int get used => _used;

  /// A file's place: its ID, with what its message says of its bytes.
  static String _placeOf(FileRef file) => '${file.id}:${file.key}:${file.sha256}:${file.size}';

  /// What opens files from now on; none (the engine stopped, or the person signed out) lets every file go.
  void useOpener(FileOpener? opener) {
    _opener = opener;
    if (opener != null) return;
    for (final entry in _files.values) {
      _release(entry);
    }
    _files.clear();
    for (final entry in _waiting) {
      entry.place?.complete(false);
    }
    _waiting.clear();
    notifyListeners();
  }

  /// Empties the folder, and share_plus's copies of the files shared from it (mobile#354): as the app's engine starts
  /// (what's there a run before this one left), at a sign-out, and as this device's data goes. A share still pending
  /// loses its file then, as share_plus itself loses one at its next share. So go what a send left in the cache folder
  /// (mobile#365): file_picker's copies, and a voice note a kill cut short (VoiceRecorder's `voice-<ms>`).
  Future<void> emptyAtStart() async {
    for (final folder in [await _folder(), if (_shared case final shared?) await shared()]) {
      if (!await folder.exists()) continue;
      await for (final left in folder.list()) {
        try {
          await left.delete(recursive: true);
        } on FileSystemException catch (error) {
          debugPrint("e2e: a decrypted file of before couldn't go: ${error.osError?.message ?? error.message}");
        }
      }
    }
    final cache = await _cache?.call();
    if (cache == null || !await cache.exists()) return;
    _cachePaths = {cache.path, await cache.resolveSymbolicLinks()}.toList();
    try {
      await FilePicker.clearTemporaryFiles();
    } on PlatformException catch (error) {
      debugPrint("e2e: file_picker's copies weren't cleared: ${error.code}");
    }
    await for (final left in cache.list()) {
      if (left is File && left.uri.pathSegments.last.startsWith('voice-')) _deleteCopy(left.path);
    }
  }

  /// A copy beside the files, as [name] (a cleaned one) in a folder of its own under [kind]: a decrypted file shared
  /// under its own name, which the folder's copies don't have (task 19's review, M1), a GIF picked to send (M5), or,
  /// [move]d in, a file picked to send ([takeIn]). It goes with the folder ([emptyAtStart]).
  Future<File> aside(String kind, String name, {String? from, List<int>? bytes, bool move = false}) async {
    final folder = Directory('${(await _folder()).path}/$kind/${uuidv4()}');
    await folder.create(recursive: true);
    final file = File('${folder.path}/$name');
    if (from == null) return file.writeAsBytes(bytes!, flush: true);
    return move ? File(from).rename(file.path) : File(from).copy(file.path);
  }

  /// A file picked to send in an encrypted conversation, moved in among these as it's picked (mobile#365): a picker's
  /// copy in the cache folder is the file in the clear, which only the core's database may keep, and here the start
  /// empties it should the app end before its send settles. One outside the cache folder is the person's own and stays
  /// where it is, as does one that can't move, which [letGo] deletes.
  Future<String> takeIn(String path) async {
    if (!_inCache(path)) return path;
    try {
      return (await aside('picked', path.substring(path.lastIndexOf('/') + 1), from: path, move: true)).path;
    } on FileSystemException catch (error) {
      debugPrint(
        "e2e: a picked file didn't move among the decrypted files: ${error.osError?.message ?? error.message}",
      );
      return path;
    }
  }

  /// The files a conversation's send took, once it settled (sent, or dismissed), or that the person took out of the
  /// tray: each in the cache folder goes (mobile#365), never the person's own.
  void letGo(Iterable<String> paths) {
    for (final path in paths) {
      if (_inCache(path)) _deleteCopy(path);
    }
  }

  bool _inCache(String path) => _cachePaths.any((cache) => path.startsWith('$cache/'));

  /// Where the file is: null while nobody asked for it, and unavailable when its message's API row names no URL of
  /// it. Reading it counts as drawing it.
  FileState? state(FileRef file, String? url) {
    if (url == null || url.isEmpty) return _unavailable;
    final entry = _files[_placeOf(file)];
    if (entry != null) entry.used = ++_clock;
    return entry?.state;
  }

  /// The file of a message, downloaded, opened, checked and copied into the folder, unless it's here or on its way:
  /// what it ends as. [auto] is a view's own ask as it shows, which doesn't fetch again a file let go of for room, or
  /// one whose download failed; a tap does, and goes before the views' asks.
  Future<FileState> open(FileRef file, String? url, String messageId, {bool auto = false}) {
    final opener = _opener;
    // None for its message: its alone. No engine yet: asked again once there's one.
    if (url == null || url.isEmpty || opener == null) return Future.value(_unavailable);
    final place = _placeOf(file);
    final had = _files[place];
    had?.messages.add(messageId);
    if (had?.work case final work?) {
      if (!auto) _first(had!);
      return work;
    }
    final state = had?.state;
    // A copy the system deleted (Android clears an app's cache under storage pressure) opens again (task 19's review,
    // M6).
    final copyGone = state is FileReady && !File(state.path).existsSync();
    if (copyGone) _release(had!);
    final kept =
        (state is FileReady && !copyGone) ||
        (state is FileFailed && (auto || _final.contains(state.reason))) ||
        (auto && state is FileGone);
    if (had != null && state != null && kept) {
      had.used = ++_clock;
      return Future.value(state);
    }
    // Every message that asked for it before still shows it.
    final entry = _files[place] = _Entry(++_serial, {...?had?.messages, messageId}, ++_clock, sealedSize(file.size));
    notifyListeners();
    final work = entry.work = _inPlace(entry, first: !auto).then((go) async {
      if (!go) return _settled(place, entry, _unavailable);
      try {
        return _settled(place, entry, await _opened(file, url, opener, entry, place));
      } catch (error) {
        final reason = error is FileError ? error.reason : FileFailure.download;
        // Counted as decryption failures are: a file the core didn't open, or opened to other bytes.
        if (reason == FileFailure.open || reason == FileFailure.hash) opener.failed();
        return _settled(place, entry, FileFailed(reason));
      } finally {
        _opening--;
        _openingBytes -= entry.bytes;
        _next();
      }
    });
    return work;
  }

  /// Every file of a message goes, its copy deleted, once no other message that asked for it is left: it was deleted.
  void forgetMessage(String messageId) {
    var any = false;
    for (final MapEntry(key: place, value: entry) in [..._files.entries]) {
      if (!entry.messages.remove(messageId) || entry.messages.isNotEmpty) continue;
      _release(entry);
      _files.remove(place);
      _waiting.remove(entry);
      // One that has its place and comes down settles as its work ends; only one still waiting gives its place up
      // (task 19's review, I2).
      if (entry.place case final place? when !place.isCompleted) place.complete(false);
      any = true;
    }
    if (any) notifyListeners();
  }

  /// A file downloaded, opened and checked, and its bytes copied into the folder, under a name of its place's alone.
  Future<FileReady> _opened(FileRef file, String url, FileOpener opener, _Entry entry, String place) async {
    final opened = await openSealed(
      file,
      download: (most, progress) => opener.download(file.id, url, most, progress),
      open: (key, id, sealed, progress) => opener.open(key, id, sealed, progress),
      progress: (share) {
        final now = entry.state;
        if (_files[place] != entry || (now is FileLoading && (now.progress * 100).floor() == (share * 100).floor())) {
          return;
        }
        entry.state = FileLoading(share);
        notifyListeners();
      },
    );
    final folder = await _folder();
    await folder.create(recursive: true);
    final copy = File('${folder.path}/${sha256.convert(utf8.encode('$place:${entry.serial}'))}');
    await copy.writeAsBytes(opened.bytes, flush: true);
    return FileReady(copy.path, opened.type, opened.bytes.length);
  }

  /// Its place among those that open files: at once while there's one and its bytes fit, or after those before it, a
  /// tap's before the views' asks.
  Future<bool> _inPlace(_Entry entry, {required bool first}) {
    final place = entry.place = Completer<bool>();
    first ? _waiting.insert(0, entry) : _waiting.add(entry);
    _next();
    return place.future;
  }

  /// The files that wait, in their order, as long as there's a place and their bytes fit: one past the budget alone.
  void _next() {
    while (_waiting.isNotEmpty &&
        _opening < openingMost &&
        (_opening == 0 || _openingBytes + _waiting.first.bytes <= inFlight)) {
      final entry = _waiting.removeAt(0);
      _opening++;
      _openingBytes += entry.bytes;
      entry.place?.complete(true);
    }
  }

  /// A tap on a file that waits for its place: it goes before the views' asks.
  void _first(_Entry entry) {
    final at = _waiting.indexOf(entry);
    if (at <= 0) return;
    _waiting
      ..removeAt(at)
      ..insert(0, entry);
    _next();
  }

  /// A file's work ended: kept, unless it was let go of meanwhile; a file kept past the limit lets others go.
  FileState _settled(String place, _Entry entry, FileState state) {
    entry.work = null;
    entry.place = null;
    if (_files[place] != entry) {
      if (state is FileReady) _deleteCopy(state.path);
      return state;
    }
    entry.state = state;
    if (state is FileReady) {
      _used += state.size;
      _makeRoom(place);
    }
    notifyListeners();
    return state;
  }

  /// Past the limit, the files drawn longest ago go, but [keep], which just came.
  void _makeRoom(String keep) {
    while (_used > limit) {
      _Entry? oldest;
      for (final MapEntry(key: place, value: entry) in _files.entries) {
        if (place == keep || entry.state is! FileReady) continue;
        if (oldest == null || entry.used < oldest.used) oldest = entry;
      }
      if (oldest == null) return;
      _release(oldest);
      oldest.state = const FileGone();
    }
  }

  void _release(_Entry entry) {
    final state = entry.state;
    if (state is! FileReady) return;
    _deleteCopy(state.path);
    _used -= state.size;
  }

  static void _deleteCopy(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException catch (error) {
      // Gone already (ENOENT): nothing to say.
      if (error.osError?.errorCode != 2) {
        debugPrint("e2e: a file's copy in the clear couldn't go: ${error.osError?.message}");
      }
    }
  }
}

/// How many times a download waits out the API's budget of bytes an IP downloads (a 429), and the longest wait.
const _budgetWaits = 3;
const _budgetWaitMost = Duration(minutes: 1);

/// How long a download waits for its first answer and for each next bytes: past the API's own 30 s for its storage's
/// first byte.
const _silence = Duration(seconds: 40);

/// The bytes at a signed URL, [most] of them at most (a RangeError past them), [progress] hearing how many came: with
/// none of the app's headers, as a redirect would carry them to the storage's host (#500's rule); the redirect itself
/// followed, as the app's HTTP client does. The API's budget of what an IP downloads (a 429) is waited out as its
/// Retry-After says, three times at most ([wait] stands in for the waiting); any other refusal is the API's word.
Future<Uint8List> downloadSigned(
  http.Client client,
  Uri url,
  int most, {
  void Function(int received)? progress,
  Future<void> Function(Duration wait)? wait,
}) async {
  for (var waited = 0; ; waited++) {
    final response = await client.send(http.Request('GET', url)).timeout(_silence);
    if (response.statusCode == 429 && waited < _budgetWaits) {
      // Its body isn't read: a storage that trickles one out would hold the file's place (task 19's review, M9).
      await response.stream.listen(null).cancel();
      final seconds = int.tryParse(response.headers['retry-after'] ?? '') ?? 1;
      final pause = Duration(seconds: seconds.clamp(1, _budgetWaitMost.inSeconds));
      await (wait == null ? Future<void>.delayed(pause) : wait(pause));
      continue;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.listen(null).cancel();
      throw duvet.DuvetApiException(
        action: 'download a file',
        statusCode: response.statusCode,
        reasonPhrase: response.reasonPhrase,
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(_silence)) {
      bytes.add(chunk);
      if (bytes.length > most) throw RangeError('the file is larger than $most bytes');
      progress?.call(bytes.length);
    }
    return bytes.takeBytes();
  }
}
