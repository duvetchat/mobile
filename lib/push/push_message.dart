/// What a push from the API says (duvetchat/api#301): FCM data, strings only.
library;

import 'dart:convert';

import '../data/links.dart';
import '../data/models.dart';

/// A push: a message that notifies the user, or the end of their session on this phone.
sealed class Push {
  const Push();

  /// The push [data] holds, or null for one the app doesn't know or can't read.
  static Push? fromData(Map<String, dynamic> data) => switch (data['type']) {
    'message' => MessagePush._fromData(data),
    'signed_out' => const SignedOutPush(),
    _ => null,
  };
}

/// A message that notifies the user: who wrote it, where, and its text as the API words it (names, not IDs; each
/// spoiler hidden).
final class MessagePush extends Push {
  final String messageId;
  final String authorId;
  final String authorName;

  /// The author's avatar as the API gives it: an attachment's ID, a URL, or empty.
  final String authorAvatar;

  /// "#room · Space", a group's name, or empty in a direct message.
  final String place;
  final String text;
  final ChatTarget target;
  final DateTime sentAt;

  const MessagePush({
    required this.messageId,
    required this.authorId,
    required this.authorName,
    required this.authorAvatar,
    required this.place,
    required this.text,
    required this.target,
    required this.sentAt,
  });

  // Its IDs are UUIDs, as the API's are: the chat's names a file (push_history.dart) and the link a path.
  static MessagePush? _fromData(Map<String, dynamic> data) {
    String? field(String key) => switch (data[key]) {
      final String value => value,
      _ => null,
    };
    final messageId = field('message_id');
    final authorId = field('author_id');
    final sentAt = int.tryParse(field('sent_at') ?? '');
    if (messageId == null || !isDuvetId(messageId) || authorId == null || sentAt == null) return null;
    final ChatTarget target;
    if (field('conversation_id') case final conversation? when isDuvetId(conversation)) {
      target = ConversationTarget(conversation);
    } else if ((field('space_id'), field('room_id')) case (
      final space?,
      final room?,
    ) when isDuvetId(space) && isDuvetId(room)) {
      target = RoomTarget(spaceId: space, roomId: room);
    } else {
      return null;
    }
    return MessagePush(
      messageId: messageId,
      authorId: authorId,
      authorName: field('author_name') ?? '',
      authorAvatar: field('author_avatar') ?? '',
      place: field('place') ?? '',
      text: field('text') ?? '',
      target: target,
      sentAt: DateTime.fromMillisecondsSinceEpoch(sentAt, isUtc: true),
    );
  }

  /// Its chat: the room's ID, or the conversation's.
  String get chatId => target.id;

  /// The message's link, which opens it in the app.
  Uri get link => Uri.parse(messageLink(target, messageId));

  /// Its data again, as the API sent it.
  Map<String, String> toData() => {
    'type': 'message',
    'message_id': messageId,
    'author_id': authorId,
    'author_name': authorName,
    'author_avatar': authorAvatar,
    'place': place,
    'text': text,
    'sent_at': '${sentAt.millisecondsSinceEpoch}',
    ...switch (target) {
      RoomTarget(:final spaceId, :final roomId) => {'space_id': spaceId, 'room_id': roomId},
      ConversationTarget(:final conversationId) => {'conversation_id': conversationId},
    },
  };
}

/// The user's session on this phone ended otherwise than by signing out: they sign in again to get notifications.
final class SignedOutPush extends Push {
  const SignedOutPush();
}

/// What a session's last push shows: one notification, whatever the chat, under an ID [notificationIdOf] never gives.
/// A tap opens the app, which asks to sign in.
const signedOutNotice = (id: -1, title: 'Duvet', body: 'Sign in again to get notifications');

/// A chat's notification ID: FNV-1a (32 bits) of its ID without the sign bit, the same in every isolate and run, so
/// a chat's messages update one notification.
int notificationIdOf(String chatId) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(chatId)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}
