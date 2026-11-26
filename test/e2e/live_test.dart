// The live tests (PLAN-E2E-CLIENTES.md, Task 11): the app's code against a real API and gateway, which the API's suite
// clients-mobile starts and names: E2E_LIVE_API and E2E_LIVE_WS, its seeded accounts (E2E_LIVE_ACCOUNTS, JSON: each
// one's id and email) and their password (E2E_LIVE_PASSWORD). Outside that suite, as in the app's own run, they're
// skipped. Each engine task adds its cases here, on the core the app carries (packages/duvet_e2e).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dart:ui' show IsolateNameServer;

import 'package:duvet/e2e/client.dart';
import 'package:duvet/e2e/content.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/decrypted_files.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet/push/background.dart';
import 'package:duvet/push/push_message.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/eventually.dart';

final _env = Platform.environment;

/// The stack's API and gateway, as the app's router names them.
ApiRouter _router() {
  final api = Uri.parse(_env['E2E_LIVE_API']!);
  return ApiRouter(api: api.authority, ws: Uri.parse(_env['E2E_LIVE_WS']!).authority, secure: api.scheme == 'https');
}

/// The stack's nth seeded account.
({String id, String email}) _account(int n) {
  final account = (jsonDecode(_env['E2E_LIVE_ACCOUNTS'] ?? '[]') as List<dynamic>)[n] as Map<String, dynamic>;
  return (id: account['id'] as String, email: account['email'] as String);
}

/// A device of an account's on the stack, as the app runs one: a session saying what the app is, whose login's
/// challenge the engine keeps; a gateway identified with no device, then once more, as a new session, with the one
/// the engine registers (Ruling 30); and the engine, on a core of its own.
class _Live {
  _Live._(this.rest, this.host, this.readies);

  final duvet.RestClient rest;
  final TestHost host;

  /// The device each READY's identify named.
  final List<String?> readies;

  /// Its engine: another on the same core, record and connection is the app's next start ([_engineOn]).
  late E2EEngine engine;
  late final E2EEngine Function() _engineOn;
  String? device;
  duvet.GatewayManager? _gateway;
  StreamSubscription<duvet.GatewayEventPayload>? _heard;

  duvet.E2eApi get api => duvet.E2eApi(rest);

  /// [kept]: the device outlives its test, for the cases after it, until the file's tests end.
  static Future<_Live> start(ApiRouter router, ({String id, String email}) account, {bool kept = false}) async {
    final rest = duvet.RestClient(http.Client(), router: router, duvetClient: duvetClient());
    final signedIn = await rest.logIn(account.email, _env['E2E_LIVE_PASSWORD'] ?? '');
    final folder = kept ? Directory.systemTemp.createTempSync('duvet-live-') : null;
    final live = _Live._(rest, TestHost(folder: folder), []);
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
      live._heard = gateway.onEvent.listen((event) {
        if (event is duvet.ReadyEvent) live.readies.add(named);
        events.add(event);
      });
      await gateway.connectAll();
    }

    await connect();
    final store = MemoryStore();
    var challenge = switch (signedIn.deviceChallenge) {
      final challenge? => (challenge: challenge, at: DateTime.now()),
      null => null,
    };
    live._engineOn = () {
      // The login's challenge, for the first engine alone.
      final login = challenge;
      challenge = null;
      return E2EEngine(
        host: live.host.gate,
        api: live.api,
        events: events.stream,
        store: store,
        clock: const SystemClock(),
        user: account.id,
        deviceName: 'Pixel 8 Pro',
        registered: (device) {
          live.device = device;
          if (named != device) unawaited(connect());
        },
        loginChallenge: login,
      );
    };
    live.engine = live._engineOn();
    Future<void> end() async {
      await live.engine.stop();
      await live._heard?.cancel();
      live._gateway?.destroy();
      await events.close();
      rest.client.close();
      if (folder != null && folder.existsSync()) folder.deleteSync(recursive: true);
    }

    kept ? _keptLive.add(end) : addTearDown(end);
    return live;
  }
}

/// Another device of [account]'s, set up by [first]'s approval by QR (Task 27 does it in the app) and on the list: its
/// engine started again, as the app's next start, and ready.
Future<_Live> _approvedOn(ApiRouter router, _Live first, ({String id, String email}) account) async {
  final fresh = await _Live.start(router, account);
  await fresh.engine.start();
  expect(fresh.engine.state.value, EngineState.newDevice);
  await fresh.engine.stop();
  final gate = fresh.host.gate;
  await gate.open(account.id);
  final begun = await gate.handle<Map<String, Object?>>({'cmd': 'approval_begin'});
  final approved = await first.host.gate.handle<Map<String, Object?>>({'cmd': 'approval_from_qr', 'qr': begun['qr']});
  await gate.handle<Object?>({'cmd': 'approval_receive', 'transfer': approved['transfer']});
  final served = await fresh.api.identity(account.id);
  final version = await fresh.api.putDeviceList(
    duvet.DeviceListUpload(
      deviceList: approved['device_list']! as String,
      certificate: approved['certificate']! as String,
      baseVersion: served.deviceListVersion,
    ),
  );
  await gate.handle<Object?>({'cmd': 'device_list_uploaded', 'version': version});
  fresh.engine = fresh._engineOn();
  await fresh.engine.start();
  expect(fresh.engine.state.value, EngineState.ready);
  return fresh;
}

/// The ends of the devices kept for later cases ([_Live.start]'s kept), run once the file's tests end.
final _keptLive = <Future<void> Function()>[];

/// Carol's and Dave's devices and their DM, which the groups' case leaves to the messages' case after it.
({_Live c, _Live d, String dm})? _carolAndDave;

void main() {
  final skip = _env['E2E_LIVE_API'] == null ? "only against a stack, in the API's clients-mobile suite" : null;

  test(
    'the client reaches the stack',
    () async {
      final router = _router();
      final alice = _account(0);
      final rest = duvet.RestClient(http.Client(), router: router);
      await rest.logIn(alice.email, _env['E2E_LIVE_PASSWORD'] ?? '');
      final gateway = duvet.GatewayManager(rest, router: router, platform: duvet.ClientPlatform.mobile);
      addTearDown(gateway.destroy);
      // Before connecting: READY comes right after the identify, on a broadcast stream.
      final ready = gateway.ready;
      await gateway.connectAll();
      expect((await ready.timeout(const Duration(seconds: 15))).user.id, alice.id);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // The engine's start (PLAN-E2E-CLIENTES.md, Task 13): a first device, from its registration to its key packages.
  test(
    'a_device_registers,_binds_its_session,_publishes_its_identity_and_its_key_packages',
    () async {
      await loadCore();
      final router = _router();
      final (alice, bob) = (_account(0), _account(1));
      final a = await _Live.start(router, alice);
      await a.engine.start();
      expect(a.engine.state.value, const EngineState.firstDevice());
      final device = a.device!;
      expect(
        [for (final d in await a.api.devices()) (d.id, d.name, d.listed, d.current)],
        [(device, 'Pixel 8 Pro', false, true)],
      );

      await a.engine.makeIdentity();
      expect(shownKey(a.engine.state.value), recoveryKeyShape);
      await a.engine.keySaved();
      expect(a.engine.state.value, EngineState.ready);

      // The API has the identity the core made, with this device listed as its one device.
      final status = await a.host.gate.handle<Map<String, Object?>>({'cmd': 'status'});
      final identity = await a.api.identity(alice.id);
      expect((identity.identityKey, identity.deviceListVersion), (status['identity_key'], 1));
      expect(identity.certificates, [status['certificate']]);
      expect([for (final d in await a.api.devices()) (d.id, d.listed, d.current)], [(device, true, true)]);
      // The gateway took an identify naming the device, a new session's: it hands the device its own events.
      await eventually(() => expect(a.readies, contains(device)), timeout: const Duration(seconds: 15));

      // Its key packages went up (M2 of the desktop's review): Bob, set up too and now her friend, claims one for it.
      final b = await _Live.start(router, bob);
      await b.engine.start();
      await b.engine.makeIdentity();
      await b.engine.keySaved();
      expect(b.engine.state.value, EngineState.ready);
      final asked = await b.rest.sendFriendRequest(alice.id);
      await a.rest.acceptFriendRequest(asked.id);
      final claimed = await b.api.claimKeyPackages(alice.id);
      expect([for (final kp in claimed) kp.deviceId], [device]);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Conversation groups (PLAN-E2E-CLIENTES.md, Task 15): a DM's group, which one of its members makes as they open it,
  // through the API's validator, and the other's device joins by its welcome. Carol and Dave, whom the case above left
  // without identities.
  test(
    "two_users'_devices_reach_the_same_epoch_and_authenticator",
    () async {
      await loadCore();
      final router = _router();
      final (carol, dave) = (_account(2), _account(3));
      final c = await _Live.start(router, carol, kept: true);
      final d = await _Live.start(router, dave, kept: true);
      for (final live in [c, d]) {
        await live.engine.start();
        await live.engine.makeIdentity();
        await live.engine.keySaved();
        expect(live.engine.state.value, EngineState.ready);
      }
      // Friends, and a DM Carol starts, which Dave opens first: either member of a DM makes its group.
      final asked = await c.rest.sendFriendRequest(dave.id);
      await d.rest.acceptFriendRequest(asked.id);
      final dm = await c.rest.createDM(dave.id);
      await d.engine.openConversation(dm.id);
      expect(d.engine.conversationState(dm.id), isNull);

      // Carol's device hears the welcome and comes in: both hold the group at one epoch, with one authenticator.
      Future<Map<String, Object?>?> groupOf(_Live live) => live.host.gate
          .handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': dm.id})
          .then<Map<String, Object?>?>((held) => held, onError: (Object _) => null);
      Map<String, Object?>? daveHeld;
      await eventually(() async {
        daveHeld = await groupOf(d);
        expect(await groupOf(c), allOf(isNotNull, equals(daveHeld)));
      }, timeout: const Duration(seconds: 30));
      expect(daveHeld, allOf(containsPair('generation', 0), containsPair('epoch', 1)));
      _carolAndDave = (c: c, d: d, dm: dm.id);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Encrypted messages (PLAN-E2E-CLIENTES.md, Task 17): Carol's and Dave's devices, in the DM the case above left them,
  // send, answer, edit and delete through the API, which never holds their text.
  test(
    'two_users_converse,_edit_and_delete',
    () async {
      final pair = _carolAndDave;
      if (pair == null) fail('the case before left no conversation');
      final (:c, :d, :dm) = pair;
      final carol = _account(2);
      Future<String?> textOn(_Live live, String id) async => (await live.engine.messages(dm, [id])).firstOrNull?.text;
      const wait = Duration(seconds: 30);

      // Carol's message: Dave's device opens it.
      final sent = (await c.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'hello Dave')))!;
      await eventually(() async => expect(await textOn(d, sent.id), 'hello Dave'), timeout: wait);
      // Dave answers it, mentioning her: hers opens it.
      final reply = (await d.engine.sendMessage(
        Outgoing(conversationId: dm, nonce: uuidv4(), text: 'hi <@${carol.id}>', replyTo: sent.id),
      ))!;
      await eventually(() async => expect(await textOn(c, reply.id), 'hi <@${carol.id}>'), timeout: wait);
      // The API holds their ciphertexts, whom the reply mentions and what it answers, and none of their text.
      final listed = await c.rest.getDirectMessages(dm);
      final [first, answer] = [
        for (final id in [sent.id, reply.id]) listed.firstWhere((m) => m.id == id),
      ];
      expect([first.ciphertext, answer.ciphertext], everyElement(isNotNull));
      expect([first.content, answer.content], everyElement(isNull));
      expect(answer.mentions, [carol.id]);
      expect(answer.referencedMessage?.messageId, sent.id);

      // Carol edits hers: Dave's device shows the edit. Dave deletes his answer: it's gone from both, and from the API.
      await c.engine.editMessage(dm, sent.id, 'hello again');
      await eventually(() async => expect(await textOn(d, sent.id), 'hello again'), timeout: wait);
      await d.engine.deleteMessage(dm, reply.id);
      await eventually(() async => expect(await c.engine.messages(dm, [reply.id]), isEmpty), timeout: wait);
      expect([for (final m in await c.rest.getDirectMessages(dm)) m.id], isNot(contains(reply.id)));
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Encrypted attachments (PLAN-E2E-CLIENTES.md, Task 19): Carol's device seals a file and sends it with its ID; the
  // API keeps its sealed bytes, and Dave's device downloads them from its signed URL, with none of the app's headers
  // and through the storage's redirect, opens them and checks them against what the message says.
  test(
    'a_file_crosses_between_two_users',
    () async {
      final pair = _carolAndDave;
      if (pair == null) fail('the case before left no conversation');
      final (:c, :d, :dm) = pair;
      const wait = Duration(seconds: 30);
      final picture = Uint8List.fromList([
        ...const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
        for (var i = 0; i < 100000; i++) (i * 7) % 256,
      ]);
      final sent = (await c.engine.sendMessage(
        Outgoing(
          conversationId: dm,
          nonce: uuidv4(),
          text: 'a file',
          files: [FileToSeal(bytes: picture, name: 'live.png', width: 10, height: 10)],
        ),
      ))!;
      ShownFile? file;
      await eventually(() async {
        final row = (await d.engine.messages(dm, [sent.id])).firstOrNull;
        expect(row?.status, MessageStatus.ok);
        file = shownFile(row!.attachments.single);
        expect((file?.name, file?.said, file?.size), ('live.png', 'image/png', picture.length));
      }, timeout: wait);
      // The API holds the sealed bytes under the file's ID, named as nothing.
      final listed = (await d.rest.getDirectMessages(dm)).firstWhere((m) => m.id == sent.id);
      final [kept] = listed.attachments!;
      expect(
        (kept.id, kept.filename, kept.contentType, kept.sizeBytes),
        (file!.id, 'file', 'application/octet-stream', sealedSize(picture.length)),
      );
      final router = _router();
      final base = Uri.parse('${router.secure ? 'https' : 'http'}://${router.api}/');
      final client = http.Client();
      addTearDown(client.close);
      final opened = await openSealed(
        file!,
        download: (most, progress) => downloadSigned(client, base.resolve(kept.url!), most, progress: progress),
        open: (key, id, sealed, progress) => d.engine.openFile(key, id, sealed, progress: progress),
      );
      expect(opened.bytes, picture);
      expect(opened.type, 'image/png');
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Devices in Settings (PLAN-E2E-CLIENTES.md, Task 25): Carol's device, which the cases above left set up, takes a
  // device of hers she lost off her account with new keys, which the device that stays takes from its transfer, then
  // takes that one off with a list: each through the API's own checks.
  test(
    'a_lost_device_goes_with_new_keys,_and_another_one_with_a_list',
    () async {
      final pair = _carolAndDave;
      if (pair == null) fail('the case before left no device');
      final c = pair.c;
      final carol = _account(2);
      final router = _router();
      final lost = await _approvedOn(router, c, carol);
      final kept = await _approvedOn(router, c, carol);
      final (own, gone, stays) = (c.device!, lost.device!, kept.device!);
      Future<List<String>> devices() async => [for (final d in await c.api.devices()) d.id]..sort();
      Future<Object?> identityKey(_Live live) async =>
          (await live.host.gate.handle<Map<String, Object?>>({'cmd': 'status'}))['identity_key'];
      const wait = Duration(seconds: 30);
      expect(await devices(), [own, gone, stays]..sort());
      final before = await c.api.identity(carol.id);

      await c.engine.removeDevice(gone, changeKeys: true);
      final shown = c.engine.state.value;
      expect(shown.rotating ? shown.recoveryKey : null, recoveryKeyShape);
      await c.engine.keySaved();
      expect(c.engine.state.value, EngineState.ready);
      final after = await c.api.identity(carol.id);
      expect(after.identityKey, isNot(before.identityKey));
      expect(after.identityKey, await identityKey(c));
      expect(await devices(), [own, stays]..sort());
      await eventually(() => expect(lost.engine.state.value.stage, EngineStage.removed), timeout: wait);
      await eventually(() async => expect(await identityKey(kept), after.identityKey), timeout: wait);

      await c.engine.removeDevice(stays);
      expect(await devices(), [own]);
      await eventually(() => expect(kept.engine.state.value.stage, EngineStage.removed), timeout: wait);
      expect(c.engine.state.value, EngineState.ready);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // Pushes opened on the phone (PLAN-E2E-CLIENTES.md, Task 21; decision 29): Dave's app closed, a push's engine opens
  // Carol's messages with his core, from the queue's own entry as the API's push carries it (here past a gap, as the
  // message before it never pushed) and, for one too long for its entry, from the queue read with his stored session.
  // It runs last, as it stops Dave's app.
  test(
    'a_push_opens_on_the_phone_from_its_entry_or_from_the_queue',
    () async {
      final pair = _carolAndDave;
      if (pair == null) fail('the case before left no conversation');
      final (:c, :d, :dm) = pair;
      final (carol, dave) = (_account(2), _account(3));
      await d.engine.stop();
      // Carol's device, in this process, answers on the core's port: Dave's phone's push engine mustn't find it.
      IsolateNameServer.removePortNameMapping(corePortName);
      final first = (await c.engine.sendMessage(
        Outgoing(conversationId: dm, nonce: uuidv4(), text: 'while Dave was away'),
      ))!;
      final second = (await c.engine.sendMessage(
        Outgoing(conversationId: dm, nonce: uuidv4(), text: 'pushed to Dave'),
      ))!;
      final long = 'a long message to Dave. ' * 200;
      final third = (await c.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: long)))!;
      // The second's entry, as the queue gives it: the push's.
      final page = await d.rest.request(
        'GET',
        '/api/users/@me/conversations/$dm/mls/queue',
        'get queue',
        query: {'after': second.seq! - 1, 'limit': 1},
      );
      final entry = ((jsonDecode(page.body) as Map)['entries'] as List).single;
      Map<String, String> pushOf(duvet.DirectMessage message, {Object? entry}) => {
        'type': 'encrypted_message',
        'message_id': message.id,
        'author_id': carol.id,
        'author_name': 'Carol',
        'author_avatar': '',
        'place': '',
        'sent_at': '${message.sentAt}',
        'conversation_id': dm,
        'seq': '${message.seq}',
        'entry': ?(entry == null ? null : jsonEncode(entry)),
      };
      Future<String> opened(Map<String, String> data) async {
        final client = http.Client();
        addTearDown(client.close);
        final shown = await openedPush(
          Push.fromData(data)! as EncryptedMessagePush,
          earlier: const [],
          session: (token: d.rest.token, sessionToken: d.rest.sessionToken, refreshedAt: null, userId: dave.id),
          core: (wait) =>
              CoreGate(serves: false, keys: d.host.keys, folder: () async => d.host.folder, lockedWait: wait),
          router: _router(),
          duvetClient: duvetClient(),
          client: client,
          store: (_) async => d.engine.store,
        );
        return shown!.text;
      }

      expect(await opened(pushOf(second, entry: entry)), 'pushed to Dave');
      expect(await opened(pushOf(third)), pushText(long));
      // The first, which never pushed, came in from the queue with the second.
      final gate = CoreGate(serves: false, keys: d.host.keys, folder: () async => d.host.folder);
      expect((await gate.open(dave.id)).state, HostState.ready);
      final rows = await shownMessages(gate, dm, [first.id]);
      await gate.close();
      expect([for (final row in rows) row.text], ['while Dave was away']);
    },
    skip: skip ?? noCore,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  tearDownAll(() async {
    for (final end in _keptLive) {
      await end();
    }
  });
}
