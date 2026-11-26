import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/sync.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// A conversation's queue (PLAN-E2E-CLIENTES.md, «La cola de una conversación»): the entries the API numbers, from its
// events and its queue, applied by their number, one conversation at a time. The desktop's sync.test.ts, case for
// case, with its review's rulings.
const _slow = Timeout(Duration(minutes: 3));

typedef _Dm = ({FakeApi fake, String ana, String bo, TestDevice a, TestDevice b, String conversation});

/// Ana's and Bo's first devices, in a DM whose group Ana made as she opened it, which Bo's device joined; what Bo's
/// device asks the API goes into [seen].
Future<_Dm> _dmWithGroup(
  List<http.Request> seen, {
  bool Function(GatewayEvent event)? boHears,
  List<http.Request>? anaSeen,
}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final a = await firstDevice(fake, ana, client: anaSeen == null ? null : watchedClient(fake, seen: anaSeen.add));
  final b = testDevice(
    fake,
    bo,
    hears: boHears,
    client: watchedClient(fake, seen: seen.add),
  );
  await b.engine.start();
  await b.engine.makeIdentity();
  await b.engine.keySaved();
  expect(b.state, EngineState.ready);
  await a.engine.openConversation(conversation);
  await sameGroup([a, b], conversation);
  return (fake: fake, ana: ana, bo: bo, a: a, b: b, conversation: conversation);
}

List<String> _queueReads(List<http.Request> seen, String conversation) => [
  for (final request in requestsOf(seen))
    if (request.startsWith('GET /api/users/@me/conversations/$conversation/mls/queue')) request,
];

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'entries_apply_by_their_number,_whatever_order_they_came_in',
    () async {
      final seen = <http.Request>[];
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await _dmWithGroup(seen);
      await stoppedByHand(a);
      // Three commits whose events come backwards and twice, then three that come in order and twice.
      for (final reverse in [true, false]) {
        fake.holdEvents();
        for (var n = 0; n < 3; n++) {
          await commitByHand(a, conversation);
        }
        final before = _queueReads(seen, conversation).length;
        fake.releaseEvents(reverse: reverse, repeat: true);
        final held = await sameGroup([a, b], conversation);
        expect(held.blocked, isFalse);
        // The batch went to the core in its order, the repeats skipped: no read of the queue (M8 of the desktop's
        // review).
        await turnEnded(b);
        expect(_queueReads(seen, conversation).length, before);
      }
      expect((await groupOf(b, conversation))!.epoch, 7);
      await a.host.close();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_gap_asks_for_the_queue',
    () async {
      final seen = <http.Request>[];
      var deaf = false;
      final (fake: _, ana: _, bo: _, :a, :b, :conversation) = await _dmWithGroup(
        seen,
        boHears: (event) => !(deaf && event.type == 'MLS_COMMIT'),
      );
      await stoppedByHand(a);
      // Bo's device misses two commits' events, then hears the third's.
      deaf = true;
      await commitByHand(a, conversation);
      await commitByHand(a, conversation);
      deaf = false;
      final before = _queueReads(seen, conversation).length;
      final last = await commitByHand(a, conversation);
      await sameGroup([a, b], conversation);
      // It read the queue from where its core was: after the entries it had applied.
      expect(
        _queueReads(seen, conversation).skip(before),
        contains('GET /api/users/@me/conversations/$conversation/mls/queue?after=${last.seq - 3}'),
      );
      await a.host.close();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'an_entry_without_its_data_is_read_from_the_queue',
    () async {
      final seen = <http.Request>[];
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await _dmWithGroup(seen);
      await stoppedByHand(a);
      fake.stripData = true;
      final before = _queueReads(seen, conversation).length;
      final taken = await commitByHand(a, conversation);
      await sameGroup([a, b], conversation);
      expect(_queueReads(seen, conversation).skip(before), [
        'GET /api/users/@me/conversations/$conversation/mls/queue?after=${taken.seq - 1}',
      ]);
      await a.host.close();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Step 5's fuzzing, with the desktop's finding: a page whose entries don't go past where its read began (the server's
  // word) had the next read start where this one did, and a server that kept sending it held the engine's one turn,
  // which runs one conversation at a time, for good.
  test(
    "a_queue_page_that_doesn't_go_past_where_its_read_began_isn't_asked_for_again_in_that_turn",
    () async {
      final seen = <http.Request>[];
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await _dmWithGroup(seen);
      await stoppedByHand(a);
      // A server that lies: the last entry there is, and a hundred more said to come after it, whatever is asked.
      final page = await a.api.queue(conversation, 0);
      final last = page.entries.last;
      final lie = {
        'entries': [
          {
            'seq': last.seq,
            'kind': last.kind,
            'data': last.data,
            'sent_at': last.sentAt,
            'generation': last.generation,
            'epoch': last.epoch,
            'message_id': ?last.messageId,
            'sender_user': ?last.senderUser,
            'sender_device': ?last.senderDevice,
          },
        ],
        'last_seq': page.lastSeq + 100,
        'floor_seq': page.floorSeq,
        'generation': page.generation,
        'epoch': page.epoch,
      };
      fake
        ..refuse((method: 'GET', path: '/api/users/@me/conversations/$conversation/mls/queue'), 200, body: lie)
        ..stripData = true;
      final before = _queueReads(seen, conversation).length;
      await commitByHand(a, conversation);
      await until(() => _queueReads(seen, conversation).length > before);
      await turnEnded(b);
      // Read once, the turn ends, as a gap that doesn't move ends it: the queue is read again with the next turn.
      expect(_queueReads(seen, conversation).length - before, 1);
      await commitByHand(a, conversation);
      await sameGroup([a, b], conversation);
      await a.host.close();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'an_expired_queue_joins_again_and_keeps_its_database',
    () async {
      final (:fake, :ana, :bo, :a, :b, :conversation) = await _dmWithGroup([]);
      // A second conversation of theirs, whose group Bo's device keeps through it all.
      final other = fake.addConversation(group: true, members: [ana, bo], owner: ana);
      await a.engine.openConversation(other);
      final kept = await sameGroup([a, b], other);
      final status = await b.host.handle<Map<String, Object?>>({'cmd': 'status'});

      // Bo's device is away while Ana's commits three times, and the queue keeps only the last.
      await b.engine.stop();
      await stoppedByHand(a);
      var last = 0;
      for (var n = 0; n < 3; n++) {
        last = (await commitByHand(a, conversation)).seq;
      }
      // Ana's engine runs again, and applies the queue to her last commit before it expires.
      final ana2 = await restarted(fake, a);
      fake.expireQueue(conversation, last);
      final back = await restarted(fake, b);
      expect(back.state, EngineState.ready);
      // It joined again by an external commit, which Ana's device applies.
      await sameGroup([ana2, back], conversation);
      final after = (await back.api.queue(conversation, last)).entries;
      expect([for (final e in after) (e.kind, e.senderUser)], [('commit', bo)]);
      // The same device, with its other conversation's group as it was.
      expect((await back.host.handle<Map<String, Object?>>({'cmd': 'status'}))['device_id'], status['device_id']);
      final still = (await groupOf(back, other))!;
      expect((still.generation, still.epoch), (kept.generation, kept.epoch));
      await ana2.engine.stop();
      await back.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'needs_identities_observes_those_users_and_goes_on',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final seen = <http.Request>[];
      final conversation = fake.addConversation(group: false, members: [ana, bo]);
      final a = await firstDevice(fake, ana);
      final log = <String>[];
      final b = await firstDevice(
        fake,
        bo,
        host: WatchedHost(TestHost().gate, log),
        client: watchedClient(fake, seen: seen.add),
      );
      // Bo's device has never observed Ana: the welcome asks for her identity first.
      await a.engine.openConversation(conversation);
      await sameGroup([a, b], conversation);
      final asked = [
        for (final request in seen)
          if (request.url.path == '/api/users/identities') request.url.queryParameters['ids'] ?? '',
      ];
      expect(asked.any((ids) => ids.contains(ana)), isTrue);
      final applies = [
        for (final (i, cmd) in log.indexed)
          if (cmd == 'apply') i,
      ];
      final observed = log.lastIndexOf('observe_user');
      expect(observed, greaterThan(applies.first));
      expect(applies.last, greaterThan(observed));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M3 of the desktop's review: a device that isn't ready keeps nothing it hears, which the queue has.
  test(
    "what's_heard_while_the_device_isn't_ready_isn't_kept:_the_queue_has_it",
    () async {
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await _dmWithGroup([]);
      final applies = <Map<String, Object?>>[];
      final host = WatchedHost(
        LockedOnce(b.host),
        [],
        answer: (command) {
          if (command['cmd'] == 'apply' && command['conversation_id'] == conversation) applies.add(command);
          return null;
        },
      );
      final back = await restarted(fake, b, host: host);
      expect(back.state, EngineState.locked);
      // Ana's device commits three times meanwhile, and Bo's hears each one.
      await stoppedByHand(a);
      for (var n = 0; n < 3; n++) {
        await commitByHand(a, conversation);
      }
      await until(() => back.heard.where((event) => event.type == 'MLS_COMMIT').length == 3);
      // Its database free, it starts: it applies nothing it heard, and the queue brings the three commits.
      back.clock.advance(const Duration(seconds: 2));
      await sameGroup([a, back], conversation);
      expect(applies.first['entries'], isEmpty);
      await a.host.close();
      await back.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // I2 of the desktop's review, for a deleted conversation: the queue's refusal lists the conversations again, and a
  // conversation they no longer have is let go, its retries with it.
  test(
    'a_conversation_deleted_meanwhile_is_let_go,_its_retries_with_it',
    () async {
      final seen = <http.Request>[];
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await _dmWithGroup(seen);
      await stoppedByHand(a);
      // Ana's device commits, and the commit's event comes without its data: Bo's device reads the queue for it, which
      // by then is gone.
      fake
        ..stripData = true
        ..holdEvents();
      await commitByHand(a, conversation);
      fake.deleteConversation(conversation);
      final before = _queueReads(seen, conversation).length;
      fake.releaseEvents();
      await until(() => _queueReads(seen, conversation).length > before);
      await turnEnded(b);
      for (var minute = 0; minute < 3; minute++) {
        b.clock.advance(const Duration(minutes: 1));
        await turnEnded(b);
      }
      expect(_queueReads(seen, conversation), hasLength(before + 1));
      await a.host.close();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // I1 of the desktop's review: once an external commit of its own lost, a welcome from where the device's first leaf
  // began is stale, and the queue isn't read from there.
  test(
    'after_a_lost_external_commit,_the_device_joins_again_without_reading_the_queue_from_its_first_leaf',
    () async {
      final seen = <http.Request>[];
      final (:fake, ana: _, bo: _, :a, :b, :conversation) = await _dmWithGroup(seen, anaSeen: seen);
      final listed = (await b.api.api.getConversations()).firstWhere((conv) => conv.id == conversation);
      final joined = listed.mls!.joinedSeq!;
      // Bo's device is away while Ana's commits three times, and the queue keeps only the last.
      await b.engine.stop();
      await stoppedByHand(a);
      var last = 0;
      for (var n = 0; n < 3; n++) {
        last = (await commitByHand(a, conversation)).seq;
      }
      fake.expireQueue(conversation, last);
      // Back, it joins by an external commit, which loses its epoch to Ana's next commit: they reach the API together,
      // Ana's first.
      int posts() => requestsOf(seen).where((request) => request == 'POST ${commitsPath(conversation)}').length;
      final (posted, read) = (posts(), _queueReads(seen, conversation).length);
      fake.gather((method: 'POST', path: commitsPath(conversation)), 2);
      final committing = commitByHand(a, conversation);
      await until(() => posts() == posted + 1);
      final back = await restarted(fake, b, client: watchedClient(fake, seen: seen.add));
      await committing;
      // Ana's commit, Bo's external commit that lost, and the one that took the next epoch.
      expect(posts(), posted + 3);
      // What Bo's device read since it came back: never the queue from where its first leaf began.
      expect(
        _queueReads(seen, conversation).skip(read),
        isNot(contains('GET /api/users/@me/conversations/$conversation/mls/queue?after=${joined - 1}')),
      );
      final ana = await restarted(fake, a);
      await sameGroup([ana, back], conversation);
      await ana.engine.stop();
      await back.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test('an_encrypted_message_is_an_entry_of_its_queue,_by_the_mapping_the_plan_gives', () {
    // DM_MESSAGE_CREATE's message, as the core's entry: its ciphertext the data, its ID the message's, its author and
    // device the sender's (PLAN-E2E-API.md, «La entrada de la cola»).
    Map<String, Object?> message(Map<String, Object?> more) => {
      'id': '01936d4e-8f00-7000-8000-0000000000a1',
      'conversation_id': '01936d4e-8f00-7000-8000-0000000000c1',
      'author_id': '01936d4e-8f00-7000-8000-0000000000b1',
      'content': null,
      'created_at': '2026-11-25T10:00:00Z',
      'updated_at': '2026-11-25T10:00:00Z',
      ...more,
    };
    final sent = duvet.DirectMessage.fromJson(
      message({
        'type': 0,
        'ciphertext': 'AAEC',
        'seq': 7,
        'sent_at': 1764064800000,
        'generation': 0,
        'epoch': 2,
        'sender_device_id': '01936d4e-8f00-7000-8000-0000000000d1',
        'mentions': ['01936d4e-8f00-7000-8000-0000000000b2'],
      }),
    );
    final made = messageEntry(sent)!;
    expect(made.conversation, '01936d4e-8f00-7000-8000-0000000000c1');
    expect(made.entry, {
      'seq': 7,
      'kind': 'message',
      'data': 'AAEC',
      'sent_at': 1764064800000,
      'message_id': '01936d4e-8f00-7000-8000-0000000000a1',
      'sender_user': '01936d4e-8f00-7000-8000-0000000000b1',
      'sender_device': '01936d4e-8f00-7000-8000-0000000000d1',
      'mentions': ['01936d4e-8f00-7000-8000-0000000000b2'],
    });
    // A notice has no number: it isn't the queue's.
    expect(messageEntry(duvet.DirectMessage.fromJson(message({'type': 3}))), isNull);
  });

  // Step 5's fuzzing, with the desktop's finding: what the server hands over is an entry only when it reads as one,
  // each field of it the message's own. A lost event costs nothing: the queue brings what it carried.
  group('what the fuzzers found', () {
    const ids = ['0193a4b2-0000-7000-8000-000000000000', '0193a4b2-0000-7000-8000-000000000001'];
    const at = '2026-11-26T10:00:00Z';
    duvet.GatewayEventPayload event(String type, Map<String, Object?> data) => duvet.GatewayEnvelope.fromJson({
      'op': 0,
      's': 1,
      'event': 'payload',
      'd': {'type': type, 'data': data},
    }).d!;
    final message = {
      'id': ids[0],
      'conversation_id': ids[1],
      'author_id': ids[0],
      'type': 0,
      'created_at': at,
      'updated_at': at,
      'ciphertext': 'AAAA',
      'seq': 5,
      'sent_at': 1763150000123,
      'generation': 0,
      'epoch': 2,
    };
    final entry = {'seq': 5, 'kind': 'commit', 'data': 'AAAA', 'sent_at': 1, 'generation': 0, 'epoch': 2};
    final commit = {'conversation_id': ids[1], 'generation': 0, 'epoch': 2, 'entry': entry};

    test("a message's entry has the message's own time, and there's none without one", () {
      expect(carriedEntry(event('DM_MESSAGE_CREATE', message))?.entry['sent_at'], 1763150000123);
      // Not 0, a time the message never carried, which the core would show as its own.
      expect(carriedEntry(event('DM_MESSAGE_CREATE', {...message}..remove('sent_at'))), isNull);
    });

    test('an event is an entry only of a conversation, and of numbers the desktop counts with too', () {
      expect(carriedEntry(event('MLS_COMMIT', commit))?.generation, 0);
      expect(carriedEntry(event('DM_MESSAGE_CREATE', {...message, 'seq': (1 << 53) - 1})), isNotNull);
      expect(carriedEntry(event('DM_MESSAGE_CREATE', {...message, 'conversation_id': ''})), isNull);
      expect(carriedEntry(event('MLS_COMMIT', {...commit, 'conversation_id': ''})), isNull);
      expect(
        carriedEntry(
          event('DM_MESSAGE_UPDATE', {'id': ids[0], 'conversation_id': '', 'edited_at': at, 'entry': entry}),
        ),
        isNull,
      );
      // Below 0, or past what the desktop's numbers hold exactly (where it refuses them), no number counts.
      for (final number in [-1, 1 << 53]) {
        for (final field in ['seq', 'generation', 'epoch']) {
          expect(carriedEntry(event('DM_MESSAGE_CREATE', {...message, field: number})), isNull, reason: field);
        }
        expect(carriedEntry(event('MLS_COMMIT', {...commit, 'generation': number})), isNull);
        expect(
          carriedEntry(
            event('MLS_COMMIT', {
              ...commit,
              'entry': {...entry, 'seq': number},
            }),
          ),
          isNull,
        );
        expect(
          carriedEntry(
            event('DM_MESSAGE_DELETE', {
              'id': ids[0],
              'conversation_id': ids[1],
              'entry': {...entry, 'seq': number},
            }),
          ),
          isNull,
        );
      }
      // Nor a time past them, the least integer among them, whose absolute value is itself in Dart's.
      for (final time in [1 << 53, -(1 << 53), 1 << 63]) {
        expect(carriedEntry(event('DM_MESSAGE_CREATE', {...message, 'sent_at': time})), isNull, reason: '$time');
      }
    });
  });
}
