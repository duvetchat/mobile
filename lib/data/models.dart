/// What the UI shows, independent of the Duvet client's wire models.
library;

import 'admin.dart' show RoleColors;
import 'bots.dart';

export 'admin.dart';
export 'bots.dart';

/// The signed-in user.
class Profile {
  final String id;
  final String username;
  final String? alias;

  /// The avatar's URL, if they set one.
  final String? avatarUrl;
  final String? bannerUrl;
  final String? bio;

  /// Whether they've confirmed their email from the link it was sent.
  final bool emailVerified;

  /// The status they chose, [Presence.online] or [Presence.doNotDisturb]:
  /// what others see while they're connected.
  final Presence status;

  const Profile({
    required this.id,
    required this.username,
    this.alias,
    this.avatarUrl,
    this.bannerUrl,
    this.bio,
    this.emailVerified = true,
    this.status = Presence.online,
  });

  String get displayName => alias?.isNotEmpty == true ? alias! : username;

  /// The same profile, with [status] chosen.
  Profile withStatus(Presence status) => Profile(
    id: id,
    username: username,
    alias: alias,
    avatarUrl: avatarUrl,
    bannerUrl: bannerUrl,
    bio: bio,
    emailVerified: emailVerified,
    status: status,
  );
}

/// Where messages go: a space's room or a conversation (DM or group). Rooms and
/// conversations take different routes and events; the UI only sees this.
sealed class ChatTarget {
  const ChatTarget();

  /// The room's or conversation's ID.
  String get id;
}

final class RoomTarget extends ChatTarget {
  final String spaceId;
  final String roomId;
  const RoomTarget({required this.spaceId, required this.roomId});

  @override
  String get id => roomId;

  @override
  bool operator ==(Object other) => other is RoomTarget && other.roomId == roomId;

  @override
  int get hashCode => Object.hash(RoomTarget, roomId);
}

final class ConversationTarget extends ChatTarget {
  final String conversationId;
  const ConversationTarget(this.conversationId);

  @override
  String get id => conversationId;

  @override
  bool operator ==(Object other) => other is ConversationTarget && other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(ConversationTarget, conversationId);
}

class ChatMessage {
  final String id;
  final String? authorId;
  final String authorName;
  final String? authorAvatarUrl;
  final String content;
  final DateTime createdAt;
  final bool edited;

  /// The client's nonce for a message it sent, which its gateway echo carries.
  final String? nonce;

  /// Pins and other notices: no author bubble.
  final bool isNotice;

  final List<MessageAttachment> attachments;

  /// The sticker it is, if it's one: a sticker message has no text.
  final String? stickerUrl;

  /// Link previews and bot cards.
  final List<MessageEmbed> embeds;

  /// The message this one replies to.
  final MessageReply? reply;

  /// Its reactions, in the order they were first added.
  final List<Reaction> reactions;

  /// A voice note: its one attachment is the recording.
  final bool isVoice;

  /// Pinned to its chat.
  final bool pinned;

  /// A bot's buttons, selects and layout.
  final List<UiComponent> components;

  /// [components] as the API sent them: what the offline cache keeps.
  final List<Map<String, dynamic>> rawComponents;

  /// Its author is a bot: a rounded square and a BOT tag, not a person's circle.
  final bool fromBot;

  /// A webhook sent it: its tag says WEBHOOK, as on the desktop.
  final bool fromWebhook;

  /// The webhook that sent it, which has no author ID: what tells two
  /// webhooks' messages apart, as on the desktop.
  final String? webhookId;

  /// A bot's answer to the user alone (the EPHEMERAL flag): no history has
  /// it, and nothing of the room's (replies, reactions, pins) applies to it.
  final bool isEphemeral;

  /// A bot's deferred answer, not completed yet (the LOADING flag).
  final bool isLoading;

  /// Its components are all of it (the IS_COMPONENTS_V2 flag), its text their
  /// text displays.
  final bool isComponentsV2;

  const ChatMessage({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.content,
    required this.createdAt,
    this.authorAvatarUrl,
    this.edited = false,
    this.nonce,
    this.isNotice = false,
    this.attachments = const [],
    this.stickerUrl,
    this.embeds = const [],
    this.reply,
    this.reactions = const [],
    this.isVoice = false,
    this.pinned = false,
    this.components = const [],
    this.rawComponents = const [],
    this.fromBot = false,
    this.fromWebhook = false,
    this.webhookId,
    this.isEphemeral = false,
    this.isLoading = false,
    this.isComponentsV2 = false,
  });

  int get attachmentCount => attachments.length;

  /// The text it shows: its content, or a v2 message's text displays.
  String get text => isComponentsV2 ? _texts(components).join('\n') : content;

  static Iterable<String> _texts(List<UiComponent> components) sync* {
    for (final c in components) {
      if (c.type == ComponentKind.textDisplay && (c.content?.isNotEmpty ?? false)) yield c.content!;
      yield* _texts(c.children);
    }
  }

  ChatMessage copyWith({
    String? id,
    String? nonce,
    String? content,
    bool? edited,
    List<Reaction>? reactions,
    bool? pinned,
    MessageReply? reply,
  }) => ChatMessage(
    id: id ?? this.id,
    authorId: authorId,
    authorName: authorName,
    authorAvatarUrl: authorAvatarUrl,
    content: content ?? this.content,
    createdAt: createdAt,
    edited: edited ?? this.edited,
    nonce: nonce ?? this.nonce,
    isNotice: isNotice,
    attachments: attachments,
    stickerUrl: stickerUrl,
    embeds: embeds,
    reply: reply ?? this.reply,
    reactions: reactions ?? this.reactions,
    isVoice: isVoice,
    pinned: pinned ?? this.pinned,
    components: components,
    rawComponents: rawComponents,
    fromBot: fromBot,
    fromWebhook: fromWebhook,
    webhookId: webhookId,
    isEphemeral: isEphemeral,
    isLoading: isLoading,
    isComponentsV2: isComponentsV2,
  );

  /// This message as an edit, or a link preview that came late, leaves it.
  /// [update] is what MESSAGE_UPDATE carries: the text, sticker, embeds,
  /// components and flags (a bot's deferred answer completes by an edit). It
  /// has none of the files, reactions, reply or pin, which stay, and it can't
  /// change who wrote it, whom the event names without their Space nickname,
  /// if at all.
  ChatMessage updatedBy(ChatMessage update) => ChatMessage(
    id: id,
    authorId: authorId,
    authorName: authorName,
    authorAvatarUrl: authorAvatarUrl,
    content: update.content,
    createdAt: createdAt,
    edited: update.edited,
    nonce: nonce,
    isNotice: isNotice,
    attachments: attachments,
    stickerUrl: update.stickerUrl,
    embeds: update.embeds,
    reply: reply,
    reactions: reactions,
    isVoice: isVoice,
    pinned: pinned,
    components: update.components,
    rawComponents: update.rawComponents,
    fromBot: fromBot,
    fromWebhook: fromWebhook,
    webhookId: webhookId,
    isEphemeral: isEphemeral,
    isLoading: update.isLoading,
    isComponentsV2: update.isComponentsV2,
  );

  /// This message once [change] took place: the name and avatar of its
  /// author, if they're the one who changed (a webhook's message keeps the
  /// name and avatar it was sent with), and the name on its reply's quote,
  /// if it quotes them. Itself when that leaves it as it was.
  ChatMessage changedBy(AuthorChanged change) {
    final wrote =
        authorId == change.userId && !fromWebhook && (authorName != change.name || authorAvatarUrl != change.avatarUrl);
    final quote = switch (reply) {
      final r? when r.authorId == change.userId && r.authorName != change.name => r.withAuthorName(change.name),
      _ => null,
    };
    if (!wrote && quote == null) return this;
    return ChatMessage(
      id: id,
      authorId: authorId,
      authorName: wrote ? change.name : authorName,
      authorAvatarUrl: wrote ? change.avatarUrl : authorAvatarUrl,
      content: content,
      createdAt: createdAt,
      edited: edited,
      nonce: nonce,
      isNotice: isNotice,
      attachments: attachments,
      stickerUrl: stickerUrl,
      embeds: embeds,
      reply: quote ?? reply,
      reactions: reactions,
      isVoice: isVoice,
      pinned: pinned,
      components: components,
      rawComponents: rawComponents,
      fromBot: fromBot,
      fromWebhook: fromWebhook,
      webhookId: webhookId,
      isEphemeral: isEphemeral,
      isLoading: isLoading,
      isComponentsV2: isComponentsV2,
    );
  }

  /// With [userId]'s reaction [emoji] added or taken away.
  ChatMessage reacted(String emoji, String userId, {required bool add, String? emojiId}) {
    final list = [...reactions];
    final i = list.indexWhere((r) => r.emoji == emoji);
    if (add) {
      if (i < 0) {
        list.add(Reaction(emoji: emoji, emojiId: emojiId, users: {userId}));
      } else {
        list[i] = Reaction(emoji: emoji, emojiId: list[i].emojiId ?? emojiId, users: {...list[i].users, userId});
      }
    } else if (i >= 0) {
      final users = {...list[i].users}..remove(userId);
      if (users.isEmpty) {
        list.removeAt(i);
      } else {
        list[i] = Reaction(emoji: emoji, emojiId: list[i].emojiId, users: users);
      }
    }
    return copyWith(reactions: list);
  }
}

/// What a reply shows of the message it answers.
class MessageReply {
  final String messageId;
  final String? authorId;
  final String authorName;
  final String content;

  /// The reply mentions the author of the message it answers (the API's
  /// `mention_author`): it's highlighted for them.
  final bool mentionAuthor;

  /// The message it answers was deleted while shown: nothing to quote or
  /// jump to.
  final bool deleted;
  const MessageReply({
    required this.messageId,
    required this.authorName,
    required this.content,
    this.authorId,
    this.mentionAuthor = false,
    this.deleted = false,
  });

  /// The same quote, of the message as edited to [content].
  MessageReply withContent(String content) => MessageReply(
    messageId: messageId,
    authorId: authorId,
    authorName: authorName,
    content: content,
    mentionAuthor: mentionAuthor,
    deleted: deleted,
  );

  /// The same quote, of a message since deleted.
  MessageReply get asDeleted => MessageReply(
    messageId: messageId,
    authorId: authorId,
    authorName: authorName,
    content: '',
    mentionAuthor: mentionAuthor,
    deleted: true,
  );

  /// The same quote, its author named [authorName].
  MessageReply withAuthorName(String authorName) => MessageReply(
    messageId: messageId,
    authorId: authorId,
    authorName: authorName,
    content: content,
    mentionAuthor: mentionAuthor,
    deleted: deleted,
  );
}

/// One emoji's reactions on a message: a Unicode emoji, or a custom one by
/// [emojiId] (then [emoji] is its name).
class Reaction {
  final String emoji;
  final String? emojiId;
  final Set<String> users;
  const Reaction({required this.emoji, required this.users, this.emojiId});

  int get count => users.length;
}

/// A file on a message. [url] is a network URL, or a local path while the
/// message is still being sent.
class MessageAttachment {
  final String id;
  final String filename;
  final String contentType;
  final String url;
  final int? width;
  final int? height;
  final int sizeBytes;

  /// Still on this device: the message carrying it is being sent.
  final bool local;

  const MessageAttachment({
    required this.id,
    required this.filename,
    required this.contentType,
    required this.url,
    this.width,
    this.height,
    this.sizeBytes = 0,
    this.local = false,
  });

  bool get isImage => contentType.startsWith('image/');
  bool get isVideo => contentType.startsWith('video/');
  bool get isAudio => contentType.startsWith('audio/');

  /// GIFs and APNGs always animate; other formats may, and play the same way.
  bool get isGif => contentType == 'image/gif' || contentType == 'image/apng';

  /// Marked as a spoiler, as the desktop app marks one: its name starts
  /// with `SPOILER_`. It stays covered until tapped.
  bool get isSpoiler => filename.startsWith(spoilerPrefix) && filename.length > spoilerPrefix.length;

  /// The name without its spoiler prefixes.
  String get displayName {
    var name = filename;
    while (name.startsWith(spoilerPrefix) && name.length > spoilerPrefix.length) {
      name = name.substring(spoilerPrefix.length);
    }
    return name;
  }

  static const spoilerPrefix = 'SPOILER_';
}

/// A link preview or a bot's card: the parts the mobile app shows.
class MessageEmbed {
  final String? title;
  final String? description;
  final String? url;
  final String? imageUrl;
  final int? imageWidth;
  final int? imageHeight;

  /// A small picture beside the text, as the desktop's card shows one.
  final String? thumbnailUrl;

  /// A video file (video/*) to play, or a player page (text/html) to open.
  final String? videoUrl;
  final String? videoContentType;
  final String? provider;

  const MessageEmbed({
    this.title,
    this.description,
    this.url,
    this.imageUrl,
    this.imageWidth,
    this.imageHeight,
    this.thumbnailUrl,
    this.videoUrl,
    this.videoContentType,
    this.provider,
  });

  bool get isEmpty =>
      title == null && description == null && imageUrl == null && thumbnailUrl == null && videoUrl == null;

  /// Only a picture, as a GIF link's embed is: shown bare, not on a card.
  bool get isBareImage => title == null && description == null && imageUrl != null;

  /// The video plays as a file when its page says it is one, or, with no
  /// type, when its URL looks like one; anything else is a player page.
  bool get isDirectVideo {
    if (videoUrl == null) return false;
    if (videoContentType != null) return videoContentType!.startsWith('video/');
    final path = Uri.tryParse(videoUrl!)?.path.toLowerCase() ?? '';
    return path.endsWith('.mp4') || path.endsWith('.webm') || path.endsWith('.mov');
  }
}

/// Someone in a space or a conversation.
class Member {
  final String userId;
  final String username;
  final String? alias;
  final String? avatarUrl;
  final bool isBot;

  /// What they wrote about themselves.
  final String? bio;
  final String? bannerUrl;

  const Member({
    required this.userId,
    required this.username,
    this.alias,
    this.avatarUrl,
    this.isBot = false,
    this.bio,
    this.bannerUrl,
  });

  String get displayName => alias?.isNotEmpty == true ? alias! : username;
}

enum Presence { online, doNotDisturb, offline }

/// The key [ChatRepository.presence] keeps a member's presence in the Space
/// [spaceId] under, as the desktop keys it: `userId:spaceId`.
String spacePresenceKey(String userId, String spaceId) => '$userId:$spaceId';

/// [userId]'s presence in [presence] (as [ChatRepository.presence] keeps it),
/// in the Space [spaceId] when given: a bot's there, kept under
/// [spacePresenceKey], comes first, as the desktop reads it, then theirs
/// everywhere.
Presence? presenceIn(Map<String, Presence> presence, String userId, {String? spaceId}) =>
    (spaceId == null ? null : presence[spacePresenceKey(userId, spaceId)]) ?? presence[userId];

/// Whether [presence] shows someone offline, as a member list fades them:
/// offline, or not reported.
bool isOffline(Presence? presence) => (presence ?? Presence.offline) == Presence.offline;

/// A space's own emoji, written `<:id:>` in a message.
class CustomEmoji {
  final String id;
  final String name;
  final String url;
  const CustomEmoji({required this.id, required this.name, required this.url});

  String get code => '<:$id:>';
}

/// A space's sticker, sent as a message of its own.
class Sticker {
  final String id;
  final String name;
  final String attachmentId;
  final String url;
  const Sticker({required this.id, required this.name, required this.attachmentId, required this.url});
}

/// A file picked to send.
class OutgoingFile {
  final String path;
  final String name;
  final String contentType;
  final int? width;
  final int? height;

  /// Its size, when known, to check against the upload limit before sending.
  final int? sizeBytes;
  const OutgoingFile({
    required this.path,
    required this.name,
    required this.contentType,
    this.width,
    this.height,
    this.sizeBytes,
  });
}

/// The user's friends and the requests between them and others.
class Friends {
  final List<Member> friends;

  /// Asking the user, and asked by the user: each with its request's ID.
  final List<FriendRequestItem> incoming;
  final List<FriendRequestItem> outgoing;
  const Friends({this.friends = const [], this.incoming = const [], this.outgoing = const []});

  static const none = Friends();
}

class FriendRequestItem {
  final String id;
  final Member person;
  final DateTime at;
  const FriendRequestItem({required this.id, required this.person, required this.at});
}

/// A Space role, as a member shows it.
class RoleTag {
  final String name;

  /// Its color, if it has one (ARGB): a gradient's first stop.
  final int? color;

  /// A gradient's middle and last stops (ARGB), if it has them.
  final int? colorVia;
  final int? colorTo;
  final String id;

  /// Its rank: higher is above.
  final int position;

  /// Its members show apart in the member list, under its name.
  final bool hoisted;
  const RoleTag(
    this.name, {
    this.color,
    this.colorVia,
    this.colorTo,
    this.id = '',
    this.position = 0,
    this.hoisted = false,
  });

  RoleColors get colors => (from: color, via: colorVia, to: colorTo);
}

/// The colors a member's name shows: their highest role with a color, as the
/// desktop picks it, from roles highest first as [ChatRepository.rolesOf] gives them.
RoleColors? nameColorsOf(Iterable<RoleTag> roles) => roles.where((r) => r.color != null).firstOrNull?.colors;

/// One of the user's uploaded files.
class MyFile {
  final String id;
  final String name;
  final String contentType;
  final int sizeBytes;
  final DateTime createdAt;
  final String url;
  const MyFile({
    required this.id,
    required this.name,
    required this.contentType,
    required this.sizeBytes,
    required this.createdAt,
    required this.url,
  });

  bool get isImage => contentType.startsWith('image/');
  bool get isAudio => contentType.startsWith('audio/');
}

/// How much of their storage the user has used, in bytes.
/// A bucket of the user's own: what it holds, its own limit if it has one,
/// and whether it's the one that keeps their uploads.
typedef BucketUsage = ({String name, int used, int? max, bool active});

class StorageInfo {
  /// The default storage's: what it holds, and its quota.
  final int used;
  final int max;

  /// The user's own buckets; one at most is active, and keeps the uploads
  /// instead of the default storage.
  final List<BucketUsage> buckets;
  const StorageInfo({required this.used, required this.max, this.buckets = const []});

  BucketUsage? get activeBucket => buckets.where((b) => b.active).firstOrNull;
}

enum ProfileImage { avatar, banner }

/// The part of a picture to keep, in its own pixels.
typedef CropRect = ({double x, double y, double w, double h});

/// A message search found, and where it is.
class SearchHit {
  final ChatTarget target;
  final ChatMessage message;
  const SearchHit({required this.target, required this.message});
}

/// What a message search looks for, where.
class SearchQuery {
  final String text;

  /// In a Space (its rooms, or just [roomId]), or in a conversation.
  final String? spaceId;
  final String? roomId;
  final String? conversationId;
  final bool hasFile;
  final bool pinned;
  final String? authorId;
  const SearchQuery(
    this.text, {
    this.spaceId,
    this.roomId,
    this.conversationId,
    this.hasFile = false,
    this.pinned = false,
    this.authorId,
  });
}

/// A file the server refused as too large (HTTP 413).
class UploadTooLarge implements Exception {
  const UploadTooLarge();
}

/// Something the server refused or didn't answer, said for people.
class ActionFailed implements Exception {
  final String message;
  const ActionFailed(this.message);

  @override
  String toString() => message;
}

/// A Space an invite leads to, as its link previews it.
class InvitePreview {
  final String code;
  final String spaceId;
  final String spaceName;
  final String description;
  final int memberCount;

  /// Already a member.
  final bool joined;
  const InvitePreview({
    required this.code,
    required this.spaceId,
    required this.spaceName,
    this.description = '',
    this.memberCount = 0,
    this.joined = false,
  });
}

/// A change to a chat's messages, pushed by the gateway.
sealed class MessageEvent {
  const MessageEvent();
}

final class MessageCreated extends MessageEvent {
  final ChatMessage message;
  const MessageCreated(this.message);
}

/// A message edited, or given a link preview: [message] has what the event
/// carries, for [ChatMessage.updatedBy].
final class MessageUpdated extends MessageEvent {
  final ChatMessage message;
  const MessageUpdated(this.message);
}

final class MessageDeleted extends MessageEvent {
  final String messageId;
  const MessageDeleted(this.messageId);
}

/// Someone pinned a message, or unpinned it, here or on another device.
final class MessagePinned extends MessageEvent {
  final String messageId;
  final bool pinned;
  const MessagePinned(this.messageId, {required this.pinned});
}

/// Someone changed their name or avatar: the messages they wrote show the new
/// ones, and so do the replies' quotes of theirs (see
/// [ChatMessage.changedBy]). [name] is the one the chat shows them by: in a
/// Space's room, their nickname there, if they have one.
final class AuthorChanged extends MessageEvent {
  final String userId;
  final String name;
  final String? avatarUrl;
  const AuthorChanged(this.userId, {required this.name, this.avatarUrl});
}

/// Someone reacted to a message, or took a reaction back. The gateway doesn't
/// say in which chat: a chat applies it if it has the message.
final class ReactionChanged extends MessageEvent {
  final String messageId;
  final String userId;
  final String emoji;
  final String? emojiId;
  final bool added;
  const ReactionChanged({
    required this.messageId,
    required this.userId,
    required this.emoji,
    required this.added,
    this.emojiId,
  });
}

/// Someone started typing in a chat, or recording a voice message: either
/// replaces the other.
class TypingUser {
  final String userId;
  final String name;
  final bool recording;
  const TypingUser({required this.userId, required this.name, this.recording = false});
}

/// Who's typing, and who's recording a voice message, as the desktop's
/// typing indicator says it; null when no one is.
String? typingSentence(Iterable<TypingUser> users) {
  final typing = [
    for (final u in users)
      if (!u.recording) u.name,
  ];
  final recording = [
    for (final u in users)
      if (u.recording) u.name,
  ];
  if (typing.isEmpty && recording.isEmpty) return null;
  return [
    if (typing.isNotEmpty)
      switch (typing) {
        [final one] => '$one is typing…',
        [final a, final b] => '$a and $b are typing…',
        _ => 'Several people are typing…',
      },
    if (recording.isNotEmpty)
      switch (recording) {
        [final one] => '$one is recording a voice message',
        [final a, final b] => '$a and $b are recording voice messages',
        _ => 'Several people are recording voice messages',
      },
  ].join(' · ');
}

/// A row of the Chats tab.
class ConversationSummary {
  final String id;
  final String title;
  final bool isGroup;

  /// The other user's avatar, for a DM.
  final String? avatarUrl;

  /// The other user, for a DM: their presence shows beside it.
  final String? otherUserId;
  final int memberCount;

  /// When it last changed, for ordering it among the recent chats.
  final DateTime? updatedAt;

  /// Who made it; a group's owner can remove people.
  final String? ownerId;

  /// The group's own name, if it has one (else [title] lists its people).
  final String? name;

  const ConversationSummary({
    required this.id,
    required this.title,
    required this.isGroup,
    this.avatarUrl,
    this.otherUserId,
    this.memberCount = 2,
    this.updatedAt,
    this.ownerId,
    this.name,
  });

  ConversationTarget get target => ConversationTarget(id);
}

enum RoomKind { text, voice }

class Room {
  final String id;
  final String spaceId;
  final String name;
  final RoomKind kind;
  final int position;

  /// What the room is for, as its managers wrote it, or null.
  final String? description;

  const Room({
    required this.id,
    required this.spaceId,
    required this.name,
    required this.kind,
    required this.position,
    this.description,
  });

  RoomTarget get target => RoomTarget(spaceId: spaceId, roomId: id);
}

/// A category's rooms, or the rooms outside any category (a null [name]).
/// A category shows when it has no rooms too.
class RoomSection {
  /// The category's ID, to collapse it by; null outside any category, or
  /// from a cache that predates it.
  final String? id;
  final String? name;
  final List<Room> rooms;
  const RoomSection({this.id, required this.name, required this.rooms});
}

class Space {
  final String id;
  final String name;
  final String? iconUrl;
  final List<RoomSection> sections;

  /// Members online or busy, or null while unknown.
  final int? onlineCount;

  /// Its banner, or null: atop its directory, as the desktop's sidebar has it.
  final String? bannerUrl;

  const Space({
    required this.id,
    required this.name,
    this.iconUrl,
    this.sections = const [],
    this.onlineCount,
    this.bannerUrl,
  });

  Iterable<Room> get rooms => sections.expand((s) => s.rooms);
}

/// How far the live connection is: [reconnecting] once a live socket drops.
enum LiveStatus { offline, connecting, online, reconnecting }

/// What's unsent in a chat when it's left: the text as the composer holds it
/// (with its picked mentions and emoji), the files, the reply target.
class ChatDraft {
  final String text;
  final Map<String, String> mentions;
  final Map<String, String> emojis;
  final Map<String, String> rooms;
  final List<OutgoingFile> files;
  final MessageReply? replyTo;
  const ChatDraft({
    this.text = '',
    this.mentions = const {},
    this.emojis = const {},
    this.rooms = const {},
    this.files = const [],
    this.replyTo,
  });

  bool get isEmpty => text.trim().isEmpty && files.isEmpty && replyTo == null;
}
