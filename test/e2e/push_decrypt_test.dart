import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/content.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/legacy.dart' show LegacyRecords;
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/push_decrypt.dart';
import 'package:duvet/e2e/store.dart' show anotherGroups, pushRecord;
import 'package:duvet/e2e/sync.dart' show refusedGenerationsIn;
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet/push/background.dart';
import 'package:duvet/push/push_message.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// The push of a conversation's message, opened on the phone (PLAN-E2E-CLIENTES.md, Task 21 and Review Focus 8; decision
// 29; Ruling 18): the API pushes it without its text, with its queue entry when it fits, and the push's engine shows
// the text Ana's core opens. The app's engine answers when it holds the core; otherwise the push's engine opens it,
// applies the entry or reads the queue with the stored session, and closes it. Past its time, or failing, it shows «New
// message» with its author, and the core stays closed. Ana's phone is a device of hers whose engine, the app's, stopped
// unless a case keeps it; the push's engine is a gate of its own on her core's folder and keys.
const _slow = Timeout(Duration(minutes: 3));

typedef _Phone = ({
  FakeApi fake,
  String ana,
  String bo,
  TestDevice a,
  TestDevice b,
  TestHost host,
  String conversation,
  List<http.Request> requests,
});

/// Ana's phone and Bo's device in a DM whose group both hold, Ana's app running: a case stops it, as a phone whose app
/// isn't running. Her app's connection to the gateway hands on only what [hears] lets through.
Future<_Phone> _phone({bool Function(GatewayEvent event)? hears}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final host = TestHost();
  final a = await firstDevice(fake, ana, host: host.gate, hears: hears);
  final b = await firstDevice(fake, bo);
  await a.engine.openConversation(conversation);
  await sameGroup([a, b], conversation);
  addTearDown(b.engine.stop);
  addTearDown(a.engine.stop);
  // Bo's device, another phone, shares this process, and its gate answers on the core's port: Ana's phone's push
  // engine mustn't find it there.
  IsolateNameServer.removePortNameMapping(corePortName);
  return (fake: fake, ana: ana, bo: bo, a: a, b: b, host: host, conversation: conversation, requests: <http.Request>[]);
}

/// The push's engine's gate on Ana's phone: it asks the app's engine when one holds the core, else opens it here.
CoreGate _pushGate(_Phone phone) =>
    CoreGate(serves: false, keys: phone.host.keys, folder: () async => phone.host.folder, lockedWait: _locked);
const _locked = Duration(milliseconds: 300);

/// The push [data] holds, opened as the push's engine opens it, with the stored session of Ana's app and what her
/// phone keeps of the app's home ([cache]): what its notification shows, none when the app says its chat is on screen.
Future<MessagePush?> _open(
  _Phone phone,
  Map<String, String> data, {
  List<MessagePush> earlier = const [],
  http.Client? client,
  CoreHost Function(Duration lockedWait)? core,
  ChatCacheStore? cache,
  Duration within = pushTime,
}) => openedPush(
  Push.fromData(data)! as EncryptedMessagePush,
  earlier: earlier,
  session: (token: phone.a.token, sessionToken: 'session', refreshedAt: null, userId: phone.ana),
  core: core ?? (_) => _pushGate(phone),
  router: fakeRouter,
  duvetClient: engineClient,
  client: client ?? watchedClient(phone.fake, seen: phone.requests.add),
  store: (_) async => phone.a.store,
  cache: cache ?? MemoryChatCacheStore(),
  within: within,
);

/// What Ana's core holds of the message (of her DM, or of [conversation]), read by a gate of the app's once the push's
/// let go: null for none.
Future<String?> _onAna(_Phone phone, String id, {String? conversation}) async {
  final gate = CoreGate(
    serves: true,
    keys: phone.host.keys,
    folder: () async => phone.host.folder,
    lockedWait: _locked,
  );
  expect((await gate.open(phone.ana)).state, HostState.ready, reason: 'the push left the core closed');
  try {
    final rows = await shownMessages(gate, conversation ?? phone.conversation, [id]);
    return rows.where((row) => row.status == MessageStatus.ok).firstOrNull?.text;
  } finally {
    await gate.close();
  }
}

/// Bo's message of [text] in the DM, the API's copy of it.
Future<duvet.DirectMessage> _says(_Phone phone, String text) async =>
    (await phone.b.engine.sendMessage(Outgoing(conversationId: phone.conversation, nonce: uuidv4(), text: text)))!;

/// The queue's reads the push made, and its renewals of the session, which it never makes.
Iterable<http.Request> _queueReads(_Phone phone) =>
    phone.requests.where((r) => r.url.path.endsWith('/conversations/${phone.conversation}/mls/queue'));
Iterable<http.Request> _renewals(_Phone phone) => phone.requests.where((r) => r.url.path.startsWith('/api/auth'));

/// The push's engine's gate on Ana's phone, each one the push makes counted with how long it may wait for a locked
/// database.
CoreHost Function(Duration lockedWait) _counted(_Phone phone, void Function(Duration lockedWait) made) => (wait) {
  made(wait);
  return _pushGate(phone);
};

/// [open], the push's waits for its app ending [_ahead] of their time, its own time ([within]) as it is: a timer counts
/// whole milliseconds and fires on one, so a wait for the time a push has left can end a moment before the push's clock
/// says that time is up (#341). Here they end well before it, the same way each run.
Future<T> _waitsAhead<T>(Duration within, Future<T> Function() open) => runZoned(
  open,
  zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) =>
        parent.createTimer(zone, duration == within || duration <= _ahead ? duration : duration - _ahead, callback),
  ),
);
const _ahead = Duration(milliseconds: 100);

/// Ana's app in an isolate of its own, as the push sees it: it answers on the push's port, and ends a moment after it
/// takes a request.
void _takesThenEnds(SendPort ready) {
  answerPushes((ask) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    Isolate.exit();
  });
  ready.send(null);
}

/// Ana's phone and Bo's device in a DM: Ana's founding answered for and kept nothing of, her app ended before it listed
/// the conversation again, her core holding her own group; then Bo's group made on the API, with a welcome to her
/// device. Bo's message there reaches her phone by a push, whose engine notes the welcome as another group's
/// (another_group) and shows no text, the commands its core is given kept in [pushed]. With [recordKept], her record
/// holds the exact record of Ana and Bo before the push, as a forget leaves it. The phone, and Bo's message.
Future<(_Phone, duvet.DirectMessage)> _anotherGroupByPush({
  List<Map<String, Object?>>? pushed,
  bool recordKept = false,
}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final host = TestHost();
  // The listing right after her founding is refused, as an app that ended before it listed again leaves it.
  var refuse = false;
  final client = watchedClient(
    fake,
    answer: (request) async {
      if (request.method == 'POST' && request.url.path == commitsPath(conversation)) {
        refuse = true;
      } else if (refuse && request.method == 'GET' && request.url.path == '/api/users/@me/conversations') {
        refuse = false;
        return http.Response(jsonEncode({'error': 'unavailable'}), 503, headers: {'content-type': 'application/json'});
      }
      return null;
    },
  );
  final a = await firstDevice(fake, ana, host: host.gate, client: client);
  final b = await firstDevice(fake, bo);
  addTearDown(b.engine.stop);
  fake.forget((method: 'POST', path: commitsPath(conversation)));
  await a.engine.openConversation(conversation).catchError((Object _) {});
  expect(await groupOf(a, conversation), isNotNull);
  await a.engine.stop();
  await b.engine.openConversation(conversation);
  final sent = (await b.engine.sendMessage(
    Outgoing(conversationId: conversation, nonce: uuidv4(), text: "in the API's group"),
  ))!;
  IsolateNameServer.removePortNameMapping(corePortName);
  final phone = (
    fake: fake,
    ana: ana,
    bo: bo,
    a: a,
    b: b,
    host: host,
    conversation: conversation,
    requests: <http.Request>[],
  );
  if (recordKept) await LegacyRecords(a.store).forgot(conversation, (owner: null, members: [ana, bo], exact: true));
  final opened = await _open(
    phone,
    fake.pushOf(conversation, sent.id),
    core: (_) => WatchedHost(_pushGate(phone), [], commands: pushed),
  );
  expect(opened!.text, Notice.newMessage.text);
  expect(a.store.read(anotherGroups), isNotNull);
  return (phone, sent);
}

/// The group of the conversation Ana's core holds, read by a gate of the app's once the push's let go: null for none.
Future<int?> _epochOnAna(_Phone phone) async {
  final gate = CoreGate(
    serves: true,
    keys: phone.host.keys,
    folder: () async => phone.host.folder,
    lockedWait: _locked,
  );
  expect((await gate.open(phone.ana)).state, HostState.ready, reason: 'the push left the core closed');
  try {
    return (await gate.handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': phone.conversation}))['epoch']
        as int?;
  } on CoreError {
    return null;
  } finally {
    await gate.close();
  }
}

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'the_entry_in_the_push_opens',
    () async {
      final phone = await _phone();
      // A message the app opened before it closed, which the notification's history lists without its text.
      final before = await _says(phone, 'earlier words');
      await until(() async => (await phone.a.engine.messages(phone.conversation, [before.id])).isNotEmpty);
      await phone.a.engine.stop();
      final sent = await _says(phone, 'the bluebird flies at noon');
      final data = phone.fake.pushOf(phone.conversation, sent.id);
      expect((data.containsKey('entry'), data.containsKey('text')), (true, false));
      final line = MessagePush(
        messageId: before.id,
        authorId: phone.bo,
        authorName: 'Bo',
        authorAvatar: '',
        place: '',
        text: '',
        target: ConversationTarget(phone.conversation),
        sentAt: DateTime.now(),
      );

      final opened = (await _open(phone, data, earlier: [line]))!;
      expect(
        (opened.text, opened.authorName, opened.messageId, opened.target),
        ('the bluebird flies at noon', 'Bo', sent.id, ConversationTarget(phone.conversation)),
      );
      // The chat's earlier line, as Ana's core holds it.
      expect(opened.earlier, {before.id: 'earlier words'});
      // The entry was enough: the API was asked nothing.
      expect(phone.requests, isEmpty);
      expect(await _onAna(phone, sent.id), 'the bluebird flies at noon');
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'without_an_entry_the_queue_is_read',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      // Too long for its entry to fit FCM's 4096 bytes: the push comes without it.
      final long = 'A long message. ' * 250;
      final sent = await _says(phone, long);
      final data = phone.fake.pushOf(phone.conversation, sent.id);
      expect(data.containsKey('entry'), isFalse);

      final opened = (await _open(phone, data))!;
      // Worded as its notification shows it: cut at 2000 characters.
      expect(opened.text, pushText(long));
      expect(opened.text, endsWith('A long message.…'));
      expect([for (final r in _queueReads(phone)) r.method], ['GET']);
      expect(_renewals(phone), isEmpty);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_gap_reads_the_queue_first',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      // The first one's push never came: the second's entry follows a number Ana's core doesn't have.
      final first = await _says(phone, 'first');
      final second = await _says(phone, 'second');
      final data = phone.fake.pushOf(phone.conversation, second.id);
      expect(data.containsKey('entry'), isTrue);

      final opened = (await _open(phone, data))!;
      expect(opened.text, 'second');
      expect(_queueReads(phone), hasLength(1));
      expect(await _onAna(phone, first.id), 'first');
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'the_app_answers_when_it_holds_the_core',
    () async {
      // Ana's app runs, its connection hearing no message of the DM's: only the push's entry brings it.
      final phone = await _phone(hears: (event) => event.type != 'DM_MESSAGE_CREATE');
      // Whether Ana's app shows the chat by the time it answers.
      var onScreen = false;
      final answering = answerPushes(
        (ask) async => (
          texts: await phone.a.engine.pushTexts(ask.conversationId, ask.entry, ask.lines, ask.wait),
          onScreen: onScreen,
        ),
      );
      addTearDown(() => stopAnsweringPushes(answering));
      final sent = await _says(phone, 'asked of the app');
      final data = phone.fake.pushOf(phone.conversation, sent.id);
      var opens = 0;

      final opened = await _open(
        phone,
        data,
        core: (_) {
          opens++;
          return _pushGate(phone);
        },
      );
      expect(opened?.text, 'asked of the app');
      // The push's engine made no core of its own (one writer, Review Focus 2), and asked the API nothing.
      expect(opens, 0);
      expect(phone.requests, isEmpty);
      // The app's engine took the entry in its turn: it holds the message.
      expect(
        [
          for (final row in await phone.a.engine.messages(phone.conversation, [sent.id])) row.text,
        ],
        ['asked of the app'],
      );
      // Decided again after its wait: a chat the app shows by then gets no notification (rule 11).
      onScreen = true;
      final seen = await _says(phone, 'seen in the app');
      expect(await _open(phone, phone.fake.pushOf(phone.conversation, seen.id)), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'an_expired_session_shows_a_message_without_text',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final sent = await _says(phone, 'not for an ended session');
      final data = phone.fake.pushOf(phone.conversation, sent.id)..remove('entry');
      phone.fake.endSession(phone.a.token);

      final opened = (await _open(phone, data))!;
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      // The queue refused it, and the push renewed nothing: renewing could race the app's own renewal.
      expect(_queueReads(phone), hasLength(1));
      expect(_renewals(phone), isEmpty);
      expect(await _onAna(phone, sent.id), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // Step 5's review, Minor 6 (mobile#366): the push's paths no case took.
  test(
    'an_expired_session_with_the_entry_in_the_push_opens_its_text_without_the_API',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final sent = await _says(phone, 'opened with an ended session');
      final data = phone.fake.pushOf(phone.conversation, sent.id);
      expect(data.containsKey('entry'), isTrue);
      phone.fake.endSession(phone.a.token);

      final opened = (await _open(phone, data))!;
      expect(opened.text, 'opened with an ended session');
      // Nothing was asked of the API, which would refuse it, and nothing was renewed.
      expect(phone.requests, isEmpty);
      expect(await _onAna(phone, sent.id), 'opened with an ended session');
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "while_the_app's_device_isn't_ready_its_core_applies_the_push_through_the_core's_port",
    () async {
      // Ana's app hears no message of the DM's: only the push's entry brings it.
      bool deaf(GatewayEvent event) => event.type != 'DM_MESSAGE_CREATE';
      final phone = await _phone(hears: deaf);
      // Her app opens its core again, as at a start, and its gate answers on the core's port. Its device not ready yet
      // (starting, setting up), it answers no push: nothing answers on the push's port.
      final app = await restarted(phone.fake, phone.a, hears: deaf);
      addTearDown(app.engine.stop);
      expect(IsolateNameServer.lookupPortByName(pushPortName), isNull);
      final sent = await _says(phone, 'applied in the core of the app');
      final data = phone.fake.pushOf(phone.conversation, sent.id);

      // The app holds the database, which the push's engine couldn't open itself: its text came through the port.
      final opened = (await _open(phone, data))!;
      expect(opened.text, 'applied in the core of the app');
      expect(_queueReads(phone), isEmpty);
      // The one writer took the entry: the app's engine holds the message.
      expect(
        [
          for (final row in await app.engine.messages(phone.conversation, [sent.id])) row.text,
        ],
        ['applied in the core of the app'],
      );
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_push_for_an_account_whose_database_this_phone_doesn't_hold_shows_a_message_without_text_and_makes_none",
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final sent = await _says(phone, 'for an account this phone never opened');
      // Another account's session, kept on the phone, whose app never opened the core here.
      final other = phone.fake.addUser();
      final opened = (await openedPush(
        Push.fromData(phone.fake.pushOf(phone.conversation, sent.id))! as EncryptedMessagePush,
        earlier: const [],
        session: (token: phone.a.token, sessionToken: 'session', refreshedAt: null, userId: other),
        core: (_) => _pushGate(phone),
        router: fakeRouter,
        duvetClient: engineClient,
        client: watchedClient(phone.fake, seen: phone.requests.add),
        store: (user) => pushRecord(user, folder: () async => phone.host.folder),
        cache: MemoryChatCacheStore(),
      ))!;
      expect(opened.text, Notice.newMessage.text);
      // Neither a database, nor its key, nor a record.
      expect(Directory('${phone.host.folder.path}/e2e/$other').existsSync(), isFalse);
      expect(phone.host.keys.keyOf(other), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'a_push_of_a_conversation_this_device_never_had_shows_a_message_without_text',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      // Bo and Carl's DM, which Ana's device was never in.
      final carl = phone.fake.addUser();
      final c = await firstDevice(phone.fake, carl);
      addTearDown(c.engine.stop);
      IsolateNameServer.removePortNameMapping(corePortName);
      final theirs = phone.fake.addConversation(group: false, members: [phone.bo, carl]);
      await phone.b.engine.openConversation(theirs);
      await sameGroup([phone.b, c], theirs);
      IsolateNameServer.removePortNameMapping(corePortName);
      final sent = (await phone.b.engine.sendMessage(
        Outgoing(conversationId: theirs, nonce: uuidv4(), text: 'for Carl alone'),
      ))!;

      final opened = (await _open(phone, phone.fake.pushOf(theirs, sent.id)))!;
      // Its entry waits out of any group in Ana's core, and the queue isn't hers to read.
      expect(opened.text, Notice.newMessage.text);
      expect(await _onAna(phone, sent.id, conversation: theirs), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    "a_push_whose_open_meets_the_app's_with_no_port_yet_lets_go_within_its_time",
    () async {
      final phone = await _phone();
      // Ana's app holds the core as it opens it, before its gate answers on the core's port.
      expect(IsolateNameServer.lookupPortByName(corePortName), isNull);
      final sent = await _says(phone, 'while the app opens');
      final data = phone.fake.pushOf(phone.conversation, sent.id);

      final started = DateTime.now();
      final opened = (await _open(
        phone,
        data,
        core: (wait) =>
            CoreGate(serves: false, keys: phone.host.keys, folder: () async => phone.host.folder, lockedWait: wait),
        within: const Duration(seconds: 1),
      ))!;
      final took = DateTime.now().difference(started);
      expect(opened.text, Notice.newMessage.text);
      // It waited for the database only the time it had.
      expect(took, lessThan(const Duration(seconds: 3)));
      // The app keeps the database it opened: its engine reads what the gateway brought.
      await until(() async => (await phone.a.engine.messages(phone.conversation, [sent.id])).isNotEmpty);
      expect(
        [
          for (final row in await phone.a.engine.messages(phone.conversation, [sent.id])) row.text,
        ],
        ['while the app opens'],
      );
    },
    skip: noCore,
    timeout: _slow,
  );

  test(
    'past_its_time_it_shows_the_fallback_and_closes_the_core',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final sent = await _says(phone, 'too late to show');
      final data = phone.fake.pushOf(phone.conversation, sent.id)..remove('entry');
      // The queue's answer takes longer than the push has.
      final held = Completer<void>();
      final client = watchedClient(
        phone.fake,
        seen: phone.requests.add,
        answer: (request) async {
          if (request.url.path.endsWith('/mls/queue')) await held.future;
          return null;
        },
      );

      final started = DateTime.now();
      final opened = (await _open(phone, data, client: client, within: const Duration(seconds: 1)))!;
      final took = DateTime.now().difference(started);
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      expect(
        took,
        allOf(greaterThanOrEqualTo(const Duration(milliseconds: 990)), lessThan(const Duration(seconds: 3))),
      );
      // The core is closed, and what the late answer brings goes nowhere.
      held.complete();
      await pumpEventQueue(times: 50);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await _onAna(phone, sent.id), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // I1 of the review: past its time, the push's work stops, and nothing opens the core after its notification shows.
  // Here Ana's app takes the push's request and never answers.
  test(
    'an_app_that_takes_the_request_and_never_answers_leaves_the_core_closed_past_the_time',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final answering = answerPushes((ask) => Completer<PushAnswer?>().future);
      addTearDown(() => stopAnsweringPushes(answering));
      final sent = await _says(phone, 'never answered');
      final made = <Duration>[];

      final started = DateTime.now();
      final opened = (await _open(
        phone,
        phone.fake.pushOf(phone.conversation, sent.id),
        within: const Duration(seconds: 2),
        core: _counted(phone, made.add),
      ))!;
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      expect(DateTime.now().difference(started), lessThan(const Duration(milliseconds: 2600)));
      // Nothing after its time: no core made, nothing asked.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(made, isEmpty, reason: "the push made a core with this much time left, though Ana's app took it");
      expect(phone.requests, isEmpty);
      expect(await _onAna(phone, sent.id), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // #341: the same app, the push's wait for its answer ending before the push's clock says its time is up. That wait
  // was the rest of the push's time: its end is the push's, and no core is made in the moment the clock has left.
  test(
    'an_app_that_takes_the_request_and_never_answers_leaves_the_core_closed_when_the_wait_ends_first',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final answering = answerPushes((ask) => Completer<PushAnswer?>().future);
      addTearDown(() => stopAnsweringPushes(answering));
      final sent = await _says(phone, 'never answered');
      final made = <Duration>[];
      const within = Duration(seconds: 2);

      final opened = (await _waitsAhead(
        within,
        () => _open(
          phone,
          phone.fake.pushOf(phone.conversation, sent.id),
          within: within,
          core: _counted(phone, made.add),
        ),
      ))!;
      expect(made, isEmpty, reason: "the push made a core with this much time left, though Ana's app took it");
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      expect(phone.requests, isEmpty);
      expect(await _onAna(phone, sent.id), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // #341: with less time than an app has to take a request, the push's wait for one is the rest of its time. Here the
  // app's name stayed and nothing takes the request, and the wait ends before the push's clock: no core is made.
  test(
    'an_app_that_never_takes_the_request_leaves_the_core_closed_when_the_push_has_less_time_than_it_waits_for_one',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final deaf = RawReceivePort((_) {});
      IsolateNameServer.removePortNameMapping(pushPortName);
      IsolateNameServer.registerPortWithName(deaf.sendPort, pushPortName);
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(pushPortName);
        deaf.close();
      });
      final sent = await _says(phone, 'nothing takes it');
      final made = <Duration>[];
      const within = Duration(seconds: 1);

      final opened = (await _waitsAhead(
        within,
        () => _open(
          phone,
          phone.fake.pushOf(phone.conversation, sent.id),
          within: within,
          core: _counted(phone, made.add),
        ),
      ))!;
      expect(made, isEmpty, reason: 'the push made a core with this much time left, past its wait for an app');
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      expect(phone.requests, isEmpty);
      expect(await _onAna(phone, sent.id), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // I1 of the review: an app whose isolate ends after it took the request leaves the push its time to open the core
  // itself, as the push hears the app's end.
  test(
    'an_app_that_ends_after_taking_the_request_leaves_the_push_time_to_open_the_core',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final ready = ReceivePort();
      addTearDown(ready.close);
      addTearDown(() => IsolateNameServer.removePortNameMapping(pushPortName));
      await Isolate.spawn(_takesThenEnds, ready.sendPort);
      await ready.first;
      final sent = await _says(phone, 'read here after all');
      final waits = <Duration>[];

      final started = DateTime.now();
      final opened = (await _open(
        phone,
        phone.fake.pushOf(phone.conversation, sent.id),
        within: const Duration(seconds: 8),
        core: _counted(phone, waits.add),
      ))!;
      expect(opened.text, 'read here after all');
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 7)));
      // Its gate waits for a locked database no longer than the push has left.
      expect(waits.single, allOf(lessThan(const Duration(seconds: 8)), greaterThan(const Duration(seconds: 6))));
    },
    skip: noCore,
    timeout: _slow,
  );

  // I1 of the review: a burst's later push, its time used by the one before it, opens no core.
  test(
    'a_push_with_no_time_left_opens_no_core',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final sent = await _says(phone, 'no time for it');
      var made = 0;

      final opened = (await _open(
        phone,
        phone.fake.pushOf(phone.conversation, sent.id),
        within: Duration.zero,
        core: _counted(phone, (_) => made++),
      ))!;
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(made, 0);
      expect(await _onAna(phone, sent.id), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // I2 of the review: a message without text, a sticker's, is told as soon as the app's engine holds it, not after
  // its whole wait.
  test(
    "a_sticker's_push_the_app_answers_shows_at_once",
    () async {
      final phone = await _phone(hears: (event) => event.type != 'DM_MESSAGE_CREATE');
      final answering = answerPushes(
        (ask) async => (
          texts: await phone.a.engine.pushTexts(ask.conversationId, ask.entry, ask.lines, ask.wait),
          onScreen: false,
        ),
      );
      addTearDown(() => stopAnsweringPushes(answering));
      final sent = (await phone.b.engine.sendMessage(
        Outgoing(conversationId: phone.conversation, nonce: uuidv4(), stickerAttachmentId: uuidv7()),
      ))!;

      final started = DateTime.now();
      final opened = (await _open(phone, phone.fake.pushOf(phone.conversation, sent.id)))!;
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 3)));
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      expect(
        [
          for (final row in await phone.a.engine.messages(phone.conversation, [sent.id])) row.status,
        ],
        [MessageStatus.ok],
      );
    },
    skip: noCore,
    timeout: _slow,
  );

  // M3 of the review: a welcome the queue brings is held to the record of a conversation from before the cutover, as
  // the app's engine holds it (Ruling 14). Cy's phone, taken out of the group and brought back into one whose members
  // aren't those it first saw, stays out, and its app's engine, next, says the members changed.
  test(
    'a_welcome_the_queue_brings_is_held_to_the_record_of_a_conversation_from_before_the_cutover',
    () async {
      final fake = FakeApi();
      final (ana, bo, cy, dee) = (fake.addUser(), fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana, legacy: true);
      // Ana and Dee share a DM, so Ana may claim Dee's key packages.
      fake.addConversation(group: false, members: [ana, dee]);
      final host = TestHost();
      // Cy's phone sees the group first: its record is the group's three members.
      final c = await firstDevice(fake, cy, host: host.gate);
      final b = await firstDevice(fake, bo);
      final d = await firstDevice(fake, dee);
      final a = await firstDevice(fake, ana);
      for (final device in [b, c, d]) {
        addTearDown(device.engine.stop);
      }
      await a.engine.openConversation(conversation);
      await sameGroup([a, b, c], conversation);
      final cyPackages = await a.api.claimKeyPackages(cy);
      final deePackages = await a.api.claimKeyPackages(dee);
      await stoppedByHand(a);
      addTearDown(a.host.close);
      await removeByHand(a, conversation, cy);
      await until(() async => await groupOf(c, conversation) == null);
      // Cy's app ends. Dee joins, then Cy is brought back: the group's members aren't those Cy's phone first saw.
      await c.engine.stop();
      await addByHand(a, conversation, dee, deePackages);
      await addByHand(a, conversation, cy, cyPackages);
      await sameGroup([a, b], conversation);
      final sent = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'with Dee now'),
      ))!;
      IsolateNameServer.removePortNameMapping(corePortName);
      final phone = (
        fake: fake,
        ana: cy,
        bo: bo,
        a: c,
        b: b,
        host: host,
        conversation: conversation,
        requests: <http.Request>[],
      );

      final opened = (await _open(phone, fake.pushOf(conversation, sent.id)))!;
      // Refused, the welcome brought Cy's phone back into no group: it can't open the message.
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      expect(_queueReads(phone), isNotEmpty);
      expect(await _epochOnAna(phone), isNull);
      // Cy's app, next, says the members changed, as it would have had it read that welcome itself.
      final again = await restarted(fake, c);
      addTearDown(again.engine.stop);
      await until(() => again.engine.conversationState(conversation)?.name == ConversationNotice.membersChanged);
    },
    skip: noCore,
    timeout: _slow,
  );

  // M4 of task 23's review: a restart's welcome that the push's engine applies, and that Cy's core refuses (it never
  // saw the statement that let Ana go), is recorded as the app's engine records it. Cy's app, next, says the members
  // changed and joins nothing on its own.
  test(
    "a_restart's_welcome_the_core_refuses_in_the_push's_engine_is_recorded_for_the_app",
    () async {
      final fake = FakeApi();
      final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
      final conversation = fake.addConversation(group: true, members: [ana, bo, cy], owner: ana);
      final host = TestHost();
      final first = [
        await firstDevice(fake, ana),
        await firstDevice(fake, bo),
        await firstDevice(fake, cy, host: host.gate),
      ];
      await first[0].engine.openConversation(conversation);
      await sameGroup(first, conversation);
      final [a, b, c] = await blockedByHand(fake, conversation, first);
      addTearDown(a.engine.stop);
      addTearDown(b.engine.stop);
      fake.hideStatements(cy);
      await a.engine.leaveConversation(conversation);
      await until(
        () => b.engine.conversationState(conversation) == ConversationState.blocked(restart: Restart.mine, owner: bo),
      );
      await until(() async => (await b.api.queue(conversation, 0)).entries.any((e) => e.kind == 'proposal'));
      await turnEnded(b);
      await turnEnded(c);
      // Cy's app ends: Bo's restart and his message reach Cy's phone by a push.
      await c.engine.stop();
      expect(await b.engine.restartGroup(conversation), [ana]);
      expect(await b.engine.restartGroup(conversation, leaving: [ana]), isEmpty);
      await until(() async => (await groupOf(b, conversation))?.generation == 1);
      final sent = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), text: 'in the new generation'),
      ))!;
      IsolateNameServer.removePortNameMapping(corePortName);
      final phone = (
        fake: fake,
        ana: cy,
        bo: bo,
        a: c,
        b: b,
        host: host,
        conversation: conversation,
        requests: <http.Request>[],
      );

      final opened = (await _open(phone, fake.pushOf(conversation, sent.id)))!;
      expect(opened.text, Notice.newMessage.text);
      expect(refusedGenerationsIn(c.store), {conversation: 1});
      // Cy's app, next: the members changed, and nothing joins on its own.
      final seen = <http.Request>[];
      final again = await restarted(fake, c, client: watchedClient(fake, seen: seen.add));
      addTearDown(again.engine.stop);
      await until(() => again.engine.conversationState(conversation)?.name == ConversationNotice.membersChanged);
      await turnEnded(again);
      expect(requestsOf(seen), isNot(contains('POST ${commitsPath(conversation)}')));
      // On Cy's yes it joins, and the record goes.
      await acceptAsShown(again, conversation);
      await until(() async => (await groupOf(again, conversation))?.generation == 1);
      expect(refusedGenerationsIn(again.store), isEmpty);
    },
    skip: noCore,
    timeout: _slow,
  );

  // FG-M9 of the review of forget_group: the push's engine holds the welcome it applies to the record kept on the
  // phone, exact as a forget kept it; notes the welcome, another group's, with its generation; and the app's engine,
  // as it starts, forgets Ana's own group from that note, read off the record, and joins the API's.
  test(
    "the_push's_engine_holds_its_welcomes_to_the_record_kept_and_notes_another_group_for_the_app",
    () async {
      final pushed = <Map<String, Object?>>[];
      final (phone, _) = await _anotherGroupByPush(pushed: pushed, recordKept: true);
      final held = [
        for (final command in pushed)
          if (command['cmd'] == 'apply')
            for (final entry in (command['entries']! as List).cast<Map<String, Object?>>())
              if (entry['kind'] == 'welcome') entry['expected'],
      ];
      expect(held, isNotEmpty);
      expect(
        held,
        everyElement({
          'members': [phone.ana, phone.bo],
          'exact': true,
        }),
      );
      expect(phone.a.store.read(anotherGroups), {phone.conversation: 0});

      final again = await restarted(phone.fake, phone.a);
      final now = await sameGroup([again, phone.b], phone.conversation);
      expect(now.devices.length, 2);
      expect(again.store.read(anotherGroups), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // mobile#383: the push's engine noted another group's welcome; the server then loses its group, and Ana's app, as it
  // starts, forgets her own group as none is listed, then makes it again. That forget lets the note go: the group made
  // again stays, and nothing forgets it to join it back by an external commit.
  test(
    "a_forget_lets_another_group's_note_go,_so_the_group_made_again_stays",
    () async {
      final (phone, _) = await _anotherGroupByPush();
      await phone.b.engine.stop();
      phone.fake.loseGroup(phone.conversation);
      final commands = <Map<String, Object?>>[];
      final again = await restarted(phone.fake, phone.a, host: WatchedHost(phone.host.gate, [], commands: commands));
      await until(() => phone.fake.viewOf(phone.conversation)['mls'] != null, what: "Ana's group made again");
      await until(() async => await groupOf(again, phone.conversation) != null);
      await turnEnded(again);
      expect(
        [
          for (final command in commands)
            if (const {'forget_group', 'join_external'}.contains(command['cmd'])) command['cmd'],
        ],
        ['forget_group'],
      );
      expect(again.store.read(anotherGroups), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // M4 of the review: what the push's engine can't open is reported by its kind, as the app's engine reports it
  // (decision 40): the app's engine never applies those entries again.
  test(
    "what_the_push's_engine_can't_open_is_reported_by_its_kind",
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      // Bo's device sends a message nobody can open, then the one Ana's phone is pushed: the first only the queue has.
      await stoppedByHand(phone.b);
      addTearDown(phone.b.host.close);
      IsolateNameServer.removePortNameMapping(corePortName);
      await sentByHand(phone.b, phone.conversation, 'spoiled', spoil: true);
      final sent = await sentByHand(phone.b, phone.conversation, 'after the spoiled one');

      final opened = (await _open(phone, phone.fake.pushOf(phone.conversation, sent.id)))!;
      expect(opened.text, 'after the spoiled one');
      await until(() => phone.fake.decryptFailures.isNotEmpty, timeout: const Duration(seconds: 10));
      expect(phone.fake.decryptFailures, [(kind: 'message', count: 1)]);
      expect(_renewals(phone), isEmpty);
    },
    skip: noCore,
    timeout: _slow,
  );

  // M6 of the review: a push the app doesn't answer names people as the app's own notices do, those the phone keeps:
  // the reader, and the people of their DMs; @unknown only for someone it doesn't keep.
  test(
    'a_push_read_here_names_the_people_the_phone_keeps',
    () async {
      final phone = await _phone();
      await phone.a.engine.stop();
      final (cy, dee) = (phone.fake.addUser(), phone.fake.addUser());
      MemoryChatCacheStore homeOf(String user) => MemoryChatCacheStore()
        ..data['home'] = jsonEncode({
          'profile': profileToJson(Profile(id: user, username: 'ana', alias: 'Ana')),
          'conversations': [
            conversationToJson(ConversationSummary(id: uuidv7(), title: 'Cy', isGroup: false, otherUserId: cy)),
            conversationToJson(
              ConversationSummary(id: phone.conversation, title: 'Bo', isGroup: false, otherUserId: phone.bo),
            ),
          ],
          'spaces': <Object?>[],
        });
      final sent = await _says(phone, 'hi <@${phone.ana}>, ask <@$cy> and <@$dee>');
      final data = phone.fake.pushOf(phone.conversation, sent.id);

      expect((await _open(phone, data, cache: homeOf(phone.ana)))!.text, 'hi @Ana, ask @Cy and @unknown');
      // What another account kept names no one.
      expect((await _open(phone, data, cache: homeOf(cy)))!.text, 'hi @unknown, ask @unknown and @unknown');
    },
    skip: noCore,
    timeout: _slow,
  );

  // I2 of the review: a message the app's engine can't open is answered once its entry is taken, not after the whole
  // wait.
  test(
    "a_push_the_app_can't_open_is_answered_once_its_entry_is_taken",
    () async {
      final phone = await _phone(hears: (event) => event.type != 'DM_MESSAGE_CREATE');
      final answering = answerPushes(
        (ask) async => (
          texts: await phone.a.engine.pushTexts(ask.conversationId, ask.entry, ask.lines, ask.wait),
          onScreen: false,
        ),
      );
      addTearDown(() => stopAnsweringPushes(answering));
      await stoppedByHand(phone.b);
      addTearDown(phone.b.host.close);
      final sent = await sentByHand(phone.b, phone.conversation, 'nobody opens this', spoil: true);

      final started = DateTime.now();
      final opened = (await _open(phone, phone.fake.pushOf(phone.conversation, sent.id)))!;
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 3)));
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
    },
    skip: noCore,
    timeout: _slow,
  );
}
