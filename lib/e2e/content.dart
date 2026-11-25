/// What this device's own database holds of a conversation's messages (PLAN-E2E-CLIENTES.md, «La vista de una
/// conversación»): the core's rows by the API's IDs, its own messages still being sent, and which of the API's rows a
/// chat draws. The API lists a conversation's messages; their text and files come from here. The desktop's content.ts
/// in Dart.
library;

import 'package:flutter/foundation.dart';

import 'host.dart';

/// Whether a message can be shown: opened (`ok`), its copy not opened yet (`waiting`), or this device's own still
/// being sent (`pending`).
enum MessageStatus { ok, waiting, pending }

/// A message as the core shows it (its `messages`): times in Unix milliseconds; one without text (a sticker, a file
/// alone) has none. Its files are as the core gives them, which the attachments' task reads.
@immutable
class ShownMessage {
  ShownMessage.of(Map<String, Object?> row)
    : conversationId = row['conversation_id']! as String,
      messageId = row['message_id'] as String?,
      nonce = row['nonce'] as String?,
      seq = row['seq'] as int?,
      userId = row['user_id']! as String,
      deviceId = row['device_id']! as String,
      sentAt = row['sent_at']! as int,
      editedAt = row['edited_at'] as int?,
      status = MessageStatus.values.byName(row['status']! as String),
      text = row['text'] as String?,
      attachments = [for (final file in row['attachments'] as List? ?? const []) (file as Map).cast<String, Object?>()],
      sharedBy = row['shared_by'] as String?,
      replyTo = row['reply_to'] as String?;

  final String conversationId;

  /// The API's ID, none while this device's own is being sent.
  final String? messageId;

  /// This device's own message's nonce.
  final String? nonce;
  final int? seq;
  final String userId;
  final String deviceId;
  final int sentAt;
  final int? editedAt;
  final MessageStatus status;
  final String? text;
  final List<Map<String, Object?>> attachments;

  /// Who shared it with this device, when a shared history brought it.
  final String? sharedBy;

  /// The message it answers.
  final String? replyTo;

  // Never its text: a message may end up in a log.
  @override
  String toString() => 'ShownMessage($messageId, ${status.name})';
}

/// The most IDs one `messages` takes.
const _idsMost = 200;

/// The core's rows of these messages of the conversation: none for one it doesn't hold, or one deleted.
Future<List<ShownMessage>> shownMessages(CoreHost host, String conversationId, List<String> ids) async => [
  for (var at = 0; at < ids.length; at += _idsMost)
    for (final row
        in (await host.handle<Map<String, Object?>>({
              'cmd': 'messages',
              'conversation_id': conversationId,
              'ids': ids.sublist(at, at + _idsMost < ids.length ? at + _idsMost : ids.length),
            }))['messages']!
            as List)
      ShownMessage.of((row as Map).cast<String, Object?>()),
];

/// This device's own messages of the conversation still being sent, in the order they were made.
Future<List<ShownMessage>> pendingRows(CoreHost host, String conversationId) async {
  // A page lists them first, the newest first.
  final page = await host.handle<Map<String, Object?>>({
    'cmd': 'messages',
    'conversation_id': conversationId,
    'limit': 100,
  });
  return [
    for (final row in page['messages']! as List)
      if (ShownMessage.of((row as Map).cast<String, Object?>()) case final shown
          when shown.status == MessageStatus.pending)
        shown,
  ].reversed.toList();
}

/// This device's own message of the conversation it sent under [nonce], once the API has it: null when none of its
/// newest has it.
Future<ShownMessage?> sentUnder(CoreHost host, String conversationId, String nonce) async {
  final page = await host.handle<Map<String, Object?>>({
    'cmd': 'messages',
    'conversation_id': conversationId,
    'limit': 100,
  });
  for (final row in page['messages']! as List) {
    final shown = ShownMessage.of((row as Map).cast<String, Object?>());
    if (shown.nonce == nonce && shown.messageId != null) return shown;
  }
  return null;
}

/// Whether this device's database holds any message of the conversation numbered before [seq].
Future<bool> heldBefore(CoreHost host, String conversationId, int seq) async =>
    ((await host.handle<Map<String, Object?>>({
              'cmd': 'messages',
              'conversation_id': conversationId,
              'before': seq,
              'limit': 1,
            }))['messages']!
            as List)
        .isNotEmpty;

/// The rows a conversation draws (Ruling 15): an encrypted row from before the user joined it (its ID below their
/// membership's, [joinedAs]) that this device doesn't hold goes, and the one notice above the chat says why
/// (`Notice.beforeJoining`). A notice of the server's, a row since, and one the device holds (shared with it) stay.
/// Without the membership, all stay.
({List<T> rows, bool beforeJoining}) drawnRows<T>(
  List<T> rows,
  String? joinedAs, {
  required String Function(T row) idOf,
  required bool Function(T row) encrypted,
  required bool Function(String id) held,
}) {
  if (joinedAs == null) return (rows: rows, beforeJoining: false);
  final drawn = [
    for (final row in rows)
      if (!encrypted(row) || idOf(row).compareTo(joinedAs) > 0 || held(idOf(row))) row,
  ];
  return drawn.length == rows.length ? (rows: rows, beforeJoining: false) : (rows: drawn, beforeJoining: true);
}
