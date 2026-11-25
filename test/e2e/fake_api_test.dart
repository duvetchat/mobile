import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/fake_api.dart';

// Real cores (the vendored core's Linux library, through CoreGate) talking through the fake API by hand, with the
// commands and routes the engine will use: what each device sends is what its core made, and what it applies is what
// the fake handed out. The desktop's testing/fake-api.test.ts, case for case.
typedef Json = Map<String, dynamic>;
typedef Reply = ({int status, dynamic body, Map<String, String> headers});

const conversations = '/api/users/@me/conversations';

/// What the app says it is, as each of its requests does (X-Duvet-Client).
const client = 'android/1.1.0';

/// Has each of [fields] (nested matchers allowed), and maybe more.
Matcher has(Map<String, Object?> fields) =>
    allOf([for (final MapEntry(:key, :value) in fields.entries) containsPair(key, value)]);

/// A request as the app sends one: its session's token, and a JSON body or bytes.
Future<Reply> call(FakeApi fake, String? token, String method, String path, [Object? body, String? as = client]) async {
  final request = http.Request(method, Uri.parse('$fakeApiUrl$path'))
    ..headers.addAll({
      'Authorization': ?(token == null ? null : 'Bearer $token'),
      'X-Duvet-Client': ?as,
      'Content-Type': body is Uint8List ? 'application/octet-stream' : 'application/json',
    });
  if (body is Uint8List) {
    request.bodyBytes = body;
  } else if (body != null) {
    request.body = jsonEncode(body);
  }
  final response = await http.Response.fromStream(await fake.client.send(request));
  final json = response.headers['content-type']?.contains('json') ?? false;
  return (
    status: response.statusCode,
    body: json ? jsonDecode(utf8.decode(response.bodyBytes)) : response.bodyBytes,
    headers: response.headers,
  );
}

class Device {
  Device(this.core, this.user, this.id, this.token, this.heard);
  final CoreGate core;
  final String user;
  final String id;
  final String token;

  /// What its connection to the gateway heard.
  final List<GatewayEvent> heard;

  Future<Json> run(Map<String, Object?> command) => core.handle<Json>(command);
}

/// A device of [user]'s: its core and its device made, the device registered and bound to a session, and connected.
Future<Device> device(FakeApi fake, String user) async {
  final folder = Directory.systemTemp.createTempSync('duvet-fake-');
  addTearDown(() => folder.deleteSync(recursive: true));
  final core = CoreGate(serves: true, folder: () async => folder);
  addTearDown(core.close);
  expect(await core.open(user), (state: HostState.ready, keyStorage: 'provided'));
  final (:token, :deviceChallenge) = fake.signIn(user);
  final id = uuidv7();
  final keys = await core.handle<Json>({'cmd': 'create_device', 'user_id': user, 'device_id': id});
  final proof = (await core.handle<Json>({'cmd': 'bind_proof', 'challenge': deviceChallenge}))['proof'];
  final registered = await call(fake, token, 'POST', '/api/users/@me/devices', {
    'device_id': id,
    'name': 'Pixel 8 Pro',
    ...keys,
    'proof': proof,
  });
  expect(registered.status, 201);
  final heard = <GatewayEvent>[];
  fake.connect(token, id, heard.add);
  return Device(core, user, id, token, heard);
}

const identityFields = ['identity_key', 'device_list', 'certificate', 'encrypted_identity', 'wrapped_backup_key'];

/// The device makes its user's identity and publishes it, as a first device does.
Future<(Json, Reply)> publishIdentity(FakeApi fake, Device d) async {
  final made = await d.run({'cmd': 'create_identity'});
  final put = await call(fake, d.token, 'PUT', '/api/users/@me/identity', {
    for (final field in identityFields) field: made[field],
    'replaces': null,
  });
  expect(put.status, 200);
  await d.run({'cmd': 'identity_uploaded'});
  await d.run({'cmd': 'device_list_uploaded', 'version': put.body['device_list_version']});
  return (made, put);
}

/// The device observes [user]'s identity as the API serves it.
Future<Json> observe(FakeApi fake, Device d, String user) async {
  final served = await call(fake, d.token, 'GET', '/api/users/$user/identity');
  expect(served.status, 200);
  return d.run({
    'cmd': 'observe_user',
    'user_id': user,
    for (final field in ['identity_key', 'device_list', 'certificates']) field: served.body[field],
  });
}

/// The device's core makes its key packages (spending those the API handed out), and the device uploads them.
Future<({List<dynamic> keyPackages, List<dynamic> handedOut})> uploadKeyPackages(
  FakeApi fake,
  Device d, [
  List<dynamic>? spent,
]) async {
  final made = await d.run({'cmd': 'key_packages', 'spent': ?spent});
  final put = await call(fake, d.token, 'PUT', '/api/users/@me/devices/@me/key-packages', {
    'key_packages': made['key_packages'],
  });
  expect(put.status, 200);
  return (keyPackages: made['key_packages'] as List<dynamic>, handedOut: put.body['handed_out'] as List<dynamic>);
}

/// A conversation as the API's list gives it to the device: its group as that device has it.
Future<Json> conversationOf(FakeApi fake, Device d, String id) async =>
    ((await call(fake, d.token, 'GET', conversations)).body as List).cast<Json>().firstWhere((c) => c['id'] == id);

/// The device's core applies entries of the conversation's queue.
Future<Json> apply(FakeApi fake, Device d, String conversation, List<dynamic> entries) => d.run({
  'cmd': 'apply',
  'conversation_id': conversation,
  'entries': entries,
  'external_sender': fake.externalSender,
});

/// A DM between Ana and Bo, a device each, and its group: made by Ana's device, joined by Bo's through its welcome.
Future<({FakeApi fake, String ana, String bo, Device a, Device b, String conversation})> dmWithGroup() async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final a = await device(fake, ana);
  final b = await device(fake, bo);
  await publishIdentity(fake, a);
  await publishIdentity(fake, b);
  expect((await uploadKeyPackages(fake, b)).handedOut, isEmpty);
  final conversation = fake.addConversation(group: false, members: [ana, bo]);

  // Ana's device makes the group: the members observed, and a key package claimed for each of their devices.
  await observe(fake, a, ana);
  expect((await observe(fake, a, bo))['state'], 'new');
  final claimed = await call(fake, a.token, 'POST', '/api/users/$bo/key-packages/claim');
  expect([for (final kp in claimed.body['key_packages']) kp['device_id']], [b.id]);
  // The device that asks needs none of its own.
  expect((await call(fake, a.token, 'POST', '/api/users/$ana/key-packages/claim')).body, {'key_packages': []});
  final shown = await conversationOf(fake, a, conversation);
  expect(shown, has({'id': conversation, 'type': 1, 'legacy': false, 'mls': null}));
  final made = await a.run({
    'cmd': 'create_group',
    'conversation_id': conversation,
    'kind': 'dm',
    'members': [for (final member in shown['members']) member['user_id']],
    'key_packages': {
      bo: [for (final kp in claimed.body['key_packages']) kp['data']],
    },
    'external_sender': fake.externalSender,
    'legacy': false,
  });
  final committed = await call(fake, a.token, 'POST', '$conversations/$conversation/mls/commits', {
    'generation': made['generation'],
    'epoch': 0,
    for (final field in ['commit', 'group_info', 'initial_group_info', 'welcome']) field: made[field],
  });
  expect(committed, answers(201, {'seq': 1, 'generation': 0, 'epoch': 1, 'welcome_seq': 2}));
  await a.run({'cmd': 'commit_result', 'conversation_id': conversation, 'accepted': true, 'seq': 1});

  // Bo's device joins by the welcome, read from the number the API says it's been in the group since.
  await pumpEventQueue();
  final heard = b.heard.firstWhere((event) => event.type == 'MLS_WELCOME');
  expect(
    heard.data,
    has({
      'conversation_id': conversation,
      'generation': 0,
      'epoch': 1,
      'devices': [b.id],
    }),
  );
  final mine = await conversationOf(fake, b, conversation);
  expect(mine['mls'], {'generation': 0, 'epoch': 1, 'last_seq': 2, 'floor_seq': 1, 'joined_seq': 2});
  final queue = await call(fake, b.token, 'GET', '$conversations/$conversation/mls/queue?after=1');
  expect(
    [
      for (final entry in queue.body['entries']) [entry['seq'], entry['kind']],
    ],
    [
      [2, 'welcome'],
    ],
  );
  await observe(fake, b, ana);
  await observe(fake, b, bo);
  expect((await apply(fake, b, conversation, queue.body['entries']))['applied_through'], 2);
  return (fake: fake, ana: ana, bo: bo, a: a, b: b, conversation: conversation);
}

/// The device sends a message: its core encrypts it, the API takes it, and the core binds it to its ID.
Future<({String nonce, String ciphertext, Json message})> send(
  FakeApi fake,
  Device d,
  String conversation,
  String text, [
  Map<String, Object?> extra = const {},
]) async {
  final nonce = uuidv7();
  final encrypted = await d.run({
    'cmd': 'encrypt',
    'conversation_id': conversation,
    'nonce': nonce,
    'envelope': messageEnvelope(text, const []),
  });
  final ciphertext = encrypted['ciphertext'] as String;
  final posted = await call(fake, d.token, 'POST', '$conversations/$conversation/messages', {
    'ciphertext': ciphertext,
    'nonce': nonce,
    ...extra,
  });
  expect(posted.status, 201);
  final message = posted.body as Json;
  await d.run({
    'cmd': 'sent',
    'conversation_id': conversation,
    'nonce': nonce,
    'message_id': message['id'],
    'seq': message['seq'],
  });
  return (nonce: nonce, ciphertext: ciphertext, message: message);
}

/// A message as the queue's entry its event's object is (PLAN-E2E-CLIENTES.md, its engine's section on a
/// conversation's queue).
Json messageEntry(Json m) => {
  'seq': m['seq'],
  'kind': 'message',
  'data': m['ciphertext'],
  'message_id': m['id'],
  'sender_user': m['author_id'],
  'sender_device': m['sender_device_id'],
  'sent_at': m['sent_at'],
};

Future<Json> encrypt(Device d, String conversation, String text) => d.run({
  'cmd': 'encrypt',
  'conversation_id': conversation,
  'nonce': uuidv7(),
  'envelope': {'text': text},
});

/// An answer of [status], and its [body] (a value, or a matcher) when given.
Matcher answers(int status, [Object? body]) =>
    isA<Reply>().having((r) => r.status, 'status', status).having((r) => r.body, 'body', body ?? anything);

/// A refusal of [status] whose body has [fields].
Matcher refusedWith(int status, [Map<String, Object?>? fields]) => answers(status, fields == null ? null : has(fields));

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('the fake API, with real cores', () {
    test('two cores converse through the fake', () async {
      final (:fake, :ana, :bo, :a, :b, :conversation) = await dmWithGroup();
      final group = await b.run({'cmd': 'group', 'conversation_id': conversation});
      expect([for (final member in group['members']) member['user_id']], [ana, bo]);

      // Ana writes: Bo's device applies the message its event brings, and reads it.
      final (:nonce, ciphertext: _, :message) = await send(fake, a, conversation, 'hello Bo');
      expect(message, has({'seq': 3, 'author_id': ana, 'sender_device_id': a.id, 'nonce': nonce, 'content': null}));
      await pumpEventQueue();
      final created = b.heard.firstWhere((event) => event.type == 'DM_MESSAGE_CREATE').data! as Json;
      expect(created, message);
      expect((await apply(fake, b, conversation, [messageEntry(created)]))['applied_through'], 3);
      final read = await b.run({
        'cmd': 'messages',
        'conversation_id': conversation,
        'ids': [created['id']],
      });
      expect(read['messages'], [
        has({
          'message_id': created['id'],
          'seq': 3,
          'text': 'hello Bo',
          'status': 'ok',
          'user_id': ana,
          'device_id': a.id,
        }),
      ]);

      // Bo sends a sticker: the empty envelope, the sticker in the clear. Ana's device reads it from the queue alone.
      final sticker = uuidv7();
      final (message: stuck, nonce: _, ciphertext: _) = await send(fake, b, conversation, '', {
        'sticker_attachment_id': sticker,
      });
      expect(stuck, has({'seq': 4, 'sticker_attachment_id': sticker}));
      final queue = await call(fake, a.token, 'GET', '$conversations/$conversation/mls/queue?after=0');
      expect(queue.body, has({'last_seq': 4, 'floor_seq': 1, 'generation': 0, 'epoch': 1}));
      expect(
        [
          for (final entry in queue.body['entries']) [entry['seq'], entry['kind']],
        ],
        [
          [1, 'commit'],
          [2, 'welcome'],
          [3, 'message'],
          [4, 'message'],
        ],
      );
      expect((await apply(fake, a, conversation, queue.body['entries']))['applied_through'], 4);
      final shown =
          (await a.run({
                'cmd': 'messages',
                'conversation_id': conversation,
                'ids': [stuck['id']],
              }))['messages'].single
              as Json;
      expect(shown, has({'text': null, 'attachments': [], 'status': 'ok', 'user_id': bo}));
      final attachments = (shown['attachments'] as List).cast<Map<String, Object?>>();
      expect(drawnAs(text: shown['text'] as String?, attachments: attachments, sticker: true), Drawn.sticker);
      // A page of the queue stops at its limit.
      final page = await call(fake, a.token, 'GET', '$conversations/$conversation/mls/queue?after=1&limit=2');
      expect([for (final entry in page.body['entries']) entry['seq']], [2, 3]);
    });

    test('one commit takes an epoch, and the same commit again gets the answer it got', () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await dmWithGroup();
      final path = '$conversations/$conversation/mls/commits';
      final first = await a.run({'cmd': 'refresh', 'conversation_id': conversation});
      final second = await b.run({'cmd': 'refresh', 'conversation_id': conversation});
      final won = await call(fake, a.token, 'POST', path, {'generation': 0, 'epoch': 1, ...first});
      expect(won, answers(201, {'seq': 3, 'generation': 0, 'epoch': 2}));
      expect(
        await call(fake, b.token, 'POST', path, {'generation': 0, 'epoch': 1, ...second}),
        refusedWith(409, {'error': 'another commit took this epoch', 'generation': 0, 'epoch': 2}),
      );
      expect((await call(fake, a.token, 'POST', path, {'generation': 0, 'epoch': 1, ...first})).body, won.body);
      // A commit whose framing isn't what the request says is refused before anything.
      expect((await call(fake, b.token, 'POST', path, {'generation': 0, 'epoch': 2, ...second})).status, 400);
      await pumpEventQueue();
      expect(
        [for (final event in b.heard.where((e) => e.type == 'MLS_COMMIT')) (event.data! as Json)['epoch']],
        [1, 2],
      );

      await a.run({'cmd': 'commit_result', 'conversation_id': conversation, 'accepted': true, 'seq': 3});
      await b.run({'cmd': 'commit_result', 'conversation_id': conversation, 'accepted': false});
      final queue = await call(fake, b.token, 'GET', '$conversations/$conversation/mls/queue?after=2');
      expect(queue.body, has({'last_seq': 3, 'generation': 0, 'epoch': 2}));
      expect((await apply(fake, b, conversation, queue.body['entries']))['applied_through'], 3);
      for (final d in [a, b]) {
        expect((await d.run({'cmd': 'group', 'conversation_id': conversation}))['epoch'], 2);
      }
      final (:message, nonce: _, ciphertext: _) = await send(fake, a, conversation, 'after the commit');
      expect((await apply(fake, b, conversation, [messageEntry(message)]))['applied_through'], 4);
    });

    test("a message's nonce answers with the message it sent, and its edit and deletion go in the queue", () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await dmWithGroup();
      final (:nonce, :ciphertext, :message) = await send(fake, a, conversation, 'once');
      final path = '$conversations/$conversation/messages';
      final again = await call(fake, a.token, 'POST', path, {'ciphertext': ciphertext, 'nonce': nonce});
      expect(again, answers(201, message));
      final other = await encrypt(a, conversation, 'twice');
      expect(
        (await call(fake, a.token, 'POST', path, {'ciphertext': other['ciphertext'], 'nonce': nonce})).status,
        409,
      );
      // The conversation's text never goes in the clear.
      expect(
        (await call(fake, a.token, 'POST', path, {'content': 'hi', 'ciphertext': ciphertext, 'nonce': uuidv7()})).body,
        {'error': 'conversations are end-to-end encrypted'},
      );
      await pumpEventQueue();
      expect(b.heard.where((event) => event.type == 'DM_MESSAGE_CREATE'), hasLength(1));

      final edit = await a.run({
        'cmd': 'edit',
        'conversation_id': conversation,
        'message_id': message['id'],
        'text': 'once more',
      });
      final edited = await call(fake, a.token, 'PATCH', '$path/${message['id']}', {'ciphertext': edit['ciphertext']});
      expect(edited.status, 200);
      expect(
        edited.body,
        has({
          'id': message['id'],
          'entry': has({'seq': 4, 'kind': 'edit', 'message_id': message['id']}),
        }),
      );
      expect(
        (await call(fake, a.token, 'PATCH', '$path/${message['id']}', {'ciphertext': edit['ciphertext']})).body,
        edited.body,
      );
      expect(
        (await call(fake, b.token, 'PATCH', '$path/${message['id']}', {'ciphertext': edit['ciphertext']})).status,
        403,
      );
      final tombstone = await a.run({'cmd': 'delete', 'conversation_id': conversation, 'message_id': message['id']});
      final deleted = await call(fake, a.token, 'DELETE', '$path/${message['id']}', {
        'ciphertext': tombstone['ciphertext'],
      });
      expect(deleted.status, 200);
      expect(
        deleted.body,
        has({
          'id': message['id'],
          'entry': has({'seq': 5, 'kind': 'delete'}),
        }),
      );
      await pumpEventQueue();
      expect(b.heard.firstWhere((event) => event.type == 'DM_MESSAGE_DELETE').data, {
        'id': message['id'],
        'conversation_id': conversation,
        'entry': deleted.body['entry'],
      });

      // The queue has the message and its edit emptied, and the deletion whole; Bo's core applies them all.
      final queue = (await call(fake, b.token, 'GET', '$conversations/$conversation/mls/queue?after=2')).body;
      expect(
        [
          for (final entry in queue['entries'])
            [entry['seq'], entry['kind'], entry['deleted'] ?? false, entry['data'] == ''],
        ],
        [
          [3, 'message', true, true],
          [4, 'edit', true, true],
          [5, 'delete', false, false],
        ],
      );
      expect((await apply(fake, b, conversation, queue['entries']))['applied_through'], 5);
      expect((await call(fake, b.token, 'GET', '$path/deleted?after=0')).body, {
        'ids': [message['id']],
      });
    });

    test('a device list goes in only on top of the current one', () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await device(fake, ana);
      await publishIdentity(fake, a);
      const path = '/api/users/@me/device-list';
      final second = await a.run({'cmd': 'sign_device_list', 'remove': []});
      expect((await call(fake, a.token, 'PUT', path, {'device_list': second['device_list'], 'base_version': 1})).body, {
        'version': 2,
      });
      await a.run({'cmd': 'device_list_uploaded', 'version': 2});
      // The current list again, byte for byte, is taken as it is.
      expect((await call(fake, a.token, 'PUT', path, {'device_list': second['device_list'], 'base_version': 1})).body, {
        'version': 2,
      });
      await observe(fake, a, ana);
      final third = await a.run({'cmd': 'sign_device_list', 'remove': []});
      expect(
        await call(fake, a.token, 'PUT', path, {'device_list': third['device_list'], 'base_version': 1}),
        refusedWith(409, {'error': 'device list changed', 'device_list': second['device_list'], 'version': 2}),
      );
      expect((await call(fake, a.token, 'PUT', path, {'device_list': third['device_list'], 'base_version': 2})).body, {
        'version': 3,
      });
      expect(
        (await call(fake, a.token, 'GET', '/api/users/$ana/identity')).body,
        has({'user_id': ana, 'device_list': third['device_list'], 'device_list_version': 3, 'active': true}),
      );
      await pumpEventQueue();
      final updates = a.heard.where((event) => event.type == 'IDENTITY_UPDATE');
      expect([for (final event in updates) (event.data! as Json)['device_list_version']], [1, 2, 3]);
      // A list the identity didn't sign is refused whatever its versions say.
      final forged = base64Decode(third['device_list'] as String);
      forged[10] ^= 1;
      expect(
        (await call(fake, a.token, 'PUT', path, {'device_list': base64Encode(forged), 'base_version': 3})).status,
        400,
      );
    });

    test('an identity goes up once, and another first device is told the one there is', () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await device(fake, ana);
      final (made, put) = await publishIdentity(fake, a);
      final again = {for (final field in identityFields) field: made[field], 'replaces': null};
      expect((await call(fake, a.token, 'PUT', '/api/users/@me/identity', again)).body, put.body);

      final a2 = await device(fake, ana);
      final other = await a2.run({'cmd': 'create_identity'});
      final raced = await call(fake, a2.token, 'PUT', '/api/users/@me/identity', {
        for (final field in identityFields) field: other[field],
        'replaces': null,
      });
      expect(raced, refusedWith(409, {'error': 'identity changed', 'identity_key': made['identity_key']}));
      expect((await call(fake, a2.token, 'GET', '/api/users/@me/identity/backup')).body, {
        for (final field in ['identity_key', 'device_list', 'encrypted_identity', 'wrapped_backup_key'])
          field: made[field],
        'wrapped_previous_backup_keys': null,
      });
    });

    test('a key package is handed out once, and an upload names those handed out', () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final (a, b, c) = (await device(fake, ana), await device(fake, bo), await device(fake, cy));
      for (final d in [a, b, c]) {
        await publishIdentity(fake, d);
      }
      fake.addConversation(group: false, members: [ana, bo]);
      final set = (await uploadKeyPackages(fake, b)).keyPackages;
      expect(set.where((kp) => kp['last_resort'] == true), hasLength(1));
      Future<Reply> claim(Device d) => call(fake, d.token, 'POST', '/api/users/$bo/key-packages/claim');
      expect((await claim(c)).status, 403); // Cy shares no conversation with Bo

      final claimed = [
        (await claim(a)).body['key_packages'][0]['data'],
        (await claim(a)).body['key_packages'][0]['data'],
      ];
      expect(claimed[0], isNot(claimed[1]));
      final handedOut = [
        for (final kp in set)
          if (claimed.contains(kp['data'])) kp['id'],
      ];
      expect(handedOut, hasLength(2));
      // The same set again: the API names the two it handed out, which the core then spends, making two in their place.
      final put = await call(fake, b.token, 'PUT', '/api/users/@me/devices/@me/key-packages', {'key_packages': set});
      expect(put.body['handed_out'], unorderedEquals(handedOut));
      final renewed = await uploadKeyPackages(fake, b, put.body['handed_out'] as List);
      expect(renewed.handedOut, isEmpty);
      expect([for (final kp in renewed.keyPackages) kp['id']], isNot(contains(handedOut[0])));

      // The single-use ones run out, then the last resort goes again and again; under 20 left, the device hears it.
      final lastResort = renewed.keyPackages.firstWhere((kp) => kp['last_resort'] == true)['data'];
      final given = [for (var i = 0; i < 102; i++) (await claim(a)).body['key_packages'][0]['data']];
      expect(given.take(100).toSet(), hasLength(100));
      expect(given.take(100), isNot(contains(lastResort)));
      expect(given.skip(100), [lastResort, lastResort]);
      await pumpEventQueue();
      final low = [for (final event in b.heard.where((e) => e.type == 'KEY_PACKAGES_LOW')) event.data];
      expect(low.first, {'device_id': b.id, 'remaining': 19});
      expect(a.heard.where((event) => event.type == 'KEY_PACKAGES_LOW'), isEmpty);
    });

    test('the inbox hands out what came after, and deletes through what was handled', () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final (a, b, c) = (await device(fake, ana), await device(fake, bo), await device(fake, cy));
      fake.addConversation(group: false, members: [ana, bo]);
      // Another connection of Bo's, of no device: it hears its user's events, never a device's.
      final elsewhere = <GatewayEvent>[];
      fake.connect(b.token, null, elsewhere.add);
      final to = '/api/devices/${b.id}/inbox';
      String text(String value) => base64Encode(utf8.encode(value));
      final one = await call(fake, a.token, 'POST', to, {'message': text('one')});
      final two = await call(fake, a.token, 'POST', to, {'message': text('two')});
      expect([one.status, two.status], [201, 201]);
      expect((await call(fake, c.token, 'POST', to, {'message': text('cy')})).status, 403);
      final big = base64Encode(Uint8List(64 * 1024 + 1));
      expect((await call(fake, a.token, 'POST', to, {'message': big})).status, 400);
      await pumpEventQueue();
      expect(
        [for (final event in b.heard.where((e) => e.type == 'DEVICE_MESSAGE')) event.data],
        [
          {'device_id': b.id, 'id': one.body['id']},
          {'device_id': b.id, 'id': two.body['id']},
        ],
      );

      const inbox = '/api/users/@me/devices/@me/inbox';
      final all = (await call(fake, b.token, 'GET', inbox)).body as List;
      expect(
        [
          for (final m in all)
            [m['id'], m['from_user_id'], m['from_device_id'], utf8.decode(base64Decode(m['message']))],
        ],
        [
          [one.body['id'], ana, a.id, 'one'],
          [two.body['id'], ana, a.id, 'two'],
        ],
      );
      expect(
        [for (final m in (await call(fake, b.token, 'GET', '$inbox?after=${one.body['id']}')).body) m['id']],
        [two.body['id']],
      );
      expect((await call(fake, b.token, 'DELETE', '$inbox?through=${one.body['id']}')).status, 204);
      expect([for (final event in elsewhere) event.type], ['READY']);
      expect([for (final m in (await call(fake, b.token, 'GET', inbox)).body) m['id']], [two.body['id']]);
    });

    test("a day's backup replaces only the copy it names", () async {
      final (:fake, ana: _, bo: _, :a, b: _, :conversation) = await dmWithGroup();
      final (:message, nonce: _, ciphertext: _) = await send(fake, a, conversation, 'kept in the backup');
      // The message's UTC day: backup_due lists a day once it ended, but any day seals.
      final day = DateTime.fromMillisecondsSinceEpoch(
        message['sent_at'] as int,
        isUtc: true,
      ).toIso8601String().substring(0, 10);
      final segment = await a.run({'cmd': 'backup_segment', 'conversation_id': conversation, 'day': day});
      final bytes = base64Decode(segment['data'] as String);
      final path = '/api/users/@me/backup/segments/$conversation/$day';
      final first = await call(fake, a.token, 'PUT', '$path?replaces=none', bytes);
      expect(first.status, 201);
      expect(
        await call(fake, a.token, 'PUT', '$path?replaces=none', bytes),
        refusedWith(409, {'current': first.body['id']}),
      );
      final second = await call(fake, a.token, 'PUT', '$path?replaces=${first.body['id']}', bytes);
      expect(second.status, 201);
      await a.run({
        'cmd': 'backup_uploaded',
        'conversation_id': conversation,
        'day': day,
        'complete': segment['complete'],
        'version': segment['version'],
      });

      expect((await call(fake, a.token, 'GET', '/api/users/@me/backup/segments?conversation_id=$conversation')).body, [
        has({
          'id': second.body['id'],
          'conversation_id': conversation,
          'day': day,
          'complete': segment['complete'],
          'key_id': segment['key_id'],
          'size': bytes.length,
          'created_at': isA<String>(),
        }),
      ]);
      final downloaded = await call(fake, a.token, 'GET', '/api/users/@me/backup/segments/${second.body['id']}');
      expect(base64Encode(downloaded.body as Uint8List), segment['data']);
      // The header names its conversation and its day: another route's isn't taken.
      expect(
        (await call(
          fake,
          a.token,
          'PUT',
          '/api/users/@me/backup/segments/$conversation/2001-01-01?replaces=none',
          bytes,
        )).status,
        400,
      );
    });

    test('a shared history goes up in parts, for its recipient\'s devices', () async {
      final (:fake, :ana, :bo, :a, :b, :conversation) = await dmWithGroup();
      await send(fake, a, conversation, 'shared with Bo');
      final certificates = (await call(fake, a.token, 'GET', '/api/users/$bo/identity')).body['certificates'];
      final made = await a.core.share({
        'cmd': 'history_share',
        'conversation_id': conversation,
        'to_user': bo,
        'range': 'all',
        'devices': certificates,
      });
      expect([for (final key in made['keys']! as List) key['device_id']], [b.id]);
      final share = '$conversations/$conversation/history-shares/${made['share_id']}';
      final about = {
        'to_user_id': bo,
        'kind': 'share',
        'range': 'all',
        'starts_at': made['start'],
        'size': made['size'],
        'parts': made['parts'],
      };
      expect((await call(fake, a.token, 'PUT', share, about)).status, 201);
      expect((await call(fake, a.token, 'POST', '$share/complete')).status, 409); // its parts aren't up yet
      for (var n = 0; n < (made['parts']! as int); n++) {
        final part = await a.core.sharePart(made['share_id']! as String, n);
        expect((await call(fake, a.token, 'PUT', '$share/parts/$n', part)).status, 204);
      }
      expect((await call(fake, a.token, 'POST', '$share/complete')).status, 204);
      for (final key in made['keys']! as List) {
        final sent = await call(fake, a.token, 'POST', '/api/devices/${key['device_id']}/inbox', {
          'message': key['message'],
        });
        expect(sent.status, 201);
      }
      await a.core.dropShare(made['share_id']! as String);

      // Bo's device hears of it, takes its key from the inbox and its parts from the API, imports it, and says so.
      await pumpEventQueue();
      expect(
        b.heard.firstWhere((event) => event.type == 'HISTORY_SHARE_CREATE').data,
        has({
          'id': made['share_id'],
          'conversation_id': conversation,
          'from_user_id': ana,
          'kind': 'share',
          'range': 'all',
          'parts': made['parts'],
        }),
      );
      final notice = b.heard
          .firstWhere((event) => event.type == 'DM_MESSAGE_CREATE' && (event.data! as Json)['type'] == 4)
          .data;
      expect(
        notice,
        has({
          'author_id': ana,
          'history_share': {'to_user_id': bo, 'range': 'all'},
        }),
      );
      expect(notice, isNot(contains('seq')));
      expect(
        [for (final s in (await call(fake, b.token, 'GET', '/api/users/@me/history-shares')).body) s['id']],
        [made['share_id']],
      );
      final from = (await call(fake, b.token, 'GET', '/api/users/$ana/identity')).body['certificates'][0];
      for (final m in (await call(fake, b.token, 'GET', '/api/users/@me/devices/@me/inbox')).body) {
        expect(
          await b.run({'cmd': 'receive_direct', 'message': m['message'], 'from_certificate': from}),
          has({'type': 'history.key'}),
        );
      }
      final parts = <Uint8List>[
        for (var n = 0; n < (made['parts']! as int); n++)
          (await call(fake, b.token, 'GET', '/api/history-shares/${made['share_id']}/parts/$n')).body as Uint8List,
      ];
      expect(await b.core.importShare(made['share_id']! as String, parts), has({'imported': isA<int>()}));
      expect((await call(fake, b.token, 'POST', '/api/history-shares/${made['share_id']}/ack')).status, 204);
      expect((await call(fake, b.token, 'GET', '/api/users/@me/history-shares')).body, isEmpty);
    });

    test('a device registers once, then binds each new session', () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final a = await device(fake, ana);
      expect(await a.run({'cmd': 'status'}), has({'user_id': ana, 'device_id': a.id}));

      final again = fake.signIn(ana);
      expect((await call(fake, again.token, 'GET', '/api/users/@me/devices')).body, [
        has({'id': a.id, 'name': 'Pixel 8 Pro', 'listed': false, 'current': false}),
      ]);
      // A proof over another session's challenge doesn't bind this one.
      final stale = await a.run({'cmd': 'bind_proof', 'challenge': fake.signIn(ana).deviceChallenge});
      expect(
        await call(fake, again.token, 'POST', '/api/users/@me/devices/${a.id}/bind', stale),
        refusedWith(403, {'error': "the proof doesn't verify"}),
      );
      final proof = await a.run({'cmd': 'bind_proof', 'challenge': again.deviceChallenge});
      expect((await call(fake, again.token, 'POST', '/api/users/@me/devices/${a.id}/bind', proof)).status, 204);
      expect((await call(fake, again.token, 'GET', '/api/users/@me/devices')).body, [
        has({'id': a.id, 'current': true}),
      ]);
      // Its ID is its own: another user's registration of it is refused.
      final folder = Directory.systemTemp.createTempSync('duvet-fake-');
      addTearDown(() => folder.deleteSync(recursive: true));
      final b = CoreGate(serves: true, folder: () async => folder);
      addTearDown(b.close);
      await b.open(bo);
      final theirs = fake.signIn(bo);
      final made = await b.handle<Json>({'cmd': 'create_device', 'user_id': bo, 'device_id': a.id});
      final bos = await b.handle<Json>({'cmd': 'bind_proof', 'challenge': theirs.deviceChallenge});
      expect(
        await call(fake, theirs.token, 'POST', '/api/users/@me/devices', {
          'device_id': a.id,
          'name': 'Duvet',
          ...made,
          'proof': bos['proof'],
        }),
        refusedWith(409, {'error': 'device id in use'}),
      );
      // A device on its user's list goes only by a list without it.
      await publishIdentity(fake, a);
      expect(
        await call(fake, a.token, 'DELETE', '/api/users/@me/devices/${a.id}'),
        refusedWith(409, {'error': 'sign a device list without it'}),
      );
    });
  }, skip: noCore);

  group("the fake's switches", () {
    test('a lost answer leaves its work done', () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await device(fake, ana);
      final made = await a.run({'cmd': 'create_identity'});
      final body = {for (final field in identityFields) field: made[field], 'replaces': null};
      fake.loseAnswer((method: 'PUT', path: '/api/users/@me/identity'));
      await expectLater(
        call(fake, a.token, 'PUT', '/api/users/@me/identity', body),
        throwsA(isA<http.ClientException>()),
      );
      expect(
        (await call(fake, a.token, 'GET', '/api/users/$ana/identity')).body,
        has({'identity_key': made['identity_key']}),
      );
      // The same upload again is the identity there is: 200, as it would have been.
      final again = await call(fake, a.token, 'PUT', '/api/users/@me/identity', body);
      expect((again.status, again.body['device_list_version']), (200, 1));
    });

    test('426, 503 and 409 answer as the API does, and change nothing', () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await dmWithGroup();
      final path = '$conversations/$conversation/messages';
      final encrypted = await encrypt(a, conversation, 'later');
      final message = {'ciphertext': encrypted['ciphertext'], 'nonce': uuidv7()};
      fake.refuse((method: 'POST', path: path), 503);
      final paused = await call(fake, a.token, 'POST', path, message);
      expect(paused, refusedWith(503, {'error': 'encrypted conversations are paused'}));
      expect(paused.headers['retry-after'], '60');
      fake.refuse((method: null, path: path), 426);
      expect(
        await call(fake, a.token, 'POST', path, message),
        refusedWith(426, {'error': 'update Duvet', 'client': null, 'minimum': null}),
      );
      fake.refuse(
        (method: null, path: RegExp(r'/messages$')),
        409,
        body: {'error': 'stale message', 'generation': 0, 'epoch': 1},
      );
      expect(await call(fake, a.token, 'POST', path, message), refusedWith(409, {'error': 'stale message'}));
      await pumpEventQueue();
      expect(b.heard.where((event) => event.type == 'DM_MESSAGE_CREATE'), isEmpty);
      // Each switch answered once: the message goes now, the next number of the queue.
      expect(await call(fake, a.token, 'POST', path, message), answers(201, has({'seq': 3})));
    });

    test('events can wait, then come backwards or twice, and an entry can come without its data', () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await dmWithGroup();
      fake.holdEvents();
      final first = await send(fake, a, conversation, 'first');
      final second = await send(fake, a, conversation, 'second');
      await pumpEventQueue();
      final before = b.heard.length;
      fake.releaseEvents(reverse: true, repeat: true);
      expect(
        [for (final event in b.heard.skip(before)) (event.data! as Json)['id']],
        [second.message['id'], second.message['id'], first.message['id'], first.message['id']],
      );

      fake.stripData = true;
      final refresh = await a.run({'cmd': 'refresh', 'conversation_id': conversation});
      final committed = await call(fake, a.token, 'POST', '$conversations/$conversation/mls/commits', {
        'generation': 0,
        'epoch': 1,
        ...refresh,
      });
      await pumpEventQueue();
      final event = b.heard.lastWhere((heard) => heard.type == 'MLS_COMMIT');
      final entry = (event.data! as Json)['entry'] as Json;
      expect(entry, has({'seq': committed.body['seq'], 'kind': 'commit'}));
      expect(entry, isNot(contains('data')));
      // The queue still has it whole.
      final queue = await call(
        fake,
        b.token,
        'GET',
        '$conversations/$conversation/mls/queue?after=${(committed.body['seq'] as int) - 1}',
      );
      expect(queue.body['entries'][0]['data'], isA<String>());
    });
  }, skip: noCore);

  group('the fake answers as the API does', () {
    test('held events are what each request saved', () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await dmWithGroup();
      fake.holdEvents();
      final (:message, nonce: _, ciphertext: _) = await send(fake, a, conversation, 'first words');
      final path = '$conversations/$conversation/messages/${message['id']}';
      final edit = await a.run({
        'cmd': 'edit',
        'conversation_id': conversation,
        'message_id': message['id'],
        'text': 'second words',
      });
      await call(fake, a.token, 'PATCH', path, {'ciphertext': edit['ciphertext']});
      final tombstone = await a.run({'cmd': 'delete', 'conversation_id': conversation, 'message_id': message['id']});
      await call(fake, a.token, 'DELETE', path, {'ciphertext': tombstone['ciphertext']});
      await pumpEventQueue();
      final before = b.heard.length;
      fake.releaseEvents();
      final [created, updated, ...] = b.heard.skip(before).toList();
      expect(created.type, 'DM_MESSAGE_CREATE');
      expect(created.data, has({'id': message['id'], 'ciphertext': message['ciphertext']}));
      expect(updated.type, 'DM_MESSAGE_UPDATE');
      final entry = (updated.data! as Json)['entry'] as Json;
      expect(entry, has({'kind': 'edit', 'data': edit['ciphertext']}));
      expect(entry, isNot(contains('deleted')));
    });

    test('a client without encryption is told to update, but for the configuration and the list', () async {
      final fake = FakeApi();
      final token = fake.signIn(fake.addUser()).token;
      Future<Reply> ask(String? as, [String path = '/api/users/@me/devices']) =>
          call(fake, token, 'GET', path, null, as);
      Matcher update(String? client, String? minimum) =>
          answers(426, {'error': 'update Duvet', 'client': client, 'minimum': minimum});
      expect(await ask(null), update(null, null));
      expect(await ask('android/1.1'), update(null, null));
      expect(await ask('desktop-linux/1.2.0'), update('desktop-linux/1.2.0', null));
      fake.minClients = {...fake.minClients, 'android': '1.1.0'};
      expect(await ask('android/1.0.9'), update('android/1.0.9', '1.1.0'));
      expect(await ask('android/1.10.0'), answers(200, []));
      expect(await ask(null, '/api/e2e'), answers(200, has({'min_clients': fake.minClients})));
      expect(await ask(null, conversations), answers(200, []));
    });

    test("a request's answer comes before its events", () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await dmWithGroup();
      await pumpEventQueue();
      final order = <String>[];
      fake.connect(b.token, b.id, (event) {
        if (event.type != 'READY') order.add(event.type);
      });
      final encrypted = await encrypt(a, conversation, 'the answer first');
      final response = await fake.client.post(
        Uri.parse('$fakeApiUrl$conversations/$conversation/messages'),
        headers: {'Authorization': 'Bearer ${a.token}', 'X-Duvet-Client': client, 'Content-Type': 'application/json'},
        body: jsonEncode({'ciphertext': encrypted['ciphertext'], 'nonce': uuidv7()}),
      );
      order.add('answer ${response.statusCode}');
      await pumpEventQueue();
      expect(order, ['answer 201', 'DM_MESSAGE_CREATE']);
    });

    test("the bodies the API's binding refuses are a 400", () async {
      final fake = FakeApi();
      final a = await device(fake, fake.addUser());
      final made = await a.run({'cmd': 'create_identity'});
      final identity = {for (final field in identityFields) field: made[field], 'replaces': null};
      final big = base64Encode(Uint8List(64 * 1024 + 1));
      for (final transfers in [
        'all',
        [null],
        [
          {'device_id': a.id, 'certificate': made['certificate'], 'message': 'not base64!'},
        ],
        [
          {'device_id': a.id, 'certificate': made['certificate'], 'message': big},
        ],
      ]) {
        expect(
          (await call(fake, a.token, 'PUT', '/api/users/@me/identity', {...identity, 'transfers': transfers})).status,
          400,
        );
      }
      expect((await call(fake, a.token, 'PUT', '/api/users/@me/identity', identity)).status, 200);
      final first = ((await a.run({'cmd': 'key_packages'}))['key_packages'] as List).first as Json;
      const path = '/api/users/@me/devices/@me/key-packages';
      for (final body in [
        <String, Object?>{},
        {
          'key_packages': [
            {...first, 'id': ''},
          ],
        },
        {
          'key_packages': [
            {...first, 'data': ''},
          ],
        },
      ]) {
        expect((await call(fake, a.token, 'PUT', path, body)).status, 400);
      }
    });

    test('a device with nothing to hand out hears it, at 0', () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final (a, b) = (await device(fake, ana), await device(fake, bo));
      for (final d in [a, b]) {
        await publishIdentity(fake, d);
      }
      fake.addConversation(group: false, members: [ana, bo]);
      expect((await call(fake, a.token, 'POST', '/api/users/$bo/key-packages/claim')).body, {'key_packages': []});
      await pumpEventQueue();
      expect(
        [for (final event in b.heard.where((e) => e.type == 'KEY_PACKAGES_LOW')) event.data],
        [
          {'device_id': b.id, 'remaining': 0},
        ],
      );
    });

    test("a rotation's transfer takes the place of the device's earlier one, outside the inbox's cap", () async {
      final fake = FakeApi();
      final ana = fake.addUser();
      final a = await device(fake, ana);
      final (made, _) = await publishIdentity(fake, a);
      // A second device of Ana's, which the first approves by its QR and which lists itself.
      final a2 = await device(fake, ana);
      final begun = await a2.run({'cmd': 'approval_begin'});
      final approved = await a.run({'cmd': 'approval_from_qr', 'qr': begun['qr']});
      final list = {'device_list': approved['device_list'], 'base_version': 1, 'certificate': approved['certificate']};
      expect((await call(fake, a2.token, 'PUT', '/api/users/@me/device-list', list)).body, {'version': 2});
      await a.run({'cmd': 'device_list_uploaded', 'version': 2});
      await observe(fake, a, ana);
      // Its inbox is full of what was sent to it.
      final inbox = '/api/devices/${a2.id}/inbox';
      final sent = [
        for (var i = 0; i < 1000; i++)
          (await call(fake, a.token, 'POST', inbox, {'message': base64Encode(utf8.encode('$i'))})).body['id'],
      ];
      expect(
        (await call(fake, a.token, 'POST', inbox, {'message': base64Encode(utf8.encode('one more'))})).status,
        409,
      );
      // A rotation's transfer goes in all the same, and the same rotation sent again puts its new one in that one's place.
      final certificates = (await call(fake, a.token, 'GET', '/api/users/$ana/identity')).body['certificates'];
      final transferred = <Object?>[];
      for (var round = 0; round < 2; round++) {
        final r = await a.run({'cmd': 'rotate_keys', 'remove': [], 'certificates': certificates});
        final put = await call(fake, a.token, 'PUT', '/api/users/@me/identity', {
          for (final field in [
            'identity_key',
            'device_list',
            'certificate',
            'encrypted_identity',
            'wrapped_backup_key',
          ])
            field: r[field],
          'wrapped_previous_backup_keys': r['wrapped_previous_backup_keys'],
          'transfers': [
            for (final t in r['transfers'])
              {'device_id': t['device_id'], 'certificate': t['certificate'], 'message': t['transfer']},
          ],
          'replaces': made['identity_key'],
        });
        expect(put.status, 200);
        final waiting = (await call(fake, a2.token, 'GET', '/api/users/@me/devices/@me/inbox?after=${sent.last}')).body;
        expect(waiting, hasLength(1));
        transferred.add(waiting[0]['id']);
      }
      expect(transferred[0], isNot(transferred[1]));
      final stillFull = await call(fake, a.token, 'POST', inbox, {'message': base64Encode(utf8.encode('still full'))});
      expect(stillFull.status, 409);
    });

    test("a reset keeps each device's joined_seq, and a message of the generation before is stale", () async {
      final (:fake, ana: _, :bo, :a, :b, :conversation) = await dmWithGroup();
      final old = await encrypt(a, conversation, 'before the reset');
      final claimed = await call(fake, a.token, 'POST', '/api/users/$bo/key-packages/claim');
      final reset = await a.run({
        'cmd': 'reset_group',
        'conversation_id': conversation,
        'key_packages': {
          bo: [for (final kp in claimed.body['key_packages']) kp['data']],
        },
      });
      final committed = await call(fake, a.token, 'POST', '$conversations/$conversation/mls/commits', {
        'generation': reset['generation'],
        'epoch': 0,
        for (final field in ['commit', 'group_info', 'initial_group_info', 'welcome']) field: reset[field],
      });
      expect(committed, answers(201, {'seq': 3, 'generation': 1, 'epoch': 1, 'welcome_seq': 4}));
      expect((await conversationOf(fake, a, conversation))['mls'], has({'generation': 1, 'joined_seq': 1}));
      expect((await conversationOf(fake, b, conversation))['mls'], has({'generation': 1, 'joined_seq': 2}));
      final stale = await call(fake, a.token, 'POST', '$conversations/$conversation/messages', {
        'ciphertext': old['ciphertext'],
        'nonce': uuidv7(),
      });
      expect(stale, refusedWith(409, {'error': 'stale message', 'generation': 1, 'epoch': 1}));
    });

    test("a message's entry says whom it mentions and what it answers", () async {
      final (:fake, :ana, bo: _, :a, :b, :conversation) = await dmWithGroup();
      final (message: first, nonce: _, ciphertext: _) = await send(fake, a, conversation, 'first');
      const stranger = '0193a4b2-0000-7000-8000-00000000dead';
      final (message: reply, nonce: _, ciphertext: _) = await send(fake, b, conversation, '<@$ana> yes', {
        'mentions': [ana, stranger],
        'message_reference': {'message_id': first['id']},
      });
      // Ana's device reads the queue from its start, as its core has applied none of it.
      final entries = (await call(
        fake,
        a.token,
        'GET',
        '$conversations/$conversation/mls/queue?after=0',
      )).body['entries'];
      final [_, _, firstEntry as Json, replyEntry as Json, ...] = entries as List;
      expect(firstEntry, has({'message_id': first['id']}));
      expect(firstEntry, isNot(contains('mentions')));
      expect(firstEntry, isNot(contains('reply_to')));
      expect(
        replyEntry,
        has({
          'message_id': reply['id'],
          'mentions': [ana],
          'reply_to': first['id'],
        }),
      );
      // The core takes the entry as the queue gives it, and keeps what the message answers.
      expect((await apply(fake, a, conversation, entries))['applied_through'], 4);
      final read = await a.run({
        'cmd': 'messages',
        'conversation_id': conversation,
        'ids': [reply['id']],
      });
      expect(read['messages'], [
        has({'text': '<@$ana> yes', 'reply_to': first['id']}),
      ]);
    });

    test('an entry past 16 KiB comes without its data, which the queue has', () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await dmWithGroup();
      final (:message, nonce: _, ciphertext: _) = await send(fake, a, conversation, 'short');
      final edit = await a.run({
        'cmd': 'edit',
        'conversation_id': conversation,
        'message_id': message['id'],
        'text': 'x' * 20000,
      });
      final path = '$conversations/$conversation/messages/${message['id']}';
      final entry =
          (await call(fake, a.token, 'PATCH', path, {'ciphertext': edit['ciphertext']})).body['entry'] as Json;
      await pumpEventQueue();
      final event = b.heard.firstWhere((heard) => heard.type == 'DM_MESSAGE_UPDATE');
      final carried = (event.data! as Json)['entry'] as Json;
      expect(carried, has({'seq': entry['seq'], 'kind': 'edit'}));
      expect(carried, isNot(contains('data')));
      final queue = await call(
        fake,
        b.token,
        'GET',
        '$conversations/$conversation/mls/queue?after=${(entry['seq'] as int) - 1}',
      );
      expect(queue.body['entries'][0]['data'], edit['ciphertext']);
    });

    test('a commit with no group to go on, and a message from a device without a leaf, are refused', () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final (a, b) = (await device(fake, ana), await device(fake, bo));
      for (final d in [a, b]) {
        await publishIdentity(fake, d);
      }
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      for (final user in [ana, bo]) {
        await observe(fake, a, user);
      }
      // A group of Ana's device alone: no key package of Bo's goes in.
      final made = await a.run({
        'cmd': 'create_group',
        'conversation_id': conversation,
        'kind': 'dm',
        'members': [ana, bo],
        'key_packages': <String, Object?>{},
        'external_sender': fake.externalSender,
        'legacy': false,
      });
      final path = '$conversations/$conversation/mls/commits';
      // Without epoch 0's group info, it isn't a creation: it goes on a group there isn't.
      expect(
        await call(fake, a.token, 'POST', path, {
          'generation': 0,
          'epoch': 0,
          'commit': made['commit'],
          'group_info': made['group_info'],
        }),
        refusedWith(409, {'error': 'no group yet'}),
      );
      final created = await call(fake, a.token, 'POST', path, {
        'generation': 0,
        'epoch': 0,
        for (final field in ['commit', 'group_info', 'initial_group_info', 'welcome']) field: made[field],
      });
      expect(created.status, 201);
      await a.run({
        'cmd': 'commit_result',
        'conversation_id': conversation,
        'accepted': true,
        'seq': created.body['seq'],
      });
      final encrypted = await encrypt(a, conversation, "only Ana's device");
      final refused = await call(fake, b.token, 'POST', '$conversations/$conversation/messages', {
        'ciphertext': encrypted['ciphertext'],
        'nonce': uuidv7(),
      });
      expect(refused, refusedWith(403, {'error': "this device isn't in the group"}));
    });
  }, skip: noCore);
}
