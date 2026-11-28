/// What the UI shows, independent of the Duvet client's wire models.
library;

import '../e2e/files.dart' show ShownFile;
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

/// Over a bot's answer, as on the desktop: "Jon used /ping".
class MessageInteraction {
  final String userName;
  final String? userAvatarUrl;

  /// The command with its group and subcommand (`permissions user get`); null
  /// for a component's interaction.
  final String? command;

  /// The message whose component was used: tapping the header goes there.
  final String? interactedMessageId;

  const MessageInteraction({required this.userName, this.userAvatarUrl, this.command, this.interactedMessageId});
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

  /// A call notice's call (an [isNotice] the API posts once a call in a
  /// conversation ends); null on any other message.
  final CallNotice? call;

  /// A history share's notice (an [isNotice] the API posts once a member shared an encrypted conversation's history
  /// with another, its type 4): with whom, and how far back; null on any other message.
  final SharedHistoryNotice? sharedHistory;

  final List<MessageAttachment> attachments;

  /// Its files deleted since it was sent: placeholders, apart from
  /// [attachments] so nothing loads, renews or opens them.
  final List<MessageAttachment> deletedAttachments;

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

  /// A bot's answer to a command or a component: who used which.
  final MessageInteraction? interaction;

  /// An encrypted conversation's message this device's own database doesn't hold opened (PLAN-E2E-CLIENTES.md, «La
  /// vista de una conversación»): it shows as waiting for it, with no text.
  final bool waiting;

  /// A [waiting] message numbered before this device joined its conversation's group, which the device doesn't hold:
  /// it was never sealed for this device and nothing will deliver it, so it says it's not on this device instead
  /// (mobile#409). Only a shared history or a backup brings it.
  final bool notOnDevice;

  /// The user's own message this device still sends, from before the app started again: a failed send, with Retry
  /// and Dismiss.
  final bool pending;

  /// A [pending] message with files whose sealed bytes went with the app (it started again): it can only be dismissed,
  /// which its row says at once.
  final bool filesGone;

  /// An encrypted conversation's message's files as the API lists them, by ID: the signed URL of each one's sealed
  /// bytes, which [attachments] draws from once this device's database says what they are (lib/e2e/files.dart).
  final Map<String, String> sealedLinks;

  /// Who shared it with this device, by name, when a shared history brought it.
  final String? sharedBy;

  /// An encrypted conversation's message's number in its conversation's queue: its text and files are what this
  /// device's own database holds of it.
  final int? seq;

  /// An encrypted conversation's message, whose text and files are what this device's own database holds of it.
  bool get encrypted => seq != null;

  /// An encrypted conversation's message this device hasn't applied yet (numbered past what it applied): it loads,
  /// neither empty nor waiting (M2 of the desktop's task 16 review).
  final bool loading;

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
    this.call,
    this.sharedHistory,
    this.attachments = const [],
    this.deletedAttachments = const [],
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
    this.interaction,
    this.waiting = false,
    this.notOnDevice = false,
    this.pending = false,
    this.filesGone = false,
    this.sealedLinks = const {},
    this.sharedBy,
    this.seq,
    this.loading = false,
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
    bool? waiting,
    bool? notOnDevice,
    String? sharedBy,
    int? seq,
    bool? loading,
    List<MessageAttachment>? attachments,
    bool? isVoice,
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
    call: call,
    sharedHistory: sharedHistory,
    attachments: attachments ?? this.attachments,
    deletedAttachments: deletedAttachments,
    stickerUrl: stickerUrl,
    embeds: embeds,
    reply: reply ?? this.reply,
    reactions: reactions ?? this.reactions,
    isVoice: isVoice ?? this.isVoice,
    pinned: pinned ?? this.pinned,
    components: components,
    rawComponents: rawComponents,
    fromBot: fromBot,
    fromWebhook: fromWebhook,
    webhookId: webhookId,
    isEphemeral: isEphemeral,
    isLoading: isLoading,
    isComponentsV2: isComponentsV2,
    interaction: interaction,
    waiting: waiting ?? this.waiting,
    notOnDevice: notOnDevice ?? this.notOnDevice,
    pending: pending,
    filesGone: filesGone,
    sealedLinks: sealedLinks,
    sharedBy: sharedBy ?? this.sharedBy,
    seq: seq ?? this.seq,
    loading: loading ?? this.loading,
  );

  /// This message as an edit, or a link preview that came late, leaves it.
  /// [update] is what MESSAGE_UPDATE carries: the text, sticker, embeds,
  /// components and flags (a bot's deferred answer completes by an edit). It
  /// has none of the files, reactions, reply or pin, which stay, and it can't
  /// change who wrote it, whom the event names without their Space nickname,
  /// if at all.
  ///
  /// An encrypted conversation's message takes none of it: its text, edit and quote are what this device's own
  /// database holds, which the chat reads again (I4 of task 17's review).
  ChatMessage updatedBy(ChatMessage update) => encrypted
      ? this
      : ChatMessage(
          id: id,
          authorId: authorId,
          authorName: authorName,
          authorAvatarUrl: authorAvatarUrl,
          content: update.content,
          createdAt: createdAt,
          edited: update.edited,
          nonce: nonce,
          isNotice: isNotice,
          call: call,
          sharedHistory: sharedHistory,
          attachments: attachments,
          deletedAttachments: deletedAttachments,
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
          interaction: update.interaction ?? interaction,
          waiting: update.waiting,
          notOnDevice: update.notOnDevice,
          pending: pending,
          filesGone: filesGone,
          sealedLinks: sealedLinks,
          sharedBy: sharedBy,
          seq: seq,
          loading: update.loading,
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
      call: call,
      sharedHistory: sharedHistory,
      attachments: attachments,
      deletedAttachments: deletedAttachments,
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
      interaction: interaction,
      waiting: waiting,
      notOnDevice: notOnDevice,
      pending: pending,
      filesGone: filesGone,
      sealedLinks: sealedLinks,
      sharedBy: sharedBy,
      seq: seq,
      loading: loading,
    );
  }

  /// This message with its file [attachmentId] at [url], a new link to it.
  /// Itself when it has no such file, or has it there already.
  ChatMessage withAttachmentLink(String attachmentId, String url) {
    if (!attachments.any((a) => a.id == attachmentId && a.url != url)) return this;
    return ChatMessage(
      id: id,
      authorId: authorId,
      authorName: authorName,
      authorAvatarUrl: authorAvatarUrl,
      content: content,
      createdAt: createdAt,
      edited: edited,
      nonce: nonce,
      isNotice: isNotice,
      call: call,
      sharedHistory: sharedHistory,
      attachments: [for (final a in attachments) a.id == attachmentId ? a.withUrl(url) : a],
      deletedAttachments: deletedAttachments,
      stickerUrl: stickerUrl,
      embeds: embeds,
      reply: reply,
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
      interaction: interaction,
      waiting: waiting,
      notOnDevice: notOnDevice,
      pending: pending,
      filesGone: filesGone,
      sealedLinks: sealedLinks,
      sharedBy: sharedBy,
      seq: seq,
      loading: loading,
    );
  }

  /// With [userId]'s reaction added or taken away: the custom emoji [emojiId], named [emoji], else the Unicode
  /// [emoji]. Two Spaces' emojis of one name are two reactions.
  ChatMessage reacted(String emoji, String userId, {required bool add, String? emojiId}) {
    final list = [...reactions];
    final i = list.indexWhere((r) => r.key == (emojiId ?? emoji));
    if (add) {
      if (i < 0) {
        list.add(Reaction(emoji: emoji, emojiId: emojiId, users: {userId}));
      } else {
        list[i] = Reaction(emoji: list[i].emoji, emojiId: list[i].emojiId, users: {...list[i].users, userId});
      }
    } else if (i >= 0) {
      final users = {...list[i].users}..remove(userId);
      if (users.isEmpty) {
        list.removeAt(i);
      } else {
        list[i] = Reaction(emoji: list[i].emoji, emojiId: list[i].emojiId, users: users);
      }
    }
    return copyWith(reactions: list);
  }

  /// Whether [userId] reacted with the emoji [key] ([Reaction.key]).
  bool reactedWith(String userId, String key) => reactions.any((r) => r.key == key && r.users.contains(userId));

  /// This message with what this device's own database holds of it now, as [held] has it (an encrypted conversation's,
  /// read again): its text, whether it was edited, waits (or isn't on this device) or was shared, and its reply's
  /// quote; what else it shows (reactions, a pin) stays. Itself when that's what it has.
  ChatMessage heldAs(ChatMessage held) {
    final quote = switch ((reply, held.reply)) {
      (final shown?, final now?) when shown.content != now.content && !shown.deleted => shown.withContent(now.content),
      _ => reply,
    };
    final files = _filesOf(held);
    if (content == held.content &&
        edited == held.edited &&
        waiting == held.waiting &&
        notOnDevice == held.notOnDevice &&
        loading == held.loading &&
        sharedBy == held.sharedBy &&
        identical(quote, reply) &&
        identical(files, attachments) &&
        isVoice == held.isVoice) {
      return this;
    }
    return copyWith(
      content: held.content,
      edited: held.edited,
      waiting: held.waiting,
      notOnDevice: held.notOnDevice,
      loading: held.loading,
      sharedBy: held.sharedBy,
      reply: quote,
      attachments: files,
      isVoice: held.isVoice,
    );
  }

  /// The files [held] says the message has: this message's own while they're the same ones with their links, as a link
  /// renewed here ([withAttachmentLink]) is newer than the one [held] was made with; otherwise [held]'s, each this
  /// message already shows at a link keeping it. A message that came live before the device held its row shows none
  /// until its row is read (mobile#404).
  List<MessageAttachment> _filesOf(ChatMessage held) {
    final shown = {for (final a in attachments) a.id: a};
    MessageAttachment kept(MessageAttachment file) => switch (shown[file.id]) {
      final mine? when mine.url.isNotEmpty || file.url.isEmpty => mine,
      _ => file,
    };
    if (shown.length == held.attachments.length && held.attachments.every((a) => identical(kept(a), shown[a.id]))) {
      return attachments;
    }
    return [for (final a in held.attachments) kept(a)];
  }
}

/// What a history share's notice says (PLAN-E2E-CLIENTES.md, «La vista de una conversación»): the member its author
/// shared the conversation's history with ([toUserId], named [toName] as the app knew them then, "you" for the
/// reader), and how far back it went ([range]: day, week, month or all).
typedef SharedHistoryNotice = ({String toUserId, String toName, String range});

/// What a call notice says about its call: who was in it, by user ID, its
/// caller first, then each member who joined its voice; and when it started
/// ringing and when it ended. The caller alone is a call nobody else got
/// into.
class CallNotice {
  final List<String> participants;
  final DateTime startedAt;
  final DateTime endedAt;
  const CallNotice({required this.participants, required this.startedAt, required this.endedAt});

  /// How long the call lasted, ringing included.
  Duration get duration => endedAt.difference(startedAt);
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

  /// The same quote, mentioning its author or not.
  MessageReply withMentionAuthor(bool mentionAuthor) => MessageReply(
    messageId: messageId,
    authorId: authorId,
    authorName: authorName,
    content: content,
    mentionAuthor: mentionAuthor,
    deleted: deleted,
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

  /// What tells reactions apart, as the API groups them: the custom emoji's ID, else the Unicode emoji. Two Spaces'
  /// emojis can share a name.
  String get key => emojiId ?? emoji;
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

  /// An encrypted conversation's file, as its message's envelope says it on this device (lib/e2e/files.dart's
  /// shownFile): drawn only from its decrypted copy, its [url] the API's signed one of its sealed bytes, or empty when
  /// the message's API row doesn't list it. Its [filename] is its cleaned name and its [contentType] only its sender's
  /// word, for the layout.
  final ShownFile? sealed;

  /// A [sealed] file's thumbnail of its own: the API's signed URL of its sealed bytes.
  final String? thumbnailUrl;

  const MessageAttachment({
    required this.id,
    required this.filename,
    required this.contentType,
    required this.url,
    this.width,
    this.height,
    this.sizeBytes = 0,
    this.local = false,
    this.sealed,
    this.thumbnailUrl,
  });

  /// When its link stops working: the `exp` of a link the API signed (for 24
  /// hours). Null for one that doesn't expire: a file still on this device,
  /// a link preview's video.
  DateTime? get linkExpires {
    if (local) return null;
    final query = Uri.tryParse(url)?.queryParameters;
    final exp = int.tryParse(query?['exp'] ?? '');
    if (exp == null || query?['sig'] == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
  }

  /// How long before its link expires a file gets a new one, before it
  /// loads, as the desktop's voice notes do.
  static const renewBefore = Duration(minutes: 30);

  /// Whether its link expires within [renewBefore] of [now]: it's renewed
  /// before it loads.
  bool linkDueAt(DateTime now) => switch (linkExpires) {
    final at? => at.difference(now) < renewBefore,
    null => false,
  };

  /// The same file, at [url].
  MessageAttachment withUrl(String url) => MessageAttachment(
    id: id,
    filename: filename,
    contentType: contentType,
    url: url,
    width: width,
    height: height,
    sizeBytes: sizeBytes,
    local: local,
    sealed: sealed,
    thumbnailUrl: thumbnailUrl,
  );

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

  /// Its stripe down the left side, as `0xRRGGBB`: one color, or a gradient
  /// from [colors]' first, through the middle one when there are three, to
  /// its last. Empty for none.
  final List<int> colors;

  /// Above the title: who it's from, their icon and their link.
  final String? authorName;
  final String? authorUrl;
  final String? authorIconUrl;

  /// Name and value pairs; an inline one shares its line with the next.
  final List<({String name, String value, bool inline})> fields;

  /// Under the rest: its footer, then its date.
  final String? footer;
  final DateTime? timestamp;

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
    this.colors = const [],
    this.authorName,
    this.authorUrl,
    this.authorIconUrl,
    this.fields = const [],
    this.footer,
    this.timestamp,
  });

  /// Nothing but a picture, a video or a provider: no words of its own.
  bool get isWordless => title == null && description == null && authorName == null && fields.isEmpty && footer == null;

  bool get isEmpty => isWordless && imageUrl == null && thumbnailUrl == null && videoUrl == null;

  /// Only a picture, as a GIF link's embed is: shown bare, not on a card.
  bool get isBareImage => isWordless && imageUrl != null;

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

/// A Space's emoji, written `<:id:>` in a message; any chat can use those of the user's Spaces.
class CustomEmoji {
  final String id;
  final String name;
  final String url;
  final String spaceId;
  const CustomEmoji({required this.id, required this.name, required this.url, required this.spaceId});

  String get code => '<:$id:>';
}

/// A Space's sticker, sent as a message of its own, in any chat.
class Sticker {
  final String id;
  final String name;
  final String attachmentId;
  final String url;
  final String spaceId;
  const Sticker({
    required this.id,
    required this.name,
    required this.attachmentId,
    required this.url,
    required this.spaceId,
  });
}

/// [items] by their Space ([spaceOf]), as a picker heads them: in [spaces]' order, [first]'s first. Those of a Space
/// [spaces] doesn't have are left out.
List<({Space space, List<T> items})> bySpace<T>(
  Iterable<T> items,
  String Function(T item) spaceOf,
  List<Space> spaces, {
  String? first,
}) {
  final groups = <String, List<T>>{};
  for (final item in items) {
    (groups[spaceOf(item)] ??= []).add(item);
  }
  return [
    for (final space in [...spaces.where((s) => s.id == first), ...spaces.where((s) => s.id != first)])
      if (groups[space.id] case final items?) (space: space, items: items),
  ];
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

  /// Sent as a spoiler: named as [MessageAttachment.isSpoiler] reads it.
  bool get isSpoiler => name.startsWith(MessageAttachment.spoilerPrefix) && name != MessageAttachment.spoilerPrefix;

  /// The name shown in the tray, without the spoiler prefixes.
  String get displayName {
    final shown = name.replaceFirst(RegExp('^(?:${MessageAttachment.spoilerPrefix})+'), '');
    return shown.isEmpty ? name : shown;
  }

  /// This file, renamed to be a spoiler or not, as the desktop's toggle does.
  OutgoingFile withSpoiler(bool spoiler) => OutgoingFile(
    path: path,
    name: spoiler ? (isSpoiler ? name : '${MessageAttachment.spoilerPrefix}$name') : displayName,
    contentType: contentType,
    width: width,
    height: height,
    sizeBytes: sizeBytes,
  );
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

/// An uploaded file: one of the user's, or of a Space's.
class MyFile {
  final String id;
  final String name;
  final String contentType;
  final int sizeBytes;
  final DateTime createdAt;
  final String url;

  /// Posted in a message: a Space's admins can't delete it alone, only with
  /// all the Space's files.
  final bool inMessage;
  const MyFile({
    required this.id,
    required this.name,
    required this.contentType,
    required this.sizeBytes,
    required this.createdAt,
    required this.url,
    this.inMessage = false,
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

/// What a message search looks for, where: the desktop's filters.
class SearchQuery {
  final String text;

  /// In a Space (its rooms, or just [roomIds]), or in a conversation.
  final String? spaceId;
  final String? conversationId;
  final List<String> roomIds;
  final List<String> authorIds;
  final List<String> mentionIds;

  /// `link`, `embed`, `file`, `image`, `video`, `sound` or `sticker`.
  final List<String> has;
  final bool? pinned;
  final DateTime? before;
  final DateTime? after;

  /// The last message of the page before: the next page starts after it.
  final String? cursor;

  /// A search of this device's database (a conversation's, or every conversation's): the rows of the pages before,
  /// which the next page starts past.
  final int offset;
  const SearchQuery(
    this.text, {
    this.spaceId,
    this.conversationId,
    this.roomIds = const [],
    this.authorIds = const [],
    this.mentionIds = const [],
    this.has = const [],
    this.pinned,
    this.before,
    this.after,
    this.cursor,
    this.offset = 0,
  });

  /// Nothing to look for: the API refuses it.
  bool get isEmpty =>
      text.isEmpty &&
      roomIds.isEmpty &&
      authorIds.isEmpty &&
      mentionIds.isEmpty &&
      has.isEmpty &&
      pinned == null &&
      before == null &&
      after == null;

  /// The same search, from the page after [cursor], or past [offset] rows of this device's.
  SearchQuery from({String? cursor, int offset = 0}) => SearchQuery(
    text,
    spaceId: spaceId,
    conversationId: conversationId,
    roomIds: roomIds,
    authorIds: authorIds,
    mentionIds: mentionIds,
    has: has,
    pinned: pinned,
    before: before,
    after: after,
    cursor: cursor,
    offset: offset,
  );
}

/// A page of a message search, how many it found in all (up to 1000), and where the next page starts: null at the end.
typedef SearchPage = ({List<SearchHit> hits, int total, SearchQuery? next});

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

/// What this device's own database holds of the chat's messages changed (an encrypted conversation's, after an apply,
/// a send, an edit, a deletion or an import): what shows of them is read again ([ChatRepository.withContent]).
final class ContentChanged extends MessageEvent {
  const ContentChanged({this.imported = false});

  /// A shared history, a catch-up or a day of the backup came in: rows from before the user joined that a page left out
  /// may show now, so its pages are read again (Ruling 15; I3 of task 31's review).
  final bool imported;
}

/// An edit or a deletion of the user's in an encrypted conversation the server refused for good: shown done on this
/// device, it never reached the others, which the app says wherever the person is (M3 of task 17's review). A share
/// of the conversation's history that ended for good after the person was told it went ([share]) is said the same way.
final class ChangeRefused {
  const ChangeRefused(this.conversationId, this.messageId, {required this.deletion, this.share = false});
  final String conversationId;
  final String messageId;
  final bool deletion;

  /// A share of the conversation's history the person was told went, which ended for good ([messageId]: its package).
  final bool share;
}

/// What the start of a chat says (PLAN-E2E-CLIENTES.md, «La vista de una conversación»): a conversation from before
/// end-to-end encryption ([legacy]) says when its older messages went ([cutoverAt], as the server gives it), and one
/// whose rows from before the user joined it gave way says so, once ([beforeJoining]).
typedef ChatStart = ({bool legacy, DateTime? cutoverAt, bool beforeJoining});

/// A chat's start that says nothing: a room's, or a conversation's from after the cutover.
const ChatStart quietStart = (legacy: false, cutoverAt: null, beforeJoining: false);

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

/// A file's link expired, or was about to, and the API signed it again: the
/// messages with the file [attachmentId] load it from [url] now.
final class AttachmentRenewed extends MessageEvent {
  final String attachmentId;
  final String url;
  const AttachmentRenewed(this.attachmentId, this.url);
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

/// A conversation's message whose notice the app couldn't show, gone to the back while it waited for the message's text
/// (DuvetRepository): for the phone's notifications, with its group's name as [place] (empty for a DM) and this
/// device's text of it, readable ([text], null without one).
typedef AwayNotice = ({ConversationTarget target, ChatMessage message, String place, String? text});

/// A notice at the top of the app that someone mentioned the user in a chat
/// that isn't on screen: who, where, and what they wrote. Tapping it opens
/// the message.
class MentionNotice {
  final String messageId;
  final ChatTarget target;

  /// The chat's title, as its screen has it: `# general`, a person's name.
  final String title;
  final String authorName;
  final String? authorAvatarUrl;

  /// Where, after the author: "in #general · Design Guild", "in Weekend" (a
  /// group), "in a direct message".
  final String where;

  /// The message on one line, as a chat's preview has it.
  final String text;

  const MentionNotice({
    required this.messageId,
    required this.target,
    required this.title,
    required this.authorName,
    required this.where,
    required this.text,
    this.authorAvatarUrl,
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

/// What the user is notified of in a place: every message, only the messages that mention them, or nothing, which
/// also takes away the place's unread mark and its mention count (`ChatRepository.quiet`).
enum NotificationLevel { all, mentions, nothing }

/// The kind of place a notification level is for.
enum NotificationTarget { space, room, conversation }

class Space {
  final String id;
  final String name;
  final String? iconUrl;
  final List<RoomSection> sections;

  /// Members online or busy, or null while unknown.
  final int? onlineCount;

  /// Its banner, or null: atop its directory, as the desktop's sidebar has it.
  final String? bannerUrl;

  /// Its owner's user ID, for the crown; null from a cache that predates it.
  final String? ownerId;

  const Space({
    required this.id,
    required this.name,
    this.iconUrl,
    this.sections = const [],
    this.onlineCount,
    this.bannerUrl,
    this.ownerId,
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
