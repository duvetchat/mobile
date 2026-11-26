import 'dart:async';
import 'dart:ui' show IsolateNameServer;

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

// The push of a conversation's message, opened on the phone (PLAN-E2E-CLIENTES.md, Task 21 and Review Focus 8;
// decision 29; Ruling 18): the API pushes it without its text, with its queue entry when it fits, and the push's engine
// shows the text Ana's core opens. The app's engine answers when it holds the core; otherwise the push's engine opens it,
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

/// The push [data] holds, opened as the push's engine opens it, with the stored session of Ana's app: what its
/// notification shows, none when the app says its chat is on screen.
Future<MessagePush?> _open(
  _Phone phone,
  Map<String, String> data, {
  List<MessagePush> earlier = const [],
  http.Client? client,
  CoreHost Function()? core,
  Duration within = pushTime,
}) => openedPush(
  Push.fromData(data)! as EncryptedMessagePush,
  earlier: earlier,
  session: (token: phone.a.token, sessionToken: 'session', refreshedAt: null, userId: phone.ana),
  core: core ?? () => _pushGate(phone),
  router: fakeRouter,
  duvetClient: engineClient,
  client: client ?? watchedClient(phone.fake, seen: phone.requests.add),
  store: (_) async => phone.a.store,
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
        core: () {
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
}
