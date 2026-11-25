import 'dart:async';
import 'dart:convert';

import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/failures.dart';
import 'package:duvet/e2e/host.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/core_lib.dart';
import '../support/ed25519.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// What a device fails to open, counted for the API by its kind (PLAN-E2E-API.md, K; decision 40), and the API's
// external sender, which a device pins the first time it sees it (Ruling 32). The desktop's failures.test.ts, with its
// review's rulings.
const _slow = Timeout(Duration(minutes: 3));

/// A message of the device's own, sent by hand with its engine stopped: the API's message.
Future<duvet.DirectMessage> _send(TestDevice device, String conversation, String text, {bool spoil = false}) async {
  final nonce = '0f4b6c1e-${text.hashCode.toRadixString(16).padLeft(8, '0').substring(0, 4)}-4000-8000-000000000000';
  final made = await device.host.handle<Map<String, Object?>>({
    'cmd': 'encrypt',
    'conversation_id': conversation,
    'nonce': nonce,
    'envelope': {'text': text},
  });
  var ciphertext = made['ciphertext']! as String;
  if (spoil) {
    // One byte of its tag changed: no member can open it.
    final bytes = base64Decode(ciphertext);
    bytes[bytes.length - 1] ^= 0xff;
    ciphertext = base64Encode(bytes);
  }
  final message = await device.api.sendMessage(
    conversation,
    duvet.EncryptedMessage(ciphertext: ciphertext, nonce: nonce),
  );
  if (!spoil) {
    await device.host.handle<Object?>({
      'cmd': 'sent',
      'conversation_id': conversation,
      'nonce': nonce,
      'message_id': message.id,
      'seq': message.seq,
    });
  }
  return message;
}

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    "an_entry_that_can't_be_opened_is_reported_by_its_kind;_a_deleted_one_isn't",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo);
      await a.engine.openConversation(conversation);
      await sameGroup([a, b], conversation);

      // While Bo's device is away, Ana's sends a message and deletes it, then sends one nobody can open.
      await b.engine.stop();
      await stoppedByHand(a);
      final gone = await _send(a, conversation, 'gone');
      final tombstone = await a.host.handle<Map<String, Object?>>({
        'cmd': 'delete',
        'conversation_id': conversation,
        'message_id': gone.id,
      });
      await a.api.deleteMessage(conversation, gone.id, tombstone['ciphertext']! as String);
      await _send(a, conversation, 'spoiled', spoil: true);

      // Bo's device reads the queue: the deleted message's emptied entry isn't a failure; the spoiled one is, a
      // message, reported within the minute with the others.
      final back = await restarted(fake, b);
      expect(fake.decryptFailures, isEmpty);
      back.clock.advance(const Duration(minutes: 1));
      await until(() => fake.decryptFailures.isNotEmpty);
      expect(fake.decryptFailures, [(kind: 'message', count: 1)]);
      await a.host.close();
      await back.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_message_from_another_device_that_can't_be_opened_is_reported_as_direct",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      fake.addConversation(group: false, members: [ana, bo]);
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(
        fake,
        bo,
        host: WatchedHost(
          TestHost().gate,
          [],
          fail: (command) => command['cmd'] == 'receive_direct'
              ? CoreError('decrypt_failed', message: "the message didn't open", kind: 'direct')
              : null,
        ),
      );
      await a.api.sendToDevice(b.registered.first, base64Encode(utf8.encode("sealed for Bo's device")));
      // Read and dropped: it would never open.
      await until(() async => (await b.api.inbox()).isEmpty);
      b.clock.advance(const Duration(minutes: 1));
      await until(() => fake.decryptFailures.isNotEmpty);
      expect(fake.decryptFailures, [(kind: 'direct', count: 1)]);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'another_external_sender_is_refused,_and_the_pinned_one_stays',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final said = <String>[];
      final printed = debugPrint;
      debugPrint = (message, {wrapWidth}) => said.add('$message');
      addTearDown(() => debugPrint = printed);
      // Ana's device pins the API's key the first time it sees it.
      final a = await firstDevice(fake, ana);
      final pinned = fake.externalSender;
      expect(a.store.read(externalSender), pinned);

      // The API then serves another, under which Bo's new device makes their DM's group.
      fake.externalSender = base64Encode(ed25519PublicKey(base64Decode(base64Encode(List.filled(32, 7)))));
      final b = await firstDevice(fake, bo);
      await b.engine.openConversation(conversation);
      expect(await groupOf(b, conversation), isNotNull);

      // Ana's device refuses the group: it can't go on there, and no restart would change its external sender.
      await until(() => a.engine.conversationState(conversation)?.name == ConversationNotice.blocked);
      expect(a.engine.conversationState(conversation), ConversationState.blocked(restart: Restart.none));
      expect(await groupOf(a, conversation), isNull);

      // Started again, the API's other key is refused with a notice, and the pinned one stays.
      final again = await restarted(fake, a);
      expect(again.store.read(externalSender), pinned);
      expect(said.any((line) => line.contains('external sender')), isTrue);
      await until(() => again.engine.conversationState(conversation) != null);
      expect(again.engine.conversationState(conversation), ConversationState.blocked(restart: Restart.none));
      await again.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M4 of the desktop's review: a pin the record can't keep holds for the session, so a later start in it, on another
  // key the API serves, keeps the first.
  test(
    "the_pinned_key_holds_for_the_session_where_the_record_can't_keep_it",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final b = await firstDevice(fake, bo);
      final said = <String>[];
      final printed = debugPrint;
      debugPrint = (message, {wrapWidth}) => said.add('$message');
      addTearDown(() => debugPrint = printed);
      final made = <Map<String, Object?>>[];
      final host = WatchedHost(
        LockedOnce(TestHost().gate),
        [],
        answer: (command) {
          if (command['cmd'] == 'create_group') made.add(command);
          return null;
        },
      );
      // Ana's first device sees the API's key, which its record can't keep, and finds its database locked.
      final a = testDevice(fake, ana, host: host, store: KeyRefusingStore(externalSender));
      await a.engine.start();
      expect(a.state, EngineState.locked);
      final pinned = fake.externalSender;
      // By its next try, the API serves another key.
      fake.externalSender = base64Encode(ed25519PublicKey(Uint8List.fromList(List.filled(32, 9))));
      a.clock.advance(const Duration(seconds: 2));
      await until(() => a.state.stage == EngineStage.firstDevice);
      await a.engine.makeIdentity();
      await a.engine.keySaved();
      await a.engine.openConversation(conversation);
      // Every try of the group's creation (the first asks for Bo's identity) held to the key it saw first.
      expect({for (final command in made) command['external_sender']}, {pinned});
      expect(said.any((line) => line.contains('external sender')), isTrue);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M2 of the desktop's review: the route takes 60 reports an hour. A refused one (429) stops the round, its count
  // and the other kinds' kept, and the next round waits an hour: duvet_client gives no Retry-After to wait for.
  test("a_rate_limit_stops_the_round,_and_the_next_report_waits_an_hour", () async {
    final reported = <({String kind, int count})>[];
    var refuse = true;
    final client = MockClient((request) async {
      if (refuse) {
        refuse = false;
        return http.Response(jsonEncode({'error': 'too many requests, try again later'}), 429);
      }
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      reported.add((kind: body['kind']! as String, count: body['count']! as int));
      return http.Response('', 204);
    });
    final api = duvet.E2eApi(duvet.RestClient(client, router: fakeRouter, token: 't', duvetClient: engineClient));
    final clock = TestClock();
    final failures = Failures(api, clock);
    failures
      ..note('message')
      ..note('message')
      ..note('commit');
    clock.advance(const Duration(minutes: 1));
    await pumpEventQueue();
    expect(reported, isEmpty);
    // Not before the hour, whatever comes meanwhile.
    failures.note('commit');
    clock.advance(const Duration(minutes: 30));
    await pumpEventQueue();
    expect(reported, isEmpty);
    clock.advance(const Duration(minutes: 30));
    await pumpEventQueue();
    expect(reported, unorderedEquals([(kind: 'message', count: 2), (kind: 'commit', count: 2)]));
    failures.stop();
  });

  // M5 of the review: a report whose request is still out when the engine stops leaves no timer behind, whatever it
  // answers.
  test('a_report_in_flight_when_the_engine_stops_leaves_no_timer', () async {
    final asked = <http.Request>[];
    final answer = Completer<http.Response>();
    final client = MockClient((request) {
      asked.add(request);
      return answer.future;
    });
    final api = duvet.E2eApi(duvet.RestClient(client, router: fakeRouter, token: 't', duvetClient: engineClient));
    final clock = TestClock();
    final failures = Failures(api, clock)..note('message');
    clock.advance(const Duration(minutes: 1));
    await pumpEventQueue();
    expect(asked, hasLength(1));
    failures.stop();
    answer.complete(http.Response(jsonEncode({'error': 'internal server error'}), 500));
    await pumpEventQueue();
    clock.advance(const Duration(minutes: 1));
    await pumpEventQueue();
    expect(asked, hasLength(1));
  });

  test('what_fails_to_open_is_counted_by_its_kind', () {
    EntryResult result(int seq, String result, {String? reason, String? rule}) =>
        (seq: seq, kind: 'message', result: result, epoch: null, reason: reason, rule: rule);
    expect(
      failedKinds(
        [
          result(1, 'undecryptable', reason: 'message'),
          result(2, 'undecryptable', reason: 'envelope'),
          result(3, 'undecryptable', reason: 'too_large'),
          result(4, 'rejected', rule: 'invalid_commit'),
          result(5, 'rejected', rule: 'invalid_welcome'),
          result(6, 'rejected', rule: 'stale_welcome'),
          result(7, 'undecryptable', reason: 'message'),
          result(8, 'applied'),
        ],
        {7},
      ),
      ['message', 'envelope', 'too_large', 'commit', 'welcome'],
    );
  });
}
