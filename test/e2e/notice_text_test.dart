import 'dart:async';
import 'dart:typed_data';

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

/// A core whose applies wait while it's held: an engine slow to open what came. Its reads of messages fail [failReads]
/// times, then wait while [holdReads] holds them.
class _SlowApplies implements CoreHost {
  _SlowApplies(this._core);
  final CoreHost _core;
  Completer<void>? _held;
  Completer<void>? _reads;
  var failReads = 0;

  void hold() => _held ??= Completer();
  void release() {
    _held?.complete();
    _held = null;
  }

  // The reads let through before [holdReads] holds the next ones, and how many it holds.
  var _passing = 0;
  var readsHeld = 0;

  void holdReads({int after = 0}) {
    _reads ??= Completer();
    _passing = after;
  }

  void releaseReads() {
    _reads?.complete();
    _reads = null;
  }

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    if (command['cmd'] == 'messages') {
      if (failReads > 0) {
        failReads--;
        throw CoreError('internal', message: 'the core is busy');
      }
      if (_reads case final held?) {
        if (_passing > 0) {
          _passing--;
        } else {
          readsHeld++;
          await held.future;
        }
      }
    }
    if (command['cmd'] == 'apply') await _held?.future;
    return _core.handle<T>(command);
  }

  @override
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int done)? progress}) =>
      _core.sealFile(key, attachmentId, plain, progress: progress);

  @override
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int done)? progress}) =>
      _core.openFile(key, attachmentId, sealed, progress: progress);

  @override
  Future<Map<String, Object?>> share(Map<String, Object?> command) => _core.share(command);

  @override
  Future<Uint8List> sharePart(String shareId, int n) => _core.sharePart(shareId, n);

  @override
  Future<void> dropShare(String shareId) => _core.dropShare(shareId);

  @override
  Future<Map<String, Object?>> importShare(String shareId, List<Uint8List> parts) => _core.importShare(shareId, parts);

  @override
  Future<Opened> open(String userId) => _core.open(userId);

  @override
  Future<void> close() => _core.close();

  @override
  Future<void> destroy(String userId) => _core.destroy(userId);
}

typedef _Chat = ({FakeApi fake, TestApp app, String bo, TestDevice b, String conversation, ConversationTarget target});

/// Ana's app, ready, and Bo's device in their DM, whose group her app made as she opened it, then left: the notices of
/// its messages show. Every notice that showed, the newest last, in [shown]; what the app hands the phone's
/// notifications, to [notifyAway].
Future<_Chat> _chat(
  List<MentionNotice> shown, {
  _SlowApplies Function(CoreGate core)? host,
  void Function(AwayNotice notice)? notifyAway,
}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final app = await appOn(fake, ana, host: host, notifyAway: notifyAway);
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

/// Ana's device, its core behind the [host] made of it, and Bo's, in a DM whose group both hold: what an app's engine
/// does with a notice's wait.
Future<({TestDevice a, TestDevice b, String bo, String conversation})> _devices(
  _SlowApplies Function(CoreGate core) host,
) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final a = await firstDevice(fake, ana, host: host(TestHost().gate));
  final b = await firstDevice(fake, bo);
  addTearDown(b.engine.stop);
  addTearDown(a.engine.stop);
  await a.engine.openConversation(conversation);
  await sameGroup([a, b], conversation);
  return (a: a, b: b, bo: bo, conversation: conversation);
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
  // its own writing, under a member's name. The notice says who wrote it, and nothing of what the API sent; a row with
  // no number, which no honest API sends, shows no notice at all (I1 of step 4's closing review).
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
      await until(() => shown.any((n) => n.messageId == ids[2]), timeout: const Duration(seconds: 10));
      expect([for (final n in shown) (n.messageId, n.authorName, n.text)], [(ids[2], 'bo', 'Sent a message')]);
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

  // I2 of the review: a message without text, a sticker's, gets its notice as soon as the device holds it, not after
  // the whole wait.
  test(
    "a_sticker's_notice_shows_as_soon_as_the_device_holds_its_message",
    () async {
      final shown = <MentionNotice>[];
      final (fake: _, app: _, bo: _, :b, :conversation, target: _) = await _chat(shown);
      final sentAt = DateTime.now();
      final sticker = (await b.engine.sendMessage(
        Outgoing(conversationId: conversation, nonce: uuidv4(), stickerAttachmentId: uuidv7()),
      ))!.id;
      await until(() => shown.any((n) => n.messageId == sticker), timeout: const Duration(seconds: 10));
      expect(DateTime.now().difference(sentAt), lessThan(const Duration(milliseconds: 1500)));
      expect(
        [
          for (final n in shown)
            if (n.messageId == sticker) n.text,
        ],
        ['Sent a message'],
      );
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of the review: a read that fails is nothing yet, and the wait reads again as the message is applied.
  test(
    'a_failed_read_has_the_wait_read_again',
    () async {
      late _SlowApplies slow;
      final (:a, :b, :bo, :conversation) = await _devices((core) => slow = _SlowApplies(core));
      addTearDown(() => slow.release());
      slow.hold();
      final id = await _says(b, conversation, 'read the second time');
      slow.failReads = 1;
      final text = a.engine.textOf(conversation, id, bo, const Duration(seconds: 10));
      await until(() => slow.failReads == 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      slow.release();
      expect(await text, 'read the second time');
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of the review: a read that doesn't answer ends with the wait.
  test(
    'a_read_that_does_not_answer_ends_with_the_wait',
    () async {
      late _SlowApplies slow;
      final (:a, :b, :bo, :conversation) = await _devices((core) => slow = _SlowApplies(core));
      addTearDown(() => slow.releaseReads());
      final id = await _says(b, conversation, 'read too late');
      await until(() async => (await a.engine.messages(conversation, [id])).isNotEmpty);
      slow.holdReads();
      final text = a.engine.textOf(conversation, id, bo, const Duration(seconds: 1));
      await pumpEventQueue();
      a.clock.advance(const Duration(seconds: 1));
      expect(await text.timeout(const Duration(seconds: 5), onTimeout: () => 'never answered'), isNull);
    },
    skip: noCore,
    timeout: _slow,
  );

  // M8 of the review: a notice decided away as the app went to the back during its wait shows as the phone's
  // notification, with the device's text: its push came while the app was in front, which left it alone.
  test(
    "a_notice_the_app_went_to_the_back_during_shows_as_the_phone's_notification",
    () async {
      final shown = <MentionNotice>[];
      final away = <AwayNotice>[];
      late _SlowApplies slow;
      final (fake: _, :app, :bo, :b, :conversation, :target) = await _chat(
        shown,
        host: (core) => slow = _SlowApplies(core),
        notifyAway: away.add,
      );
      addTearDown(() => slow.release());
      slow.hold();
      final id = await _says(b, conversation, 'told while away');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      app.repository.wentToBack();
      slow.release();
      await until(() => away.isNotEmpty, timeout: const Duration(seconds: 10));
      expect(
        [for (final n in away) (n.message.id, n.message.authorId, n.target, n.place, n.text)],
        [(id, bo, target, '', 'told while away')],
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(shown.where((n) => n.messageId == id), isEmpty);
      expect(away, hasLength(1));
    },
    skip: noCore,
    timeout: _slow,
  );

  // M5 of the review: the app's answer to a push comes within its wait, whatever its reads: past it, the first line's
  // text alone.
  test(
    "the_app's_answer_to_a_push_comes_within_its_wait",
    () async {
      late _SlowApplies slow;
      final (:a, :b, :bo, :conversation) = await _devices((core) => slow = _SlowApplies(core));
      addTearDown(() => slow.releaseReads());
      final earlier = await _says(b, conversation, 'an earlier line');
      final pushed = await _says(b, conversation, 'the pushed line');
      await until(() async => (await a.engine.messages(conversation, [earlier, pushed])).length == 2);
      // Its first read answers; the next, of the chat's lines, doesn't.
      slow.holdReads(after: 1);
      final texts = a.engine.pushTexts(conversation, null, [
        (id: pushed, author: bo),
        (id: earlier, author: bo),
      ], const Duration(seconds: 1));
      await until(() => slow.readsHeld > 0);
      a.clock.advance(const Duration(seconds: 1));
      expect(await texts.timeout(const Duration(seconds: 5), onTimeout: () => {'never': 'answered'}), {
        pushed: 'the pushed line',
      });
    },
    skip: noCore,
    timeout: _slow,
  );
}
