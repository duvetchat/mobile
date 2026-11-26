import 'dart:async';

import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/content.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_repository.dart';
import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// The app's own notices of a conversation's messages take their text from the device (PLAN-E2E-CLIENTES.md, Task 21,
// as the desktop's Task 20 and the rules its review gave): a notice waits, 2 s at most, for the engine to apply its
// message, then says what this device's database holds of it from the author the API names; without it in time, who
// wrote and that a message came, and nothing of the API's message. It's decided again after its wait, and a message
// notifies once.
const _slow = Timeout(Duration(minutes: 3));

/// A core whose applies wait while it's held: an engine slow to open what came.
class _SlowApplies implements CoreHost {
  _SlowApplies(this._core);
  final CoreHost _core;
  Completer<void>? _held;

  void hold() => _held ??= Completer();
  void release() {
    _held?.complete();
    _held = null;
  }

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    if (command['cmd'] == 'apply') await _held?.future;
    return _core.handle<T>(command);
  }

  @override
  Future<Opened> open(String userId) => _core.open(userId);

  @override
  Future<void> close() => _core.close();

  @override
  Future<void> destroy(String userId) => _core.destroy(userId);
}

typedef _Chat = ({FakeApi fake, TestApp app, String bo, TestDevice b, String conversation, ConversationTarget target});

/// Ana's app, ready, and Bo's device in their DM, whose group her app made as she opened it, then left: the notices of
/// its messages show. Every notice that showed, the newest last, in [shown].
Future<_Chat> _chat(List<MentionNotice> shown, {_SlowApplies Function(CoreGate core)? host}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final app = await appOn(fake, ana, host: host);
  await app.ready();
  final b = await firstDevice(fake, bo);
  addTearDown(b.engine.stop);
  final target = ConversationTarget(conversation);
  app.repository.chatShown(target);
  await until(() async => await groupOf(b, conversation) != null);
  await until(
    () => app.core
        .handle<Object?>({'cmd': 'group', 'conversation_id': conversation})
        .then((_) => true, onError: (_) => false),
  );
  app.repository.chatHidden(target);
  final notices = app.repository.mentionNotices;
  void heard() {
    for (final notice in notices.value) {
      if (!shown.any((n) => n.messageId == notice.messageId)) shown.add(notice);
    }
  }

  notices.addListener(heard);
  addTearDown(() => notices.removeListener(heard));
  return (fake: fake, app: app, bo: bo, b: b, conversation: conversation, target: target);
}

Future<String> _says(TestDevice device, String conversation, String text) async =>
    (await device.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: text)))!.id;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    "a_notice_shows_the_decrypted_text,_or_says_a_message_came_when_it_can't_be_read_in_time",
    () async {
      final shown = <MentionNotice>[];
      late _SlowApplies slow;
      final (fake: _, :app, bo: _, :b, :conversation, :target) = await _chat(
        shown,
        host: (core) => slow = _SlowApplies(core),
      );
      List<String> texts(String id) => [
        for (final n in shown)
          if (n.messageId == id) n.text,
      ];

      // Opened in time: the device's text.
      final said = await _says(b, conversation, 'hello there');
      await until(() => texts(said).isNotEmpty);
      expect(texts(said), ['hello there']);

      // Not opened within its 2 s: who wrote, and that a message came, no sooner.
      slow.hold();
      final sentAt = DateTime.now();
      final slowOne = await _says(b, conversation, 'too slow');
      await until(() => texts(slowOne).isNotEmpty, timeout: const Duration(seconds: 10));
      final waited = DateTime.now().difference(sentAt);
      expect(
        waited,
        allOf(greaterThanOrEqualTo(const Duration(milliseconds: 1990)), lessThan(const Duration(seconds: 4))),
      );
      expect(texts(slowOne), ['Sent a message']);

      // Decided again after its wait: its chat came on screen meanwhile, and nothing shows.
      final seen = await _says(b, conversation, 'seen meanwhile');
      app.repository.chatShown(target);
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      app.repository.chatHidden(target);
      expect(texts(seen), isEmpty);

      // The late texts come: neither notifies, then or again.
      slow.release();
      await until(() async {
        final rows = await shownMessages(app.core, conversation, [slowOne, seen]);
        return rows.where((row) => row.status == MessageStatus.ok).length == 2;
      });
      final later = await _says(b, conversation, 'now in time');
      await until(() => texts(later).isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(texts(slowOne), ['Sent a message']);
      expect(texts(seen), isEmpty);
      expect(texts(later), ['now in time']);
    },
    skip: noCore,
    timeout: _slow,
  );

  // The desktop's review, I1: a server may send a conversation's message with text, files, a sticker or components of
  // its own writing, under a member's name. The notice says who wrote it, and nothing of what the API sent.
  test(
    "a_notice_shows_nothing_of_the_api's_message_but_who_wrote_it,_whatever_its_fields",
    () async {
      final shown = <MentionNotice>[];
      final (fake: _, :app, :bo, b: _, :conversation, target: _) = await _chat(shown);
      final at = DateTime.now().toUtc().toIso8601String();
      Map<String, Object?> forged(String id, Map<String, Object?> fields) => {
        'id': id,
        'conversation_id': conversation,
        'author_id': bo,
        'type': 0,
        'created_at': at,
        'updated_at': at,
        'user': {'id': bo, 'username': 'bo', 'created_at': at, 'updated_at': at},
        ...fields,
      };
      final ids = [uuidv7(), uuidv7(), uuidv7()];
      for (final (id, fields) in [
        (ids[0], {'content': 'written by the server'}),
        (
          ids[1],
          {
            'content': 'a file of the server',
            'attachments': [
              {
                'id': uuidv7(),
                'filename': 'cat.png',
                'content_type': 'image/png',
                'url': 'https://fake-api.test/attachments/x',
                'size_bytes': 10,
                'created_at': at,
              },
            ],
            'sticker_attachment_id': uuidv7(),
          },
        ),
        // With a number, as an encrypted message: no device holds it, and its notice waits its 2 s.
        (ids[2], {'content': 'numbered by the server', 'seq': 999, 'ciphertext': 'AAAA', 'generation': 0, 'epoch': 1}),
      ]) {
        if (payloadOf((type: 'DM_MESSAGE_CREATE', data: forged(id, fields)), app.repository.profile.value!.id)
            case final payload?) {
          app.repository.handleEvent(payload);
        }
      }
      await until(() => ids.every((id) => shown.any((n) => n.messageId == id)), timeout: const Duration(seconds: 10));
      expect([for (final n in shown) (n.authorName, n.text)], List.filled(3, ('bo', 'Sent a message')));
    },
    skip: noCore,
    timeout: _slow,
  );

  // A push's notification is decided again after its wait too (rule 11): the app's engine, answering it, says whether
  // its chat is on screen now, where it shows itself.
  test(
    'a_push_the_app_answers_says_whether_its_chat_is_on_screen',
    () async {
      final shown = <MentionNotice>[];
      final (fake: _, :app, :bo, :b, :conversation, :target) = await _chat(shown);
      final said = await _says(b, conversation, 'answered by the app');
      final line = [(id: said, author: bo)];
      Future<({Map<String, String> texts, bool onScreen})?> answer() =>
          app.repository.pushTexts(conversation, null, line, const Duration(seconds: 5));
      expect((await answer())?.texts, {said: 'answered by the app'});
      expect((await answer())?.onScreen, isFalse);
      app.repository.chatShown(target);
      expect((await answer())?.onScreen, isTrue);
      // A thread of it shows only its replies.
      app.repository.chatShown(target, threadOf: said);
      expect((await answer())?.onScreen, isFalse);
      app.repository.chatHidden(target, threadOf: said);
      // Its chat open behind, the app out of sight.
      app.repository.chatShown(target);
      app.repository.wentToBack();
      expect((await answer())?.onScreen, isFalse);
    },
    skip: noCore,
    timeout: _slow,
  );
}
