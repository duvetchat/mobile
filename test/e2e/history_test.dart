import 'dart:convert';
import 'dart:typed_data';

import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_chats.dart' as recent show previewOf;
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/history.dart' show packageWait;
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/store.dart' show historyKeys;
import 'package:duvet/e2e/sync.dart' show entryOf;
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet/encryption/share_history.dart' show sharedSaid;
import 'package:duvet/main.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/app_repository.dart';
import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';
import '../support/fake_repository.dart';

// Shared history (PLAN-E2E-CLIENTES.md, Task 31, its Task 30 in Dart; decision 26): a member shares how far back a
// conversation goes on their device with another, whose devices import it only on the person's yes; a catch-up
// (decision 14) imports by itself, once the engine is quiet. The desktop's history tests, case for case.
const _slow = Timeout(Duration(minutes: 3));

typedef _Crew = ({
  FakeApi fake,
  String ana,
  String bo,
  TestDevice a,
  TestDevice b,
  TestDevice c,
  String group,
  List<duvet.DirectMessage> early,
  List<http.Request> seen,
  List<http.Request> bSeen,
});

/// Ana's group with Cy, where she said two things before she added Bo: his first device holds none of it, as a member
/// who just joined. What Ana's and Bo's devices asked the API; Bo's hears only what [bHears] lets through.
Future<_Crew> _crew({bool Function(GatewayEvent event)? bHears}) async {
  final fake = FakeApi();
  final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
  fake
    ..befriend(ana, bo)
    ..befriend(ana, cy);
  final seen = <http.Request>[];
  final bSeen = <http.Request>[];
  final a = await firstDevice(fake, ana, client: watchedClient(fake, seen: seen.add));
  final c = await firstDevice(fake, cy);
  final group = (await a.engine.createGroup('Crew', [cy])).id;
  await sameGroup([a, c], group);
  final early = [
    for (final text in ['before Bo', 'still before Bo'])
      (await a.engine.sendMessage(Outgoing(conversationId: group, nonce: uuidv4(), text: text)))!,
  ];
  final b = await firstDevice(
    fake,
    bo,
    client: watchedClient(fake, seen: bSeen.add),
    hears: bHears,
  );
  await a.engine.addMember(group, bo);
  await sameGroup([a, b, c], group);
  return (fake: fake, ana: ana, bo: bo, a: a, b: b, c: c, group: group, early: early, seen: seen, bSeen: bSeen);
}

/// Ana's DM with Dee, who has no device yet, and what Ana said there: Dee's first device gets it as a catch-up.
Future<({FakeApi fake, String dee, TestDevice a, String dm, duvet.DirectMessage sent})> _deviceless() async {
  final fake = FakeApi();
  final (ana, dee) = (fake.addUser(), fake.addUser());
  fake.befriend(ana, dee);
  final a = await firstDevice(fake, ana);
  final dm = (await a.engine.createDM(dee)).id;
  await a.engine.openConversation(dm);
  await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([dee]));
  final sent = (await a.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'hi Dee')))!;
  return (fake: fake, dee: dee, a: a, dm: dm, sent: sent);
}

/// Whether the device holds the message, opened.
Future<bool> _holds(TestDevice device, String conversation, String id) async =>
    (await device.engine.messages(conversation, [id])).any((m) => m.status == MessageStatus.ok);

/// The offers on the device of the conversation's, once there's one.
Future<List<HistoryOffer>> _offered(TestDevice device, String conversation) async {
  await until(() => (device.engine.historyOffers.value[conversation] ?? const []).isNotEmpty);
  return device.engine.historyOffers.value[conversation]!;
}

/// The device's rows of these messages, by ID.
Future<Map<String, ShownMessage>> _rows(TestDevice device, String conversation, List<String> ids) async => {
  for (final row in await device.engine.messages(conversation, ids)) row.messageId!: row,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    "a_week_is_shared:_its_parts_go_up,_its_keys_go_to_each_of_the_member's_devices,_and_the_group_sees_the_notice",
    () async {
      final (:fake, :ana, :bo, :a, :b, :c, :group, early: _, :seen, bSeen: _) = await _crew();
      final b2 = await approvedDevice(fake, b);

      final shared = await a.engine.shareHistory(group, bo, 'week');
      expect(shared.truncated, isFalse);
      // Answered once the API took it: the rest goes by itself.
      bool completed(http.Request r) => r.method == 'POST' && r.url.path.endsWith('/complete');
      await until(() => seen.any(completed), what: 'the share completed');
      bool package(http.Request r) => r.method == 'PUT' && RegExp(r'/history-shares/[0-9a-f-]+$').hasMatch(r.url.path);
      final put = seen.singleWhere(package);
      final shareId = put.url.pathSegments.last;
      final about = jsonDecode(put.body) as Map<String, dynamic>;
      expect(
        about,
        allOf(containsPair('to_user_id', bo), containsPair('kind', 'share'), containsPair('range', 'week')),
      );
      final parts = [
        for (final r in seen)
          if (r.method == 'PUT' && r.url.path.contains('/history-shares/$shareId/parts/')) r.url.pathSegments.last,
      ];
      expect(parts, [for (var n = 0; n < (about['parts'] as int); n++) '$n']);
      final complete = seen.indexWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/history-shares/$shareId/complete'),
      );
      // Its key to each of Bo's devices before it's complete: the group's notice and Bo's listing come once they went.
      final inboxes = [
        for (final (i, r) in seen.indexed)
          if (r.method == 'POST' && r.url.path.endsWith('/inbox')) (i, r.url.pathSegments[2]),
      ];
      expect({for (final (_, device) in inboxes) device}, {b.registered.last, b2.registered.last});
      expect(complete >= 0 && inboxes.every((sent) => sent.$1 < complete), isTrue);

      // The group sees its notice: Ana's, for Bo, of a week, with no text of anyone's.
      bool isNotice(GatewayEvent e) => e.type == 'DM_MESSAGE_CREATE' && (e.data! as Map)['type'] == 4;
      await until(() => c.heard.any(isNotice));
      final notice = c.heard.firstWhere(isNotice).data! as Map;
      expect((notice['author_id'], notice['content']), (ana, null));
      expect(notice['history_share'], {'to_user_id': bo, 'range': 'week'});
      // Its parts were let go once it was delivered.
      await until(
        () => a.host.sharePart(shareId, 0).then((_) => false, onError: (Object error) => error is CoreError),
        what: "the share's parts let go",
      );
      for (final d in [a, b, b2, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_share_that_didn't_fit_says_it_was_cut_to_the_newest",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      fake.befriend(ana, bo);
      // A core whose package didn't all fit, as one past 64 MiB: its newest, from a time on.
      final cut = DateTime.utc(2026, 11, 19, 12);
      final a = await firstDevice(fake, ana, host: _Cut(TestHost().gate, cut));
      final b = await firstDevice(fake, bo);
      final dm = (await a.engine.createDM(bo)).id;
      await sameGroup([a, b], dm);
      final shared = await a.engine.shareHistory(dm, bo, 'all');
      expect(shared, (truncated: true, start: cut));
      // What the person is told once the API took it: that it was cut to the newest, from when; or that they shared it.
      expect(sharedSaid(shared, 'Bo', 'all'), 'Not all of it fit: Bo gets the messages from 19 November 2026 on.');
      expect(sharedSaid((truncated: false, start: cut), 'Bo', 'week'), 'You shared the last 7 days with Bo');
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_share_is_imported_only_when_the_person_says_so;_a_catch-up,_by_itself',
    () async {
      final (:fake, :ana, :bo, :a, :b, :c, :group, :early, seen: _, bSeen: _) = await _crew();
      final ids = [for (final m in early) m.id];
      await a.engine.shareHistory(group, bo, 'week');
      // Bo's device is offered Ana's week, which nothing imports meanwhile, however quiet the engine stays.
      final [offer] = await _offered(b, group);
      expect((offer.fromUserId, offer.range, offer.conversationId), (ana, 'week', group));
      b.clock.advance(const Duration(minutes: 1));
      await turnEnded(b);
      expect(await _rows(b, group, ids), isEmpty);
      expect(await b.api.shares(), hasLength(1));
      // The person says yes: Ana's messages are on Bo's device, the offer goes, and the API is told.
      await b.engine.takeHistoryOffer(offer.shareId);
      final rows = await _rows(b, group, ids);
      expect(
        [for (final id in ids) (rows[id]?.text, rows[id]?.sharedBy)],
        [('before Bo', ana), ('still before Bo', ana)],
      );
      expect(b.engine.historyOffers.value[group] ?? const [], isEmpty);
      expect(await b.api.shares(), isEmpty);

      // A catch-up: Dee had no device while Ana wrote to her. Her first device takes its key and waits for its engine
      // to be quiet, then imports it by itself, offering nothing.
      final dee = fake.addUser();
      fake.befriend(ana, dee);
      final dm = (await a.engine.createDM(dee)).id;
      await a.engine.openConversation(dm);
      await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([dee]));
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'hi Dee')))!;
      final d = await firstDevice(fake, dee);
      await until(() => d.store.read(historyKeys) is List && (d.store.read(historyKeys)! as List).isNotEmpty);
      await until(() async => (await d.api.shares()).isNotEmpty);
      await turnEnded(d);
      expect(await d.engine.messages(dm, [sent.id]), isEmpty);
      await until(() async {
        d.clock.advance(quietBeforeImport);
        return (await d.engine.messages(dm, [sent.id])).any((m) => m.text == 'hi Dee');
      });
      expect(d.engine.historyOffers.value[dm] ?? const [], isEmpty);
      await until(() async => (await d.api.shares()).isEmpty);
      for (final device in [a, b, c, d]) {
        await device.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'imported_messages_say_who_shared_them,_and_fill_the_rows_that_waited',
    () async {
      final (:fake, :ana, :bo, :a, b: joined, :c, :group, :early, seen: _, bSeen: _) = await _crew();
      var b = joined;
      // Ana writes while Bo's device is away; its copy doesn't open there (one byte of it spoiled): his row waits.
      await b.engine.stop();
      final kept = (await a.engine.sendMessage(Outgoing(conversationId: group, nonce: uuidv4(), text: 'kept for Bo')))!;
      await b.host.open(bo);
      final entry = (await a.api.queue(group, 0)).entries.firstWhere((e) => e.messageId == kept.id);
      final spoiled = Uint8List.fromList(base64Decode(entry.data!));
      spoiled[spoiled.length - 1] ^= 0xff;
      await b.host.handle<Object?>({
        'cmd': 'apply',
        'conversation_id': group,
        'entries': [
          {...entryOf(entry), 'data': base64Encode(spoiled)},
        ],
      });
      b = await restarted(fake, b);
      expect((await _rows(b, group, [kept.id]))[kept.id]?.status, MessageStatus.waiting);
      // One Bo's device opened itself.
      final own = (await a.engine.sendMessage(Outgoing(conversationId: group, nonce: uuidv4(), text: 'Bo has this')))!;
      await until(() async => (await _rows(b, group, [own.id]))[own.id]?.status == MessageStatus.ok);

      await a.engine.shareHistory(group, bo, 'week');
      final [offer] = await _offered(b, group);
      await b.engine.takeHistoryOffer(offer.shareId);
      final rows = await _rows(b, group, [...early.map((m) => m.id), kept.id, own.id]);
      // From before he joined, and the one that waited: Ana's, shared by her. The one he holds stays his own.
      expect([
        for (final m in [...early, kept]) (rows[m.id]?.status, rows[m.id]?.userId, rows[m.id]?.sharedBy),
      ], everyElement((MessageStatus.ok, ana, ana)));
      expect(rows[kept.id]?.text, 'kept for Bo');
      expect((rows[own.id]?.text, rows[own.id]?.sharedBy), ('Bo has this', null));
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_package_whose_key_hasn't_come_waits_for_it",
    () async {
      var keysIn = false;
      final (fake: _, ana: _, :bo, :a, :b, :c, :group, early: _, seen: _, :bSeen) = await _crew(
        bHears: (event) => keysIn || event.type != 'DEVICE_MESSAGE',
      );
      await a.engine.shareHistory(group, bo, 'week');
      // Bo's device hears of the package, and its key isn't read from its inbox yet: nothing is offered or downloaded.
      await until(() => b.heard.any((e) => e.type == 'HISTORY_SHARE_CREATE'));
      await turnEnded(b);
      b.clock.advance(const Duration(minutes: 1));
      await turnEnded(b);
      expect(b.engine.historyOffers.value[group] ?? const [], isEmpty);
      expect(bSeen.where((r) => r.url.path.contains('/history-shares/') && r.url.path.contains('/parts/')), isEmpty);
      // Its key comes, as the next session reads the inbox: then it's offered.
      keysIn = true;
      b.connect(b.registered.last);
      final [offer] = await _offered(b, group);
      expect(offer.range, 'week');
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "the_eleventh_share_of_the_hour_says_why_it_didn't_go",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: false, members: [bo, ana], owner: bo);
      final app = await appOn(fake, ana);
      await app.ready();
      final b = await firstDevice(fake, bo);
      app.repository.chatShown(ConversationTarget(conversation));
      await until(() async => await groupOf(b, conversation) != null);
      // A 429 that isn't the package's (the member's identity, past the API's requests a second) isn't the hour's ten.
      fake.refuse((method: 'GET', path: '/api/users/$bo/identity'), 429, headers: {'Retry-After': '1'});
      await expectLater(
        app.repository.shareHistory(conversation, bo, 'day'),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', Notice.shareHistoryFailed.text)),
      );
      for (var i = 0; i < 10; i++) {
        await app.repository.shareHistory(conversation, bo, 'day');
      }
      // The eleventh: when the next frees, as the API's Retry-After says.
      await expectLater(
        app.repository.shareHistory(conversation, bo, 'day'),
        throwsA(
          isA<ActionFailed>().having(
            (e) => e.message,
            'message',
            'You can share history 10 times an hour. Try again in 60 minutes.',
          ),
        ),
      );
      await b.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_member_with_no_device_is_told_there's_no_one_to_share_with",
    () async {
      final (:fake, :dee, :a, :dm, sent: _) = await _deviceless();
      final seen = <http.Request>[];
      final a2 = await restarted(fake, a, client: watchedClient(fake, seen: seen.add));
      await expectLater(a2.engine.shareHistory(dm, dee, 'week'), throwsA(isA<NoDeviceToShareWith>()));
      expect(seen.where((r) => r.url.path.contains('/history-shares/')), isEmpty);
      await a2.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M4 of the review and the twins' rule 4: a failure waits a minute at least, a 429 too, whatever its Retry-After.
  test(
    'a_package_that_failed_to_come_in_goes_again_after_a_minute',
    () async {
      final (:fake, :dee, :a, :dm, :sent) = await _deviceless();
      // Its first part's download is refused once, with a Retry-After of nothing.
      fake.refuse(
        (method: 'GET', path: RegExp(r'/api/history-shares/[0-9a-f-]+/parts/0$')),
        429,
        headers: {'Retry-After': '0'},
      );
      final seen = <http.Request>[];
      final d = await firstDevice(fake, dee, client: watchedClient(fake, seen: seen.add));
      bool part(http.Request r) => r.method == 'GET' && r.url.path.endsWith('/parts/0');
      await until(() {
        d.clock.advance(quietBeforeImport);
        return seen.where(part).isNotEmpty;
      });
      await turnEnded(d);
      expect(await _holds(d, dm, sent.id), isFalse);
      // Under a minute later, the engine quiet all along, nothing went again.
      for (var waited = Duration.zero; waited < const Duration(seconds: 50); waited += quietBeforeImport) {
        d.clock.advance(quietBeforeImport);
        await turnEnded(d);
      }
      expect(seen.where(part), hasLength(1));
      // Its minute over, and the engine quiet again, it comes in.
      await until(() async {
        d.clock.advance(quietBeforeImport);
        return _holds(d, dm, sent.id);
      });
      expect(seen.where(part), hasLength(2));
      await a.engine.stop();
      await d.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_package_imported_on_one_try_is_only_acknowledged_on_the_next,_never_imported_twice',
    () async {
      final (:fake, :dee, :a, :dm, :sent) = await _deviceless();
      // Its acknowledgement's answer is lost once.
      fake.loseAnswer((method: 'POST', path: RegExp(r'/api/history-shares/[0-9a-f-]+/ack$')));
      final asked = <String>[];
      final d = await firstDevice(fake, dee, host: WatchedHost(TestHost().gate, asked));
      // Imported, its acknowledgement lost: its key stays in the record, done with only once it's acknowledged again,
      // when only its ID is kept.
      await until(() async {
        d.clock.advance(quietBeforeImport);
        final record = ((d.store.read(historyKeys) as List?) ?? const []).cast<Map<String, Object?>>();
        return await _holds(d, dm, sent.id) && record.isNotEmpty && record.every((one) => !one.containsKey('kind'));
      });
      expect(asked.where((cmd) => cmd == 'history_import'), hasLength(1));
      expect(await d.api.shares(), isEmpty);
      await a.engine.stop();
      await d.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Review Focus 2: only the app's engine, the one with a screen, writes a history into the database.
  test('a_background_engine_never_shares_or_imports', () async {
    final gate = CoreGate(serves: false, keys: MemoryKeys());
    final refused = throwsA(isA<CoreError>().having((e) => (e.code, e.field), 'code', ('bad_command', 'cmd')));
    await expectLater(
      gate.share({'cmd': 'history_share', 'conversation_id': uuidv4(), 'to_user': uuidv4(), 'range': 'all'}),
      refused,
    );
    await expectLater(gate.share({'cmd': 'catch_up', 'conversation_id': uuidv4(), 'user_id': uuidv4()}), refused);
    await expectLater(gate.importShare(uuidv4(), [Uint8List(1)]), refused);
  });

  // A package too big for the phone ends the app as it imports: begun three times without ending, a catch-up isn't
  // imported by itself again, nor acknowledged, and waits as an offer the person can try (M1 of the review).
  test(
    'an_import_that_never_ended_three_times_waits_for_the_person',
    () async {
      final fake = FakeApi();
      final (ana, dee) = (fake.addUser(), fake.addUser());
      fake.befriend(ana, dee);
      final a = await firstDevice(fake, ana);
      final dm = (await a.engine.createDM(dee)).id;
      await a.engine.openConversation(dm);
      await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([dee]));
      final sent = (await a.engine.sendMessage(Outgoing(conversationId: dm, nonce: uuidv4(), text: 'too much')))!;
      var d = await firstDevice(fake, dee);
      await until(() => d.store.read(historyKeys) is List && (d.store.read(historyKeys)! as List).isNotEmpty);
      // Its import began three times, each ended with the app.
      await d.engine.stop();
      await d.store.write(historyKeys, [
        for (final key in (d.store.read(historyKeys)! as List).cast<Map<String, Object?>>()) {...key, 'starts': 3},
      ]);
      d = await restarted(fake, d);
      final [offer] = await _offered(d, dm);
      expect(offer.fromUserId, ana);
      for (var i = 0; i < 4; i++) {
        d.clock.advance(quietBeforeImport);
        await turnEnded(d);
      }
      expect(await d.engine.messages(dm, [sent.id]), isEmpty);
      expect(await d.api.shares(), hasLength(1));
      // The person's yes imports it, and the API is told.
      await d.engine.takeHistoryOffer(offer.shareId);
      expect(
        [
          for (final m in await d.engine.messages(dm, [sent.id])) m.text,
        ],
        ['too much'],
      );
      expect(await d.api.shares(), isEmpty);
      await a.engine.stop();
      await d.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Ruling 1, M2 and M3 of the review: the person is answered once the API took the package, and the rest goes by
  // itself from where it stopped: a 429 waits what it says, and a key that went doesn't go again. One package, counted
  // once, one notice.
  test(
    'a_share_is_answered_once_the_server_took_it,_and_goes_on_by_itself_from_where_it_stopped',
    () async {
      final (:fake, ana: _, :bo, :a, :b, :c, :group, early: _, :seen, bSeen: _) = await _crew();
      final b2 = await approvedDevice(fake, b);
      // Its first part is refused for its limit, two minutes; then Bo's second device's inbox fails once.
      fake
        ..refuse(
          (method: 'PUT', path: RegExp(r'/history-shares/[0-9a-f-]+/parts/0$')),
          429,
          headers: {'Retry-After': '120'},
        )
        ..refuse((method: 'POST', path: '/api/devices/${b2.registered.last}/inbox'), 500);
      final shared = await a.engine.shareHistory(group, bo, 'week');
      expect(shared.truncated, isFalse);
      int count(String method, Pattern path) =>
          seen.where((r) => r.method == method && path.allMatches(r.url.path).isNotEmpty).length;
      final parts = RegExp(r'/history-shares/[0-9a-f-]+/parts/0$');
      await until(() => count('PUT', parts) == 1, what: 'the first part refused');
      // Not before the two minutes its 429 asked.
      for (var waited = Duration.zero; waited < const Duration(seconds: 100); waited += const Duration(seconds: 20)) {
        a.clock.advance(const Duration(seconds: 20));
        await turnEnded(a);
      }
      expect(count('PUT', parts), 1);
      bool isNotice(GatewayEvent e) => e.type == 'DM_MESSAGE_CREATE' && (e.data! as Map)['type'] == 4;
      await until(() {
        a.clock.advance(const Duration(seconds: 30));
        return c.heard.any(isNotice);
      }, what: 'the share completed');
      expect(count('PUT', RegExp(r'/history-shares/[0-9a-f-]+$')), 1);
      expect(count('PUT', parts), 2);
      expect(count('POST', '/api/devices/${b.registered.last}/inbox'), 1);
      expect(count('POST', '/api/devices/${b2.registered.last}/inbox'), 2);
      expect(count('POST', RegExp(r'/history-shares/[0-9a-f-]+/complete$')), 1);
      await turnEnded(c);
      expect(c.heard.where(isNotice), hasLength(1));
      for (final d in [a, b, b2, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // Ruling 1 and the twins' rule 2: a share the person was told went, and that then ends for good (here a part the
  // API refuses), is said to them; its keys never went, so nobody sees its notice.
  test(
    'a_share_that_ends_for_good_after_the_server_took_it_is_said',
    () async {
      final (fake: fake, ana: _, :bo, :a, :b, :c, :group, early: _, :seen, bSeen: _) = await _crew();
      fake.refuse((method: 'PUT', path: RegExp(r'/history-shares/[0-9a-f-]+/parts/0$')), 413);
      final said = <({String conversationId, String messageId, String kind})>[];
      final heard = a.engine.changesRefused.listen(said.add);
      await a.engine.shareHistory(group, bo, 'week');
      await until(() => said.isNotEmpty, what: 'the share said to have stopped');
      final put = seen.singleWhere(
        (r) => r.method == 'PUT' && RegExp(r'/history-shares/[0-9a-f-]+$').hasMatch(r.url.path),
      );
      expect(said, [(conversationId: group, messageId: put.url.pathSegments.last, kind: 'share')]);
      expect(
        seen.where((r) => r.method == 'POST' && (r.url.path.endsWith('/inbox') || r.url.path.endsWith('/complete'))),
        isEmpty,
      );
      await turnEnded(c);
      expect(c.heard.where((e) => e.type == 'DM_MESSAGE_CREATE' && (e.data! as Map)['type'] == 4), isEmpty);
      await heard.cancel();
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // I1 of the review: a package the API lists past its caps (more than 64 parts, more than 64 MiB) is never fetched
  // nor acknowledged; a part longer than a part can be is cut off as it comes, and its package let go.
  test(
    "packages_past_the_API's_caps_are_never_fetched,_and_a_part_past_a_part's_is_cut_off",
    () async {
      final (:fake, :dee, :a, :dm, :sent) = await _deviceless();
      final seen = <http.Request>[];
      final asked = <String>[];
      var d = await firstDevice(
        fake,
        dee,
        host: WatchedHost(TestHost().gate, asked),
        client: watchedClient(fake, seen: seen.add),
      );
      // Ana's catch-up for Dee, its key taken and itself listed for her device, its first part padded on its way.
      await until(
        () async => (d.store.read(historyKeys) as List?)?.isNotEmpty == true && (await d.api.shares()).isNotEmpty,
        what: "Dee's catch-up's key and listing",
      );
      final [catchUp] = await d.api.shares();
      fake.padSharePart(catchUp.id, 0, (1 << 20) + 16);
      // Two a server lists past the caps, with keys on Dee's device.
      await d.engine.stop();
      final ana = catchUp.fromUserId;
      final past = [
        fake.addShare(conversation: dm, from: ana, to: dee, parts: 65),
        fake.addShare(conversation: dm, from: ana, to: dee, size: (64 << 20) + 1),
      ];
      await d.store.write(historyKeys, [
        ...(d.store.read(historyKeys)! as List).cast<Object?>(),
        for (final id in past)
          {
            'share_id': id,
            'kind': 'catch_up',
            'conversation_id': dm,
            'user_id': ana,
            'at': DateTime.now().millisecondsSinceEpoch,
          },
      ]);
      d = await restarted(fake, d);
      // The padded one is let go, acknowledged, before history_import is ever asked; the others stay as they are.
      await until(() async {
        d.clock.advance(quietBeforeImport);
        return !(await d.api.shares()).any((share) => share.id == catchUp.id);
      }, what: 'the padded package let go');
      for (var i = 0; i < 4; i++) {
        d.clock.advance(quietBeforeImport);
        await turnEnded(d);
      }
      expect(asked, isNot(contains('history_import')));
      expect(await _holds(d, dm, sent.id), isFalse);
      expect({for (final share in await d.api.shares()) share.id}, past.toSet());
      expect(seen.where((r) => past.any((id) => r.url.path.contains('/history-shares/$id/'))), isEmpty);
      await a.engine.stop();
      await d.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // I2 of the review and the twins' rule 1: the API lists the oldest 100 packages a device hasn't acknowledged. Keys
  // past them stay, and come in as acknowledgements make room: all 101 go.
  test(
    "keys_past_the_API's_page_of_100_wait_for_their_turn",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      fake.befriend(ana, bo);
      final a = await firstDevice(fake, ana);
      var b = await firstDevice(fake, bo);
      final dm = (await a.engine.createDM(bo)).id;
      await sameGroup([a, b], dm);
      // 101 of Ana's catch-ups for Bo, whose keys his device took.
      await b.engine.stop();
      final ids = [for (var i = 0; i < 101; i++) fake.addShare(conversation: dm, from: ana, to: bo)];
      await b.store.write(historyKeys, [
        for (final id in ids)
          {
            'share_id': id,
            'kind': 'catch_up',
            'conversation_id': dm,
            'user_id': ana,
            'at': DateTime.now().millisecondsSinceEpoch,
          },
      ]);
      b = await restarted(fake, b);
      await until(
        () async {
          b.clock.advance(quietBeforeImport);
          return (await b.api.shares()).isEmpty;
        },
        timeout: const Duration(minutes: 2),
        what: 'every package acknowledged',
      );
      final record = (b.store.read(historyKeys)! as List).cast<Map<String, Object?>>();
      expect({for (final one in record) one['share_id']}, ids.toSet());
      expect(record.every((one) => one['done'] is int && !one.containsKey('kind')), isTrue);
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // I2 of the review: a package let go, acknowledged as one that can never come in, makes room on the API's page too.
  test(
    "keys_past_the_API's_page_of_100_wait_behind_packages_let_go_too",
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      fake.befriend(ana, bo);
      final a = await firstDevice(fake, ana);
      var b = await firstDevice(fake, bo);
      final dm = (await a.engine.createDM(bo)).id;
      await sameGroup([a, b], dm);
      await b.engine.stop();
      final ids = [for (var i = 0; i < 101; i++) fake.addShare(conversation: dm, from: ana, to: bo)];
      await b.store.write(historyKeys, [
        for (final id in ids)
          {
            'share_id': id,
            'kind': 'catch_up',
            'conversation_id': dm,
            'user_id': ana,
            'at': DateTime.now().millisecondsSinceEpoch,
          },
      ]);
      // The first 100 don't open here, as packages a member made up; the last does.
      final asked = <Map<String, Object?>>[];
      b = await restarted(
        fake,
        b,
        host: WatchedHost(
          b.host,
          [],
          commands: asked,
          fail: (command) => command['cmd'] == 'history_import' && command['share_id'] != ids.last
              ? CoreError('decrypt_failed')
              : null,
        ),
      );
      await until(
        () async {
          b.clock.advance(quietBeforeImport);
          return (await b.api.shares()).isEmpty;
        },
        timeout: const Duration(minutes: 2),
        what: 'every package acknowledged',
      );
      expect(asked.where((c) => c['cmd'] == 'history_import' && c['share_id'] == ids.last), hasLength(1));
      await a.engine.stop();
      await b.engine.stop();
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // M4 of the review: a package of a conversation the user is no longer in goes, unacknowledged, once an import of it
  // failed (their other devices may still take it in): it isn't downloaded again every hour for its 30 days.
  test(
    'a_package_of_a_conversation_the_user_left_goes_unacknowledged',
    () async {
      final (:fake, :dee, :a, :dm, sent: _) = await _deviceless();
      final asked = <String>[];
      final d = await firstDevice(
        fake,
        dee,
        host: WatchedHost(
          TestHost().gate,
          asked,
          fail: (command) => command['cmd'] == 'history_import' ? CoreError('internal') : null,
        ),
      );
      await until(
        () async => (d.store.read(historyKeys) as List?)?.isNotEmpty == true && (await d.api.shares()).isNotEmpty,
        what: "the catch-up's key and listing",
      );
      // Dee is no longer in the conversation, and the import fails.
      fake.dropMembers(dm, [dee]);
      await until(() {
        d.clock.advance(quietBeforeImport);
        return asked.contains('history_import');
      }, what: 'the import tried');
      for (var waited = Duration.zero; waited < const Duration(minutes: 3); waited += quietBeforeImport) {
        d.clock.advance(quietBeforeImport);
        await turnEnded(d);
      }
      expect(asked.where((cmd) => cmd == 'history_import'), hasLength(1));
      expect(await d.api.shares(), hasLength(1));
      final record = (d.store.read(historyKeys)! as List).cast<Map<String, Object?>>();
      expect((record.length, record.single.containsKey('kind')), (1, false));
      await a.engine.stop();
      await d.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // The twins' rule 1: an offer left holds a place of the API's page; three show in a chat at once, the newest first,
  // and a Dismiss tells the API this device is done with one, which lets the next show.
  test(
    'three_offers_show_at_once,_the_newest_first,_and_a_Dismiss_lets_one_go',
    () async {
      final (fake: _, ana: _, :bo, :a, :b, :c, :group, early: _, seen: _, bSeen: _) = await _crew();
      for (final range in shareRanges) {
        await a.engine.shareHistory(group, bo, range);
      }
      await until(() async => (await b.api.shares()).length == 4, what: 'four packages listed');
      await until(
        () =>
            [for (final o in b.engine.historyOffers.value[group] ?? const <HistoryOffer>[]) o.range].join(' ') ==
            'all month week',
        what: 'the newest three offered',
      );
      final [newest, ...] = b.engine.historyOffers.value[group]!;
      await b.engine.dismissHistoryOffer(newest.shareId);
      expect([for (final o in b.engine.historyOffers.value[group]!) o.range], ['month', 'week', 'day']);
      await until(() async {
        b.clock.advance(quietBeforeImport);
        return !(await b.api.shares()).any((share) => share.id == newest.shareId);
      }, what: 'the dismissed one acknowledged');
      expect(await b.api.shares(), hasLength(3));
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // The twins' rule 3: a package done with is kept by its ID alone for 30 days, so a server that hands its key and its
  // listing again gets nothing offered or imported again.
  test(
    'a_key_and_a_package_that_come_again_once_done_with_are_dropped',
    () async {
      final (:fake, ana: _, :bo, :a, :b, :c, :group, early: _, seen: _, bSeen: _) = await _crew();
      await a.engine.shareHistory(group, bo, 'week');
      final [offer] = await _offered(b, group);
      await b.engine.takeHistoryOffer(offer.shareId);
      expect(await b.api.shares(), isEmpty);
      // Its key and its listing again.
      fake
        ..unackShare(offer.shareId, b.registered.last)
        ..replayInbox(b.registered.last);
      await until(() async => (await b.api.shares()).isNotEmpty);
      b.connect(b.registered.last);
      for (var i = 0; i < 4; i++) {
        b.clock.advance(quietBeforeImport);
        await turnEnded(b);
      }
      expect(b.engine.historyOffers.value[group] ?? const [], isEmpty);
      final record = (b.store.read(historyKeys)! as List).cast<Map<String, Object?>>();
      expect(record, [
        {'share_id': offer.shareId, 'done': isA<int>()},
      ]);
      for (final d in [a, b, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // M1 of the review: an import counts as begun right before history_import, and one that failed is no longer counted,
  // in the record too, so a later end of the app doesn't make it one that never ended.
  test(
    "an_import_that_failed_isn't_counted_as_one_that_never_ended",
    () async {
      final (:fake, :dee, :a, :dm, :sent) = await _deviceless();
      final asked = <String>[];
      var slips = 1;
      final d = await firstDevice(
        fake,
        dee,
        host: WatchedHost(
          TestHost().gate,
          asked,
          fail: (command) => command['cmd'] == 'history_import' && slips-- > 0 ? CoreError('internal') : null,
        ),
      );
      Map<String, Object?>? key() =>
          ((d.store.read(historyKeys) as List?) ?? const []).cast<Map<String, Object?>>().firstOrNull;
      await until(() {
        d.clock.advance(quietBeforeImport);
        return asked.contains('history_import');
      }, what: 'the first import');
      await until(() => key() != null && !key()!.containsKey('starts'), what: 'its start no longer counted');
      expect(await _holds(d, dm, sent.id), isFalse);
      // Its minute over, it comes in.
      await until(() async {
        d.clock.advance(quietBeforeImport);
        return _holds(d, dm, sent.id);
      });
      await a.engine.stop();
      await d.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // Ruling 2 and M6 of the review: the core deletes a key once it imported its package, so a key the record holds that
  // the core no longer has is an import whose end wasn't recorded (the app ended first): its package is acknowledged.
  test(
    'a_key_the_core_no_longer_has_was_imported:_its_package_is_acknowledged',
    () async {
      final (:fake, :dee, :a, :dm, :sent) = await _deviceless();
      fake.refuse((method: 'POST', path: RegExp(r'/api/history-shares/[0-9a-f-]+/ack$')), 500);
      final asked = <String>[];
      var d = await firstDevice(fake, dee, host: WatchedHost(TestHost().gate, asked));
      await until(() async {
        d.clock.advance(quietBeforeImport);
        return _holds(d, dm, sent.id);
      });
      // The app ended before the record said the import was done.
      await d.engine.stop();
      await d.store.write(historyKeys, [
        for (final one in (d.store.read(historyKeys)! as List).cast<Map<String, Object?>>())
          {...one}..remove('imported'),
      ]);
      d = await restarted(fake, d);
      await until(() async {
        d.clock.advance(quietBeforeImport);
        return (await d.api.shares()).isEmpty;
      }, what: 'its package acknowledged');
      expect(asked.where((cmd) => cmd == 'history_import'), hasLength(2));
      expect(await _holds(d, dm, sent.id), isTrue);
      await a.engine.stop();
      await d.engine.stop();
    },
    skip: noCore,
    timeout: _slow,
  );

  // M4 of the review and the twins' rule 4: a failure waits a minute, then twice as long each time, up to an hour; a
  // 429 what its Retry-After says, never less than that first minute.
  test('a_429_waits_what_its_Retry-After_says,_never_less_than_a_minute', () {
    duvet.DuvetApiException answer(int status, [int? seconds]) => duvet.DuvetApiException(
      action: 'share',
      statusCode: status,
      retryAfter: seconds == null ? null : Duration(seconds: seconds),
    );
    expect(packageWait(answer(429, 0), 0), const Duration(minutes: 1));
    expect(packageWait(answer(429, 10), 3), const Duration(minutes: 1));
    expect(packageWait(answer(429, 7200), 0), const Duration(hours: 2));
    expect(packageWait(answer(429), 2), const Duration(minutes: 4));
    expect(packageWait(answer(429), 0, unsaid: const Duration(days: 1)), const Duration(days: 1));
    expect(packageWait(answer(500, 7200), 0), const Duration(minutes: 1));
    expect(
      [for (var tries = 0; tries < 8; tries++) packageWait(answer(500), tries).inMinutes],
      [1, 2, 4, 8, 16, 32, 60, 60],
    );
  });

  // I3 of the review: in the app, a member who joined later is missing what came before; once a share of it is added,
  // the chat hears it came in, and its newest page has those messages, shared by their sender, and no notice at its
  // start.
  test(
    'what_a_share_brings_from_before_joining_shows_in_the_chat_once_added',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      fake
        ..befriend(ana, bo)
        ..befriend(ana, cy);
      final a = await firstDevice(fake, ana);
      final c = await firstDevice(fake, cy);
      final group = (await a.engine.createGroup('Crew', [cy])).id;
      await sameGroup([a, c], group);
      final early = (await a.engine.sendMessage(Outgoing(conversationId: group, nonce: uuidv4(), text: 'before Bo')))!;
      final app = await appOn(fake, bo);
      await app.ready();
      // His app hears what's for its device, as the app identifies with it once it has one.
      final device = (await app.core.handle<Map<String, Object?>>({'cmd': 'status'}))['device_id']! as String;
      final token = app.seen.map((r) => r.headers['Authorization']).nonNulls.first.replaceFirst('Bearer ', '');
      app.end();
      addTearDown(
        fake.connect(token, device, (event) {
          if (payloadOf(event, bo) case final payload?) app.repository.handleEvent(payload);
        }),
      );
      await a.engine.addMember(group, bo);
      final target = ConversationTarget(group);
      // His app lists the group, with when he joined it.
      await app.repository.refreshConversations();
      final events = <MessageEvent>[];
      final heard = app.repository.messageEvents(target).listen(events.add);
      await until(() async {
        final page = await app.repository.messages(target);
        return !page.any((m) => m.id == early.id) && app.repository.chatStart(target).beforeJoining;
      }, what: "the rows from before Bo joined gave way");
      await a.engine.shareHistory(group, bo, 'week');
      await until(() => (app.repository.historyOffers.value[group] ?? const []).isNotEmpty, what: 'the offer');
      await app.repository.takeHistoryOffer(group, app.repository.historyOffers.value[group]!.single.shareId);
      await until(() => events.any((e) => e is ContentChanged && e.imported), what: 'the chat told');
      final [row] = [
        for (final m in await app.repository.messages(target))
          if (m.id == early.id) m,
      ];
      expect((row.content, row.sharedBy != null), ('before Bo', true));
      expect(app.repository.chatStart(target).beforeJoining, isFalse);
      await heard.cancel();
      for (final d in [a, c]) {
        await d.engine.stop();
      }
    },
    skip: noCore,
    timeout: _slow,
  );

  // The chats list names a notice's author, or "You", before its preview, as a call's.
  test('a_share_notice_previews_as_whom_it_went_to_and_how_far_back', () {
    final notice = ChatMessage(
      id: 'n',
      authorId: 'a',
      authorName: 'Ana',
      content: '',
      createdAt: DateTime(2026),
      isNotice: true,
      sharedHistory: (toUserId: 'b', toName: 'Bo', range: 'month'),
    );
    expect(recent.previewOf(notice, (content) => content), 'shared the last 30 days with Bo');
  });

  group('in the chat', () {
    Future<FakeRepository> shown(WidgetTester tester) async {
      final repository = FakeRepository()..encryption.value = EngineState.ready;
      await tester.pumpWidget(DuvetApp(repository: repository));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maya').first);
      await tester.pumpAndSettle();
      return repository;
    }

    // Opened from the members sheet, on another member: how far back, then Share.
    Future<void> shareFromMembers(WidgetTester tester, {String pick = 'The last 7 days'}) async {
      await tester.tap(find.bySemanticsLabel('More').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Members').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maya').last);
      await tester.pumpAndSettle();
      // On Maya's profile, under its buttons.
      await tester.ensureVisible(find.text(Notice.shareHistory.text));
      await tester.pumpAndSettle();
      await tester.tap(find.text(Notice.shareHistory.text));
      await tester.pumpAndSettle();
      expect(find.text(Notice.shareHistoryWith.fill({'name': 'Maya'})), findsOneWidget);
      await tester.tap(find.text(pick));
      await tester.pumpAndSettle();
      await tester.tap(find.text(Notice.shareHistorySend.text));
      await tester.pumpAndSettle();
    }

    testWidgets('share_history_is_offered_on_another_member,_with_its_range,_and_says_what_came_of_it', (tester) async {
      final repository = await shown(tester);
      await shareFromMembers(tester, pick: 'The last 30 days');
      expect(repository.encryptionTaps, ['shareHistory c-maya ${FakeRepository.maya} month']);
      // Taken whole: the sheet closes, saying it was shared.
      expect(find.text(Notice.shareHistoryWith.fill({'name': 'Maya'})), findsNothing);
      expect(find.text('You shared the last 30 days with Maya'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      // One that didn't fit says it was cut to the newest.
      repository.shareAnswer = (truncated: true, start: DateTime.utc(2026, 11, 19, 12));
      await shareFromMembers(tester);
      expect(find.text('Not all of it fit: Maya gets the messages from 19 November 2026 on.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      // The hour's eleventh: why it didn't go, in the sheet, for another try.
      repository.shareRefusal = ActionFailed(Notice.shareHistoryLimit.fill({'when': 'in 60 minutes'}));
      await shareFromMembers(tester);
      expect(find.text('You can share history 10 times an hour. Try again in 60 minutes.'), findsOneWidget);
      expect(find.text(Notice.shareHistoryWith.fill({'name': 'Maya'})), findsOneWidget);
    });

    testWidgets("a_share_notice_is_drawn_as_a_notice,_and_its_offer_adds_on_the_person's_yes", (tester) async {
      final repository = FakeRepository()..encryption.value = EngineState.ready;
      await tester.pumpWidget(DuvetApp(repository: repository));
      await tester.pumpAndSettle();
      repository.history['c-maya']!.add(
        ChatMessage(
          id: 'n4',
          authorId: FakeRepository.maya,
          authorName: 'Maya',
          content: '',
          createdAt: DateTime(2026, 10, 23, 9, 6),
          isNotice: true,
          sharedHistory: (toUserId: FakeRepository.me.id, toName: 'you', range: 'week'),
        ),
      );
      repository.historyOffers.value = {
        'c-maya': [
          const HistoryOffer(shareId: 's2', conversationId: 'c-maya', fromUserId: FakeRepository.maya, range: 'month'),
          const HistoryOffer(shareId: 's1', conversationId: 'c-maya', fromUserId: FakeRepository.maya, range: 'week'),
        ],
      };
      await tester.tap(find.text('Maya').first);
      await tester.pumpAndSettle();
      final said = Notice.sharedWithYou.fill({'a': 'Maya', 'range': Notice.rangeWeek.text});
      final month = Notice.sharedWithYou.fill({'a': 'Maya', 'range': Notice.rangeMonth.text});
      // The notice in the chat, and each offer over the message box.
      expect(find.text(said), findsNWidgets(2));
      expect(find.text(month), findsOneWidget);
      // Dismissed on the person's no: that offer goes.
      await tester.tap(find.bySemanticsLabel('Dismiss').first);
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps, ['dismissHistoryOffer c-maya s2']);
      expect(find.text(month), findsNothing);
      // Added on the person's yes: the offer goes, and the notice stays.
      await tester.tap(find.text(Notice.sharedAdd.text));
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps, ['dismissHistoryOffer c-maya s2', 'takeHistoryOffer c-maya s1']);
      expect(find.text(Notice.sharedAdd.text), findsNothing);
      expect(find.text(said), findsOneWidget);
      // A notice: held, it offers its deletion and no reply, edit or pin.
      await tester.longPress(find.text(said));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Reply'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Pin'), findsNothing);
    });
  });
}

/// A core whose packages didn't all fit: its newest, from [start] on, as history_share says of one past 64 MiB.
class _Cut extends WatchedHost {
  _Cut(CoreHost host, this.start) : super(host, []);
  final DateTime start;

  @override
  Future<Map<String, Object?>> share(Map<String, Object?> command) async => {
    ...await super.share(command),
    'truncated': true,
    'start': start.millisecondsSinceEpoch,
  };
}
