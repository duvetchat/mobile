/// How Duvet writes mentions and custom emoji inside a message's text, as the
/// desktop app does: `<@userId>`, `<#roomId>` and `<:emojiId:>`.
library;

final _token = RegExp(r'<@([0-9a-fA-F-]{8,})>|<:([0-9a-fA-F-]{8,}):>|<#([0-9a-fA-F-]{8,})>');

sealed class MessageToken {
  const MessageToken();
}

final class TextToken extends MessageToken {
  final String text;
  const TextToken(this.text);
}

final class MentionToken extends MessageToken {
  final String userId;
  const MentionToken(this.userId);
}

final class RoomToken extends MessageToken {
  final String roomId;
  const RoomToken(this.roomId);
}

final class EmojiToken extends MessageToken {
  final String emojiId;
  const EmojiToken(this.emojiId);
}

/// Splits [content] into text, mentions, room mentions and custom emoji, in
/// order.
List<MessageToken> tokenize(String content) {
  final tokens = <MessageToken>[];
  var at = 0;
  for (final m in _token.allMatches(content)) {
    if (m.start > at) tokens.add(TextToken(content.substring(at, m.start)));
    tokens.add(switch (m.groups([1, 2, 3])) {
      [final user?, _, _] => MentionToken(user),
      [_, final emoji?, _] => EmojiToken(emoji),
      [_, _, final room] => RoomToken(room!),
      _ => throw StateError('unreachable'),
    });
    at = m.end;
  }
  if (at < content.length) tokens.add(TextToken(content.substring(at)));
  return tokens;
}

/// [content] as people read it: `@Maya`, `#general` and `:party:`, or, for
/// names not known here, the desktop's `@` and the user ID's first 8
/// characters, `#unknown` and `:emoji:`.
String readableContent(
  String content, {
  String? Function(String userId)? nameOf,
  String? Function(String emojiId)? emojiNameOf,
  String? Function(String roomId)? roomNameOf,
}) => content.replaceAllMapped(
  _token,
  (m) => switch (m.groups([1, 2, 3])) {
    [final user?, _, _] => '@${nameOf?.call(user) ?? user.substring(0, 8)}',
    [_, final emoji?, _] => ':${emojiNameOf?.call(emoji) ?? 'emoji'}:',
    [_, _, final room] => '#${roomNameOf?.call(room!) ?? 'unknown'}',
    _ => throw StateError('unreachable'),
  },
);

/// The user IDs [content] mentions.
Set<String> mentionedIn(String content) => {
  for (final t in tokenize(content))
    if (t is MentionToken) t.userId,
};
