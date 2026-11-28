import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/decrypted_files.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/thumbnails.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/app_repository.dart';
import '../support/engines.dart';
import '../support/core_lib.dart';
import '../support/fake_api.dart';

// The files of conversations this device opened (PLAN-E2E-CLIENTES.md, «Adjuntos»; Ruling 19): decrypted into a folder
// of the app's own, e2e-media, 256 MiB of them at most, each copy deleted as its file goes, past the cap or with its
// message's deletion; a video whole before it plays; the folder emptied as the app's engine starts. The core and the
// API stand aside here: the opener hands back what a file opens to. The desktop's decrypted-files.test.ts, with the
// folder.

const _pngHead = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const _mp4Head = [0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d];

/// An opener whose downloads and opens a test can stand in for, counting what it's asked.
/// The file picker's platform, which deletes its copies' folder as Android's does (android_file_picker's clearCache).
class _ClearingPicker extends FilePickerPlatform {
  Directory? folder;
  var cleared = 0;

  @override
  Future<void> clearTemporaryFiles() async {
    cleared++;
    if (folder case final copies? when copies.existsSync()) copies.deleteSync(recursive: true);
  }
}

class _Opener implements FileOpener {
  /// What each file opens to, by ID.
  final plain = <String, Uint8List>{};
  final started = <String>[];
  var failures = 0;
  Future<Uint8List> Function(String url, int most, void Function(int)? progress)? downloads;
  Future<Uint8List> Function(String id, Uint8List sealed, void Function(int)? progress)? opens;

  @override
  Future<Uint8List> download(String id, String url, int most, void Function(int received)? progress) {
    started.add(url);
    return downloads?.call(url, most, progress) ?? Future.value(Uint8List(most));
  }

  @override
  Future<Uint8List> open(String key, String id, Uint8List sealed, void Function(int done)? progress) =>
      opens?.call(id, sealed, progress) ?? Future.value(plain[id]!);

  @override
  void failed() => failures++;
}

String _sha(List<int> bytes) => base64Encode(sha256.convert(bytes).bytes);

/// What one Share of a decrypted file leaves in the app's [temporary] folder: the app's own copy, set aside under
/// e2e-media's share, and share_plus's of it, in its own folder.
List<File> _shared(Directory temporary) => [
  for (final path in ['e2e-media/share/${uuidv4()}/photo.jpg', 'share_plus/photo.jpg'])
    File('${temporary.path}/$path')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]),
];

/// A folder of decrypted files on a temporary folder of its own, its opener, and files to open: [size] bytes, their
/// first ones [head] (a PNG's), at the API's signed URL of their ID.
({
  DecryptedFiles files,
  Directory folder,
  _Opener opener,
  ({FileRef file, String url}) Function(String, int, [List<int>]) fileOf,
})
_folder({int limit = maxDecrypted, int inFlight = openingBytesMost}) {
  final root = Directory.systemTemp.createTempSync('duvet-media-');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final folder = Directory('${root.path}/e2e-media');
  final files = DecryptedFiles(limit: limit, inFlight: inFlight, folder: () async => folder);
  final opener = _Opener();
  files.useOpener(opener);
  ({FileRef file, String url}) fileOf(String id, int size, [List<int> head = _pngHead]) {
    final bytes = Uint8List(size)..setAll(0, head);
    opener.plain[id] = bytes;
    return (
      file: FileRef(id: id, key: 'a2V5', sha256: _sha(bytes), size: size),
      url: '/attachments/$id?sig=test&exp=1',
    );
  }

  return (files: files, folder: folder, opener: opener, fileOf: fileOf);
}

/// The copies the folder holds now.
List<String> _copies(Directory folder) =>
    folder.existsSync() ? [for (final file in folder.listSync().whereType<File>()) file.uri.pathSegments.last] : [];

Future<void> _until(bool Function() holds) async {
  for (var i = 0; i < 400 && !holds(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(holds(), isTrue);
}

/// Ana's app and Bo's first device in their DM, its group made: Ana's app hears what [hears] lets through, and
/// [answers] answer routes the fake lacks.
Future<({TestApp app, TestDevice b, String conversation, ConversationTarget target, String ana})> _appAndBo({
  bool Function(GatewayEvent event)? hears,
  Map<String, Object?> answers = const {},
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadCore();
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final target = ConversationTarget(conversation);
  final app = await appOn(fake, ana, hears: hears, answers: answers);
  await app.ready();
  final b = await firstDevice(fake, bo);
  addTearDown(b.engine.stop);
  app.repository.chatShown(target);
  await until(() async => await groupOf(b, conversation) != null);
  return (app: app, b: b, conversation: conversation, target: target, ana: ana);
}

/// Bo's message with a picture, as Ana's app shows it, and the picture opened there.
Future<({String id, MessageAttachment file, FileReady ready})> _pictureFromBo(
  TestApp app,
  TestDevice b,
  String conversation,
  ConversationTarget target,
) async {
  final sent = (await b.engine.sendMessage(
    Outgoing(
      conversationId: conversation,
      nonce: uuidv4(),
      files: [
        FileToSeal(bytes: Uint8List.fromList([..._pngHead, 9, 9, 9]), name: 'plan.png'),
      ],
    ),
  ))!;
  MessageAttachment? file;
  await until(() async {
    final shown = (await app.repository.messages(target)).where((m) => m.id == sent.id).firstOrNull;
    file = shown?.attachments.where((a) => a.sealed != null && a.url.isNotEmpty).firstOrNull;
    return file != null;
  });
  final ready = await DecryptedFiles.instance.open(file!.sealed!, file!.url, sent.id);
  return (id: sent.id, file: file!, ready: ready as FileReady);
}

void main() {
  test("decrypted_files_leave_the_folder_past_the_cap,_and_with_their_message's_deletion", () async {
    expect(maxDecrypted, 256 << 20);
    final (:files, :folder, opener: _, :fileOf) = _folder(limit: 1000);
    final (one, two, three) = (fileOf('1', 400), fileOf('2', 400), fileOf('3', 400));
    await files.open(one.file, one.url, 'm1');
    await files.open(two.file, two.url, 'm1');
    expect(files.used, 800);
    expect(_copies(folder), hasLength(2));
    // A third past the cap: the file drawn longest ago goes, its copy deleted.
    await files.open(three.file, three.url, 'm2');
    expect(files.used, 800);
    expect(files.state(one.file, one.url), isA<FileGone>());
    final ready = files.state(two.file, two.url)! as FileReady;
    expect(File(ready.path).readAsBytesSync(), hasLength(400));
    expect(_copies(folder), hasLength(2));
    // It isn't fetched again by itself, as the view that asked for it may still show it: a tap does.
    await files.open(one.file, one.url, 'm1', auto: true);
    expect(files.state(one.file, one.url), isA<FileGone>());
    // Its message deleted, a file goes at once, its copy with it.
    files.forgetMessage('m1');
    expect(files.state(two.file, two.url), isNull);
    expect(files.state(one.file, one.url), isNull);
    expect(File(ready.path).existsSync(), isFalse);
    expect(files.used, 400);
    expect(_copies(folder), hasLength(1));
    // Every one goes as the engine stops: nothing decrypted stays.
    files.useOpener(null);
    await _until(() => _copies(folder).isEmpty);
    expect(files.used, 0);
  });

  test('a_video_is_downloaded_whole,_with_its_progress,_before_it_plays', () async {
    final (:files, folder: _, :opener, :fileOf) = _folder();
    final video = fileOf('v', 300000, _mp4Head);
    final seen = <FileState?>[];
    opener.downloads = (url, most, progress) async {
      for (final share in [0.25, 0.5, 0.75, 1.0]) {
        progress?.call((most * share).floor());
        seen.add(files.state(video.file, video.url));
      }
      return Uint8List(most);
    };
    opener.opens = (id, sealed, progress) async {
      expect(sealed.length, sealedSize(300000));
      progress?.call(300000);
      seen.add(files.state(video.file, video.url));
      return opener.plain[id]!;
    };
    final done = await files.open(video.file, video.url, 'm');
    // While it came, and while the core opened it, it was loading, and further along each time; playable only after.
    expect(seen, everyElement(isA<FileLoading>()));
    final shares = [for (final state in seen) (state! as FileLoading).progress];
    expect(shares, [...shares]..sort());
    expect(shares, everyElement(allOf(greaterThan(0), lessThanOrEqualTo(1))));
    expect(done, isA<FileReady>().having((r) => r.type, 'type', 'video/mp4').having((r) => r.size, 'size', 300000));
  });

  test("a_file_that_doesn't_open,_or_whose_bytes_differ,_is_a_failure_kept_with_its_reason", () async {
    final (:files, :folder, opener: _, :fileOf) = _folder();
    final file = fileOf('x', 100);
    final lied = FileRef(id: 'x', key: 'a2V5', sha256: _sha(Uint8List(100)..fillRange(0, 100, 7)), size: 100);
    expect(
      await files.open(lied, file.url, 'm'),
      isA<FileFailed>().having((f) => f.reason, 'reason', FileFailure.hash),
    );
    expect(_copies(folder), isEmpty);
    final nowhere = fileOf('y', 100);
    expect(
      await files.open(nowhere.file, null, 'm'),
      isA<FileFailed>().having((f) => f.reason, 'reason', FileFailure.unavailable),
    );
  });

  // Review Focus 7: nothing of the sender's names the copy.
  test("a_decrypted_file's_copy_is_named_by_its_place,_never_by_its_sender", () async {
    final (:files, :folder, opener: _, :fileOf) = _folder();
    final file = fileOf('../../../escape', 100);
    final ready = (await files.open(file.file, file.url, 'm')) as FileReady;
    expect(File(ready.path).parent.path, folder.path);
    expect(_copies(folder).single, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  // Task 18's review, I1: any member can write another's file ID in an envelope.
  test("two_messages_naming_one_ID_never_show_or_block_each_other's_file", () async {
    final (:files, :folder, opener: _, :fileOf) = _folder();
    final real = fileOf('x', 100);
    // Another message names its ID with other bytes: the API lists the file on its own message alone, so for this one
    // it's unavailable, and that says nothing of the first's.
    final named = FileRef(id: 'x', key: 'b3RoZXI=', sha256: _sha(Uint8List(100)..fillRange(0, 100, 1)), size: 100);
    expect((await files.open(named, null, 'm2') as FileFailed).reason, FileFailure.unavailable);
    expect((files.state(named, null)! as FileFailed).reason, FileFailure.unavailable);
    expect(files.state(real.file, real.url), isNull);
    // Even with a URL, other bytes fail on their own: the real file still opens.
    expect((await files.open(named, real.url, 'm2') as FileFailed).reason, FileFailure.hash);
    expect(await files.open(real.file, real.url, 'm1', auto: true), isA<FileReady>());
    expect((files.state(named, real.url)! as FileFailed).reason, FileFailure.hash);
    // The other message's deletion takes nothing of the first's.
    files.forgetMessage('m2');
    expect(files.state(real.file, real.url), isA<FileReady>());
    expect(_copies(folder), hasLength(1));
  });

  // Task 18's review, I4: only a hash, size or open failure is final.
  test('a_download_that_fails_is_asked_again_on_a_tap,_and_only_what_its_bytes_are_is_final', () async {
    final (:files, folder: _, :opener, :fileOf) = _folder();
    final file = fileOf('d', 100);
    var downloads = 0;
    var lost = true;
    opener.downloads = (url, most, progress) async {
      downloads++;
      if (lost) throw const SocketException('offline');
      return Uint8List(most);
    };
    FileFailure? reasonOf(FileState state) => state is FileFailed ? state.reason : null;
    expect(reasonOf(await files.open(file.file, file.url, 'm', auto: true)), FileFailure.download);
    // A view's own ask doesn't fetch it again; a tap does.
    expect(reasonOf(await files.open(file.file, file.url, 'm', auto: true)), FileFailure.download);
    expect(downloads, 1);
    lost = false;
    expect(await files.open(file.file, file.url, 'm'), isA<FileReady>());
    expect(downloads, 2);
    // Other bytes than its message says: final, a tap changes nothing.
    final lied = fileOf('e', 100);
    final other = FileRef(id: 'e', key: 'a2V5', sha256: _sha(Uint8List(100)..fillRange(0, 100, 7)), size: 100);
    expect(reasonOf(await files.open(other, lied.url, 'm')), FileFailure.hash);
    expect(reasonOf(await files.open(other, lied.url, 'm')), FileFailure.hash);
    expect(downloads, 3);
    // The core's refusal is final; an open that didn't reach it (no engine now) isn't.
    final refused = fileOf('f', 100);
    opener.opens = (id, sealed, progress) async => throw CoreError('decrypt_failed');
    expect(reasonOf(await files.open(refused.file, refused.url, 'm')), FileFailure.open);
    expect(reasonOf(await files.open(refused.file, refused.url, 'm')), FileFailure.open);
    final unready = fileOf('g', 100);
    opener.opens = (id, sealed, progress) async => throw StateError("encrypted conversations aren't ready here");
    expect(reasonOf(await files.open(unready.file, unready.url, 'm')), FileFailure.download);
    opener.opens = null;
    expect(await files.open(unready.file, unready.url, 'm'), isA<FileReady>());
  });

  // Task 18's review, I5: each file holds its sealed bytes about three times over while it comes down.
  test("four_files_come_down_at_once,_a_tap's_first", () async {
    final (:files, folder: _, :opener, :fileOf) = _folder();
    final gates = <String, Completer<void>>{};
    opener.downloads = (url, most, progress) async {
      await (gates[url] = Completer<void>()).future;
      return Uint8List(most);
    };
    final all = [
      for (final id in ['1', '2', '3', '4', '5', '6']) fileOf(id, 100),
    ];
    final opening = [for (final f in all) files.open(f.file, f.url, 'm', auto: true)];
    expect(openingMost, 4);
    await _until(() => opener.started.length == 4);
    expect(opener.started, [for (final f in all.take(4)) f.url]);
    // A tap on the last: it goes before the fifth, a view's own ask.
    final tapped = files.open(all[5].file, all[5].url, 'm');
    gates[all[0].url]!.complete();
    await _until(() => opener.started.length == 5);
    expect(opener.started[4], all[5].url);
    for (final f in all) {
      if (gates[f.url] case final gate? when !gate.isCompleted) gate.complete();
    }
    await _until(() => opener.started.length == 6);
    gates[all[4].url]!.complete();
    expect([
      ...await Future.wait([...opening, tapped]),
    ], everyElement(isA<FileReady>()));
  });

  // Task 19's review, I2: a file that waited for its place has it now; its message's deletion lets it go, and the
  // message's other files with it.
  test("a_file_coming_down_after_it_waited_for_its_place_goes_with_its_message's_deletion", () async {
    final (:files, :folder, :opener, :fileOf) = _folder();
    final gates = <String, Completer<void>>{};
    opener.downloads = (url, most, progress) async {
      await (gates[url] = Completer<void>()).future;
      return Uint8List(most);
    };
    final all = [
      for (final id in ['1', '2', '3', '4', '5', '6']) fileOf(id, 100),
    ];
    // The fifth and the sixth are the same message's.
    final opening = [for (final (i, f) in all.indexed) files.open(f.file, f.url, i < 4 ? 'm$i' : 'last', auto: true)];
    await _until(() => opener.started.length == 4);
    gates[all[0].url]!.complete();
    // The fifth has its place, and comes down.
    await _until(() => opener.started.length == 5);
    expect(() => files.forgetMessage('last'), returnsNormally);
    expect(files.state(all[4].file, all[4].url), isNull);
    expect(files.state(all[5].file, all[5].url), isNull);
    gates[all[4].url]!.complete();
    await opening[4];
    expect(_copies(folder), hasLength(1));
    // The rest come down in the places left.
    for (final f in all.take(4)) {
      if (gates[f.url] case final gate? when !gate.isCompleted) gate.complete();
    }
    await Future.wait(opening.take(4));
    expect(_copies(folder), hasLength(4));
  });

  // Task 19's review, M6: Android clears its cache under storage pressure, the copies with it.
  test('a_copy_the_system_deleted_is_opened_again', () async {
    final (:files, folder: _, :opener, :fileOf) = _folder();
    final f = fileOf('1', 100);
    final ready = await files.open(f.file, f.url, 'm', auto: true) as FileReady;
    File(ready.path).deleteSync();
    final again = await files.open(f.file, f.url, 'm', auto: true);
    expect(again, isA<FileReady>());
    expect(File((again as FileReady).path).existsSync(), isTrue);
    expect(opener.started, hasLength(2));
    expect(files.used, 100);
  });

  // Task 19's review, M7: each file in flight holds its sealed bytes a few times over, so they go within a budget
  // beside the count; one past it goes alone.
  test('files_come_down_within_a_budget_of_sealed_bytes,_and_one_past_it_alone', () async {
    final (:files, folder: _, :opener, :fileOf) = _folder(inFlight: 2 * sealedSize(100));
    final gates = <String, Completer<void>>{};
    opener.downloads = (url, most, progress) async {
      await (gates[url] = Completer<void>()).future;
      return Uint8List(most);
    };
    final small = [
      for (final id in ['1', '2', '3']) fileOf(id, 100),
    ];
    final large = fileOf('4', 1000);
    final opening = [
      for (final f in [...small, large]) files.open(f.file, f.url, 'm', auto: true),
    ];
    await _until(() => opener.started.length == 2);
    await pumpEventQueue();
    expect(opener.started, [small[0].url, small[1].url]);
    gates[small[0].url]!.complete();
    await _until(() => opener.started.length == 3);
    gates[small[1].url]!.complete();
    gates[small[2].url]!.complete();
    // Past the budget alone: it goes once nothing else comes down.
    await _until(() => opener.started.length == 4);
    gates[large.url]!.complete();
    expect(await Future.wait(opening), everyElement(isA<FileReady>()));
  });

  // Task 19's review, M9: the download's 40 s of silence don't cover an error's body.
  test("an_error_answer's_body_isn't_read:_a_storage_that_trickles_one_holds_no_place", () async {
    var asked = 0;
    final client = MockClient.streaming((request, _) async {
      asked++;
      final trickle = StreamController<List<int>>()..add([1]);
      if (asked == 1) return http.StreamedResponse(trickle.stream, 429, headers: {'retry-after': '1'});
      if (asked == 2) return http.StreamedResponse(Stream.value([1, 2, 3]), 200);
      return http.StreamedResponse(trickle.stream, 500);
    });
    final url = Uri.parse('https://api.duvet.test/attachments/x');
    // A 429 whose body never ends is waited out, and the next answer read.
    expect(await downloadSigned(client, url, 10, wait: (_) async {}).timeout(const Duration(seconds: 5)), [1, 2, 3]);
    // A refusal whose body never ends is the API's word at once.
    await expectLater(
      downloadSigned(client, url, 10).timeout(const Duration(seconds: 5)),
      throwsA(isA<duvet.DuvetApiException>()),
    );
  });

  // Task 18's review, Missing 2: decision 40 counts them, under the kind attachment.
  test("a_file_that_doesn't_open,_or_opens_to_other_bytes,_is_counted;_one_that_doesn't_come_down_isn't", () async {
    final (:files, folder: _, :opener, :fileOf) = _folder();
    final file = fileOf('c', 100);
    await files.open(
      FileRef(id: 'c', key: 'a2V5', sha256: _sha(Uint8List(100)..fillRange(0, 100, 9)), size: 100),
      file.url,
      'm',
    );
    expect(opener.failures, 1);
    final unopened = fileOf('o', 100);
    opener.opens = (id, sealed, progress) async => throw CoreError('decrypt_failed');
    await files.open(unopened.file, unopened.url, 'm');
    expect(opener.failures, 2);
    opener
      ..opens = null
      ..downloads = (url, most, progress) async => throw const SocketException('offline');
    final offline = fileOf('n', 100);
    await files.open(offline.file, offline.url, 'm');
    final huge = fileOf('s', 100);
    await files.open(FileRef(id: 's', key: 'a2V5', sha256: huge.file.sha256, size: 40 << 20), huge.url, 'm');
    await files.open(fileOf('u', 100).file, null, 'm');
    expect(opener.failures, 2);
  });

  test('the_temporary_folder_is_emptied_at_start', () async {
    final (:files, :folder, opener: _, fileOf: _) = _folder();
    // What an app that closed left there: a copy, and a folder.
    folder.createSync(recursive: true);
    File('${folder.path}/${'a' * 64}').writeAsBytesSync([1, 2, 3]);
    Directory('${folder.path}/left').createSync();
    await files.emptyAtStart();
    expect(folder.existsSync() ? folder.listSync() : const <FileSystemEntity>[], isEmpty);
  });

  test(
    "the_app's_engine_empties_the_temporary_folder_as_it_starts",
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadCore();
      final fake = FakeApi();
      final ana = fake.addUser();
      final left = <File>[];
      final app = await appOn(
        fake,
        ana,
        prepare: (support) {
          final media = Directory('${support.path}/e2e-media')..createSync(recursive: true);
          left.add(File('${media.path}/${'b' * 64}')..writeAsBytesSync(List.filled(10, 7)));
        },
      );
      await app.ready();
      expect(left.single.existsSync(), isFalse);
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Step 5's review, I1 (mobile#365): what a send left under the app's cache folder when the app ended before it
  // settled goes as the app's engine starts. A picked file moved in among the decrypted files, file_picker's copies
  // (its clearTemporaryFiles, which deletes its folder on Android), and a voice note a kill cut short; nothing else.
  test(
    "what_a_send_left_in_the_cache_goes_as_the_app's_engine_starts",
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadCore();
      final picker = _ClearingPicker();
      final before = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = before);
      final fake = FakeApi();
      final ana = fake.addUser();
      final left = <File>[];
      late File kept;
      final app = await appOn(
        fake,
        ana,
        prepare: (cache) {
          picker.folder = Directory('${cache.path}/file_picker');
          for (final path in [
            'e2e-media/picked/${uuidv4()}/scaled_photo.jpg',
            'file_picker/${uuidv4()}/notes.pdf',
            'voice-1764000000000.ogg',
            'voice-1764000000001.m4a',
          ]) {
            left.add(File('${cache.path}/$path')..createSync(recursive: true));
          }
          kept = File('${cache.path}/kept.ogg')..createSync();
        },
      );
      await app.ready();
      expect(left.where((file) => file.existsSync()), isEmpty);
      expect(picker.cleared, 1);
      expect(kept.existsSync(), isTrue);
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // mobile#365: file_picker hands over a picked file's canonical path, which path_provider's name of the cache folder
  // may not be (Android's /data/user/0 leads to /data/data). A file outside the cache folder is the person's own:
  // never moved, never deleted. Before the start learns the cache folder, nothing is taken in.
  test("a_picked_file_is_taken_in_under_either_path_of_the_cache,_and_the_person's_own_stays", () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final root = Directory.systemTemp.createTempSync('duvet-cache-');
    addTearDown(() => root.deleteSync(recursive: true));
    final real = Directory('${root.path}/real')..createSync();
    final cache = Link('${root.path}/cache')..createSync(real.path);
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => cache.path);
    addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
    final files = DecryptedFiles();
    // As file_picker names it: canonical, every link resolved (macOS's /var leads to /private/var too).
    final picked = File('${real.resolveSymbolicLinksSync()}/file_picker/${uuidv4()}/notes.pdf')
      ..createSync(recursive: true);
    final own = File('${root.path}/notes.pdf')..createSync();
    expect(await files.takeIn(picked.path), picked.path);

    await files.emptyAtStart();
    final moved = await files.takeIn(picked.path);
    expect(moved, startsWith('${cache.path}/e2e-media/picked/'));
    expect(picked.existsSync(), isFalse);
    expect(await files.takeIn(own.path), own.path);
    files.letGo([moved, own.path]);
    expect(File(moved).existsSync(), isFalse);
    expect(own.existsSync(), isTrue);
  });

  // Step 5's review, I3 (mobile#354): a Share leaves two plaintext copies of the file, the app's own under e2e-media's
  // share and share_plus's under <temporary>/share_plus, which nothing of the app's deleted and a sign-out left.
  test(
    "a_shared_file's_copies_go_as_the_app's_engine_starts_and_at_a_sign-out",
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadCore();
      final fake = FakeApi();
      final ana = fake.addUser();
      final copies = <File>[];
      final app = await appOn(fake, ana, prepare: (support) => copies.addAll(_shared(support)));
      await app.ready();
      expect(copies.where((copy) => copy.existsSync()), isEmpty);
      copies.addAll(_shared(app.support));
      await app.repository.logOut();
      expect(copies.where((copy) => copy.existsSync()), isEmpty);
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    "a_shared_file's_copies_go_with_this_device's_data",
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadCore();
      final fake = FakeApi();
      final ana = fake.addUser();
      final app = await appOn(fake, ana);
      await app.ready();
      final copies = _shared(app.support);
      await app.repository.removeThisDevice();
      expect(copies.where((copy) => copy.existsSync()), isEmpty);
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Ruling 31: the API knows an encrypted file as `file`; only a message this device holds names it.
  test(
    "the_person's_attachments_name_an_encrypted_file_from_this_device's_own_messages",
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await loadCore();
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final target = ConversationTarget(conversation);
      final app = await appOn(fake, ana);
      await app.ready();
      final b = await firstDevice(fake, bo);
      app.repository.chatShown(target);
      await until(() async => await groupOf(b, conversation) != null);
      final picked = Directory.systemTemp.createTempSync('duvet-picked-');
      addTearDown(() => picked.deleteSync(recursive: true));
      OutgoingFile pick(String name, List<int> bytes) {
        final file = File('${picked.path}/$name')..writeAsBytesSync(bytes);
        return OutgoingFile(path: file.path, name: name, contentType: 'image/png', sizeBytes: bytes.length);
      }

      await app.repository.send(
        target,
        '',
        nonce: uuidv4(),
        files: [
          pick('plan.png', [..._pngHead, 1, 2, 3]),
        ],
      );
      // One whose message never went, dismissed: its file is up, on no message this device holds.
      fake.cutAfterFiles((method: 'POST', path: '/api/users/@me/conversations/$conversation/messages'));
      final lost = uuidv4();
      await expectLater(
        app.repository.send(
          target,
          '',
          nonce: lost,
          files: [
            pick('lost.png', [..._pngHead, 4, 5, 6]),
          ],
        ),
        throwsA(anything),
      );
      await app.repository.discard(target, lost);
      final files = await app.repository.myFiles();
      expect([for (final f in files) f.name]..sort(), ['plan.png', Notice.fileEncrypted.text]..sort());
      // Nothing previews or downloads their sealed bytes.
      expect([for (final f in files) (f.contentType, f.url)], everyElement(('application/octet-stream', '')));
      await b.engine.stop();
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Task 19's review, M10: the app's own wiring of a deletion to the folder, each way the engine learns of one.
  test(
    'a_message_the_gateway_says_is_deleted_lets_its_files_go_at_once',
    () async {
      GatewayEvent? deletion;
      final (:app, :b, :conversation, :target, :ana) = await _appAndBo(
        hears: (event) {
          if (event.type != 'DM_MESSAGE_DELETE') return true;
          deletion = event;
          return false;
        },
      );
      final (:id, :file, :ready) = await _pictureFromBo(app, b, conversation, target);
      await b.engine.deleteMessage(conversation, id);
      await until(() => deletion != null);
      app.repository.handleEvent(payloadOf(deletion!, ana)!);
      // At once, as the chat drops its row: the engine's turn, which applies the tombstone, hasn't come yet.
      expect(DecryptedFiles.instance.state(file.sealed!, file.url), isNull);
      expect(File(ready.path).existsSync(), isFalse);
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a_message_the_queue_says_is_deleted_lets_its_files_go',
    () async {
      // Its event lost: only the queue's tombstone tells of it.
      final (:app, :b, :conversation, :target, ana: _) = await _appAndBo(
        hears: (event) => event.type != 'DM_MESSAGE_DELETE',
      );
      final (:id, :file, :ready) = await _pictureFromBo(app, b, conversation, target);
      await b.engine.deleteMessage(conversation, id);
      // The next message has the engine read the queue up to it, the tombstone included.
      await b.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'and another'));
      await until(() => !File(ready.path).existsSync());
      expect(DecryptedFiles.instance.state(file.sealed!, file.url), isNull);
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    "a_file_over_the_active_bucket's_limit_once_sealed_is_refused_before_it_goes",
    () async {
      final at = DateTime.now().toUtc().toIso8601String();
      final (:app, b: _, :conversation, :target, ana: _) = await _appAndBo(
        answers: {
          // The storage takes 1 MiB a file; the bucket files go to, 2000 bytes.
          'GET /api/users/@me/storage': {
            'used_bytes': 0,
            'max_bytes': 1 << 30,
            'upload_limit_bytes': 1 << 20,
            'percentage_used': 0,
          },
          'GET /api/users/@me/buckets': [
            {
              'id': uuidv4(),
              'owner_id': uuidv4(),
              'name': 'mine',
              'endpoint': 'https://s3.duvet.test',
              'bucket_name': 'files',
              'access_key_id': 'key',
              'is_active': true,
              'upload_limit_bytes': 2000,
              'created_at': at,
              'updated_at': at,
            },
          ],
        },
      );
      final picked = Directory.systemTemp.createTempSync('duvet-picked-');
      addTearDown(() => picked.deleteSync(recursive: true));
      final file = File('${picked.path}/big.png')..writeAsBytesSync([..._pngHead, ...List.filled(1990, 0)]);
      final from = app.seen.length;
      await expectLater(
        app.repository.send(
          target,
          '',
          nonce: uuidv4(),
          files: [OutgoingFile(path: file.path, name: 'big.png', contentType: 'image/png', sizeBytes: 1998)],
        ),
        throwsA(isA<UploadTooLarge>()),
      );
      expect(app.count('POST', '/api/users/@me/conversations/$conversation/messages', from: from), 0);
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Task 19's review, M11: video_player reads a video's size and length, which its message carries as the desktop's
  // does; a frame of it would take a frame grabber.
  test(
    "a_video's_size_and_length_go_with_it",
    () async {
      final was = videoFactsOf;
      videoFactsOf = (_) async => (width: 1280, height: 720, durationMs: 4200);
      addTearDown(() => videoFactsOf = was);
      final (:app, :b, :conversation, :target, ana: _) = await _appAndBo();
      final picked = Directory.systemTemp.createTempSync('duvet-picked-');
      addTearDown(() => picked.deleteSync(recursive: true));
      final file = File('${picked.path}/clip.mp4')..writeAsBytesSync([..._mp4Head, ...List.filled(200, 0)]);
      final sent = await app.repository.send(
        target,
        '',
        nonce: uuidv4(),
        files: [OutgoingFile(path: file.path, name: 'clip.mp4', contentType: 'video/mp4', sizeBytes: 212)],
      );
      late ShownFile shown;
      await until(() async {
        final row = (await b.engine.messages(conversation, [sent.id])).firstOrNull;
        if (row?.status != MessageStatus.ok) return false;
        shown = shownFile(row!.attachments.single)!;
        return true;
      });
      expect((shown.width, shown.height, shown.durationMs), (1280, 720, 4200));
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // The ruled downloads: from the signed URL with none of the app's headers, the API's budget's 429 waited out.
  test("a_download_refused_by_the_API's_budget_waits_for_its_Retry-After", () async {
    final asked = <http.Request>[];
    final sealed = Uint8List.fromList(List.generate(300, (i) => i % 251));
    var refusals = 1;
    final client = MockClient((request) async {
      asked.add(request);
      if (refusals-- > 0) return http.Response('{"error":"too many bytes"}', 429, headers: {'retry-after': '1'});
      return http.Response.bytes(sealed, 200);
    });
    final waits = <Duration>[];
    final url = Uri.parse('https://api.duvet.test/attachments/x?sig=s&exp=1');
    final received = <int>[];
    final bytes = await downloadSigned(
      client,
      url,
      1000,
      progress: received.add,
      wait: (wait) async => waits.add(wait),
    );
    expect(bytes, sealed);
    expect(waits, [const Duration(seconds: 1)]);
    expect(received.last, sealed.length);
    // None of the app's headers go: no session, no client, no cookie.
    expect([for (final request in asked) request.url], [url, url]);
    for (final request in asked) {
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains(anyOf('authorization', 'x-session-token', 'x-duvet-client', 'cookie'))),
      );
    }
    // A file past what it may be is cut where it passes it.
    expect(
      () => downloadSigned(MockClient((_) async => http.Response.bytes(Uint8List(2000), 200)), url, 1000),
      throwsA(isA<RangeError>()),
    );
    // Refusals past its waits, and any other, are the API's word.
    expect(
      () => downloadSigned(
        MockClient((_) async => http.Response('', 429, headers: {'retry-after': '1'})),
        url,
        1000,
        wait: (_) async {},
      ),
      throwsA(isA<duvet.DuvetApiException>().having((e) => e.statusCode, 'status', 429)),
    );
  });
}
