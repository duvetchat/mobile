import 'package:duvet_client/duvet.dart' show Activity;
import 'package:flutter/foundation.dart';

import '../e2e/engine.dart' show EngineState;
import '../e2e/sync.dart' show ConversationState;
import 'models.dart';
import 'recent_chats.dart';
import 'voice_signaling.dart';

/// Everything the app asks of a Duvet server. The UI depends on this alone;
/// [DuvetRepository] talks to the real API, and tests pass a fake.
/// The marks the UI shows: a chat at nothing ([ChatRepository.quiet]) shows neither, though [ChatRepository.unread]
/// and [ChatRepository.mentions] keep them, so they come back with its level. What shows them listens to
/// [ChatRepository.notificationLevels] too.
extension ShownMarks on ChatRepository {
  bool shownUnread(String chatId) => unread.value.contains(chatId) && !quiet(chatId);
  int shownMentions(String chatId) => quiet(chatId) ? 0 : mentions.value[chatId] ?? 0;
}

abstract interface class ChatRepository {
  /// The signed-in user, or null when signed out.
  ValueListenable<Profile?> get profile;

  /// Spaces, as the gateway sends them after it connects.
  ValueListenable<List<Space>> get spaces;

  /// The DMs and groups, the most recently created first.
  ValueListenable<List<ConversationSummary>> get conversations;

  /// The chats opened on this device and the DMs with news, the newest first.
  ValueListenable<List<RecentChat>> get recents;

  /// The IDs of the rooms and conversations with unread messages.
  ValueListenable<Set<String>> get unread;

  /// The categories the user folded away in Space directories, by ID: kept on
  /// this device, for this account. A category not here is open.
  ValueListenable<Set<String>> get collapsedCategories;
  void setCategoryCollapsed(String categoryId, bool collapsed);

  /// The chats pinned to the top of Chats, as `room:<id>` or `conv:<id>`
  /// (see `pinKey`): kept on this device, for this account, as neither the
  /// API nor the desktop has pins.
  ValueListenable<Set<String>> get pinnedChats;
  void setChatPinned(String key, bool pinned);

  ValueListenable<LiveStatus> get status;

  /// The gateway's voice and call signalling, which voice rooms and calls
  /// run on (`VoiceController`).
  VoiceSignaling get voiceSignaling;

  /// The session ended for good: the user signed out, or the server refused
  /// its tokens (saved ones at launch included). Fires before the session's
  /// gateway goes, so voice can still say it leaves; what the phone kept for
  /// the account goes with it.
  Stream<void> get signedOut;

  /// Resumes a saved session; answers whether there was one that still works.
  Future<bool> restore();

  /// The app is in front again, after the background or a locked screen,
  /// where its timers may not have run: the session is renewed if its tokens
  /// are an hour old, and a connection cut off while away goes again at once,
  /// once that renewal is done, asking the API whether the session still
  /// stands.
  void cameToFront();

  /// The app went to the background: its own notices and their sound keep quiet there, as the phone's notifications
  /// tell of what comes (lib/push).
  void wentToBack();

  /// End-to-end encryption on this device, as its engine has it (lib/e2e/engine.dart): what the app shows of it.
  ValueListenable<EngineState> get encryption;

  /// The person's taps on it: make a first device's identity (Set up, or Finish an upload that was cut), say its
  /// recovery key is saved (its upload), put that upload off after it failed (Later), and set this installation up
  /// again as a new device (a removed device, or one whose database's key is lost). Each does nothing in another state.
  Future<void> makeIdentity();
  Future<void> keySaved();
  Future<void> uploadLater();
  Future<void> startOver();

  /// What each encrypted conversation says over its message box of its group (lib/e2e/sync.dart), by its ID: none
  /// while its group goes on. A conversation on screen ([chatShown]) gets its group, made where this user may.
  ValueListenable<Map<String, ConversationState>> get conversationStates;

  /// The person's taps on it: Restart encryption, over a blocked group they may restart, and Open with these members,
  /// over a conversation whose members aren't those this device first saw. Each does nothing in another state.
  Future<void> restartGroup(String conversationId);

  Future<void> acceptMembers(String conversationId);

  Future<void> logIn(String email, String password);

  Future<void> logOut();

  /// Reloads the conversations from the API.
  Future<void> refreshConversations();

  /// The newest message of each room and conversation seen this session, by
  /// chat ID: what the Space Directory previews.
  ValueListenable<Map<String, ChatMessage>> get latest;

  /// Fetches the newest message of each of [targets] not in [latest] yet,
  /// and the whole page of the busiest few, kept for [cachedMessages].
  Future<void> loadLatest(Iterable<ChatTarget> targets);

  /// A message as a one-line preview, mentions and emoji by name.
  String previewOf(ChatMessage message);

  /// The chat's latest messages, the oldest first, or those [before] a message.
  Future<List<ChatMessage>> messages(ChatTarget target, {String? before});

  /// The chat's latest page as it was last seen here, kept on the device, or
  /// null when it never was: what a chat opens on while [messages] fetches it
  /// again.
  Future<List<ChatMessage>?> cachedMessages(ChatTarget target);

  /// Live changes to the chat's messages.
  Stream<MessageEvent> messageEvents(ChatTarget target);

  /// Who starts typing in the chat.
  Stream<TypingUser> typing(ChatTarget target);

  /// Who's typing now, by chat ID, as the open chat shows them: what the
  /// Chats list and a Space's rooms show outside it.
  ValueListenable<Map<String, List<TypingUser>>> get typingNow;

  /// A room's ephemeral messages: its bots' answers to the user alone, which
  /// no history has. They last the session, until dismissed.
  List<ChatMessage> ephemeralIn(ChatTarget target);

  /// The user dismissed an ephemeral message: it goes.
  void dismissEphemeral(ChatTarget target, String messageId);

  /// Sends [content] with [files], or a sticker, in reply to [replyTo] if
  /// given; [nonce] matches the gateway's echo to it. With files,
  /// [onProgress] follows the upload (0 to 1) and completing [cancel] stops
  /// it. A file the server finds too large throws [UploadTooLarge], and a
  /// refusal the API explains an [ActionFailed] with its reason.
  Future<ChatMessage> send(
    ChatTarget target,
    String content, {
    required String nonce,
    List<OutgoingFile> files = const [],
    Sticker? sticker,
    String? replyTo,
    bool? mentionRepliedUser,
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  });

  /// Sends a voice note: [audio] in [format] (`ogg` for Ogg/Opus). A refusal
  /// the API explains throws an [ActionFailed] with its reason.
  Future<ChatMessage> sendVoiceNote(ChatTarget target, List<int> audio, {required String nonce, String format});

  /// Tells the chat the user is recording a voice note.
  Future<void> sendRecording(ChatTarget target);

  /// The largest file the user may upload, in bytes; null when unknown.
  Future<int?> uploadLimit();

  /// A page of the messages matching [query], the newest first.
  Future<SearchPage> search(SearchQuery query);

  /// The chat's pinned messages, the last pinned first.
  Future<List<ChatMessage>> pins(ChatTarget target);

  /// Pins a message, or unpins it. A refusal the API explains throws an
  /// [ActionFailed] with its reason.
  Future<void> pin(ChatTarget target, String messageId, {required bool pinned});

  /// A message's reply thread, oldest first: its root and every reply under it.
  Future<List<ChatMessage>> thread(ChatTarget target, String messageId);

  /// Everyone known this session: the members of the Spaces whose lists were
  /// loaded, and of the conversations.
  List<Member> get people;

  /// Creates a Space, with [iconPath] as its icon if given; answers its ID.
  Future<String> createSpace(String name, {String? description, String? iconPath});

  Future<void> leaveSpace(String spaceId);

  /// A new invite to a room, lasting [maxAge] (forever when null); answers
  /// its link.
  Future<String> createInvite(String spaceId, String roomId, {Duration? maxAge});

  /// Marks every room of the Space read.
  void markSpaceRead(String spaceId);

  /// The user's friends and friend requests; [loadFriends] fetches them.
  ValueListenable<Friends> get friends;
  Future<void> loadFriends();

  /// Asks [userId] to be friends. A refusal the API explains (no such user,
  /// a bot, friends already) throws an [ActionFailed] with its reason.
  Future<void> sendFriendRequest(String userId);
  Future<void> acceptFriendRequest(String requestId);

  /// Declines a request to the user, or takes back one of theirs.
  Future<void> rejectFriendRequest(String requestId);
  Future<void> unfriend(String userId);

  /// A group with [userIds]; answers it.
  Future<ConversationSummary> createGroup(String name, List<String> userIds);
  Future<void> renameConversation(String conversationId, String name);
  Future<void> addToConversation(String conversationId, String userId);
  Future<void> removeFromConversation(String conversationId, String userId);
  Future<void> leaveConversation(String conversationId);

  /// [userId]'s roles in a Space, highest first.
  List<RoleTag> rolesOf(String spaceId, String userId);

  /// Whether [userId] is in the Space, as far as the gateway and the member
  /// lists loaded have told.
  bool isMember(String spaceId, String userId);

  /// Makes an account, then signs in to it; the API emails a link to verify
  /// the address. A refusal the API explains (a username taken, say) throws
  /// an [ActionFailed] with its reason.
  Future<void> signUp({required String username, required String email, required String password, String? alias});
  Future<void> sendVerificationEmail();

  /// Emails the signed-in user a link to set a new password, as Forgot
  /// password does when signed out.
  Future<void> sendResetPasswordEmail();

  /// Verifies the email with the token from the emailed link.
  Future<void> verifyEmail(String token);

  /// Emails a link to reset the password of the account using [email].
  Future<void> forgotPassword(String email);
  Future<void> resetPassword(String token, String password);

  /// Emails a link to [email] to move the account there.
  Future<void> sendChangeEmail(String email);
  Future<void> changeEmail(String token, String email);

  /// The user's display name: empty clears it, back to the username. A [bio]
  /// replaces theirs (empty clears it), as a [username] does; left out, each
  /// stays. A refusal the API explains (a username taken, say) throws an
  /// [ActionFailed] with its reason.
  Future<void> updateProfile({required String alias, String? bio, String? username});

  /// Chooses the user's status, [Presence.online] or
  /// [Presence.doNotDisturb]: what others see while they're connected.
  Future<void> setStatus(Presence status);

  /// A new avatar or banner: the picture at [path], cropped already.
  /// [onProgress] follows the upload (0 to 1).
  Future<void> uploadProfileImage(ProfileImage kind, String path, {void Function(double progress)? onProgress});

  /// Takes the user's avatar or banner away: they show none, as before they
  /// chose one.
  Future<void> removeProfileImage(ProfileImage kind);

  Future<List<MyFile>> myFiles();
  Future<void> deleteMyFile(String id);
  Future<StorageInfo> storage();

  // Running a Space ----------------------------------------------------------

  /// The Space as its settings show it, with the user's permissions in it;
  /// null when it isn't known.
  SpaceProfile? spaceProfile(String spaceId);

  /// Deletes a Space the user owns, for everyone in it.
  Future<void> deleteSpace(String spaceId);

  /// Whether the user may do [bit] in a room, with its overwrites applied.
  bool canInRoom(String spaceId, String roomId, int bit);

  /// Changes the Space; [removeBanner] takes its banner away, as no
  /// [bannerPath] can. With pictures, [onProgress] follows their upload (0 to
  /// 1). An empty [locale] clears it. [defaultNotifications] is what its members
  /// are notified of until they choose: every message or only mentions.
  Future<void> updateSpace(
    String spaceId, {
    String? name,
    String? description,
    String? locale,
    String? iconPath,
    String? bannerPath,
    bool removeBanner = false,
    bool removeIcon = false,
    NotificationLevel? defaultNotifications,
    void Function(double progress)? onProgress,
  });

  /// Rooms and categories, by position.
  List<AdminRoom> adminRooms(String spaceId);
  Future<void> createRoom(String spaceId, String name, AdminRoomKind kind, {String? parentId});
  Future<void> renameRoom(String spaceId, String roomId, String name);

  /// Sets what a room is for; null or blank clears it. Not for categories.
  Future<void> setRoomDescription(String spaceId, String roomId, String? description);
  Future<void> deleteRoom(String spaceId, String roomId);

  /// Moves a room into [parentId]'s rooms (null: out of any category; a
  /// category stays out), to [position] as the API takes it: the place it's
  /// inserted at, before the room now there, counted before it leaves its
  /// own. Past the last one's position puts it last.
  Future<void> moveRoom(String spaceId, String roomId, {String? parentId, required int position});
  List<RoomOverwrite> overwrites(String spaceId, String roomId);

  /// Saves an overwrite; an empty one is removed, where there is one.
  Future<void> setOverwrite(String spaceId, String roomId, RoomOverwrite overwrite);

  /// Roles, highest first, @everyone last.
  List<SpaceRole> roles(String spaceId);
  Future<SpaceRole> createRole(String spaceId, String name);

  /// Changes what's given. [colors] replaces all of the role's colors: a
  /// stop left null is cleared.
  Future<void> updateRole(String spaceId, String roleId, {String? name, RoleColors? colors, int? perms, bool? hoisted});

  /// Moves a role to [position] (higher is above; @everyone is 0, and stays
  /// there), the roles between shifting one place to make room.
  Future<void> moveRole(String spaceId, String roleId, int position);
  Future<void> deleteRole(String spaceId, String roleId);
  List<String> roleMembers(String spaceId, String roleId);
  Future<void> setRole(String spaceId, String roleId, String userId, {required bool has});

  Future<List<SpaceInvite>> spaceInvites(String spaceId);
  Future<void> revokeInvite(String spaceId, String inviteId);

  Future<List<SpaceAsset>> assets(String spaceId, AssetKind kind);

  /// [onProgress] follows the picture's upload (0 to 1).
  Future<void> addAsset(
    String spaceId,
    AssetKind kind,
    String name,
    String path, {
    void Function(double progress)? onProgress,
  });
  Future<void> renameAsset(String spaceId, AssetKind kind, String id, String name);
  Future<void> deleteAsset(String spaceId, AssetKind kind, String id);

  Future<List<SpaceWebhook>> webhooks(String spaceId);

  /// Answers the new webhook's URL: shown once, never again.
  Future<String> createWebhook(String spaceId, String roomId, String name);
  Future<String> resetWebhook(String spaceId, SpaceWebhook webhook);
  Future<void> deleteWebhook(String spaceId, SpaceWebhook webhook);

  /// Renames a webhook, or changes its picture: a file at [avatarPath], or
  /// none with [removeAvatar]. Its past messages keep the one they had.
  Future<void> updateWebhook(
    String spaceId,
    SpaceWebhook webhook, {
    String? name,
    String? avatarPath,
    bool removeAvatar = false,
  });

  Future<SpaceStorage> spaceStorage(String spaceId);

  /// A bucket for the Space's files; while one is active, the uploads go to it.
  Future<void> createSpaceBucket(String spaceId, BucketDraft draft);

  /// Sends every field: a null limit removes it, an empty secret keeps it.
  Future<void> updateSpaceBucket(String spaceId, String bucketId, BucketDraft draft);

  /// Refused while it holds files, said with how many.
  Future<void> deleteSpaceBucket(String spaceId, String bucketId);
  Future<void> setSpaceBucketActive(String spaceId, String bucketId, bool active);

  /// A file posted in no message: the API won't delete one that is.
  Future<void> deleteSpaceFile(String spaceId, String fileId);

  /// Every file of the Space's, those in messages too.
  Future<void> deleteAllSpaceFiles(String spaceId);

  /// The team invites waiting on the user: fetched on READY, and again when
  /// TEAM_INVITE_CREATE brings one.
  ValueListenable<List<TeamInvite>> get teamInvites;
  Future<void> acceptTeamInvite(String inviteId);
  Future<void> declineTeamInvite(String inviteId);

  /// The developer teams the user is in.
  Future<List<DevTeam>> teams();
  Future<DevTeam> createTeam(String name);
  Future<void> renameTeam(String teamId, String name);

  /// Deletes a team the user owns, with its applications and their bots.
  Future<void> deleteTeam(String teamId);
  Future<List<Member>> teamMembers(String teamId);

  /// Invites the person with this [email]: a verified account's, not a bot's.
  Future<void> inviteToTeam(String teamId, String email);
  Future<void> removeTeamMember(String teamId, String userId);

  Future<List<DevApp>> applications(String teamId);
  Future<DevApp> createApplication(String teamId, String name, {String? description});
  Future<DevApp> updateApplication(DevApp app, {String? name, String? description, bool? public});
  Future<void> deleteApplication(DevApp app);

  /// An application's slash commands, by name.
  Future<List<BotCommand>> appCommands(DevApp app);

  /// Registers [command] when its id is empty, else replaces its name,
  /// description and options; answers it as saved. Refusals carry the API's
  /// reason (a name it doesn't take, an option's rules).
  Future<BotCommand> saveAppCommand(DevApp app, BotCommand command);
  Future<void> deleteAppCommand(DevApp app, String commandId);

  /// Gives [app] a bot, and answers its token: shown once, never again.
  Future<String> createBot(DevApp app);
  Future<String> resetBotToken(DevApp app);

  /// Deletes the app's bot, from every Space it is in.
  Future<void> deleteBot(DevApp app);
  Future<Member> botProfile(String botUserId);

  /// Changes the app's bot: [clearAlias] takes its display name away, as
  /// [removeAvatar] and [removeBanner] do its pictures; new ones are files at
  /// [avatarPath] and [bannerPath].
  Future<void> updateBot(
    DevApp app, {
    String? username,
    String? alias,
    bool clearAlias = false,
    String? avatarPath,
    String? bannerPath,
    bool removeAvatar = false,
    bool removeBanner = false,
  });

  /// The commands of the Space's applications.
  Future<List<BotCommand>> commands(String spaceId);

  /// Uses a component of a bot's message; answers the modal the bot opens,
  /// if it does.
  Future<BotModal?> useComponent(RoomTarget target, String messageId, UiComponent component, {List<String>? values});

  /// Uses a command, with its options' values by name; answers the modal the
  /// bot opens, if it does.
  Future<BotModal?> useCommand(RoomTarget target, BotCommand command, Map<String, Object> options);

  /// Sends what a modal's fields hold (the components [modalAnswers] makes).
  Future<void> submitModal(BotModal modal, List<Map<String, dynamic>> components);

  /// A bot, for its invite card.
  Future<BotInfo> bot(String userId);
  Future<void> addBot(String spaceId, String botId);

  /// Takes a bot out of a Space; the gateway's member removal drops it from
  /// the members list.
  Future<void> removeBot(String spaceId, String botId);

  /// Takes a person out of a Space (Kick Members); they can join it again.
  /// The gateway's member removal drops them from the members list.
  Future<void> kick(String spaceId, String userId);

  /// Bans a person from a Space (Ban Members), with [reason] or none: they
  /// leave it as a kick takes them, and can't join it again.
  Future<void> ban(String spaceId, String userId, {String? reason});

  /// The Space's bans, newest first (Ban Members).
  Future<List<SpaceBan>> bans(String spaceId);

  /// Lifts [userId]'s ban from a Space (Ban Members): they can join again.
  Future<void> unban(String spaceId, String userId);

  /// A Space's ID each time someone, here or elsewhere, bans or unbans in it.
  Stream<String> get bansChanged;

  /// The Space's roles, highest first, but the one everyone has: for role
  /// selects and options.
  List<({String id, String name})> spaceRoles(String spaceId);

  /// What an invite code leads to.
  Future<InvitePreview> invite(String code);

  /// Joins the Space an invite leads to; answers its ID.
  Future<String> joinInvite(String code);

  /// [messages] of the chat with what this device's own database holds of each now ([ChatMessage.heldAs]): an
  /// encrypted conversation's text, edits, waiting rows and quotes (PLAN-E2E-CLIENTES.md, «La vista de una
  /// conversación»), read again on [ContentChanged]; a room's as they are. Those it can't read now stay as they are.
  Future<List<ChatMessage>> withContent(ChatTarget target, List<ChatMessage> messages);

  /// Sends again the user's message [nonce] that waits on this device ([ChatMessage.pending]), with what the device
  /// kept of it: the message as sent.
  Future<ChatMessage> resend(ChatTarget target, String nonce);

  /// Drops the user's message [nonce] that wasn't sent: it waits on this device no more.
  Future<void> discard(ChatTarget target, String nonce);

  /// What the chat's start says: [quietStart] for a room.
  ChatStart chatStart(ChatTarget target);

  /// Replaces the text of the user's own message.
  Future<ChatMessage> edit(ChatTarget target, String messageId, String content);

  /// Deletes the user's own message, for everyone.
  Future<void> delete(ChatTarget target, String messageId);

  /// Adds the user's reaction [emoji] (a custom one's name, with [emojiId]) to
  /// a message, or takes it back.
  Future<void> react(ChatTarget target, String messageId, String emoji, {required bool add, String? emojiId});

  /// One message, e.g. the original of a reply that isn't loaded.
  Future<ChatMessage> fetchMessage(ChatTarget target, String messageId);

  /// A link to [attachment] that works now. Its own while it has more than
  /// [MessageAttachment.renewBefore] left (or one renewed here since), else a
  /// new one the API signs, which the messages with the file then carry
  /// ([AttachmentRenewed]), the pages kept for offline included. [refused]:
  /// its link, the one [attachment] has, failed to load, so a new one even if
  /// it hasn't expired, but not within a minute of the last one
  /// signed. Its own when the API can't sign one.
  Future<String> attachmentLink(MessageAttachment attachment, {bool refused = false});

  /// The messages after [messageId], the oldest first: what was missed while
  /// the socket was down.
  Future<List<ChatMessage>> messagesAfter(ChatTarget target, String messageId);

  /// Unread mentions of the user, by chat ID.
  ValueListenable<Map<String, int>> get mentions;

  /// The notification levels the user chose, by place: a Space's, a room's or a conversation's ID. READY loads them
  /// and NOTIFICATION_SETTINGS_UPDATE keeps them current; a place without one notifies by its default.
  ValueListenable<Map<String, NotificationLevel>> get notificationLevels;

  /// What a Space notifies of: the user's level for it, else its default ([spaceDefault]).
  NotificationLevel spaceLevel(String spaceId);

  /// What a Space notifies its members of until they choose: every message or only mentions, which its owner and
  /// Administrators set (only mentions until they do, and from a server without it).
  NotificationLevel spaceDefault(String spaceId);

  /// What a room notifies of: the user's level for it, else its Space's.
  NotificationLevel roomLevel(String roomId);

  /// What a conversation notifies of: the user's level for it, else every message.
  NotificationLevel conversationLevel(String conversationId);

  /// Whether a chat (a room's or a conversation's ID) notifies of nothing: no notice, no sound, no unread mark and no
  /// mention count. [unread] and [mentions] still hold it, so its marks come back as its level changes.
  bool quiet(String chatId);

  /// Sets the user's level for a place, or clears it ([level] null) so the place notifies by its default. The levels
  /// change once NOTIFICATION_SETTINGS_UPDATE comes back.
  Future<void> setNotificationLevel(String targetId, NotificationTarget target, NotificationLevel? level);

  /// Makes [fid], this phone's Firebase installation ID, the session's push registration: the user's messages that
  /// notify come to the phone while they have no computer with Duvet open (lib/push).
  Future<void> setPushRegistration(String fid);

  /// Deletes the session's push registration: the phone gets no pushes any more.
  Future<void> deletePushRegistration();

  /// The notices of mentions of the user in chats that aren't on screen, the
  /// newest first, a few at most, each for a few seconds. None in do not
  /// disturb; a message deleted takes its notice away, and opening its chat
  /// ([chatShown]) does too.
  ValueListenable<List<MentionNotice>> get mentionNotices;

  /// Takes a message's notice away: it was opened, or swiped off.
  void dismissMentionNotice(String messageId);

  /// The chat on screen ([threadOf]: a thread of it, showing the replies to
  /// that message), whose mentions show no notice: a chat's screen says so
  /// while it's on top with the app in front, then [chatHidden]. A chat
  /// [opened] (not a thread, nor only back from the background) takes its
  /// notices away.
  void chatShown(ChatTarget target, {String? threadOf, bool opened = true});

  /// The chat stopped being on screen; nothing changes when another is on
  /// screen by now.
  void chatHidden(ChatTarget target, {String? threadOf});

  /// The last message the user read in a room, as the server knows it; null
  /// when it doesn't (and in conversations).
  String? lastReadOf(ChatTarget target);

  /// Fires when the gateway is back after a drop with a new session (READY):
  /// chats fetch what they missed. When it resumes the session instead, it
  /// replays what was missed, and this doesn't fire.
  Stream<void> get resumed;

  /// What's unsent per chat, by chat ID; kept for the session.
  Map<String, ChatDraft> get drafts;

  /// Who's in the chat: the room's space, or the conversation. Cached; [refresh]
  /// fetches again.
  Future<List<Member>> members(ChatTarget target, {bool refresh = false});

  /// Anyone, by user ID, from the API: for those no list has, such as
  /// someone who left.
  Future<Member> user(String userId);

  /// A user's name, if any list or message seen this session gave it.
  String? nameOf(String userId);

  /// An avatar's URL, from the attachment ID the API and the gateway name it
  /// by (a caller's, say); null for none.
  String? avatarUrl(String? avatar);

  /// A custom emoji's name, if it's one of the user's Spaces' and they were loaded.
  String? emojiNameOf(String emojiId);

  /// A custom emoji's image by its ID, any Space's: the API's `/emojis/{id}`, which needs no session.
  String emojiUrl(String emojiId);

  /// Who's online, by user ID, as the gateway reports it; someone missing
  /// hasn't been reported this session. A member's status in one Space (a
  /// bot's is its shard's there), which comes first there ([presenceIn]), is
  /// kept under [spacePresenceKey] too.
  ValueListenable<Map<String, Presence>> get presence;

  /// Who's connected only from the mobile app, by user ID, as the client
  /// status that comes with each presence says: they show a phone rather
  /// than the dot while they're connected. Where [presence] fills someone in
  /// from a list, this does too. It has nobody's per Space: a person's
  /// platforms are the same in every Space, and a bot's connections all count
  /// as a computer's.
  ValueListenable<Set<String>> get mobileOnly;

  /// What people are doing (a game, the song Spotify plays), by user ID, as
  /// the gateway tells it of those the user shares a Space with; someone
  /// missing is doing nothing it knows of.
  ValueListenable<Map<String, List<Activity>>> get activities;

  /// The emoji any chat can use beyond Unicode's: every one of the user's Spaces', as the API lists them.
  Future<List<CustomEmoji>> customEmojis();

  /// The stickers any chat can send: every one of the user's Spaces'.
  Future<List<Sticker>> stickers();

  /// The DM with [userId], opened if there was none.
  Future<ConversationSummary> directMessage(String userId);

  Future<void> sendTyping(ChatTarget target);

  /// Records that the chat was opened, showing [latest] as its newest message.
  void opened(ChatTarget target, String title, {ChatMessage? latest});

  /// Marks the chat read up to [messageId].
  void markRead(ChatTarget target, String messageId);

  void dispose();
}
