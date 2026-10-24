/// What the UI shows, independent of the Duvet client's wire models.
library;

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
  });

  int get attachmentCount => attachments.length;

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
  );

  /// This message as an edit, or a link preview that came late, leaves it.
  /// [update] is what MESSAGE_UPDATE carries: the text, sticker, embeds and
  /// components. It has none of the files, reactions, reply or pin, which
  /// stay, and names the author only when [withAuthor].
  ChatMessage updatedBy(ChatMessage update, {bool withAuthor = true}) => ChatMessage(
    id: id,
    authorId: authorId,
    authorName: withAuthor ? update.authorName : authorName,
    authorAvatarUrl: withAuthor ? update.authorAvatarUrl : authorAvatarUrl,
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
    fromBot: withAuthor ? update.fromBot : fromBot,
    fromWebhook: fromWebhook,
  );

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
  const MessageReply({required this.messageId, required this.authorName, required this.content, this.authorId});

  /// The same quote, of the message as edited to [content].
  MessageReply withContent(String content) =>
      MessageReply(messageId: messageId, authorId: authorId, authorName: authorName, content: content);
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

  /// GIFs always animate; other formats may, and play the same way.
  bool get isGif => contentType == 'image/gif';

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
  final String? provider;

  const MessageEmbed({this.title, this.description, this.url, this.imageUrl, this.provider});

  bool get isEmpty => title == null && description == null && imageUrl == null;
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

  /// Its color, if it has one (ARGB).
  final int? color;
  const RoleTag(this.name, {this.color});
}

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

  /// Whether the event named the author: a link preview's doesn't.
  final bool withAuthor;
  const MessageUpdated(this.message, {this.withAuthor = true});
}

final class MessageDeleted extends MessageEvent {
  final String messageId;
  const MessageDeleted(this.messageId);
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

/// Someone started typing in a chat.
class TypingUser {
  final String userId;
  final String name;
  const TypingUser({required this.userId, required this.name});
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

  const Room({required this.id, required this.spaceId, required this.name, required this.kind, required this.position});

  RoomTarget get target => RoomTarget(spaceId: spaceId, roomId: id);
}

/// A category's rooms, or the rooms outside any category (a null [name]).
class RoomSection {
  final String? name;
  final List<Room> rooms;
  const RoomSection({required this.name, required this.rooms});
}

class Space {
  final String id;
  final String name;
  final String? iconUrl;
  final List<RoomSection> sections;

  /// Members online or busy, or null while unknown.
  final int? onlineCount;

  const Space({required this.id, required this.name, this.iconUrl, this.sections = const [], this.onlineCount});

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
  final List<OutgoingFile> files;
  final MessageReply? replyTo;
  const ChatDraft({
    this.text = '',
    this.mentions = const {},
    this.emojis = const {},
    this.files = const [],
    this.replyTo,
  });

  bool get isEmpty => text.trim().isEmpty && files.isEmpty && replyTo == null;
}
