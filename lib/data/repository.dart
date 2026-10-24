import 'package:flutter/foundation.dart';

import 'models.dart';
import 'recent_chats.dart';
import 'voice_signaling.dart';

/// Everything the app asks of a Duvet server. The UI depends on this alone;
/// [DuvetRepository] talks to the real API, and tests pass a fake.
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

  ValueListenable<LiveStatus> get status;

  /// The gateway's voice and call signalling, which voice rooms and calls
  /// run on (`VoiceController`).
  VoiceSignaling get voiceSignaling;

  /// Resumes a saved session; answers whether there was one that still works.
  Future<bool> restore();

  Future<void> logIn(String email, String password);

  Future<void> logOut();

  /// Reloads the conversations from the API.
  Future<void> refreshConversations();

  /// The newest message of each room and conversation seen this session, by
  /// chat ID: what the Space Directory previews.
  ValueListenable<Map<String, ChatMessage>> get latest;

  /// Fetches the newest message of each of [targets] not in [latest] yet.
  Future<void> loadLatest(Iterable<ChatTarget> targets);

  /// A message as a one-line preview, mentions and emoji by name.
  String previewOf(ChatMessage message);

  /// The chat's latest messages, the oldest first, or those [before] a message.
  Future<List<ChatMessage>> messages(ChatTarget target, {String? before});

  /// Live changes to the chat's messages.
  Stream<MessageEvent> messageEvents(ChatTarget target);

  /// Who starts typing in the chat.
  Stream<TypingUser> typing(ChatTarget target);

  /// Sends [content] with [files], or a sticker, in reply to [replyTo] if
  /// given; [nonce] matches the gateway's echo to it. With files,
  /// [onProgress] follows the upload (0 to 1) and completing [cancel] stops
  /// it. A file the server finds too large throws [UploadTooLarge].
  Future<ChatMessage> send(
    ChatTarget target,
    String content, {
    required String nonce,
    List<OutgoingFile> files = const [],
    Sticker? sticker,
    String? replyTo,
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  });

  /// Sends a voice note: [audio] in [format] (`ogg` for Ogg/Opus).
  Future<ChatMessage> sendVoiceNote(ChatTarget target, List<int> audio, {required String nonce, String format});

  /// Tells the chat the user is recording a voice note.
  Future<void> sendRecording(ChatTarget target);

  /// The largest file the user may upload, in bytes; null when unknown.
  Future<int?> uploadLimit();

  /// Messages matching [query], the newest first.
  Future<List<SearchHit>> search(SearchQuery query);

  /// The chat's pinned messages, the last pinned first.
  Future<List<ChatMessage>> pins(ChatTarget target);

  /// Pins a message, or unpins it.
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

  /// Makes an account, then signs in to it; the API emails a link to verify
  /// the address.
  Future<void> signUp({required String username, required String email, required String password, String? alias});
  Future<void> sendVerificationEmail();

  /// Verifies the email with the token from the emailed link.
  Future<void> verifyEmail(String token);

  /// Emails a link to reset the password of the account using [email].
  Future<void> forgotPassword(String email);
  Future<void> resetPassword(String token, String password);

  /// Emails a link to [email] to move the account there.
  Future<void> sendChangeEmail(String email);
  Future<void> changeEmail(String token, String email);

  /// The user's display name: empty clears it, back to the username. A [bio]
  /// replaces theirs (empty clears it); left out, it stays.
  Future<void> updateProfile({required String alias, String? bio});

  /// Chooses the user's status, [Presence.online] or
  /// [Presence.doNotDisturb]: what others see while they're connected.
  Future<void> setStatus(Presence status);

  /// A new avatar or banner: [crop] of the picture at [path].
  Future<void> uploadProfileImage(ProfileImage kind, String path, CropRect crop);

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
  Future<void> updateSpace(String spaceId, {String? name, String? description, String? iconPath, String? bannerPath});

  /// Rooms and categories, by position.
  List<AdminRoom> adminRooms(String spaceId);
  Future<void> createRoom(String spaceId, String name, AdminRoomKind kind, {String? parentId});
  Future<void> renameRoom(String spaceId, String roomId, String name);
  Future<void> deleteRoom(String spaceId, String roomId);

  /// Moves a room to [position] among its category's (or the Space's) rooms.
  Future<void> moveRoom(String spaceId, String roomId, int position);
  List<RoomOverwrite> overwrites(String spaceId, String roomId);

  /// Saves an overwrite; an empty one is removed.
  Future<void> setOverwrite(String spaceId, String roomId, RoomOverwrite overwrite);

  /// Roles, highest first, @everyone last.
  List<SpaceRole> roles(String spaceId);
  Future<SpaceRole> createRole(String spaceId, String name);
  Future<void> updateRole(
    String spaceId,
    String roleId, {
    String? name,
    int? color,
    bool clearColor = false,
    int? perms,
  });
  Future<void> deleteRole(String spaceId, String roleId);
  List<String> roleMembers(String spaceId, String roleId);
  Future<void> setRole(String spaceId, String roleId, String userId, {required bool has});

  Future<List<SpaceInvite>> spaceInvites(String spaceId);
  Future<void> revokeInvite(String spaceId, String inviteId);

  Future<List<SpaceAsset>> assets(String spaceId, AssetKind kind);
  Future<void> addAsset(String spaceId, AssetKind kind, String name, String path);
  Future<void> renameAsset(String spaceId, AssetKind kind, String id, String name);
  Future<void> deleteAsset(String spaceId, AssetKind kind, String id);

  Future<List<SpaceWebhook>> webhooks(String spaceId);

  /// Answers the new webhook's URL: shown once, never again.
  Future<String> createWebhook(String spaceId, String roomId, String name);
  Future<String> resetWebhook(String spaceId, SpaceWebhook webhook);
  Future<void> deleteWebhook(String spaceId, SpaceWebhook webhook);

  Future<SpaceStorage> spaceStorage(String spaceId);

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

  /// The Space's roles, highest first: for role selects and options.
  List<({String id, String name})> spaceRoles(String spaceId);

  /// What an invite code leads to.
  Future<InvitePreview> invite(String code);

  /// Joins the Space an invite leads to; answers its ID.
  Future<String> joinInvite(String code);

  /// Replaces the text of the user's own message.
  Future<ChatMessage> edit(ChatTarget target, String messageId, String content);

  /// Deletes the user's own message, for everyone.
  Future<void> delete(ChatTarget target, String messageId);

  /// Adds the user's reaction [emoji] (a custom one's name, with [emojiId]) to
  /// a message, or takes it back.
  Future<void> react(ChatTarget target, String messageId, String emoji, {required bool add, String? emojiId});

  /// One message, e.g. the original of a reply that isn't loaded.
  Future<ChatMessage> fetchMessage(ChatTarget target, String messageId);

  /// The messages after [messageId], the oldest first: what was missed while
  /// the socket was down.
  Future<List<ChatMessage>> messagesAfter(ChatTarget target, String messageId);

  /// Unread mentions of the user, by chat ID.
  ValueListenable<Map<String, int>> get mentions;

  /// The last message the user read in a room, as the server knows it; null
  /// when it doesn't (and in conversations).
  String? lastReadOf(ChatTarget target);

  /// Fires when the gateway is back after a drop: chats fetch what they missed.
  Stream<void> get resumed;

  /// What's unsent per chat, by chat ID; kept for the session.
  Map<String, ChatDraft> get drafts;

  /// Who's in the chat: the room's space, or the conversation. Cached; [refresh]
  /// fetches again.
  Future<List<Member>> members(ChatTarget target, {bool refresh = false});

  /// A user's name, if any list or message seen this session gave it.
  String? nameOf(String userId);

  /// A custom emoji's name, if its space's emoji were loaded.
  String? emojiNameOf(String emojiId);

  /// Who's online, by user ID, as the gateway reports it; someone missing
  /// hasn't been reported this session.
  ValueListenable<Map<String, Presence>> get presence;

  /// The emoji the chat can use beyond Unicode's: its space's. None in DMs.
  Future<List<CustomEmoji>> customEmojis(ChatTarget target);

  /// The stickers the chat can send: its space's. None in DMs.
  Future<List<Sticker>> stickers(ChatTarget target);

  /// The DM with [userId], opened if there was none.
  Future<ConversationSummary> directMessage(String userId);

  Future<void> sendTyping(ChatTarget target);

  /// Records that the chat was opened, showing [latest] as its newest message.
  void opened(ChatTarget target, String title, {ChatMessage? latest});

  /// Marks the chat read up to [messageId].
  void markRead(ChatTarget target, String messageId);

  void dispose();
}
