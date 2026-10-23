/// How Duvet writes mentions and custom emoji inside a message's text, as the
/// desktop app does: `<@userId>` and `<:emojiId:>`.
library;

final _token = RegExp(r'<@([0-9a-fA-F-]{8,})>|<:([0-9a-fA-F-]{8,}):>');

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

final class EmojiToken extends MessageToken {
  final String emojiId;
  const EmojiToken(this.emojiId);
}

/// Splits [content] into text, mentions and custom emoji, in order.
List<MessageToken> tokenize(String content) {
  final tokens = <MessageToken>[];
  var at = 0;
  for (final m in _token.allMatches(content)) {
    if (m.start > at) tokens.add(TextToken(content.substring(at, m.start)));
    tokens.add(m.group(1) != null ? MentionToken(m.group(1)!) : EmojiToken(m.group(2)!));
    at = m.end;
  }
  if (at < content.length) tokens.add(TextToken(content.substring(at)));
  return tokens;
}

/// [content] as people read it: `@Maya` and `:party:`, or `@someone` and
/// `:emoji:` for names not known here.
String readableContent(
  String content, {
  String? Function(String userId)? nameOf,
  String? Function(String emojiId)? emojiNameOf,
}) => content.replaceAllMapped(
  _token,
  (m) => m.group(1) != null
      ? '@${nameOf?.call(m.group(1)!) ?? 'someone'}'
      : ':${emojiNameOf?.call(m.group(2)!) ?? 'emoji'}:',
);

/// The user IDs [content] mentions.
Set<String> mentionedIn(String content) => {
  for (final t in tokenize(content))
    if (t is MentionToken) t.userId,
};
