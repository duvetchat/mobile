/// Duvet's own links, as the desktop app reads them (`urls.ts`): a message's
/// link, an invite's, and the app's `duvet://` deep links.
library;

import 'models.dart' show ChatTarget, ConversationTarget, RoomTarget;

const duvetDomain = 'https://duvet.chat';

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

/// The message a link names: in a room of a space, or in a conversation.
class MessageLink {
  final String? spaceId;
  final String? roomId;
  final String? conversationId;
  final String messageId;
  const MessageLink.room({required String this.spaceId, required String this.roomId, required this.messageId})
    : conversationId = null;
  const MessageLink.conversation({required String this.conversationId, required this.messageId})
    : spaceId = null,
      roomId = null;
}

/// `https://duvet.chat/channels/<space>/<room>/<message>` or
/// `…/conversations/<conversation>/<message>` (or the same after `duvet://`),
/// each ID a UUID; null otherwise.
MessageLink? parseMessageLink(String url) {
  final path = _duvetPath(url);
  if (path == null) return null;
  final parts = path.split('/');
  if (parts.length < 2 || !parts.skip(1).every(_uuid.hasMatch)) return null;
  return switch (parts) {
    ['channels', final space, final room, final message] => MessageLink.room(
      spaceId: space,
      roomId: room,
      messageId: message,
    ),
    ['conversations', final conversation, final message] => MessageLink.conversation(
      conversationId: conversation,
      messageId: message,
    ),
    _ => null,
  };
}

/// The link [parseMessageLink] reads back: message [messageId] in [target].
String messageLink(ChatTarget target, String messageId) => switch (target) {
  RoomTarget(:final spaceId, :final roomId) => '$duvetDomain/channels/$spaceId/$roomId/$messageId',
  ConversationTarget(:final id) => '$duvetDomain/conversations/$id/$messageId',
};

/// An invite's code: `https://duvet.chat/invite?code=X`, as desktop writes
/// them, `…/invite/X`, or `duvet://invite/X`; null otherwise.
String? parseInviteCode(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final path = _duvetPath(url);
  if (path == null) return null;
  final parts = path.split('/');
  final code = switch (parts) {
    ['invite'] => uri.queryParameters['code'],
    ['invite', final code] => code,
    _ => null,
  };
  return code == null || code.isEmpty || code.contains(RegExp(r'[/?#\\]')) ? null : code;
}

/// The link that adds a bot to a Space, as the desktop writes it.
String botInviteLink(String botUserId) => '$duvetDomain/invite?bot=$botUserId';

/// The bot a bot's invite link adds (`duvet.chat/invite?bot=<id>`), or null.
String? parseBotInvite(String url) {
  final path = _duvetPath(url);
  if (path != 'invite' && path != 'invite.html') return null;
  final id = Uri.tryParse(url.trim())?.queryParameters['bot'];
  return id != null &&
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false).hasMatch(id)
      ? id
      : null;
}

/// Where a link opens in the app.
sealed class DeepLink {
  const DeepLink();
}

final class OpenMessage extends DeepLink {
  final MessageLink link;
  const OpenMessage(this.link);
}

final class OpenInvite extends DeepLink {
  final String code;
  const OpenInvite(this.code);
}

/// The emailed link that verifies an address: `/verify?token=…`.
final class OpenVerify extends DeepLink {
  final String token;
  const OpenVerify(this.token);
}

/// The emailed link to choose a new password: `/reset-password?token=…`.
final class OpenReset extends DeepLink {
  final String token;
  const OpenReset(this.token);
}

/// The emailed link that moves the account to a new address.
final class OpenChangeEmail extends DeepLink {
  final String token;
  final String email;
  const OpenChangeEmail(this.token, this.email);
}

/// A link the app opens itself, or null for any other.
DeepLink? parseDeepLink(String url) {
  final path = _duvetPath(url);
  final query = Uri.tryParse(url.trim())?.queryParameters ?? const {};
  final token = query['token'];
  if (path != null && token != null && token.isNotEmpty) {
    switch (path) {
      case 'verify':
        return OpenVerify(token);
      case 'reset-password':
        return OpenReset(token);
      case 'change-email' when query['email']?.isNotEmpty == true:
        return OpenChangeEmail(token, query['email']!);
    }
  }
  if (parseInviteCode(url) case final code?) return OpenInvite(code);
  if (parseMessageLink(url) case final link?) return OpenMessage(link);
  return null;
}

// The path of a duvet.chat or duvet:// link, without its slashes at either end.
String? _duvetPath(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  final String path;
  if (uri.scheme == 'duvet') {
    // duvet://invite/X: the host is the first segment.
    path = [uri.host, ...uri.pathSegments].where((s) => s.isNotEmpty).join('/');
  } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      (uri.host == 'duvet.chat' || uri.host == 'www.duvet.chat')) {
    path = uri.pathSegments.where((s) => s.isNotEmpty).join('/');
  } else {
    return null;
  }
  return path;
}
