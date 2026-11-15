import 'dart:io';

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
}
