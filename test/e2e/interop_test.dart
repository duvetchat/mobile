// The mobile app's half of the API's suite clients-interop (PLAN-E2E-CLIENTES.md, Task 35; Review Focus 1 and 9): this
// app's engine talking to the desktop's (its src/lib/e2e/testing/interop.test.ts, which the suite runs at the same
// time) through a real API and gateway. Bob and Carol, and a device of Dave's, are this app's; Alice, with a second
// device, and Dave's first device, the other's. Each side waits for what the other does through the server; what a
// person carries between two screens (a code, a QR, a recovery key, a security number) goes through the folder the
// suite names (E2E_INTEROP_DIR). The texts each side writes are the script's, the same in both files. Outside that
// suite, skipped.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:duvet/e2e/cbor.dart' show listDevices;
import 'package:duvet/e2e/client.dart';
import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/decrypted_files.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/thumbnails.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../support/core_lib.dart';
import '../support/engines.dart';

final _env = Platform.environment;
final _witness = _env['E2E_INTEROP_WITNESS'] ?? '';
final _shared = _env['E2E_INTEROP_DIR'] ?? '';
final _sticker = _env['E2E_INTEROP_STICKER'] ?? '';

/// The first wait on the other app, whose test may still be starting; then each step's.
const _first = Duration(minutes: 8);
const _step = Duration(minutes: 2);

/// How often a wait asks the API: a route takes 64 requests a minute from a user, this device's engine's included. A
/// wait on what a core or an engine shows asks nothing, and looks every 100 ms.
const _poll = Duration(seconds: 2);

/// The script, the same in the desktop's half.
abstract final class _Script {
  static const aliceHello = "Hello Bob, it's Alice on the desktop";
  static const aliceEdited = "Hello Bob, it's Alice on the desktop (edited)";
  static const aliceGone = 'Alice deletes this one';
  static final aliceWitness = "The desktop's witness: $_witness";
  static String bobHello(String alice) => 'Hi <@$alice>, Bob here on Android';
  static String bobEdited(String alice) => 'Hi <@$alice>, Bob here on Android (edited)';
  static const bobGone = 'Bob deletes this one';
  static final bobWitness = "The phone's witness: $_witness";
  static const alicePicture = 'A picture from the desktop';
  static const bobPicture = 'A picture from the phone';

  /// Pictures whose thumbnails are more than a message holds (8 KiB): each goes as a file of its own, after its
  /// picture.
  static const alicePictureApart = 'A picture from the desktop, its thumbnail apart';
  static const bobPictureApart = 'A picture from the phone, its thumbnail apart';
  static const toCarol = 'Carol, this came before your device';
  static const carolAnswer = 'Carol here: I read it';
  static const groupName = 'Interop group';
  static const groupAlice = 'In the group: Alice';
  static const groupBob = 'In the group: Bob';
  static const groupCarol = 'In the group: Carol read what came before her';

  /// A voice note each way: its length and its 64 peaks.
  static const aliceVoiceMs = 4200;
  static final aliceWaveform = Uint8List.fromList([for (var i = 0; i < 64; i++) 255 - i * 4]);
  static const bobVoiceMs = 3100;
  static final bobWaveform = Uint8List.fromList([for (var i = 0; i < 64; i++) i * 4]);
}

/// Waits until [get] gives something, as another device's work ends in its own time, looking every [every]: a look
/// that throws (a refusal, a lost answer) is one more look; past [timeout], it fails with the last one's error.
Future<T> _until<T extends Object>(
  Future<T?> Function() get, {
  Duration timeout = _step,
  Duration every = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? last;
  while (true) {
    try {
      final got = await get();
      if (got != null) return got;
    } catch (error) {
      last = error;
    }
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('what the test waited for never came${last == null ? '' : ' ($last)'}');
    }
    await Future<void>.delayed(every);
  }
}

Future<void> _eventually(
  FutureOr<bool> Function() holds, {
  Duration timeout = _step,
  Duration every = const Duration(milliseconds: 100),
}) => _until(() async => await holds() ? true : null, timeout: timeout, every: every);

// ---- what a person carries between two screens: a note in the shared folder, written whole (a rename)

void _note(String name, Map<String, Object?> value) {
  final path = '$_shared/$name.json';
  File('$path.part').writeAsStringSync(jsonEncode(value));
  File('$path.part').renameSync(path);
}

Future<Map<String, Object?>> _noted(String name, {Duration timeout = _step}) async {
  final file = File('$_shared/$name.json');
  await _eventually(file.existsSync, timeout: timeout);
  return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
}

/// The stack's API and gateway, as the app's router names them.
ApiRouter _router() {
  final api = Uri.parse(_env['E2E_LIVE_API']!);
  return ApiRouter(api: api.authority, ws: Uri.parse(_env['E2E_LIVE_WS']!).authority, secure: api.scheme == 'https');
}

typedef _Account = ({String id, String email});

/// The stack's nth seeded account.
_Account _account(int n) {
  final account = (jsonDecode(_env['E2E_LIVE_ACCOUNTS'] ?? '[]') as List<dynamic>)[n] as Map<String, dynamic>;
  return (id: account['id'] as String, email: account['email'] as String);
}

/// Every device made here, which the witness's case looks through and the file's end stops.
final _made = <_Device>[];

/// A device of an account's on the stack, as the app runs one and as live_test.dart's: a session saying what the app
/// is, whose login's challenge the engine keeps; a gateway identified with no device, then once more with the one the
/// engine registers (Ruling 30); its record, in memory; and the engine, on a core of its own in a folder of its own.
class _Device {
  _Device._(this.rest, this.host, this.store);

  final duvet.RestClient rest;
  final TestHost host;
  final MemoryStore store;
  late final E2EEngine engine;
  String? device;
  duvet.GatewayManager? _gateway;
  StreamSubscription<duvet.GatewayEventPayload>? _heard;
  late final Future<void> Function() end;

  duvet.E2eApi get api => duvet.E2eApi(rest);

  static Future<_Device> start(_Account account) async {
    final router = _router();
    final rest = duvet.RestClient(http.Client(), router: router, duvetClient: duvetClient());
    final signedIn = await rest.logIn(account.email, _env['E2E_LIVE_PASSWORD'] ?? '');
    final folder = Directory.systemTemp.createTempSync('duvet-interop-');
    final live = _Device._(rest, TestHost(folder: folder), MemoryStore());
    final events = StreamController<duvet.GatewayEventPayload>.broadcast();
    String? named;
    Future<void> connect() async {
      await live._heard?.cancel();
      live._gateway?.destroy();
      // A client of the gateway's own: destroying the manager closes its client's, and the engine's goes on.
      final own = duvet.RestClient(
        http.Client(),
        router: router,
        token: rest.token,
        sessionToken: rest.sessionToken,
        duvetClient: rest.duvetClient,
      );
      final gateway = live._gateway = duvet.GatewayManager(
        own,
        router: router,
        platform: duvet.ClientPlatform.mobile,
        identifyDevice: () => named = live.device,
      );
      live._heard = gateway.onEvent.listen(events.add);
      await gateway.connectAll();
    }

    await connect();
    final challenge = switch (signedIn.deviceChallenge) {
      final challenge? => (challenge: challenge, at: DateTime.now()),
      null => null,
    };
    live.engine = E2EEngine(
      host: live.host.gate,
      api: live.api,
      events: events.stream,
      store: live.store,
      clock: const SystemClock(),
      user: account.id,
      deviceName: 'Pixel 8 Pro',
      registered: (device) {
        live.device = device;
        if (named != device) unawaited(connect());
      },
      loginChallenge: challenge,
      // What the app's chats draw, kept as the app's repository keeps it.
      shown: listedDrawing(live.api.api.getConversations, account.id),
    );
    live.end = () async {
      await live.engine.stop();
      await live._heard?.cancel();
      live._gateway?.destroy();
      await events.close();
      rest.client.close();
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    };
    _made.add(live);
    return live;
  }

  /// This first device of its account's: its identity made, its recovery key saved, ready. The key it showed.
  Future<String> setUp() async {
    await engine.start();
    expect(engine.state.value, const EngineState.firstDevice());
    await engine.makeIdentity();
    final key = shownKey(engine.state.value)!;
    await engine.keySaved();
    expect(engine.state.value, EngineState.ready);
    return key;
  }
}

// ---- conversations and their messages, as a device's core shows them and the API lists them

typedef _Shown = ({ShownMessage row, duvet.DirectMessage? listed});

/// The newest rows of the conversation this device's core holds: no request, as a wait looks often.
Future<List<ShownMessage>> _rows(_Device d, String conversation) async {
  final page = await d.host.gate.handle<Map<String, Object?>>({
    'cmd': 'messages',
    'conversation_id': conversation,
    'limit': 100,
  });
  return [for (final row in page['messages']! as List) ShownMessage.of((row as Map).cast<String, Object?>())];
}

/// A message of [author]'s this device's core shows in the conversation, whose row passes [which], with the API's
/// listing of it, asked for once the row is there.
Future<_Shown?> _shown(_Device d, String conversation, String author, bool Function(ShownMessage row) which) async {
  final row = (await _rows(
    d,
    conversation,
  )).where((one) => one.status == MessageStatus.ok && one.userId == author && which(one)).firstOrNull;
  if (row == null) return null;
  final listed = (await d.rest.getDirectMessages(conversation)).where((m) => m.id == row.messageId).firstOrNull;
  return (row: row, listed: listed);
}

bool Function(ShownMessage row) _withText(String text) =>
    (row) => row.text == text;

Future<_Shown> _read(_Device d, String conversation, String text, String author, {Duration timeout = _step}) =>
    _until(() => _shown(d, conversation, author, _withText(text)), timeout: timeout);

/// The conversation of this user's list that passes [which], once it's there.
Future<duvet.Conversation> _listed(
  _Device d,
  bool Function(duvet.Conversation conv) which, {
  Duration timeout = _step,
}) => _until(() async => (await d.rest.getConversations()).where(which).firstOrNull, timeout: timeout, every: _poll);

/// The conversation's group as the device's core holds it, or null without one.
Future<Map<String, Object?>?> _held(_Device d, String conversation) => d.host.gate
    .handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': conversation})
    .then<Map<String, Object?>?>((group) => group, onError: (Object _) => null);

/// Takes the friend request [from] sent this device's user.
Future<void> _befriend(_Device d, String from) async {
  final request = await _until(
    () async => (await d.rest.getPendingRequests()).where((r) => r.senderId == from).firstOrNull,
    timeout: _first,
    every: _poll,
  );
  await d.rest.acceptFriendRequest(request.id);
}

// ---- the files: a picture, its thumbnail as the app makes one, and a voice note

/// An audio file whose head is the fixture's of that type (Android's voice notes are Oggs), made long.
Uint8List _audio(String type) {
  final fixture = jsonDecode(File('test/e2e/e2e-conventions.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['types'] as List).cast<Map<String, dynamic>>();
  final head = base64Decode(cases.firstWhere((one) => one['type'] == type)['bytes'] as String);
  return Uint8List.fromList([...head, for (var at = head.length; at < head.length + 16000; at++) (at * 31) % 256]);
}

/// A file of a message this device shows, sealed as the API keeps it, downloaded from its signed URL and opened.
Future<({Uint8List bytes, String type})> _opened(_Device d, FileRef file, duvet.DirectMessage? listed) async {
  final url = listed?.attachments?.where((one) => one.id == file.id).firstOrNull?.url;
  if (url == null) throw StateError('the API keeps no file of that ID for the message');
  final router = _router();
  final base = Uri.parse('${router.secure ? 'https' : 'http'}://${router.api}/');
  final client = http.Client();
  try {
    return await openSealed(
      file,
      download: (most, progress) => downloadSigned(client, base.resolve(url), most, progress: progress),
      open: (key, id, sealed, progress) => d.engine.openFile(key, id, sealed, progress: progress),
    );
  } finally {
    client.close();
  }
}

/// Bytes as lowercase hexadecimal.
String _hex(List<int> bytes) => [for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0')].join();

// ---- the devices and conversations the cases leave to the next ones, and what this app writes out (Review Focus 1)

final _printed = <String>[];
late _Device _b1;
late _Device _c1;

/// Bob's recovery key, which his first device showed, and the DM's two messages deleted, for the backup's case.
var _bobKey = '';
final _gone = <String>[];
var _dm = '';
var _toCarol = '';
var _group = '';

void main() {
  final skip = _witness.isEmpty || _shared.isEmpty || _sticker.isEmpty
      ? "only against a stack, in the API's clients-interop suite"
      : null;
  const nobody = (id: '', email: '');
  final (alice, bob, carol, dave) = skip == null
      ? (_account(0), _account(1), _account(2), _account(3))
      : (nobody, nobody, nobody, nobody);
  final original = debugPrint;
  setUpAll(() async {
    debugPrint = (message, {wrapWidth}) {
      _printed.add(message ?? '');
      original(message, wrapWidth: wrapWidth);
    };
    if (skip == null && noCore == null) await loadCore();
  });
  tearDownAll(() async {
    for (final d in _made) {
      await d.end();
    }
    debugPrint = original;
  });

  test(
    "setup:_bob's_phone_is_ready,_and_bob_and_carol_take_alice's_friend_requests,_carol_before_she_has_a_device",
    () async {
      // Carol takes it from a session without a device, which her device's case later starts on.
      _c1 = await _Device.start(carol);
      await _befriend(_c1, alice.id);
      _b1 = await _Device.start(bob);
      // What his first device shows, which a person keeps: his recovery key, for the device he recovers later.
      _bobKey = await _b1.setUp();
      _note('bob-recovery-key', {'key': _bobKey});
      await _befriend(_b1, alice.id);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 12)),
  );

  // Step 1: this engine joins the group the desktop's made; each reads what the other sends, its edits and deletions.
  test(
    'alice_opens_a_dm_with_bob;_they_write_to_each_other,_and_each_edits_and_deletes_a_message',
    () async {
      final conv = await _listed(
        _b1,
        (c) => c.type == duvet.ConversationType.dm && c.members.any((m) => m.userId == alice.id),
        timeout: _first,
      );
      _dm = conv.id;
      await _b1.engine.openConversation(_dm);
      await _eventually(() async => await _held(_b1, _dm) != null);
      final hello = await _read(_b1, _dm, _Script.aliceHello, alice.id);
      await _read(_b1, _dm, _Script.aliceWitness, alice.id);
      final doomed = await _read(_b1, _dm, _Script.aliceGone, alice.id);

      final reply = (await _b1.engine.sendMessage(
        Outgoing(conversationId: _dm, nonce: uuidv4(), text: _Script.bobHello(alice.id), replyTo: hello.row.messageId),
      ))!;
      await _b1.engine.sendMessage(Outgoing(conversationId: _dm, nonce: uuidv4(), text: _Script.bobWitness));
      final mine = (await _b1.engine.sendMessage(
        Outgoing(conversationId: _dm, nonce: uuidv4(), text: _Script.bobGone),
      ))!;
      // The API holds none of their text.
      final contents = [for (final m in await _until(() => _b1.rest.getDirectMessages(_dm), every: _poll)) m.content];
      expect(jsonEncode(contents).contains(_witness), isFalse);

      // The desktop's edit and deletion, then this app's.
      final edited = await _read(_b1, _dm, _Script.aliceEdited, alice.id);
      expect(edited.row.messageId, hello.row.messageId);
      expect(edited.row.editedAt, isNotNull);
      await _eventually(() async => (await _b1.engine.messages(_dm, [doomed.row.messageId!])).isEmpty);
      await _b1.engine.editMessage(_dm, reply.id, _Script.bobEdited(alice.id));
      await _b1.engine.deleteMessage(_dm, mine.id);
      _gone.addAll([doomed.row.messageId!, mine.id]);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 14)),
  );

  // Step 2: the desktop's picture with its thumbnail, its voice note and its sticker; this app's picture and voice
  // note.
  test(
    'files_cross_each_way,_a_picture_with_its_thumbnail_and_a_voice_note,_and_a_sticker',
    () async {
      // The desktop's pictures: their bytes, PNGs by them, their size, and thumbnails this app draws, one inside its
      // message and one a file of its own.
      for (final (text, name, apart) in [
        (_Script.alicePicture, 'from-the-desktop.png', false),
        (_Script.alicePictureApart, 'apart.png', true),
      ]) {
        final picture = await _read(_b1, _dm, text, alice.id);
        final file = shownFile(picture.row.attachments.single)!;
        expect((file.name, file.said, file.width, file.height), (name, 'image/png', 400, 300));
        final opened = await _opened(_b1, file, picture.listed);
        expect((opened.type, opened.bytes.length), ('image/png', file.size));
        expect((file.thumbnail != null, file.thumbnailRef != null), (!apart, apart));
        final small = switch (file.thumbnail) {
          final inside? => base64Decode(inside),
          null => (await _opened(_b1, file.thumbnailRef!, picture.listed)).bytes,
        };
        expect(thumbnailDrawn(small), isTrue);
        final drawn = img.decodeImage(small);
        expect((drawn?.width, drawn?.height), (320, 240));
      }

      final note = await _until(
        () => _shown(
          _b1,
          _dm,
          alice.id,
          (row) => row.text == null && shownFile(row.attachments.firstOrNull)?.said == 'audio/webm',
        ),
      );
      final sound = shownFile(note.row.attachments.single)!;
      expect((sound.durationMs, sound.waveform), (_Script.aliceVoiceMs, base64Encode(_Script.aliceWaveform)));
      expect(drawnAs(text: note.row.text, attachments: note.row.attachments, sticker: false), Drawn.voiceNote);
      expect((await _opened(_b1, sound, note.listed)).type, 'audio/webm');

      // The sticker: an empty envelope here, its sticker in the clear in the API's listing.
      final sticker = await _until(
        () => _shown(_b1, _dm, alice.id, (row) => row.text == null && row.attachments.isEmpty),
      );
      expect(sticker.listed?.stickerAttachmentId, _sticker);
      expect(drawnAs(text: sticker.row.text, attachments: sticker.row.attachments, sticker: true), Drawn.sticker);

      // This app's: its pictures' sizes and thumbnails as the app works them out, one of noise down to its 80th row,
      // whose thumbnail is a file of its own, and a voice note.
      for (final (text, name, noisy) in [
        (_Script.bobPicture, 'from-the-phone.png', 0),
        (_Script.bobPictureApart, 'apart.png', 80),
      ]) {
        final mine = img.Image(width: 400, height: 300);
        final noise = Random(35);
        for (final pixel in mine) {
          final band = pixel.y < noisy;
          pixel
            ..r = band ? noise.nextInt(256) : (pixel.x >> 5) * 20
            ..g = band ? noise.nextInt(256) : (pixel.y >> 5) * 20
            ..b = band ? noise.nextInt(256) : 90;
        }
        final bytes = img.encodePng(mine);
        final facts = (await pictureFacts(bytes))!;
        expect(facts.thumbnail!.length > 8 << 10, noisy > 0);
        final shared = FileToSeal(
          bytes: bytes,
          name: name,
          width: facts.width,
          height: facts.height,
          thumbnail: facts.thumbnail,
        );
        await _b1.engine.sendMessage(Outgoing(conversationId: _dm, nonce: uuidv4(), text: text, files: [shared]));
      }
      final voice = FileToSeal(
        bytes: _audio('audio/ogg'),
        name: 'voice-note.ogg',
        durationMs: _Script.bobVoiceMs,
        waveform: _Script.bobWaveform,
      );
      await _b1.engine.sendMessage(Outgoing(conversationId: _dm, nonce: uuidv4(), files: [voice]));
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  // Step 5: Carol's device comes after Alice's message, which waited for it: as her device joins their DM, the
  // desktop's engine hands her what it noted for her (a catch-up), which hers takes by itself; she reads it, and
  // answers.
  test(
    "carol,_whose_device_comes_after_alice's_message,_gets_it_as_she_joins,_and_answers",
    () async {
      final conv = await _listed(
        _c1,
        (c) => c.type == duvet.ConversationType.dm && c.members.any((m) => m.userId == alice.id),
      );
      _toCarol = conv.id;
      await _eventually(() async => (await _c1.rest.getDirectMessages(_toCarol)).isNotEmpty, every: _poll);
      await _c1.setUp();
      await _c1.engine.openConversation(_toCarol);
      // It came in the catch-up her engine took, which says who shared it.
      final caught = await _read(_c1, _toCarol, _Script.toCarol, alice.id);
      expect(caught.row.sharedBy, alice.id);
      await _c1.engine.sendMessage(Outgoing(conversationId: _toCarol, nonce: uuidv4(), text: _Script.carolAnswer));
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  // Step 3: the desktop's group with Bob, where both write; Carol, added, takes the week Alice shares with her.
  test(
    'alice_makes_a_group_with_bob,_adds_carol_and_shares_a_week_of_history_with_her',
    () async {
      final conv = await _listed(_b1, (c) => c.type == duvet.ConversationType.group && c.name == _Script.groupName);
      _group = conv.id;
      await _b1.engine.openConversation(_group);
      final first = await _read(_b1, _group, _Script.groupAlice, alice.id);
      final second = (await _b1.engine.sendMessage(
        Outgoing(conversationId: _group, nonce: uuidv4(), text: _Script.groupBob),
      ))!;

      await _listed(_c1, (c) => c.id == _group);
      await _c1.engine.openConversation(_group);
      await _eventually(() async => await _held(_c1, _group) != null);
      final ids = [first.row.messageId!, second.id];
      expect(await _c1.engine.messages(_group, ids), isEmpty);
      final offer = await _until(() async => (_c1.engine.historyOffers.value[_group] ?? const []).firstOrNull);
      expect((offer.fromUserId, offer.range), (alice.id, 'week'));
      await _c1.engine.takeHistoryOffer(offer.shareId);
      final rows = {for (final row in await _c1.engine.messages(_group, ids)) row.messageId: row};
      expect(
        [for (final id in ids) (rows[id]?.text, rows[id]?.sharedBy)],
        [(_Script.groupAlice, alice.id), (_Script.groupBob, alice.id)],
      );
      await _c1.engine.sendMessage(Outgoing(conversationId: _group, nonce: uuidv4(), text: _Script.groupCarol));
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  // Step 4: Bob leaves once Carol wrote; Alice's removal of Carol takes the group off Carol's device.
  test(
    'bob_leaves,_and_alice_removes_carol',
    () async {
      await _read(_b1, _group, _Script.groupCarol, carol.id);
      await _b1.engine.leaveConversation(_group);
      await _eventually(() async => !(await _b1.rest.getConversations()).any((c) => c.id == _group), every: _poll);
      await _eventually(() async => await _held(_c1, _group) == null);
      expect((await _until(_c1.rest.getConversations, every: _poll)).any((c) => c.id == _group), isFalse);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  // Step 6: Dave's phone, approved by his desktop device by the code; then it approves a new desktop device by the
  // code, and another by scanning its QR, with no code.
  test(
    "dave's_phone_is_approved_by_his_desktop_device,_and_approves_two_desktop_devices,_by_code_and_by_qr",
    () async {
      final phone = await _Device.start(dave);
      await phone.engine.start();
      expect(phone.engine.state.value, EngineState.newDevice);
      await phone.engine.beginApproval();
      await phone.engine.useCode();
      final shown = await _noted('dave-desktop-code', timeout: _first);
      expect(shown['device'], phone.device);
      await _eventually(() => phone.engine.state.value.setup?.offered ?? false);
      await phone.engine.acceptCode(shown['code']! as String);
      _note('dave-phone-accepted', {'device': phone.device});
      await _eventually(() => phone.engine.state.value.stage == EngineStage.ready);
      // Set up by the desktop's transfer: the identity the API serves of Dave's.
      final status = await phone.host.gate.handle<Map<String, Object?>>({'cmd': 'status'});
      expect(status['identity_key'], (await _until(() => phone.api.identity(dave.id), every: _poll)).identityKey);

      // A new desktop device asks: this one offers, shows its code, and confirms once it's typed in there.
      DeviceApproval? asked() => phone.engine.state.value.approval;
      await _eventually(() => asked()?.phase == ApprovalPhase.asked);
      final desktop = asked()!.device;
      // The yes names the question it answers (mobile#355).
      await phone.engine.approveDevice(desktop, asked()!.question ?? '');
      await _eventually(() => asked()?.phase == ApprovalPhase.code);
      _note('dave-phone-code', {'device': desktop, 'code': asked()!.code});
      expect(await _noted('dave-desktop-accepted'), {'device': desktop});
      await phone.engine.confirmApproval(desktop);
      await _eventually(() => asked() == null);

      // Another shows its QR: scanned, it's approved with no code.
      final qr = await _noted('dave-desktop-qr');
      final text = qr['qr']! as String;
      final scanned = (await phone.engine.scannedDevice(text))!;
      expect((scanned.id, scanned.listed), (qr['device'], false));
      expect(await phone.engine.approveScanned(text, scanned), isTrue);
      await _eventually(() async => (await phone.engine.scannedDevice(text))?.listed ?? false, every: _poll);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 14)),
  );

  // Step 8: the same security number on both apps; Alice's new keys come with their notice, and the new number is the
  // same on both, before Bob verifies it by scanning her QR and after.
  test(
    'alice_changes_her_keys,_and_her_security_number_with_bob_matches_his_before_and_after_he_verifies',
    () async {
      final before = await _noted('alice-number-before', timeout: _first);
      final ours = await _b1.engine.safetyNumber(alice.id);
      expect(ours.digits, before['digits']);
      _note('bob-number-before', {'digits': ours.digits});

      // Her change: its notice, a plain one as he hadn't verified her, in their conversation.
      await _eventually(() => _b1.engine.contacts.value.changes[alice.id] != null);
      expect(_b1.engine.contacts.value.changes[alice.id]?.verified, isFalse);
      expect((await _b1.engine.keyChangesIn(_dm)).keys, contains(alice.id));
      final after = await _noted('alice-number-after');
      final now = await _b1.engine.safetyNumber(alice.id);
      expect(now.digits, after['digits']);
      expect(now.digits, isNot(ours.digits));
      expect(await _b1.engine.verifyScanned(alice.id, after['qr']! as String), isTrue);
      expect(_b1.engine.contacts.value.verified[alice.id], isTrue);
      final verified = await _b1.engine.safetyNumber(alice.id);
      expect(verified.digits, after['digits']);
      _note('bob-number-verified', {'digits': verified.digits});
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 12)),
  );

  // Step 7: Bob's phone backs up their DM's days, each sealed by its core as its engine seals one (the API dates the
  // messages by its own clock, so none of their days has ended for the engine's own pass), and confirmed. A device of
  // his on the desktop recovers with his key and restores them, then a new phone of his does too: each holds the DM as
  // his first device did, its edits in and its deletions out, a file of it opening.
  test(
    'bob_backs_up_their_dm,_and_a_desktop_device_and_a_new_phone_of_his_restore_it_as_they_recover',
    () async {
      String dayOf(int at) => DateTime.fromMillisecondsSinceEpoch(at, isUtc: true).toIso8601String().substring(0, 10);
      final days = {
        for (final m in await _until(() => _b1.rest.getDirectMessages(_dm), every: _poll))
          if (m.sentAt case final at?) dayOf(at),
      };
      final deleted = await _until(() => _b1.api.deletedMessages(_dm), every: _poll);
      expect(deleted, containsAll(_gone));
      for (final day in days) {
        final built = await _b1.host.gate.handle<Map<String, Object?>>({
          'cmd': 'backup_segment',
          'conversation_id': _dm,
          'day': day,
          'deleted': deleted,
        });
        await _b1.api.putSegment(_dm, day, base64Decode(built['data']! as String));
        await _b1.host.gate.handle<Object?>({
          'cmd': 'backup_uploaded',
          'conversation_id': _dm,
          'day': day,
          'complete': built['complete'],
          'version': built['version'],
        });
      }
      final segments = await _until(() => _b1.api.segments(conversationId: _dm), every: _poll);
      expect({for (final segment in segments) segment.day}, containsAll(days));
      _note('bob-backup-up', {
        'days': [...days],
      });

      // The desktop's device goes on his list first; then a new phone of his.
      await _eventually(
        () async => listDevices((await _b1.api.identity(bob.id)).deviceList)?.length == 2,
        timeout: _first,
        every: _poll,
      );
      final phone = await _Device.start(bob);
      await phone.engine.start();
      expect(phone.engine.state.value, EngineState.newDevice);
      await phone.engine.recover(_bobKey);
      expect(phone.engine.state.value, EngineState.ready);
      for (final (text, author) in [
        (_Script.aliceEdited, alice.id),
        (_Script.aliceWitness, alice.id),
        (_Script.bobEdited(alice.id), bob.id),
        (_Script.bobWitness, bob.id),
        (_Script.bobPicture, bob.id),
      ]) {
        await _read(phone, _dm, text, author);
      }
      expect(await phone.engine.messages(_dm, _gone), isEmpty);
      final picture = await _read(phone, _dm, _Script.alicePicture, alice.id);
      final file = shownFile(picture.row.attachments.single)!;
      expect((await _opened(phone, file, picture.listed)).type, 'image/png');
      await _eventually(() => [BackupStage.uploading, BackupStage.upToDate].contains(phone.engine.backup.value.stage));
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 14)),
  );

  // Review Focus 1: the witness, sent from here and read from the desktop, is in no record of the devices', no file of
  // their folders (their cores' databases are sealed) and nothing this app wrote out. The suite looks through the stack
  // and this half's output.
  test(
    'the_witness_is_nowhere_this_app_keeps_outside_its_cores_databases',
    () async {
      final raw = utf8.encode(_witness);
      final forms = [_witness, _hex(raw)];
      for (var j = 0; j < 3; j++) {
        final run = raw.sublist(j, j + 3 * ((raw.length - j) ~/ 3));
        forms.addAll([base64Encode(run), base64Url.encode(run)]);
      }
      bool holds(String text) => forms.any(text.contains);
      final kept = [
        for (final d in _made)
          for (final entry in d.store.kept.entries) '${entry.key}=${entry.value}',
      ];
      final files = [
        for (final d in _made)
          for (final entity in d.host.folder.listSync(recursive: true))
            if (entity is File) entity,
      ];
      expect(files.any((file) => file.path.endsWith('core.db')), isTrue);
      // What a failure names is where the witness was, never the witness: the suite looks through this output too.
      expect([
        for (final item in kept)
          if (holds(item)) item.split('=').first,
      ], isEmpty);
      expect([
        for (final file in files)
          if (holds(latin1.decode(file.readAsBytesSync()))) file.path,
      ], isEmpty);
      expect(_printed.where(holds).length, 0);
      // The core does hold it: the look went where it was.
      expect(await _shown(_b1, _dm, alice.id, _withText(_Script.aliceWitness)), isNotNull);
      expect(await _shown(_b1, _dm, bob.id, _withText(_Script.bobWitness)), isNotNull);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
