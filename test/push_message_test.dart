import 'dart:convert';

import 'package:duvet/data/models.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/push/push_message.dart';
import 'package:flutter_test/flutter_test.dart';

const _space = '01920000-0000-7000-8000-000000000001';
const _room = '01920000-0000-7000-8000-000000000002';
const _conversation = '01920000-0000-7000-8000-000000000003';
const _message = '01920000-0000-7000-8000-000000000004';
const _maya = '01920000-0000-7000-8000-000000000005';

/// A push's data as the API sends it: strings only.
Map<String, dynamic> _data({String? space = _space, String? room = _room, String? conversation}) => {
  'type': 'message',
  'message_id': _message,
  'author_id': _maya,
  'author_name': 'Maya',
  'author_avatar': '',
  'place': conversation == null ? '#general · Design Guild' : '',
  'text': 'lunch?',
  'sent_at': '1794702917695',
  'space_id': ?space,
  'room_id': ?room,
  'conversation_id': ?conversation,
};

void main() {
  test('fromData reads a room\'s message, with its chat and its link', () {
    final push = Push.fromData(_data()) as MessagePush;
    expect(
      (push.messageId, push.authorName, push.place, push.text, push.chatId, push.target),
      (_message, 'Maya', '#general · Design Guild', 'lunch?', _room, const RoomTarget(spaceId: _space, roomId: _room)),
    );
    expect(push.sentAt, DateTime.fromMillisecondsSinceEpoch(1794702917695, isUtc: true));
    expect(push.link.toString(), 'https://duvet.chat/channels/$_space/$_room/$_message');
  });

  // An end-to-end encrypted API never pushes a conversation's message with its text: one that did would show words
  // the server wrote, under a member's name.
  test("fromData reads no conversation's message of the old type, which carries the server's text", () {
    expect(Push.fromData(_data(space: null, room: null, conversation: _conversation)), isNull);
  });

  // PLAN-E2E-API.md, its section on pushes; decision 29: who wrote it, where and when, its number, and its queue entry
  // when it fit.
  test("fromData reads a conversation's encrypted message: its number and its entry, and no text", () {
    final entry = {
      'seq': 7,
      'kind': 'message',
      'data': 'AAEC',
      'sent_at': 1794702917695,
      'generation': 0,
      'epoch': 2,
      'message_id': _message,
      'sender_user': _maya,
      'sender_device': _space,
    };
    final data = {
      'type': 'encrypted_message',
      'message_id': _message,
      'author_id': _maya,
      'author_name': 'Maya',
      'author_avatar': '',
      'place': 'Friday raid',
      'sent_at': '1794702917695',
      'conversation_id': _conversation,
      'seq': '7',
      'entry': jsonEncode(entry),
    };
    final push = Push.fromData(data)! as EncryptedMessagePush;
    expect(
      (push.messageId, push.conversationId, push.authorId, push.authorName, push.place, push.seq),
      (_message, _conversation, _maya, 'Maya', 'Friday raid', 7),
    );
    expect(push.entry, entry);
    expect(push.sentAt, DateTime.fromMillisecondsSinceEpoch(1794702917695, isUtc: true));
    // Without its entry (a message too long for it), or with one that isn't JSON: read from the queue.
    expect((Push.fromData({...data}..remove('entry'))! as EncryptedMessagePush).entry, isNull);
    expect((Push.fromData({...data, 'entry': '{not json'})! as EncryptedMessagePush).entry, isNull);
    // Without what says which message it is, or where: nothing.
    expect(Push.fromData({...data, 'conversation_id': '../x'}), isNull);
    expect(Push.fromData({...data}..remove('seq')), isNull);

    // What it shows: the device's text, the chat's earlier lines as the device holds them, or «New message».
    final shown = push.shown({_message: 'lunch?', _room: 'before'});
    expect(
      (shown.text, shown.authorName, shown.place, shown.target),
      ('lunch?', 'Maya', 'Friday raid', const ConversationTarget(_conversation)),
    );
    expect(shown.earlier, {_room: 'before'});
    expect(push.shown(const {}).text, 'New message');
  });

  // As the API's push worded a room's (push.Text): the device's text has the message's tokens, and its spoilers.
  test("a conversation's push words its text as the API words a room's, with no room's name and no spoiler", () {
    const ada = '0193a4b2-0000-7000-8000-0000000000ad';
    final text = 'hi <@$ada> and <@$_maya>, see <#$_room> :) <:$_space:>\n\n  ||the ending\nof it|| ok';
    expect(pushText(text, names: {ada: 'Ada'}), 'hi @Ada and @unknown, see #unknown :) :emoji: ▮▮▮ ok');
    expect(pushText('  ||all of it||  '), '▮▮▮');
    expect(pushText(' \n '), isNull);
    expect(pushText('x' * 2500)!.runes.length, 2000);
    final push =
        Push.fromData({
              'type': 'encrypted_message',
              'message_id': _message,
              'author_id': _maya,
              'author_name': 'Maya',
              'sent_at': '1794702917695',
              'conversation_id': _conversation,
              'seq': '7',
            })!
            as EncryptedMessagePush;
    final shown = push.shown({_message: 'for <@$ada>', _room: ' '}, names: {ada: 'Ada'});
    expect(shown.text, 'for @Ada');
    expect(shown.earlier, isEmpty);
    expect(push.shown({_message: '||   ||'}).text, '▮▮▮');
  });

  test('fromData reads a session\'s last push, and nothing of a type or a message it can\'t read', () {
    expect(Push.fromData({'type': 'signed_out'}), isA<SignedOutPush>());
    expect(Push.fromData({'type': 'call'}), isNull);
    expect(Push.fromData({'message_id': _message}), isNull);
    expect(Push.fromData(_data(room: null)), isNull, reason: 'a room\'s message without its room');
    expect(Push.fromData({..._data(), 'sent_at': 'soon'}), isNull);
  });

  test('a message push goes back to its data whole', () {
    final push = Push.fromData(_data()) as MessagePush;
    expect(Push.fromData(push.toData()), isA<MessagePush>().having((p) => p.toData(), 'data', push.toData()));
  });

  test('the last push of a session shows the notice to sign in again, under an ID no chat can have', () {
    expect((signedOutNotice.title, signedOutNotice.body), ('Duvet', 'Sign in again to get notifications'));
    expect(signedOutNotice.id, isNegative, reason: 'notificationIdOf is never negative');
  });

  test('notificationIdOf is the same for a chat every time, never negative, and differs between chats', () {
    expect(notificationIdOf(_room), notificationIdOf(_room));
    expect(notificationIdOf(_room), isNonNegative);
    expect(notificationIdOf(_room), isNot(notificationIdOf(_conversation)));
    // FNV-1a's own check value, masked to 31 bits: the same in every isolate and every run.
    expect(notificationIdOf('a'), 0xe40c292c & 0x7fffffff);
  });

  test('fromData reads a call that rings, and its end', () {
    final call =
        Push.fromData({
              'type': 'call',
              'conversation_id': _conversation,
              'initiator_id': _maya,
              'initiator_name': 'Maya',
              'initiator_avatar': 'avatar-id',
              'place': 'Friday raid',
              'started_at': '1794702917695',
              'ring_until': '1794702947695',
            })
            as CallPush;
    expect(
      (call.conversationId, call.initiatorId, call.initiatorName, call.initiatorAvatar, call.place),
      (_conversation, _maya, 'Maya', 'avatar-id', 'Friday raid'),
    );
    expect(call.startedAt, DateTime.fromMillisecondsSinceEpoch(1794702917695, isUtc: true));
    expect(call.ringUntil, DateTime.fromMillisecondsSinceEpoch(1794702947695, isUtc: true));

    final end =
        Push.fromData({'type': 'call_end', 'conversation_id': _conversation, 'started_at': '1794702917695'})
            as CallEndPush;
    expect((end.conversationId, end.startedAt), (_conversation, 1794702917695));
    // Without its start, an end is of whatever call of the conversation shows.
    final anyCall = Push.fromData({'type': 'call_end', 'conversation_id': _conversation}) as CallEndPush;
    expect(anyCall.startedAt, 0);
  });

  test('fromData reads no call without a conversation it can trust or the times of its ring', () {
    final call = {
      'type': 'call',
      'conversation_id': _conversation,
      'initiator_id': _maya,
      'started_at': '1794702917695',
      'ring_until': '1794702947695',
    };
    expect(Push.fromData({...call, 'conversation_id': '../x'}), isNull);
    expect(Push.fromData({...call}..remove('ring_until')), isNull);
    expect(Push.fromData({...call, 'started_at': 'soon'}), isNull);
    expect(Push.fromData({'type': 'call_end', 'conversation_id': 'x'}), isNull);
  });

  // Step 5's fuzzing: a time a date can't hold (past 8.64e15 ms either way, where DateTime throws a RangeError) is the
  // server's word too, and its throw cost the notification in the push's engine.
  test('fromData reads a time no date holds as no time, never a throw', () {
    const never = '99999999999999999';
    expect(Push.fromData({..._data(), 'sent_at': never}), isNull);
    expect(Push.fromData({..._data(), 'sent_at': '-$never'}), isNull);
    // The least an integer holds, whose absolute value is itself in Dart's.
    expect(Push.fromData({..._data(), 'sent_at': '-9223372036854775808'}), isNull);
    expect(MessagePush.kept({..._data(), 'sent_at': never}), isNull);
    final encrypted = {
      'type': 'encrypted_message',
      'message_id': _message,
      'author_id': _maya,
      'conversation_id': _conversation,
      'seq': '7',
    };
    expect(Push.fromData({...encrypted, 'sent_at': never}), isNull);
    final call = {'type': 'call', 'conversation_id': _conversation, 'initiator_id': _maya};
    expect(Push.fromData({...call, 'started_at': never, 'ring_until': '1794702947695'}), isNull);
    expect(Push.fromData({...call, 'started_at': '1794702917695', 'ring_until': never}), isNull);
    // The last time a date holds still reads.
    expect(Push.fromData({..._data(), 'sent_at': '8640000000000000'}), isA<MessagePush>());
  });

  test("a call's notification has an ID of its own, apart from its conversation's messages", () {
    expect(callNotificationIdOf(_conversation), isNot(notificationIdOf(_conversation)));
    expect(callNotificationIdOf(_conversation), callNotificationIdOf(_conversation));
    expect(callNotificationIdOf(_conversation), greaterThanOrEqualTo(0));
  });

  // M8 of the task 21 review: a conversation's message the app couldn't tell in front, gone to the back while its
  // notice waited, shows as its push would: the device's text worded as a push words it, never the API's message.
  test("a conversation's message the app couldn't tell in front shows as its push would", () {
    final message = ChatMessage(
      id: _message,
      authorId: _maya,
      authorName: 'Maya',
      authorAvatarUrl: 'https://cdn.example/maya.png',
      content: 'written by the server',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1794702917695, isUtc: true),
    );
    final target = ConversationTarget(_conversation);
    final away = MessagePush.away((target: target, message: message, place: 'Crew', text: 'see ||this||   now'));
    expect(
      (away.messageId, away.authorId, away.authorName, away.authorAvatar, away.place, away.text, away.target),
      (_message, _maya, 'Maya', 'https://cdn.example/maya.png', 'Crew', 'see ▮▮▮ now', target),
    );
    expect(away.sentAt, message.createdAt);
    expect(MessagePush.away((target: target, message: message, place: '', text: null)).text, Notice.newMessage.text);
  });
}
