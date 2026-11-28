import 'dart:io';

import 'package:duvet/data/models.dart';
import 'package:duvet/push/push_history.dart';
import 'package:duvet/push/push_message.dart';
import 'package:flutter_test/flutter_test.dart';

String _id(int n) => '01920000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Message [n] of Maya's in room [room] of Space 1.
MessagePush _push(int n, {int room = 100}) =>
    Push.fromData({
          'type': 'message',
          'message_id': _id(n),
          'author_id': _id(900),
          'author_name': 'Maya',
          'author_avatar': '',
          'place': '#general · Design Guild',
          'text': 'number $n',
          'sent_at': '${1794702917695 + n}',
          'space_id': _id(1),
          'room_id': _id(room),
        })
        as MessagePush;

/// Message [n] of Bo's in conversation [conversation], with [text] as this device's core opened it.
MessagePush _said(int n, {int conversation = 300, String text = 'a secret'}) => MessagePush(
  messageId: _id(n),
  authorId: _id(901),
  authorName: 'Bo',
  authorAvatar: '',
  place: '',
  text: text,
  target: ConversationTarget(_id(conversation)),
  sentAt: DateTime.fromMillisecondsSinceEpoch(1794702917695 + n, isUtc: true),
);

List<String> _texts(List<MessagePush> pushes) => [for (final p in pushes) p.text];

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('push-history'));
  tearDown(() => dir.delete(recursive: true));

  test('a chat keeps its last six messages, oldest first, on disk', () async {
    final history = PushHistory(dir);
    var kept = <MessagePush>[];
    for (var n = 1; n <= 8; n++) {
      kept = await history.add(_push(n));
    }
    expect(_texts(kept), ['number 3', 'number 4', 'number 5', 'number 6', 'number 7', 'number 8']);
    // Another isolate's history reads the same.
    expect(_texts(await PushHistory(dir).add(_push(9))), [
      'number 4',
      'number 5',
      'number 6',
      'number 7',
      'number 8',
      'number 9',
    ]);
  });

  test('a message pushed twice is kept once', () async {
    final history = PushHistory(dir);
    await history.add(_push(1));
    expect(_texts(await history.add(_push(1))), ['number 1']);
  });

  test('each chat keeps its own, and forgetting one leaves the others', () async {
    final history = PushHistory(dir);
    await history.add(_push(1));
    await history.add(_push(2, room: 200));
    await history.forget(_id(100));
    expect(_texts(await history.add(_push(3))), ['number 3']);
    expect(_texts(await history.add(_push(4, room: 200))), ['number 2', 'number 4']);
    // A chat that has none forgets nothing, and fails nothing.
    await history.forget(_id(300));
  });

  test('forgetAll forgets every chat, as the session ends', () async {
    final history = PushHistory(dir);
    await history.add(_push(1));
    await history.add(_push(2, room: 200));
    await history.forgetAll();
    expect(_texts(await history.add(_push(3))), ['number 3']);
    expect(_texts(await history.add(_push(4, room: 200))), ['number 4']);
    // Nothing kept, nothing to fail on.
    await PushHistory(Directory('${dir.path}/none')).forgetAll();
  });

  test('a history it can\'t read starts over', () async {
    final history = PushHistory(dir);
    await history.add(_push(1));
    final file = File('${dir.path}/push/${_id(100)}.json');
    await file.writeAsString('not json');
    expect(_texts(await history.add(_push(2))), ['number 2']);
  });

  // PLAN-E2E-CLIENTES.md, Task 21: a conversation's lines are the device's to read; the history keeps who and when.
  test('the_notification_history_keeps_no_conversation_text', () async {
    final history = PushHistory(dir);
    final kept = await history.addAll([_said(1, text: 'the bluebird flies at noon'), _said(2, text: 'at dawn')]);
    expect([for (final p in kept) (p.messageId, p.authorName, p.text)], [(_id(1), 'Bo', ''), (_id(2), 'Bo', '')]);
    expect(_texts(await history.read(_id(300))), ['', '']);
    final file = File('${dir.path}/push/${_id(300)}.json').readAsStringSync();
    expect(file, allOf(isNot(contains('bluebird')), isNot(contains('dawn')), contains(_id(1))));
    // A room's lines keep their text, as the API wrote it.
    expect(_texts(await history.add(_push(3))), ['number 3']);
  });

  test("the version before's histories of conversations, with their text, are deleted at the first start", () async {
    final history = PushHistory(dir);
    await history.add(_push(1));
    // As a version before this one wrote a conversation's: its text in the clear.
    final old = File('${dir.path}/push/${_id(300)}.json')..createSync(recursive: true);
    old.writeAsStringSync(
      '[{"type":"message","message_id":"${_id(2)}","author_id":"${_id(901)}","author_name":"Bo","author_avatar":"",'
      '"place":"","text":"the bluebird flies at noon","sent_at":"1794702917697","conversation_id":"${_id(300)}"}]',
    );
    await history.forgetConversationTexts();
    expect(old.existsSync(), isFalse);
    expect(_texts(await history.read(_id(100))), ['number 1']);
    // This version's are kept: they hold no text.
    await history.add(_said(4));
    await history.forgetConversationTexts();
    expect([for (final p in await history.read(_id(300))) p.messageId], [_id(4)]);
  });
}
