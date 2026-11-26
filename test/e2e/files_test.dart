import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';
import '../support/multipart.dart';

// A conversation's files (PLAN-E2E-CLIENTES.md, «Adjuntos», and its conventions between clients): each sealed by the
// core with a key and an ID of its own, sent with that ID, and opened by the other device from the API's signed URL,
// its bytes checked against what the message says of them. What a sender writes of a file is theirs: a name with a
// path, a type it isn't, a size it doesn't have. Ana's and Bo's devices, in a DM whose group Ana made. The desktop's
// engine/files.test.ts, case for case, with task 18's review's rules.
const _slow = Timeout(Duration(minutes: 3));

String _messagesPath(String conversation) => '/api/users/@me/conversations/$conversation/messages';

/// A message's request held where it's about to reach the API: [held] completes as it's held, and it goes on (or,
/// [drop]ped, never reaches the API) once [release] completes; with a [nonce], the request of that message alone.
class _Hold {
  _Hold({this.nonce});
  final String? nonce;
  final held = Completer<void>();
  final release = Completer<void>();
  var drop = false;
}

/// Ana's and Bo's first devices in their DM (Ana's hearing what [aHears] lets through), every request Ana's device
/// made, and the hold of her next message's request ([holdNext], none by default).
Future<
  ({
    FakeApi fake,
    TestDevice a,
    TestDevice b,
    String conversation,
    List<http.Request> seen,
    http.Client aClient,
    void Function(_Hold? hold) holdNext,
  })
>
_dm({bool Function(GatewayEvent event)? aHears}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final seen = <http.Request>[];
  _Hold? hold;
  final aClient = watchedClient(
    fake,
    seen: seen.add,
    answer: (request) async {
      final holding = hold;
      if (holding == null || request.method != 'POST' || request.url.path != _messagesPath(conversation)) return null;
      if (holding.nonce case final nonce? when !latin1.decode(request.bodyBytes).contains(nonce)) return null;
      hold = null;
      holding.held.complete();
      await holding.release.future;
      return holding.drop ? http.Response('{"error":"never reached the API"}', 400) : null;
    },
  );
  final a = await firstDevice(fake, ana, client: aClient, hears: aHears);
  final b = await firstDevice(fake, bo);
  await a.engine.openConversation(conversation);
  await sameGroup([a, b], conversation);
  return (
    fake: fake,
    a: a,
    b: b,
    conversation: conversation,
    seen: seen,
    aClient: aClient,
    holdNext: (_Hold? next) => hold = next,
  );
}

/// The message posts Ana's device made to the conversation that were forms: each one's values and files.
List<({Map<String, List<String>> values, List<FormPart> files})> _forms(List<http.Request> seen, String conversation) =>
    [
      for (final request in seen)
        if (request.method == 'POST' && request.url.path == _messagesPath(conversation))
          if (formParts(request.headers['content-type'], request.bodyBytes) case final parts?) formOf(parts),
    ];

final _random = Random.secure();
Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

/// Bytes a client reads as a PNG, a JPEG, a GIF or an Ogg: their signature, then anything.
Uint8List _withHead(List<int> head, int n) => Uint8List.fromList([...head, ..._bytes(n - head.length)]);
Uint8List _png(int n) => _withHead(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], n);
Uint8List _jpeg(int n) => _withHead(const [0xff, 0xd8, 0xff], n);
Uint8List _gif(int n) => _withHead(ascii.encode('GIF89a'), n);
Uint8List _ogg(int n) => _withHead(ascii.encode('OggS'), n);

/// Whether [bytes] hold [part] anywhere.
bool _holds(Uint8List bytes, List<int> part) {
  outer:
  for (var at = 0; at + part.length <= bytes.length; at++) {
    for (var i = 0; i < part.length; i++) {
      if (bytes[at + i] != part[i]) continue outer;
    }
    return true;
  }
  return false;
}

/// The device's files of a message, once its core holds the message, as a view reads them.
Future<List<ShownFile>> _filesOn(TestDevice device, String conversation, String id) async {
  var files = <ShownFile>[];
  await until(() async {
    final row = (await device.engine.messages(conversation, [id])).firstOrNull;
    if (row?.status != MessageStatus.ok) return false;
    files = [for (final raw in row!.attachments) ?shownFile(raw)];
    return true;
  });
  return files;
}

/// How a device downloads a file the API keeps at [url]: with none of the app's headers, [most] bytes at most.
FileDownload _download(TestDevice device, String? url) => (most, progress) async {
  if (url == null) throw StateError('the API names no such file');
  return device.api.signedFile(
    url,
    onProgress: (received, _) {
      if (received > most) throw RangeError('the file is larger than $most bytes');
      progress?.call(received);
    },
  );
};

/// How a device's core opens a file.
FileOpen _open(TestDevice device) =>
    (key, id, sealed, progress) => device.engine.openFile(key, id, sealed, progress: progress);

String? _urlOf(duvet.DirectMessage message, String id) =>
    message.attachments?.where((a) => a.id == id).firstOrNull?.url;

/// The IDs of the conversation's messages the API holds, as a device reads its queue.
Future<List<String>> _posted(TestDevice device, String conversation) async => [
  for (final entry in (await device.api.queue(conversation, 0)).entries)
    if (entry.kind == 'message') entry.messageId!,
];

/// Fails unless [future] fails; gives what it failed with.
Future<Object> _refused(Future<Object?> future) async {
  try {
    await future;
  } catch (error) {
    return error;
  }
  fail('it was taken');
}

/// A file as another client could send it, its envelope written by hand: the core seals it and encrypts what it's
/// told, and nothing checks what the sender says of it. Sent beside Ana's engine, which is idle.
Future<duvet.DirectMessage> _sendWritten(
  TestDevice device,
  String conversation,
  List<({Uint8List bytes, Map<String, Object?> said})> files,
) async {
  final attachments = <Map<String, Object?>>[];
  final sealed = <Uint8List>[];
  for (final (:bytes, :said) in files) {
    final key = (await device.host.handle<Map<String, Object?>>({'cmd': 'attachment_key'}))['key']! as String;
    final id = uuidv7();
    sealed.add(await device.host.sealFile(key, id, bytes));
    attachments.add({
      'id': id,
      'key': key,
      'sha256': base64Encode(sha256.convert(bytes).bytes),
      'name': 'file',
      'type': 'application/octet-stream',
      'size': bytes.length,
      ...said,
    });
  }
  final nonce = uuidv4();
  final made = await device.host.handle<Map<String, Object?>>({
    'cmd': 'encrypt',
    'conversation_id': conversation,
    'nonce': nonce,
    'envelope': {'attachments': attachments},
  });
  final message = await device.api.sendMessage(
    conversation,
    duvet.EncryptedMessage(
      ciphertext: made['ciphertext']! as String,
      nonce: nonce,
      attachmentIds: [for (final a in attachments) a['id']! as String],
    ),
    files: sealed,
  );
  await device.host.handle<Object?>({
    'cmd': 'sent',
    'conversation_id': conversation,
    'nonce': nonce,
    'message_id': message.id,
    'seq': message.seq,
  });
  return message;
}

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'a_file_is_sealed,_sent_with_its_id,_and_opened_by_the_other_device',
    () async {
      final (:fake, :a, :b, :conversation, :seen, aClient: _, holdNext: _) = await _dm();
      final picture = _png(70000);
      final progress = <(int, int)>[];
      final sent = (await a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          text: 'a picture',
          files: [FileToSeal(bytes: picture, name: 'cat.png', width: 640, height: 480)],
        ),
        onProgress: (done, total) => progress.add((done, total)),
      ))!;
      // The API took one file, under the ID the envelope names: the sealed bytes, as a file it can't open.
      final [file] = await _filesOn(b, conversation, sent.id);
      expect((file.name, file.said, file.size, file.width, file.height), ('cat.png', 'image/png', 70000, 640, 480));
      expect(
        [for (final at in sent.attachments!) (at.id, at.filename, at.contentType, at.sizeBytes)],
        [(file.id, 'file', 'application/octet-stream', sealedSize(70000))],
      );
      final kept = fake.fileBytes(file.id)!;
      expect(kept.length, sealedSize(picture.length));
      expect(_holds(kept, picture.sublist(8, 64)), isFalse);
      // It went in a form, its ID beside it; its part names nothing of the file, and the bar measured what went up.
      final [form] = _forms(seen, conversation);
      expect(form.values['attachment_ids'], [file.id]);
      expect(
        [for (final part in form.files) (part.name, part.filename, part.bytes.length)],
        [('files', 'file', sealedSize(picture.length))],
      );
      expect(progress.last.$1, progress.last.$2);
      expect(progress.last.$2, greaterThan(sealedSize(picture.length)));
      expect(seen.any((request) => latin1.decode(request.bodyBytes).contains('cat.png')), isFalse);

      // Bo's device downloads it from its signed URL, and its core opens it: the picture, typed by its bytes.
      final opened = await openSealed(file, download: _download(b, _urlOf(sent, file.id)), open: _open(b));
      expect(opened.bytes, picture);
      expect(opened.type, 'image/png');
      expect(drawnBy(opened.type), DrawnIn.image);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_thumbnail_of_8_KiB_or_less_rides_in_the_message;_a_larger_one_is_a_file_of_its_own',
    () async {
      final (fake: _, :a, :b, :conversation, :seen, aClient: _, holdNext: _) = await _dm();
      final (small, large) = (_jpeg(4 << 10), _jpeg(20 << 10));
      final sent = (await a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [
            FileToSeal(bytes: _png(1000), name: 'a.png', thumbnail: small),
            FileToSeal(bytes: _png(2000), name: 'b.png', thumbnail: large),
          ],
        ),
      ))!;
      final [first, second] = await _filesOn(b, conversation, sent.id);
      expect((first.thumbnail, first.thumbnailRef), (base64Encode(small), null));
      expect(second.thumbnail, isNull);
      expect(second.thumbnailRef?.size, large.length);
      // The files in their order, then the thumbnail of its own, which goes up in the same request.
      final [form] = _forms(seen, conversation);
      expect(form.values['attachment_ids'], [first.id, second.id, second.thumbnailRef!.id]);
      final thumbnail = await openSealed(
        second.thumbnailRef!,
        download: _download(b, _urlOf(sent, second.thumbnailRef!.id)),
        open: _open(b),
      );
      expect(thumbnail.bytes, large);
      expect(thumbnail.type, 'image/jpeg');

      // Thumbnails of 8 KiB or less that the message can't hold together go apart, until it fits.
      final many = (await a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [for (var i = 0; i < 5; i++) FileToSeal(bytes: _png(100), name: '$i.png', thumbnail: _jpeg(7900))],
        ),
      ))!;
      final files = await _filesOn(b, conversation, many.id);
      expect(files, hasLength(5));
      final inside = files.where((f) => f.thumbnail != null).toList();
      final apart = files.where((f) => f.thumbnailRef != null).toList();
      expect(inside.length + apart.length, 5);
      expect(inside, isNotEmpty);
      expect(apart, isNotEmpty);
      for (final f in apart) {
        final opened = await openSealed(
          f.thumbnailRef!,
          download: _download(b, _urlOf(many, f.thumbnailRef!.id)),
          open: _open(b),
        );
        expect(opened.type, 'image/jpeg');
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_decrypted_file_is_drawn_by_its_bytes_or_saved,_never_opened',
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, holdNext: _) = await _dm();
      final page = utf8.encode("<!doctype html><script>parent.postMessage('x', '*')</script>");
      final svg = utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');
      final sent = await _sendWritten(a, conversation, [
        (bytes: page, said: {'name': 'cat.png', 'type': 'image/png'}),
        (bytes: svg, said: {'name': 'logo.svg', 'type': 'image/svg+xml'}),
        (bytes: _jpeg(3000), said: {'name': 'photo.bin', 'type': 'application/octet-stream'}),
      ]);
      final [html, vector, photo] = await _filesOn(b, conversation, sent.id);
      Future<String> typeOf(ShownFile file) async =>
          (await openSealed(file, download: _download(b, _urlOf(sent, file.id)), open: _open(b))).type;
      // An HTML page called a PNG is no picture: its bytes say what it is, and it's only ever saved, as bytes.
      expect(await typeOf(html), 'application/octet-stream');
      expect(drawnBy(await typeOf(html)), DrawnIn.save);
      // An SVG isn't drawn either: no widget of the app's takes one.
      expect(drawnBy(await typeOf(vector)), DrawnIn.save);
      // A picture is a picture whatever its sender calls it.
      expect(await typeOf(photo), 'image/jpeg');
      expect(drawnBy('image/jpeg'), DrawnIn.image);
      for (final type in ['video/mp4', 'video/webm', 'video/quicktime']) {
        expect(drawnBy(type), DrawnIn.video);
      }
      for (final type in ['audio/ogg', 'audio/webm', 'audio/mpeg', 'audio/mp4', 'audio/wav', 'audio/flac']) {
        expect(drawnBy(type), DrawnIn.audio);
      }
      for (final type in ['image/avif', 'image/webp', 'image/gif', 'image/png']) {
        expect(drawnBy(type), DrawnIn.image);
      }
      for (final type in ['text/html', 'image/svg+xml', 'application/pdf', 'image/heic', 'application/octet-stream']) {
        expect(drawnBy(type), DrawnIn.save);
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_file's_name,_type_and_size_are_checked_before_they're_used",
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, holdNext: _) = await _dm();
      final bytes = _png(100);
      final sent = await _sendWritten(a, conversation, [
        (
          bytes: bytes,
          said: {
            'name': '../../Download/${String.fromCharCode(0x202e)}gnp.exe',
            'type': 'image/png',
            'width': 4000000000,
          },
        ),
        // It says it's smaller than it is: the download stops past what a file of its size holds.
        (bytes: bytes, said: {'name': 'small.png', 'size': 10}),
        // And bigger: what came isn't all of it.
        (bytes: bytes, said: {'name': 'big.png', 'size': 1000}),
        // A size no request could carry is never downloaded.
        (bytes: bytes, said: {'name': 'huge.png', 'size': 1 << 40, 'duration_ms': 1 << 60}),
      ]);
      final [named, small, big, huge] = await _filesOn(b, conversation, sent.id);
      // Its name without its path or what hides its kind; a width no picture has left out; its type only a claim.
      expect((named.name, named.said, named.width), ('gnp.exe', 'image/png', null));
      final shownAs = await openSealed(named, download: _download(b, _urlOf(sent, named.id)), open: _open(b));
      expect(shownAs.type, 'image/png');

      final reasons = [
        for (final file in [small, big])
          switch (await _refused(openSealed(file, download: _download(b, _urlOf(sent, file.id)), open: _open(b)))) {
            FileError(:final reason) => reason,
            final other => other,
          },
      ];
      expect(reasons, [FileFailure.size, FileFailure.size]);
      var asked = false;
      final refused = await _refused(
        openSealed(
          huge,
          download: (_, _) async {
            asked = true;
            return Uint8List(0);
          },
          open: (_, _, _, _) async => throw StateError('never'),
        ),
      );
      expect((refused as FileError).reason, FileFailure.size);
      expect(asked, isFalse);
      expect(huge.durationMs, isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_file_whose_hash_differs_isn't_shown",
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, holdNext: _) = await _dm();
      final other = base64Encode(sha256.convert(_png(64)).bytes);
      final sent = await _sendWritten(a, conversation, [
        (bytes: _png(100), said: {'name': 'a.png', 'sha256': other}),
      ]);
      final [file] = await _filesOn(b, conversation, sent.id);
      final error = await _refused(openSealed(file, download: _download(b, _urlOf(sent, file.id)), open: _open(b)));
      expect((error as FileError).reason, FileFailure.hash);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_GIF_picked_in_a_conversation_goes_as_a_sealed_file',
    () async {
      final (fake: _, :a, :b, :conversation, :seen, aClient: _, holdNext: _) = await _dm();
      const url = 'https://static.klipy.com/ii/abc/12/34/dancing-cat.gif';
      final bytes = _gif(5000);
      final picked = await gifFile(url, (asked) async => asked == url ? bytes : null);
      expect(picked?.name, 'dancing-cat.gif');
      // Bytes that aren't a GIF aren't sent as one.
      expect(await gifFile(url, (_) async => _png(100)), isNull);
      final sent = (await a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [FileToSeal(bytes: picked!.bytes, name: picked.name)],
        ),
      ))!;
      final [file] = await _filesOn(b, conversation, sent.id);
      expect((file.name, file.said, file.size), ('dancing-cat.gif', 'image/gif', bytes.length));
      expect((await b.engine.messages(conversation, [sent.id])).single.text, isNull);
      // The API never saw where it came from.
      expect(seen.any((request) => latin1.decode(request.bodyBytes).contains('klipy')), isFalse);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_cancelled_upload_discards_its_message',
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, :holdNext) = await _dm();
      final hold = _Hold();
      holdNext(hold);
      final cancel = Completer<void>();
      final nonce = uuidv4();
      final sending = a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: nonce,
          text: 'never mind',
          files: [FileToSeal(bytes: _png(5000), name: 'a.png')],
        ),
        cancel: cancel.future,
      );
      await hold.held.future;
      cancel.complete();
      // The send stops at once, its request still held, not once the request gives up.
      await _refused(sending).timeout(const Duration(seconds: 5));
      // Let go once its abort came: the Cancel stopped its request, which never reaches the API (task 19's review,
      // M10).
      await pumpEventQueue();
      hold.release.complete();
      // The person's Cancel: the core lets the message go, and nothing of it reached anyone.
      expect(await a.engine.discardMessage(conversation, nonce), isNull);
      expect(await a.engine.pendingMessages(conversation), isEmpty);
      expect(await _posted(b, conversation), isEmpty);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 19's review, M4 (the desktop's N1): a message made while an older one's flush reads what waits goes in that
  // flush, with its own upload.
  test(
    "a_message_another_flush_sends_has_its_own_upload:_its_progress,_and_its_Cancel's_abort",
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, :holdNext) = await _dm();
      final second = uuidv4();
      final hold = _Hold(nonce: second);
      holdNext(hold);
      final cancel = Completer<void>();
      final progress = <int>[];
      // Two sends in one tick: the second is made before the first's flush reads what waits, and goes in it.
      final sendingFirst = a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'one'));
      final sendingSecond = a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: second,
          text: 'two',
          files: [FileToSeal(bytes: _png(5000), name: 'b.png')],
        ),
        onProgress: (sent, _) => progress.add(sent),
        cancel: cancel.future,
      );
      await hold.held.future;
      // Its bar moves, whichever flush sends it.
      expect(progress, isNotEmpty);
      cancel.complete();
      await _refused(sendingSecond).timeout(const Duration(seconds: 5));
      await pumpEventQueue();
      hold.release.complete();
      final first = await sendingFirst;
      // The person's Cancel stopped its request: only the first message reached anyone.
      expect(await a.engine.discardMessage(conversation, second), isNull);
      expect(await _posted(b, conversation), [first!.id]);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_failed_message_another_flush_sends_again_is_stopped_by_its_Dismiss,_or_bound_once_it_went',
    () async {
      final (:fake, :a, :b, :conversation, seen: _, aClient: _, :holdNext) = await _dm();
      final failed = uuidv4();
      // Its request never reaches the API: it waits, with its files, and the next send's flush sends it again.
      fake.cutRequest((method: 'POST', path: _messagesPath(conversation)));
      await _refused(
        a.engine.sendMessage(
          Outgoing(
            conversationId: conversation,
            nonce: failed,
            text: 'first try',
            files: [FileToSeal(bytes: _png(3000), name: 'c.png')],
          ),
        ),
      );
      final hold = _Hold(nonce: failed);
      holdNext(hold);
      final next = a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'next'));
      await hold.held.future;
      // The person's Dismiss while that flush's request is out.
      final went = await a.engine.discardMessage(conversation, failed).timeout(const Duration(seconds: 10));
      await pumpEventQueue();
      hold.release.complete();
      final sent = (await next)!;
      final posted = await _posted(b, conversation);
      if (went == null) {
        // Stopped before the API took it: only the next message went.
        expect(posted, [sent.id]);
      } else {
        // The API took it first: it's bound here, and this device reads it as its own.
        expect(posted, unorderedEquals([went, sent.id]));
        expect((await a.engine.messages(conversation, [went])).single.status, MessageStatus.ok);
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "the_person's_attachments_name_an_encrypted_file_from_this_device's_own_messages",
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, holdNext: _) = await _dm();
      final sent = (await a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          text: 'two files',
          files: [
            FileToSeal(bytes: _png(100), name: '../notes/plan.png'),
            FileToSeal(bytes: _bytes(50), name: 'report.bin'),
          ],
        ),
      ))!;
      final ids = [for (final attachment in sent.attachments!) attachment.id];
      await _filesOn(b, conversation, sent.id);
      for (final device in [a, b]) {
        final names = await device.engine.fileNames();
        expect([for (final id in ids) names[id]], ['plan.png', 'report.bin']);
      }
      // A file this device holds no message of has no name here.
      expect((await b.engine.fileNames())[uuidv7()], isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 18's review, I2: only the core's calls take the engine's turn; a message's request waits outside it.
  test(
    'an_incoming_message_is_applied_while_an_upload_is_held',
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, :holdNext) = await _dm();
      final hold = _Hold();
      holdNext(hold);
      final sending = a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [FileToSeal(bytes: _png(5000), name: 'a.png')],
        ),
      );
      await hold.held.future;
      // Bo's message comes while Ana's upload is held: her device applies it, and her other work goes on.
      final his = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'meanwhile'),
      ))!;
      await until(
        () async => (await a.engine.messages(conversation, [his.id])).firstOrNull?.text == 'meanwhile',
        timeout: const Duration(seconds: 15),
      );
      hold.release.complete();
      expect(await sending, isNotNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_cancel_stops_its_own_upload,_and_never_waits_for_an_older_message's",
    () async {
      final (fake: _, :a, b: _, :conversation, :seen, aClient: _, :holdNext) = await _dm();
      final hold = _Hold();
      holdNext(hold);
      final older = a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [FileToSeal(bytes: _png(5000), name: 'a.png')],
        ),
      );
      await hold.held.future;
      // A newer message waits behind it in its conversation's lane; its Cancel ends it at once, and so does its
      // Dismiss.
      final cancel = Completer<void>();
      final nonce = uuidv4();
      final newer = a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: nonce,
          files: [FileToSeal(bytes: _png(3000), name: 'b.png')],
        ),
        cancel: cancel.future,
      );
      await until(() async => (await a.engine.pendingMessages(conversation)).length == 2);
      cancel.complete();
      Future<Object?> soon(Future<Object?> work) =>
          Future.any([work, Future<Object?>.delayed(const Duration(seconds: 5), () => 'waiting')]);
      expect(await soon(newer.then((_) => 'sent', onError: (Object _) => 'stopped')), 'stopped');
      expect(await soon(a.engine.discardMessage(conversation, nonce)), isNull);
      hold.release.complete();
      await older;
      expect(await a.engine.pendingMessages(conversation), isEmpty);
      expect(_forms(seen, conversation), hasLength(1));
      expect(await _posted(a, conversation), hasLength(1));
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 18's review, I3: a refusal of a message's files won't change, so they don't go up again at every flush.
  test(
    "a_waiting_message_with_files_that_the_API_refused_waits_for_the_person's_Retry",
    () async {
      final (:fake, :a, b: _, :conversation, :seen, aClient: _, holdNext: _) = await _dm();
      final path = (method: 'POST', path: _messagesPath(conversation));
      fake.refuse(path, 413, body: {'error': 'file too large'});
      final nonce = uuidv4();
      final files = [FileToSeal(bytes: _png(5000), name: 'big.png')];
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, files: files)));
      // The next message, and a READY, send what waits: the refused one stays.
      await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'next'));
      a.connect(a.registered.last);
      await turnEnded(a);
      await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'after the READY'));
      expect(_forms(seen, conversation), hasLength(1));
      // The person's Retry sends it.
      expect(await a.engine.resendMessage(conversation, nonce), isNotNull);
      expect(_forms(seen, conversation), hasLength(2));
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 18's review, I6: what sends a message with files a second time, under task 16's and 17's names.
  test(
    'a_message_cut_before_its_answer_is_sent_again_with_the_same_bytes,_with_files',
    () async {
      // Ana's device doesn't hear its own messages' events, which its queue would settle them with first.
      final (:fake, :a, :b, :conversation, :seen, aClient: _, holdNext: _) = await _dm(
        aHears: (event) => event.type != 'DM_MESSAGE_CREATE',
      );
      final path = (method: 'POST', path: _messagesPath(conversation));
      List<Uint8List> partsOf(({Map<String, List<String>> values, List<FormPart> files}) form) => [
        for (final part in form.files) part.bytes,
      ];
      // The API takes it, and its answer is lost: sent again, the same bytes, which the API answers with its message.
      final once = uuidv4();
      final picture = [FileToSeal(bytes: _png(5000), name: 'a.png')];
      fake.loseAnswer(path);
      await _refused(
        a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: once, text: 'once', files: picture)),
      );
      final sent = (await a.engine.resendMessage(conversation, once))!;
      final [first, again] = _forms(seen, conversation);
      expect(again.values['ciphertext'], first.values['ciphertext']);
      expect(again.values['attachment_ids'], first.values['attachment_ids']);
      expect(partsOf(again), partsOf(first));
      expect(await _posted(a, conversation), [sent.id]);
      expect([for (final f in await _filesOn(b, conversation, sent.id)) f.name], ['a.png']);

      // Its files went up, and its connection was cut before the message: sent again, the API takes them again.
      final twice = uuidv4();
      fake.cutAfterFiles(path);
      final other = [FileToSeal(bytes: _png(4000), name: 'b.png')];
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: twice, files: other)));
      final resent = (await a.engine.resendMessage(conversation, twice))!;
      final [cut, taken] = _forms(seen, conversation).sublist(2);
      expect(taken.values['attachment_ids'], cut.values['attachment_ids']);
      expect([for (final file in resent.attachments!) file.id], cut.values['attachment_ids']);
      expect(await _posted(a, conversation), [sent.id, resent.id]);
      final [file] = await _filesOn(b, conversation, resent.id);
      final opened = await openSealed(file, download: _download(b, _urlOf(resent, file.id)), open: _open(b));
      expect(opened.type, 'image/png');
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_stale_message_is_discarded_and_encrypted_again,_with_files',
    () async {
      final (:fake, :a, :b, :conversation, :seen, aClient: _, holdNext: _) = await _dm();
      final path = (method: 'POST', path: _messagesPath(conversation));
      // Its request never reached the API, while the group moved on six epochs: the core says it's stale.
      fake.cutRequest(path);
      final nonce = uuidv4();
      final files = [FileToSeal(bytes: _png(5000), name: 'late.png')];
      await _refused(
        a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, text: 'late', files: files)),
      );
      await stoppedByHand(b);
      for (var i = 0; i < 6; i++) {
        await commitByHand(b, conversation);
      }
      await until(() async => (await groupOf(a, conversation))!.epoch == 7);
      final sent = (await a.engine.resendMessage(conversation, nonce))!;
      expect(sent.nonce, isNot(nonce));
      final [cut, remade] = [_forms(seen, conversation).first, _forms(seen, conversation).last];
      expect(remade.values['attachment_ids'], cut.values['attachment_ids']);
      final bo = await restarted(fake, b);
      expect([for (final f in await _filesOn(bo, conversation, sent.id)) f.name], ['late.png']);

      // The API says it's stale (409): made again under another nonce, with the same files.
      final refused = uuidv4();
      final group = (await groupOf(a, conversation))!;
      fake.refuse(path, 409, body: {'error': 'stale message', 'generation': group.generation, 'epoch': group.epoch});
      final more = [FileToSeal(bytes: _png(3000), name: 'again.png')];
      final posted = (await a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: refused, files: more)))!;
      expect(posted.nonce, isNot(refused));
      final [before, after] = _forms(seen, conversation).sublist(_forms(seen, conversation).length - 2);
      expect(after.values['attachment_ids'], before.values['attachment_ids']);
      expect([for (final f in await _filesOn(bo, conversation, posted.id)) f.name], ['again.png']);
      await bo.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_message_cut_before_its_answer,_and_the_app_closed,_waits_for_its_Dismiss,_with_files',
    () async {
      final (:fake, :a, b: _, :conversation, seen: _, :aClient, holdNext: _) = await _dm();
      fake.cutRequest((method: 'POST', path: _messagesPath(conversation)));
      final nonce = uuidv4();
      await _refused(
        a.engine.sendMessage(
          Outgoing(
            conversationId: conversation,
            nonce: nonce,
            text: 'with a file',
            files: [FileToSeal(bytes: _png(5000), name: 'a.png')],
          ),
        ),
      );
      expect(a.engine.holdsFiles(nonce), isTrue);
      // Started again: its sealed bytes went with the app, so it goes neither at the start nor on a Retry.
      final again = await restarted(fake, a, client: aClient);
      await turnEnded(again);
      expect(again.engine.holdsFiles(nonce), isFalse);
      expect([for (final p in await again.engine.pendingMessages(conversation)) p.nonce], [nonce]);
      expect(await _refused(again.engine.resendMessage(conversation, nonce)), isA<FilesGone>());
      expect(await _posted(again, conversation), isEmpty);
      expect(await again.engine.discardMessage(conversation, nonce), isNull);
      expect(await again.engine.pendingMessages(conversation), isEmpty);
      await again.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_voice_note_goes_by_its_convention',
    () async {
      final (:fake, :a, :b, :conversation, seen: _, aClient: _, holdNext: _) = await _dm();
      // Cut first: its Retry goes through the core's check of the envelope it kept, byte for byte.
      fake.cutRequest((method: 'POST', path: _messagesPath(conversation)));
      final waveform = Uint8List.fromList(List.generate(64, (i) => i * 4));
      final note = [FileToSeal(bytes: _ogg(3000), name: 'voice-note.ogg', durationMs: 2300, waveform: waveform)];
      final nonce = uuidv4();
      await _refused(a.engine.sendMessage(Outgoing(conversationId: conversation, nonce: nonce, files: note)));
      final sent = (await a.engine.resendMessage(conversation, nonce))!;
      final [file] = await _filesOn(b, conversation, sent.id);
      expect((file.said, file.durationMs, file.waveform), ('audio/ogg', 2300, base64Encode(waveform)));
      final row = (await b.engine.messages(conversation, [sent.id])).single;
      expect(drawnAs(text: row.text, attachments: row.attachments, sticker: false), Drawn.voiceNote);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 18's review, Missing 2: decision 40 counts them, under the kind attachment.
  test(
    "an_attachment_that_doesn't_open_is_counted,_as_decryption_failures_are",
    () async {
      final (:fake, :a, b: _, conversation: _, seen: _, aClient: _, holdNext: _) = await _dm();
      a.engine.fileFailed();
      a.clock.advance(const Duration(minutes: 2));
      await until(() => fake.decryptFailures.any((failure) => failure.kind == 'attachment'));
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 18's review, M4: a message's files go with every deletion the engine learns of.
  test(
    'a_message_the_queue_deletes_is_told_deleted,_for_its_files_to_go',
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, holdNext: _) = await _dm();
      final deleted = <String>[];
      final heard = a.engine.messagesDeleted.listen((gone) => deleted.addAll(gone.ids));
      addTearDown(heard.cancel);
      final sent = (await b.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [FileToSeal(bytes: _png(500), name: 'a.png')],
        ),
      ))!;
      await _filesOn(a, conversation, sent.id);
      await b.engine.deleteMessage(conversation, sent.id);
      await until(() => deleted.contains(sent.id));
      // The person's own deletion tells it too.
      final own = (await a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [FileToSeal(bytes: _png(500), name: 'b.png')],
        ),
      ))!;
      await a.engine.deleteMessage(conversation, own.id);
      await until(() => deleted.contains(own.id));
    },
    skip: noCore,
    timeout: _slow,
  );

  // Task 18's review, Missing 1: the per-file cap, against the sealed size, and the request's 32 MiB.
  // Step 5's review, M6 (mobile#356): in the core's format a part's nonce is its index, so one key over two contents
  // would use GCM's nonces twice. Only a key drawn for each file keeps that from happening.
  test(
    'each_file_and_a_thumbnail_apart_take_a_key_of_their_own,_and_a_file_sent_again_another',
    () async {
      final (fake: _, :a, :b, :conversation, seen: _, aClient: _, holdNext: _) = await _dm();
      final first = (await a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [
            FileToSeal(bytes: _png(1000), name: 'a.png'),
            FileToSeal(bytes: _png(2000), name: 'b.png', thumbnail: _jpeg(20 << 10)),
          ],
        ),
      ))!;
      final [one, two] = await _filesOn(b, conversation, first.id);
      // The same file sent again with other content, as after a Cancel: a message of its own.
      final again = (await a.engine.sendMessage(
        Outgoing(
          conversationId: conversation,
          nonce: uuidv4(),
          files: [FileToSeal(bytes: _png(1000), name: 'a.png')],
        ),
      ))!;
      final [three] = await _filesOn(b, conversation, again.id);
      expect({one.key, two.key, two.thumbnailRef!.key, three.key}, hasLength(4));
    },
    skip: noCore,
    timeout: _slow,
  );

  // M4: a thumbnail of its own was taken whatever its size, up to a request's 32 MiB, and every reader downloaded it as
  // its row neared the screen. Past what a JPEG or a PNG of 320 px a side takes (512 KiB), it's none.
  test("a_thumbnail_of_its_own_past_512_KiB_is_none:_it's_never_downloaded", () {
    final ref = {'id': uuidv7(), 'key': 'a2V5', 'sha256': 'aGFzaA=='};
    final raw = {'id': uuidv7(), 'key': 'a2V5', 'sha256': 'aGFzaA==', 'name': 'a.png', 'type': 'image/png', 'size': 1};
    expect(
      shownFile({
        ...raw,
        'thumbnail_ref': {...ref, 'size': 512 << 10},
      })?.thumbnailRef?.size,
      512 << 10,
    );
    expect(
      shownFile({
        ...raw,
        'thumbnail_ref': {...ref, 'size': (512 << 10) + 1},
      })?.name,
      'a.png',
    );
    expect(
      shownFile({
        ...raw,
        'thumbnail_ref': {...ref, 'size': (512 << 10) + 1},
      })?.thumbnailRef,
      isNull,
    );
    expect(
      shownFile({
        ...raw,
        'thumbnail_ref': {...ref, 'size': 32 << 20},
      })?.thumbnailRef,
      isNull,
    );
  });

  test('a_file_past_the_limit_once_sealed_is_refused_before_it_goes', () {
    expect(sealedSize(0), 16);
    expect(sealedSize(65536), 65536 + 16);
    expect(sealedSize(65537), 65537 + 32);
    const limit = 20 << 20;
    // Its plain size fits, its sealed one doesn't: the API would refuse it with a 413 once it all went up.
    expect(tooLargeToSend([limit - 100], fileLimit: limit), isTrue);
    expect(tooLargeToSend([limit - (1 << 20)], fileLimit: limit), isFalse);
    // Files under the cap each, past the request's 32 MiB together.
    expect(tooLargeToSend([18 << 20, 18 << 20], fileLimit: limit), isTrue);
    expect(tooLargeToSend([10 << 20, 10 << 20]), isFalse);
    expect(tooLargeToSend([40 << 20]), isTrue);
  });

  // Step 5's fuzzing, with the desktop's finding: base64Decode takes the URL's alphabet and an escaped padding, which
  // the desktop's atob refuses, so the two apps read another waveform or thumbnail of the same text.
  test("a_file's_waveform_and_thumbnail_are_read_only_in_the_form_the_core_writes", () {
    final file = {'id': uuidv4(), 'key': 'a2V5', 'sha256': 'c2hh', 'name': 'a.ogg', 'size': 3};
    final waveform = base64Encode(List.filled(waveformSamples, 0xfb));
    final thumbnail = base64Encode(List.filled(100, 0xfb));
    expect(shownFile({...file, 'waveform': waveform})!.waveform, waveform);
    expect(shownFile({...file, 'thumbnail': thumbnail})!.thumbnail, thumbnail);
    for (final (field, value) in [('waveform', waveform), ('thumbnail', thumbnail)]) {
      for (final other in [value.replaceAll('+', '-').replaceAll('/', '_'), value.replaceAll('=', '%3D')]) {
        final shown = shownFile({...file, field: other})!;
        expect([shown.waveform, shown.thumbnail], [null, null], reason: '$field $other');
      }
    }
  });
}
