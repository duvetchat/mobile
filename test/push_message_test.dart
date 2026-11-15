import 'package:duvet/data/models.dart';
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

  test('fromData reads a conversation\'s message', () {
    final push = Push.fromData(_data(space: null, room: null, conversation: _conversation)) as MessagePush;
    expect((push.chatId, push.target, push.place), (_conversation, const ConversationTarget(_conversation), ''));
    expect(push.link.toString(), 'https://duvet.chat/conversations/$_conversation/$_message');
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
}
