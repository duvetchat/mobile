import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/content.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/e2e/push_decrypt.dart';
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

/// What Ana's core holds of the message, read by a gate of the app's once the push's let go: null for none.
Future<String?> _onAna(_Phone phone, String id) async {
  final gate = CoreGate(
    serves: true,
    keys: phone.host.keys,
    folder: () async => phone.host.folder,
    lockedWait: _locked,
  );
  expect((await gate.open(phone.ana)).state, HostState.ready, reason: 'the push left the core closed');
  try {
    final rows = await shownMessages(gate, phone.conversation, [id]);
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

/// Ana's app in an isolate of its own, as the push sees it: it answers on the push's port, and ends a moment after it
/// takes a request.
void _takesThenEnds(SendPort ready) {
  answerPushes((ask) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    Isolate.exit();
  });
  ready.send(null);
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
      var made = 0;

      final started = DateTime.now();
      final opened = (await _open(
        phone,
        phone.fake.pushOf(phone.conversation, sent.id),
        within: const Duration(seconds: 2),
        core: _counted(phone, (_) => made++),
      ))!;
      expect((opened.text, opened.authorName), (Notice.newMessage.text, 'Bo'));
      expect(DateTime.now().difference(started), lessThan(const Duration(milliseconds: 2600)));
      // Nothing after its time: no core made, nothing asked.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(made, 0);
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
      await until(() => again.engine.conversationState(conversation) == ConversationState.membersChanged);
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
