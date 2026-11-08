import 'dart:async';

import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/recent_chats.dart' as recent show previewOf;
import 'package:duvet/data/repository.dart';
import 'package:flutter/foundation.dart';

import 'fake_voice.dart';

/// An in-memory [ChatRepository]: the shell's old sample data, and hooks for
/// tests to push what the gateway would.
class FakeRepository implements ChatRepository {
  // UUID-shaped, as mentions are written.
  static const me = Profile(id: '0a0a0a0a-0000-4000-8000-000000000001', username: 'gaby', alias: 'Gaby');
  static const maya = '0a0a0a0a-0000-4000-8000-000000000002';
  static const leo = '0a0a0a0a-0000-4000-8000-000000000003';

  static const party = CustomEmoji(
    id: '0e0e0e0e-0000-4000-8000-000000000001',
    name: 'party',
    url: 'https://example.invalid/party.png',
  );
  static const wave = Sticker(
    id: '05050505-0000-4000-8000-000000000001',
    name: 'wave',
    attachmentId: '05050505-0000-4000-8000-0000000000aa',
    url: 'https://example.invalid/wave.png',
  );
  static const everyone = [
    Member(userId: '0a0a0a0a-0000-4000-8000-000000000001', username: 'gaby', alias: 'Gaby'),
    Member(userId: maya, username: 'maya', alias: 'Maya'),
    Member(userId: leo, username: 'leo'),
  ];

  final bool signedIn;
  final String password;
  FakeRepository({this.signedIn = true, this.password = 'secret'});

  @override
  final ValueNotifier<Profile?> profile = ValueNotifier(null);
  @override
  final ValueNotifier<List<Space>> spaces = ValueNotifier(const []);
  @override
  final ValueNotifier<List<ConversationSummary>> conversations = ValueNotifier(const []);
  @override
  final ValueNotifier<Set<String>> unread = ValueNotifier(const {});
  @override
  final ValueNotifier<Set<String>> collapsedCategories = ValueNotifier(const {});

  @override
  void setCategoryCollapsed(String categoryId, bool collapsed) => collapsedCategories.value = {
    for (final id in collapsedCategories.value)
      if (id != categoryId) id,
    if (collapsed) categoryId,
  };
  final recentChats = RecentChats(MemoryRecentChatsStore());
  @override
  ValueListenable<List<RecentChat>> get recents => recentChats.chats;
  @override
  final ValueNotifier<LiveStatus> status = ValueNotifier(LiveStatus.offline);

  /// The gateway's voice side: tests push its events and read what went out.
  @override
  final FakeVoiceSignaling voiceSignaling = FakeVoiceSignaling();
  @override
  final ValueNotifier<Map<String, ChatMessage>> latest = ValueNotifier(const {});
  @override
  final ValueNotifier<Map<String, List<TypingUser>>> typingNow = ValueNotifier(const {});
  @override
  final ValueNotifier<Map<String, int>> mentions = ValueNotifier(const {});
  @override
  final drafts = <String, ChatDraft>{};
  final lastRead = <String, String>{};
  final _resumed = StreamController<void>.broadcast();
  final edits = <(String, String)>[];
  final deletes = <String>[];
  final reactions = <(String, String, bool)>[];

  /// Fails sends while set.
  bool failSends = false;

  /// The server refuses files as too large while set.
  bool tooLarge = false;

  /// The upload limit [uploadLimit] answers.
  int? limit;
  bool cancelled = false;

  /// Reports the last upload's progress, as the client would.
  void Function(double progress)? lastUpload;
  final voiceNotes = <(List<int>, String)>[];
  final recordings = <ChatTarget>[];
  final joined = <String>[];
  final invites = <String, InvitePreview>{};

  @override
  Future<ChatMessage> sendVoiceNote(
    ChatTarget target,
    List<int> audio, {
    required String nonce,
    String format = 'ogg',
  }) async {
    voiceNotes.add((audio, format));
    return ChatMessage(
      id: 'voice-${voiceNotes.length}',
      authorId: me.id,
      authorName: me.displayName,
      content: '',
      createdAt: DateTime(2026, 10, 23, 9, 30),
      nonce: nonce,
      isVoice: true,
      attachments: [
        MessageAttachment(
          id: 'v${voiceNotes.length}',
          filename: 'voice-note.$format',
          contentType: 'audio/$format',
          url: 'https://example.invalid/voice.$format',
        ),
      ],
    );
  }

  @override
  Future<void> sendRecording(ChatTarget target) async => recordings.add(target);

  @override
  Future<int?> uploadLimit() async => limit;

  final searches = <SearchQuery>[];
  final pinned = <String, List<ChatMessage>>{};
  final pinChanges = <(String, bool)>[];
  final threads = <String, List<ChatMessage>>{};

  @override
  Future<List<SearchHit>> search(SearchQuery query) async {
    searches.add(query);
    final q = query.text.toLowerCase();
    return [
      for (final MapEntry(:key, :value) in history.entries)
        if ((query.conversationId == null || query.conversationId == key) &&
            (query.roomId == null || query.roomId == key) &&
            (query.spaceId == null || key.startsWith('r-')) &&
            !(query.spaceId == null && query.conversationId == null))
          for (final m in value.reversed)
            if (m.content.toLowerCase().contains(q))
              SearchHit(
                target: key.startsWith('c-') ? ConversationTarget(key) : RoomTarget(spaceId: 's-guild', roomId: key),
                message: m,
              ),
    ];
  }

  @override
  Future<List<ChatMessage>> pins(ChatTarget target) async => [...?pinned[target.id]];

  @override
  Future<void> pin(ChatTarget target, String messageId, {required bool pinned}) async =>
      pinChanges.add((messageId, pinned));

  @override
  Future<List<ChatMessage>> thread(ChatTarget target, String messageId) async => [...?threads[messageId]];

  @override
  List<Member> people = everyone;

  final created = <(String, String?, String?)>[];
  final left = <String>[];
  final invitesMade = <(String, Duration?)>[];

  @override
  Future<String> createSpace(String name, {String? description, String? iconPath}) async {
    created.add((name, description, iconPath));
    _refuse('createSpace');
    return 's-new';
  }

  final deletedSpaces = <String>[];

  @override
  Future<void> deleteSpace(String spaceId) async {
    deletedSpaces.add(spaceId);
    spaces.value = spaces.value.where((s) => s.id != spaceId).toList();
  }

  @override
  Future<void> leaveSpace(String spaceId) async {
    left.add(spaceId);
    spaces.value = spaces.value.where((s) => s.id != spaceId).toList();
  }

  /// How many invites fail before one works.
  int inviteFailures = 0;

  /// While set, new invites wait for it: a link on its way.
  Completer<void>? holdInvites;

  @override
  Future<String> createInvite(String spaceId, String roomId, {Duration? maxAge}) async {
    invitesMade.add((roomId, maxAge));
    await holdInvites?.future;
    if (inviteFailures > 0) {
      inviteFailures--;
      throw const ActionFailed('You can’t invite people to #general');
    }
    return 'https://duvet.chat/invite?code=k7Qe2m';
  }

  @override
  void markSpaceRead(String spaceId) {
    final rooms = {for (final s in spaces.value.where((s) => s.id == spaceId)) ...s.rooms.map((r) => r.id)};
    unread.value = unread.value.difference(rooms);
  }

  @override
  final ValueNotifier<Friends> friends = ValueNotifier(Friends.none);
  final friendCalls = <String>[];
  Friends friendsOnServer = Friends.none;
  final roleTags = <String, List<RoleTag>>{};
  final conversationCalls = <String>[];

  @override
  Future<void> loadFriends() async {
    await Future<void>.value();
    friends.value = friendsOnServer;
  }

  @override
  Future<void> sendFriendRequest(String userId) async => friendCalls.add('send $userId');

  @override
  Future<void> acceptFriendRequest(String requestId) async => friendCalls.add('accept $requestId');

  @override
  Future<void> rejectFriendRequest(String requestId) async => friendCalls.add('reject $requestId');

  @override
  Future<void> unfriend(String userId) async => friendCalls.add('unfriend $userId');

  @override
  List<RoleTag> rolesOf(String spaceId, String userId) => roleTags[userId] ?? const [];

  /// Who's in each Space, by its ID.
  final spaceMembers = <String, Set<String>>{};

  @override
  bool isMember(String spaceId, String userId) => spaceMembers[spaceId]?.contains(userId) ?? false;

  /// Why the server refuses to make or change a group, if it does.
  String? conversationRefused;

  @override
  Future<ConversationSummary> createGroup(String name, List<String> userIds) async {
    if (conversationRefused != null) throw ActionFailed(conversationRefused!);
    conversationCalls.add('group $name ${userIds.join(',')}');
    const group = ConversationSummary(id: 'c-new', title: 'New group', isGroup: true, memberCount: 3);
    conversations.value = [group, ...conversations.value];
    return group;
  }

  @override
  Future<void> renameConversation(String conversationId, String name) async =>
      conversationCalls.add('rename $conversationId $name');

  @override
  Future<void> addToConversation(String conversationId, String userId) async {
    if (conversationRefused != null) throw ActionFailed(conversationRefused!);
    conversationCalls.add('add $conversationId $userId');
  }

  @override
  Future<void> removeFromConversation(String conversationId, String userId) async =>
      conversationCalls.add('remove $conversationId $userId');

  @override
  Future<void> leaveConversation(String conversationId) async {
    conversationCalls.add('leave $conversationId');
    conversations.value = conversations.value.where((c) => c.id != conversationId).toList();
  }

  final account = <String>[];
  List<MyFile> files = [];
  StorageInfo usage = const StorageInfo(used: 0, max: 5 * 1024 * 1024 * 1024);

  @override
  Future<void> signUp({
    required String username,
    required String email,
    required String password,
    String? alias,
  }) async {
    account.add('signup $username $email');
    _seed();
    profile.value = Profile(id: me.id, username: username, alias: alias, emailVerified: false);
  }

  @override
  Future<void> sendVerificationEmail() async => account.add('send verification');

  @override
  Future<void> verifyEmail(String token) async {
    account.add('verify $token');
    if (profile.value case final p?) {
      profile.value = Profile(id: p.id, username: p.username, alias: p.alias, emailVerified: true);
    }
  }

  @override
  Future<void> forgotPassword(String email) async {
    if (!email.contains('@')) throw Exception('no account');
    account.add('forgot $email');
  }

  @override
  Future<void> resetPassword(String token, String password) async => account.add('reset $token');

  @override
  Future<void> sendChangeEmail(String email) async => account.add('change-send $email');

  @override
  Future<void> changeEmail(String token, String email) async => account.add('change $token $email');

  /// Why the server refuses a profile change or a picture, if it does.
  String? profileRefused;
  String? pictureRefused;

  @override
  Future<void> updateProfile({required String alias, String? bio}) async {
    if (profileRefused != null) throw ActionFailed(profileRefused!);
    account.add('alias $alias');
    if (bio != null) account.add('bio $bio');
    final p = profile.value!;
    profile.value = Profile(
      id: p.id,
      username: p.username,
      alias: alias.isEmpty ? null : alias,
      bio: bio == null ? p.bio : (bio.trim().isEmpty ? null : bio.trim()),
      status: p.status,
    );
  }

  /// Why the server refuses a status, if it does.
  String? statusRefused;

  /// Completes status changes when set; otherwise they answer at once.
  Completer<void>? holdStatus;

  @override
  Future<void> setStatus(Presence status) async {
    account.add('status ${status.name}');
    await holdStatus?.future;
    if (statusRefused != null) throw ActionFailed(statusRefused!);
    profile.value = profile.value!.withStatus(status);
  }

  @override
  Future<void> uploadProfileImage(ProfileImage kind, String path, {void Function(double progress)? onProgress}) async {
    await _upload(onProgress);
    if (pictureRefused != null) throw ActionFailed(pictureRefused!);
    account.add('${kind.name} $path');
  }

  @override
  Future<void> removeProfileImage(ProfileImage kind) async {
    if (pictureRefused != null) throw ActionFailed(pictureRefused!);
    account.add('remove ${kind.name}');
    final p = profile.value!;
    profile.value = Profile(
      id: p.id,
      username: p.username,
      alias: p.alias,
      avatarUrl: kind == ProfileImage.avatar ? null : p.avatarUrl,
      bannerUrl: kind == ProfileImage.banner ? null : p.bannerUrl,
      bio: p.bio,
      emailVerified: p.emailVerified,
      status: p.status,
    );
  }

  /// Held, an upload waits on it, its progress in [lastUpload].
  Completer<void>? holdUploads;

  Future<void> _upload(void Function(double progress)? onProgress) async {
    if (onProgress == null) return;
    onProgress(0);
    lastUpload = onProgress;
    await holdUploads?.future;
  }

  @override
  Future<List<MyFile>> myFiles() async => [...files];

  @override
  Future<void> deleteMyFile(String id) async {
    account.add('delete $id');
    files.removeWhere((f) => f.id == id);
  }

  @override
  Future<StorageInfo> storage() async => usage;

  // Running a Space: what the admin screens did, in order.
  final admin = <String>[];

  /// Why the server refuses a call, by the method's name, as the real
  /// repository says it (the API's reason).
  final refusals = <String, String>{};
  void _refuse(String call) {
    if (refusals[call] case final why?) throw ActionFailed(why);
  }

  int spacePerms = Perm.all;
  bool spaceOwner = true;
  final adminRoomList = <String, List<AdminRoom>>{};
  final roleList = <String, List<SpaceRole>>{};
  final roleHolders = <String, Set<String>>{};
  final overwriteList = <String, List<RoomOverwrite>>{};
  List<SpaceInvite> inviteList = [];
  final assetList = <AssetKind, List<SpaceAsset>>{AssetKind.emoji: [], AssetKind.sticker: []};
  List<SpaceWebhook> webhookList = [];
  SpaceStorage storageOfSpace = const SpaceStorage(used: 0);

  /// Rooms the user can't invite to.
  final noInvites = <String>{};

  /// Voice rooms the user can't join, or can't speak in.
  final noJoin = <String>{};
  final noSpeak = <String>{};

  /// Permissions the user lacks in a room, by room ID.
  final deniedInRoom = <String, int>{};

  /// What [spaceProfile] says of ManageChannels in some room.
  bool managesRooms = false;

  @override
  bool canInRoom(String spaceId, String roomId, int bit) => switch (bit) {
    _ when (deniedInRoom[roomId] ?? 0) & bit != 0 => false,
    Perm.createInvites => !noInvites.contains(roomId),
    Perm.joinVoice => !noJoin.contains(roomId),
    Perm.speakInVoice => !noSpeak.contains(roomId),
    _ => true,
  };

  @override
  SpaceProfile? spaceProfile(String spaceId) {
    final space = spaces.value.where((s) => s.id == spaceId).firstOrNull;
    if (space == null) return null;
    return SpaceProfile(
      id: space.id,
      name: space.name,
      iconUrl: space.iconUrl,
      bannerUrl: space.bannerUrl,
      memberCount: everyone.length,
      owner: spaceOwner,
      perms: spacePerms,
      managesRooms: managesRooms,
    );
  }

  @override
  Future<void> updateSpace(
    String spaceId, {
    String? name,
    String? description,
    String? iconPath,
    String? bannerPath,
    bool removeBanner = false,
    bool removeIcon = false,
    void Function(double progress)? onProgress,
  }) async {
    if (iconPath != null || bannerPath != null) await _upload(onProgress);
    admin.add(
      'space ${[if (name != null) 'name=$name', if (description != null) 'about=$description', if (iconPath != null) 'icon=$iconPath', if (removeIcon && iconPath == null) 'icon=none', if (bannerPath != null) 'banner=$bannerPath', if (removeBanner && bannerPath == null) 'banner=none'].join(' ')}',
    );
    if (name != null || iconPath != null || bannerPath != null || removeBanner || removeIcon) {
      spaces.value = [
        for (final s in spaces.value)
          s.id == spaceId
              ? Space(
                  id: s.id,
                  name: name ?? s.name,
                  iconUrl: iconPath != null
                      ? 'https://example.invalid/icon.png'
                      : removeIcon
                      ? null
                      : s.iconUrl,
                  sections: s.sections,
                  onlineCount: s.onlineCount,
                  ownerId: s.ownerId,
                  // As SPACE_UPDATE brings it: an uploaded banner, or none.
                  bannerUrl: bannerPath != null
                      ? 'https://example.invalid/banner.png'
                      : removeBanner
                      ? null
                      : s.bannerUrl,
                )
              : s,
      ];
    }
  }

  @override
  List<AdminRoom> adminRooms(String spaceId) => adminRoomList[spaceId] ??= [
    for (final section in spaces.value.where((s) => s.id == spaceId).firstOrNull?.sections ?? const <RoomSection>[])
      for (final r in section.rooms)
        AdminRoom(
          id: r.id,
          name: r.name,
          kind: r.kind == RoomKind.voice ? AdminRoomKind.voice : AdminRoomKind.text,
          position: r.position,
          description: r.description,
        ),
  ];

  /// [roomId] in the Spaces as [change] leaves it (null: gone), as the
  /// gateway's ROOM_UPDATE or ROOM_DELETE would: the chat reads its room there.
  void _editRoom(String spaceId, String roomId, Room? Function(Room room) change) => spaces.value = [
    for (final s in spaces.value)
      s.id != spaceId
          ? s
          : Space(
              id: s.id,
              name: s.name,
              iconUrl: s.iconUrl,
              onlineCount: s.onlineCount,
              bannerUrl: s.bannerUrl,
              ownerId: s.ownerId,
              sections: [
                for (final section in s.sections)
                  RoomSection(
                    id: section.id,
                    name: section.name,
                    rooms: [
                      for (final r in section.rooms)
                        if (r.id != roomId) r else ?change(r),
                    ],
                  ),
              ],
            ),
  ];

  @override
  Future<void> createRoom(String spaceId, String name, AdminRoomKind kind, {String? parentId}) async {
    admin.add('room+ $name ${kind.name}');
    final rooms = adminRooms(spaceId);
    rooms.add(AdminRoom(id: 'r-$name', name: name, kind: kind, parentId: parentId, position: rooms.length));
  }

  @override
  Future<void> renameRoom(String spaceId, String roomId, String name) async {
    admin.add('room~ $roomId $name');
    final rooms = adminRooms(spaceId);
    final i = rooms.indexWhere((r) => r.id == roomId);
    rooms[i] = AdminRoom(
      id: roomId,
      name: name,
      kind: rooms[i].kind,
      parentId: rooms[i].parentId,
      position: rooms[i].position,
      description: rooms[i].description,
    );
    _editRoom(
      spaceId,
      roomId,
      (r) => Room(
        id: r.id,
        spaceId: r.spaceId,
        name: name,
        kind: r.kind,
        position: r.position,
        description: r.description,
      ),
    );
  }

  @override
  Future<void> setRoomDescription(String spaceId, String roomId, String? description) async {
    final text = description == null || description.trim().isEmpty ? null : description.trim();
    admin.add('room¶ $roomId ${text ?? '-'}');
    final rooms = adminRooms(spaceId);
    final i = rooms.indexWhere((r) => r.id == roomId);
    rooms[i] = AdminRoom(
      id: roomId,
      name: rooms[i].name,
      kind: rooms[i].kind,
      parentId: rooms[i].parentId,
      position: rooms[i].position,
      description: text,
    );
    _editRoom(
      spaceId,
      roomId,
      (r) => Room(id: r.id, spaceId: r.spaceId, name: r.name, kind: r.kind, position: r.position, description: text),
    );
  }

  @override
  Future<void> deleteRoom(String spaceId, String roomId) async {
    admin.add('room- $roomId');
    adminRooms(spaceId).removeWhere((r) => r.id == roomId);
    _editRoom(spaceId, roomId, (_) => null);
  }

  @override
  Future<void> moveRoom(String spaceId, String roomId, {String? parentId, required int position}) async {
    admin.add('room> $roomId ${parentId ?? '-'} $position');
    // As the API does: out of the old place, then in before [position].
    final rooms = adminRooms(spaceId);
    final moved = rooms.firstWhere((r) => r.id == roomId);
    final to = moved.kind == AdminRoomKind.category ? null : parentId;
    var at = position;
    if (moved.parentId == to && at > moved.position) at--;
    for (final (i, r) in rooms.indexed.toList()) {
      var p = r.position;
      if (r.id == roomId) {
        p = at;
      } else {
        if (r.parentId == moved.parentId && p > moved.position) p--;
        if (r.parentId == to && p >= at) p++;
      }
      rooms[i] = AdminRoom(
        id: r.id,
        name: r.name,
        kind: r.kind,
        parentId: r.id == roomId ? to : r.parentId,
        position: p,
        description: r.description,
      );
    }
    rooms.sort((a, b) => a.position.compareTo(b.position));
  }

  @override
  List<RoomOverwrite> overwrites(String spaceId, String roomId) => [...?overwriteList[roomId]];

  @override
  Future<void> setOverwrite(String spaceId, String roomId, RoomOverwrite overwrite) async {
    admin.add('overwrite $roomId ${overwrite.targetId} +${overwrite.allow} -${overwrite.deny}');
    final list = overwriteList[roomId] ??= [];
    list.removeWhere((o) => o.targetId == overwrite.targetId);
    if (!overwrite.isEmpty) list.add(overwrite);
  }

  @override
  List<SpaceRole> roles(String spaceId) => [
    for (final r in roleList[spaceId] ??= [
      const SpaceRole(
        id: 'role-mod',
        name: 'Moderator',
        color: 0x30A46C,
        perms: Perm.pinMessages | Perm.manageMessages,
        position: 2,
      ),
      SpaceRole(id: spaceId, name: '@everyone', perms: Perm.viewChannels | Perm.sendMessages, everyone: true),
    ])
      SpaceRole(
        id: r.id,
        name: r.name,
        color: r.color,
        colorVia: r.colorVia,
        colorTo: r.colorTo,
        perms: r.perms,
        position: r.position,
        everyone: r.everyone,
        memberCount: r.everyone ? everyone.length : roleMembers(spaceId, r.id).length,
      ),
  ];

  @override
  Future<SpaceRole> createRole(String spaceId, String name) async {
    admin.add('role+ $name');
    _refuse('createRole');
    roles(spaceId);
    final role = SpaceRole(id: 'role-$name', name: name, position: 1);
    roleList[spaceId]!.insert(roleList[spaceId]!.length - 1, role);
    return role;
  }

  @override
  Future<void> updateRole(
    String spaceId,
    String roleId, {
    String? name,
    RoleColors? colors,
    int? perms,
    bool? hoisted,
  }) async {
    String hex(int c) => c.toRadixString(16);
    admin.add(
      'role~ $roleId ${[
        if (name != null) 'name=$name',
        if (colors != null) colors.from == null ? 'nocolor' : 'color=${[colors.from, colors.via, colors.to].nonNulls.map(hex).join('..')}',
        if (perms != null) 'perms=$perms',
        if (hoisted != null) 'hoisted=$hoisted',
      ].join(' ')}',
    );
    roles(spaceId);
    final list = roleList[spaceId]!;
    final i = list.indexWhere((r) => r.id == roleId);
    final r = list[i];
    list[i] = SpaceRole(
      id: r.id,
      name: name ?? r.name,
      color: colors == null ? r.color : colors.from,
      colorVia: colors == null ? r.colorVia : colors.via,
      colorTo: colors == null ? r.colorTo : colors.to,
      perms: perms ?? r.perms,
      position: r.position,
      everyone: r.everyone,
      hoisted: hoisted ?? r.hoisted,
    );
  }

  @override
  Future<void> moveRole(String spaceId, String roleId, int position) async {
    admin.add('role^ $roleId $position');
    roles(spaceId);
    final list = roleList[spaceId]!;
    final from = list.firstWhere((r) => r.id == roleId).position;
    // As the API: clamped above @everyone, the roles between shifted one place.
    final to = position.clamp(1, list.length - 1);
    SpaceRole at(SpaceRole r, int position) => SpaceRole(
      id: r.id,
      name: r.name,
      color: r.color,
      colorVia: r.colorVia,
      colorTo: r.colorTo,
      perms: r.perms,
      position: position,
      everyone: r.everyone,
      hoisted: r.hoisted,
    );
    for (final (i, r) in list.indexed) {
      if (r.id == roleId) {
        list[i] = at(r, to);
      } else if (!r.everyone && to > from && r.position > from && r.position <= to) {
        list[i] = at(r, r.position - 1);
      } else if (!r.everyone && to < from && r.position >= to && r.position < from) {
        list[i] = at(r, r.position + 1);
      }
    }
    list.sort((a, b) => a.everyone != b.everyone ? (a.everyone ? 1 : -1) : b.position.compareTo(a.position));
  }

  @override
  Future<void> deleteRole(String spaceId, String roleId) async {
    admin.add('role- $roleId');
    roleList[spaceId]?.removeWhere((r) => r.id == roleId);
  }

  @override
  List<String> roleMembers(String spaceId, String roleId) => [...?roleHolders[roleId]];

  @override
  Future<void> setRole(String spaceId, String roleId, String userId, {required bool has}) async {
    admin.add('${has ? 'give' : 'take'} $roleId ${nameOf(userId)}');
    final holders = roleHolders[roleId] ??= {};
    has ? holders.add(userId) : holders.remove(userId);
    // As the real one: their roles change, and the Space's listeners hear.
    final role = roles(spaceId).where((r) => r.id == roleId).firstOrNull;
    final tags = [...?roleTags[userId]]..removeWhere((t) => t.id == roleId);
    if (has && role != null) tags.add(RoleTag(role.name, color: role.color, id: role.id, position: role.position));
    roleTags[userId] = tags..sort((a, b) => b.position.compareTo(a.position));
    spaces.value = [...spaces.value];
  }

  @override
  Future<List<SpaceInvite>> spaceInvites(String spaceId) async => [...inviteList];

  @override
  Future<void> revokeInvite(String spaceId, String inviteId) async {
    admin.add('revoke $inviteId');
    inviteList = inviteList.where((i) => i.id != inviteId).toList();
  }

  @override
  Future<List<SpaceAsset>> assets(String spaceId, AssetKind kind) async => [...assetList[kind]!];

  @override
  Future<void> addAsset(
    String spaceId,
    AssetKind kind,
    String name,
    String path, {
    void Function(double progress)? onProgress,
  }) async {
    await _upload(onProgress);
    admin.add('${kind.name}+ $name $path');
    assetList[kind]!.add(SpaceAsset(id: '${kind.name}-$name', name: name, url: 'https://x/$name.png'));
  }

  @override
  Future<void> renameAsset(String spaceId, AssetKind kind, String id, String name) async {
    admin.add('${kind.name}~ $id $name');
    final list = assetList[kind]!;
    final i = list.indexWhere((a) => a.id == id);
    list[i] = SpaceAsset(id: id, name: name, url: list[i].url);
  }

  @override
  Future<void> deleteAsset(String spaceId, AssetKind kind, String id) async {
    admin.add('${kind.name}- $id');
    assetList[kind]!.removeWhere((a) => a.id == id);
  }

  @override
  Future<List<SpaceWebhook>> webhooks(String spaceId) async => [...webhookList];

  @override
  Future<String> createWebhook(String spaceId, String roomId, String name) async {
    admin.add('hook+ $roomId $name');
    _refuse('createWebhook');
    webhookList = [
      ...webhookList,
      SpaceWebhook(id: 'w-$name', roomId: roomId, roomName: 'general', name: name, createdAt: DateTime(2026, 10, 23)),
    ];
    return 'https://api.duvet.chat/api/webhooks/w-$name/secret';
  }

  @override
  Future<String> resetWebhook(String spaceId, SpaceWebhook webhook) async {
    admin.add('hook~ ${webhook.id}');
    _refuse('resetWebhook');
    return 'https://api.duvet.chat/api/webhooks/${webhook.id}/fresh';
  }

  @override
  Future<void> updateWebhook(
    String spaceId,
    SpaceWebhook webhook, {
    String? name,
    String? avatarPath,
    bool removeAvatar = false,
  }) async {
    admin.add(
      'hook* ${webhook.id} ${[if (name != null) 'name=$name', if (avatarPath != null) 'avatar', if (removeAvatar) 'noavatar'].join(' ')}',
    );
    webhookList = [
      for (final w in webhookList)
        w.id != webhook.id
            ? w
            : SpaceWebhook(
                id: w.id,
                roomId: w.roomId,
                roomName: w.roomName,
                name: name ?? w.name,
                createdAt: w.createdAt,
                avatarUrl: removeAvatar
                    ? null
                    : (avatarPath == null ? w.avatarUrl : 'https://example.invalid/hook.png'),
              ),
    ];
  }

  @override
  Future<void> deleteWebhook(String spaceId, SpaceWebhook webhook) async {
    admin.add('hook- ${webhook.id}');
    webhookList = webhookList.where((w) => w.id != webhook.id).toList();
  }

  @override
  Future<SpaceStorage> spaceStorage(String spaceId) async => storageOfSpace;

  // The developer portal: teams, their members and apps, by team ID, and the
  // bots' profiles by user ID. Changes go in [admin].
  @override
  final ValueNotifier<List<TeamInvite>> teamInvites = ValueNotifier(const []);
  List<DevTeam> teamList = [];
  final teamMemberList = <String, List<Member>>{};
  final appList = <String, List<DevApp>>{};
  final botList = <String, Member>{};

  void _dropTeamInvite(String id) => teamInvites.value = teamInvites.value.where((i) => i.id != id).toList();

  @override
  Future<void> acceptTeamInvite(String inviteId) async {
    admin.add('team accept $inviteId');
    _refuse('acceptTeamInvite');
    _dropTeamInvite(inviteId);
  }

  @override
  Future<void> declineTeamInvite(String inviteId) async {
    admin.add('team decline $inviteId');
    _dropTeamInvite(inviteId);
  }

  @override
  Future<List<DevTeam>> teams() async => [...teamList];

  @override
  Future<DevTeam> createTeam(String name) async {
    admin.add('team+ $name');
    _refuse('createTeam');
    final team = DevTeam(id: 't-$name', name: name, ownerId: me.id);
    teamList = [...teamList, team];
    teamMemberList[team.id] = [everyone.first];
    return team;
  }

  @override
  Future<void> renameTeam(String teamId, String name) async {
    admin.add('team* $teamId $name');
    teamList = [for (final t in teamList) t.id == teamId ? DevTeam(id: t.id, name: name, ownerId: t.ownerId) : t];
  }

  @override
  Future<void> deleteTeam(String teamId) async {
    admin.add('team- $teamId');
    teamList = teamList.where((t) => t.id != teamId).toList();
  }

  @override
  Future<List<Member>> teamMembers(String teamId) async => [...?teamMemberList[teamId]];

  @override
  Future<void> inviteToTeam(String teamId, String email) async {
    admin.add('team invite $teamId $email');
    _refuse('inviteToTeam');
  }

  @override
  Future<void> removeTeamMember(String teamId, String userId) async {
    admin.add('team kick $teamId $userId');
    teamMemberList[teamId]?.removeWhere((m) => m.userId == userId);
  }

  @override
  Future<List<DevApp>> applications(String teamId) async => [...?appList[teamId]];

  DevApp _replaceApp(DevApp app) {
    appList[app.teamId] = [for (final a in appList[app.teamId] ?? <DevApp>[]) a.id == app.id ? app : a];
    return app;
  }

  @override
  Future<DevApp> createApplication(String teamId, String name, {String? description}) async {
    admin.add('app+ $teamId $name');
    _refuse('createApplication');
    final app = DevApp(id: 'a-$name', teamId: teamId, name: name, description: description);
    appList[teamId] = [...?appList[teamId], app];
    return app;
  }

  @override
  Future<DevApp> updateApplication(DevApp app, {String? name, String? description, bool? public}) async {
    admin.add(
      'app* ${app.id} ${[if (name != null) 'name=$name', if (description != null) 'description=$description', if (public != null) 'public=$public'].join(' ')}',
    );
    return _replaceApp(
      DevApp(
        id: app.id,
        teamId: app.teamId,
        name: name ?? app.name,
        description: description ?? app.description,
        public: public ?? app.public,
        botUserId: app.botUserId,
      ),
    );
  }

  @override
  Future<void> deleteApplication(DevApp app) async {
    admin.add('app- ${app.id}');
    appList[app.teamId]?.removeWhere((a) => a.id == app.id);
  }

  /// Each application's commands, by its ID.
  final appCommandList = <String, List<BotCommand>>{};
  int _commandIds = 0;

  @override
  Future<List<BotCommand>> appCommands(DevApp app) async =>
      [...?appCommandList[app.id]]..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<BotCommand> saveAppCommand(DevApp app, BotCommand command) async {
    _refuse('saveAppCommand');
    final saved = BotCommand(
      id: command.id.isEmpty ? 'cmd-${++_commandIds}' : command.id,
      applicationId: app.id,
      appName: app.name,
      name: command.name,
      description: command.description,
      options: command.options,
    );
    admin.add('${command.id.isEmpty ? 'command+' : 'command'} ${saved.name}');
    final list = appCommandList[app.id] ??= [];
    list
      ..removeWhere((c) => c.id == saved.id)
      ..add(saved);
    return saved;
  }

  @override
  Future<void> deleteAppCommand(DevApp app, String commandId) async {
    _refuse('deleteAppCommand');
    admin.add('command- $commandId');
    appCommandList[app.id]?.removeWhere((c) => c.id == commandId);
  }

  @override
  Future<String> createBot(DevApp app) async {
    admin.add('bot+ ${app.id}');
    _refuse('createBot');
    final id = 'b-${app.id}';
    botList[id] = Member(userId: id, username: '${app.name.toLowerCase()}-bot', isBot: true);
    _replaceApp(
      DevApp(
        id: app.id,
        teamId: app.teamId,
        name: app.name,
        description: app.description,
        public: app.public,
        botUserId: id,
      ),
    );
    return 'bot-token-1';
  }

  @override
  Future<String> resetBotToken(DevApp app) async {
    admin.add('bot~ ${app.id}');
    _refuse('resetBotToken');
    return 'bot-token-2';
  }

  @override
  Future<void> deleteBot(DevApp app) async {
    admin.add('bot- ${app.id}');
    botList.remove(app.botUserId);
    _replaceApp(
      DevApp(id: app.id, teamId: app.teamId, name: app.name, description: app.description, public: app.public),
    );
  }

  @override
  Future<Member> botProfile(String botUserId) async => botList[botUserId]!;

  @override
  Future<void> updateBot(
    DevApp app, {
    String? username,
    String? alias,
    bool clearAlias = false,
    String? avatarPath,
    String? bannerPath,
    bool removeAvatar = false,
    bool removeBanner = false,
  }) async {
    admin.add(
      'bot* ${app.id} ${[if (username != null) 'username=$username', if (alias != null) 'alias=$alias', if (clearAlias) 'noalias', if (avatarPath != null) 'avatar', if (bannerPath != null) 'banner', if (removeAvatar) 'noavatar', if (removeBanner) 'nobanner'].join(' ')}',
    );
    _refuse('updateBot');
    final b = botList[app.botUserId]!;
    botList[b.userId] = Member(
      userId: b.userId,
      username: username ?? b.username,
      alias: clearAlias ? null : alias ?? b.alias,
      avatarUrl: removeAvatar ? null : (avatarPath == null ? b.avatarUrl : 'https://example.invalid/bot.png'),
      bannerUrl: removeBanner ? null : (bannerPath == null ? b.bannerUrl : 'https://example.invalid/bot-banner.png'),
      isBot: true,
    );
  }

  List<BotCommand> botCommands = [];
  final interactions = <String>[];
  BotModal? nextModal;
  final submitted = <List<Map<String, dynamic>>>[];
  final botsAdded = <(String, String)>[];

  @override
  Future<List<BotCommand>> commands(String spaceId) async => botCommands;

  @override
  Future<BotModal?> useComponent(
    RoomTarget target,
    String messageId,
    UiComponent component, {
    List<String>? values,
  }) async {
    _refuse('useComponent');
    interactions.add('component ${component.customId}${values == null ? '' : ' ${values.join(',')}'}');
    final modal = nextModal;
    nextModal = null;
    return modal;
  }

  @override
  Future<BotModal?> useCommand(RoomTarget target, BotCommand command, Map<String, Object> options) async {
    interactions.add('command ${command.name} ${options.entries.map((e) => '${e.key}=${e.value}').join(' ')}'.trim());
    final modal = nextModal;
    nextModal = null;
    return modal;
  }

  @override
  Future<void> submitModal(BotModal modal, List<Map<String, dynamic>> components) async => submitted.add(components);

  @override
  Future<BotInfo> bot(String userId) async => BotInfo(id: userId, name: 'Ballot');

  /// Who [user] answers for, by ID; anyone else isn't found.
  Map<String, Member> users = {};

  @override
  Future<Member> user(String userId) async => users[userId] ?? (throw const ActionFailed('Couldn’t find that user'));

  @override
  Future<void> addBot(String spaceId, String botId) async {
    _refuse('addBot');
    botsAdded.add((spaceId, botId));
  }

  final botsRemoved = <(String, String)>[];

  @override
  Future<void> removeBot(String spaceId, String botId) async {
    _refuse('removeBot');
    botsRemoved.add((spaceId, botId));
    // The gateway's SPACE_MEMBER_REMOVE that follows.
    spaceMembers[spaceId]?.remove(botId);
    spaces.value = [...spaces.value];
  }

  @override
  List<({String id, String name})> spaceRoles(String spaceId) => const [(id: 'role-mod', name: 'Moderator')];

  @override
  Future<InvitePreview> invite(String code) async {
    // A request takes a moment: the preview waits for its answer.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _refuse('invite');
    return invites[code] ?? (throw Exception('no such invite'));
  }

  @override
  Future<String> joinInvite(String code) async {
    joined.add(code);
    _refuse('joinInvite');
    return invites[code]!.spaceId;
  }

  @override
  String? lastReadOf(ChatTarget target) => lastRead[target.id];

  @override
  Stream<void> get resumed => _resumed.stream;

  final _signedOut = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get signedOut => _signedOut.stream;

  /// What the gateway coming back would do.
  void resume() => _resumed.add(null);
  final latestLoads = <String>[];

  final _events = StreamController<(String, MessageEvent)>.broadcast();
  final _typing = StreamController<(String, TypingUser)>.broadcast();

  final history = <String, List<ChatMessage>>{};
  final sent =
      <
        ({ChatTarget target, String content, String nonce, List<OutgoingFile> files, Sticker? sticker, String? replyTo})
      >[];
  final directMessagesOpened = <String>[];
  @override
  final ValueNotifier<Map<String, Presence>> presence = ValueNotifier({maya: Presence.online});
  @override
  final ValueNotifier<Set<String>> mobileOnly = ValueNotifier(const {});
  final reads = <(ChatTarget, String)>[];

  /// Completes sends when set; otherwise they answer at once.
  Completer<void>? holdSends;

  void _seed() {
    profile.value = me;
    recentChats.load(me.id);
    status.value = LiveStatus.online;
    conversations.value = const [
      ConversationSummary(id: 'c-maya', title: 'Maya', isGroup: false, otherUserId: maya),
      ConversationSummary(id: 'c-leo', title: 'Leo', isGroup: false, otherUserId: leo),
      ConversationSummary(id: 'c-team', title: 'Design crew', isGroup: true, memberCount: 4),
    ];
    unread.value = {'c-maya'};
    spaces.value = const [
      Space(
        id: 's-guild',
        name: 'Design Guild',
        onlineCount: 1,
        ownerId: maya,
        sections: [
          RoomSection(
            name: null,
            rooms: [Room(id: 'r-general', spaceId: 's-guild', name: 'general', kind: RoomKind.text, position: 0)],
          ),
          RoomSection(
            name: 'Voice',
            rooms: [Room(id: 'r-lounge', spaceId: 's-guild', name: 'lounge', kind: RoomKind.voice, position: 1)],
          ),
        ],
      ),
    ];
    history['c-maya'] = [
      message('m1', author: maya, name: 'Maya', text: 'Hey! Did you see the new tab bar?'),
      message('m2', author: me.id, name: me.displayName, text: 'Yes, way better than the side panels.'),
    ];
    history['r-general'] = [message('m3', author: leo, name: 'Leo', text: 'Pushed the new type ramp')];
  }

  static ChatMessage message(
    String id, {
    required String author,
    required String name,
    required String text,
    String? nonce,
    DateTime? at,
    MessageReply? reply,
    List<Reaction> reactions = const [],
  }) => ChatMessage(
    id: id,
    authorId: author,
    authorName: name,
    content: text,
    createdAt: at ?? DateTime(2026, 10, 23, 9),
    nonce: nonce,
    reply: reply,
    reactions: reactions,
  );

  /// What the gateway would push. A bot's answer to the user alone is kept
  /// apart, as the real repository keeps it.
  void push(String chatId, MessageEvent event) {
    if (event is MessageCreated && event.message.isEphemeral) {
      (ephemeral[chatId] ??= []).add(event.message);
    } else if (event is MessageCreated) {
      if (event.message.authorId != me.id) unread.value = {...unread.value, chatId};
      latest.value = {...latest.value, chatId: event.message};
      if (chatId.startsWith('c-')) {
        recentChats.conversationMessage(chatId, event.message);
      } else {
        recentChats.roomMessage(chatId, event.message);
      }
    }
    _events.add((chatId, event));
  }

  void pushTyping(String chatId, TypingUser user) => _typing.add((chatId, user));

  @override
  Future<bool> restore() async {
    if (signedIn) _seed();
    return signedIn;
  }

  /// How many times the app came back to the front.
  int cameToFrontTimes = 0;

  @override
  void cameToFront() => cameToFrontTimes++;

  @override
  Future<void> logIn(String email, String password) async {
    if (password != this.password) throw Exception('rejected');
    _seed();
  }

  @override
  Future<void> logOut() => endSession();

  /// What the real repository does when the session ends for good: signed
  /// out, or its tokens refused (one saved at launch included). As there,
  /// the gateway goes before the profile does.
  Future<void> endSession() async {
    _signedOut.add(null);
    await recentChats.close(forget: true);
    voiceSignaling.socket = null;
    profile.value = null;
    conversations.value = const [];
    spaces.value = const [];
  }

  @override
  Future<void> refreshConversations() async {}

  @override
  Future<ChatMessage> edit(ChatTarget target, String messageId, String content) async {
    edits.add((messageId, content));
    final list = history[target.id] ?? [];
    final i = list.indexWhere((m) => m.id == messageId);
    final edited = (i >= 0 ? list[i] : message(messageId, author: me.id, name: me.displayName, text: '')).copyWith(
      content: content,
      edited: true,
    );
    if (i >= 0) list[i] = edited;
    return edited;
  }

  @override
  Future<void> delete(ChatTarget target, String messageId) async {
    deletes.add(messageId);
    history[target.id]?.removeWhere((m) => m.id == messageId);
  }

  @override
  Future<void> react(ChatTarget target, String messageId, String emoji, {required bool add, String? emojiId}) async {
    reactions.add((messageId, emoji, add));
  }

  @override
  Future<ChatMessage> fetchMessage(ChatTarget target, String messageId) async =>
      [...?history[target.id], ...?older[target.id]].firstWhere((m) => m.id == messageId);

  /// Messages only a fetch by ID finds: older than the loaded page.
  final older = <String, List<ChatMessage>>{};

  /// What [messagesAfter] answers, by chat ID.
  final missed = <String, List<ChatMessage>>{};

  @override
  Future<List<ChatMessage>> messagesAfter(ChatTarget target, String messageId) async => [...?missed[target.id]];

  /// Each room's ephemeral messages, and those the user dismissed.
  final ephemeral = <String, List<ChatMessage>>{};
  final dismissed = <String>[];

  @override
  List<ChatMessage> ephemeralIn(ChatTarget target) => [...?ephemeral[target.id]];

  @override
  void dismissEphemeral(ChatTarget target, String messageId) {
    dismissed.add(messageId);
    ephemeral[target.id]?.removeWhere((m) => m.id == messageId);
  }

  @override
  Future<void> loadLatest(Iterable<ChatTarget> targets) async {
    for (final t in targets) {
      if (latest.value.containsKey(t.id)) continue;
      latestLoads.add(t.id);
      if (history[t.id]?.lastOrNull case final m?) latest.value = {...latest.value, t.id: m};
    }
  }

  @override
  String previewOf(ChatMessage message) => recent.previewOf(message, (c) => c);

  @override
  Future<List<ChatMessage>> messages(ChatTarget target, {String? before}) async {
    if (before == null) return [...?history[target.id]];
    await Future<void>.delayed(pageDelay);
    final pages = olderPages[target.id];
    return pages == null || pages.isEmpty ? const [] : pages.removeAt(0);
  }

  /// The pages before the history, newest first, one per ask, each after
  /// [pageDelay].
  final olderPages = <String, List<List<ChatMessage>>>{};
  Duration pageDelay = Duration.zero;

  @override
  Stream<MessageEvent> messageEvents(ChatTarget target) =>
      _events.stream.where((e) => e.$1 == target.id || e.$1 == '*').map((e) => e.$2);

  @override
  Stream<TypingUser> typing(ChatTarget target) => _typing.stream.where((e) => e.$1 == target.id).map((e) => e.$2);

  @override
  Future<ChatMessage> send(
    ChatTarget target,
    String content, {
    required String nonce,
    List<OutgoingFile> files = const [],
    Sticker? sticker,
    String? replyTo,
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    sent.add((target: target, content: content, nonce: nonce, files: files, sticker: sticker, replyTo: replyTo));
    if (files.isNotEmpty) {
      onProgress?.call(0);
      lastUpload = onProgress;
      cancel?.then((_) => cancelled = true);
    }
    await holdSends?.future;
    if (cancelled) throw Exception('cancelled');
    if (tooLarge) throw const UploadTooLarge();
    if (failSends) throw Exception('offline');
    return ChatMessage(
      id: 'sent-${sent.length}',
      authorId: me.id,
      authorName: me.displayName,
      content: content,
      createdAt: DateTime(2026, 10, 23, 9, 30),
      nonce: nonce,
      stickerUrl: sticker?.url,
      reply: switch (replyTo) {
        null => null,
        final id => () {
          final original = history[target.id]?.where((m) => m.id == id).firstOrNull;
          return MessageReply(
            messageId: id,
            authorId: original?.authorId,
            authorName: original?.authorName ?? 'Someone',
            content: original?.content ?? '',
          );
        }(),
      },
      attachments: [
        for (final (i, f) in files.indexed)
          MessageAttachment(
            id: 'att-$i',
            filename: f.name,
            contentType: f.contentType,
            url: 'https://example.invalid/${f.name}',
          ),
      ],
    );
  }

  /// More members of the rooms, after [everyone].
  final extraRoomMembers = <Member>[];

  @override
  Future<List<Member>> members(ChatTarget target, {bool refresh = false}) async {
    if (target is! RoomTarget) return everyone.where((m) => m.userId != leo).toList();
    final list = [...everyone, ...extraRoomMembers];
    // As the real one: a list loaded tells who's in the Space.
    (spaceMembers[target.spaceId] ??= {}).addAll(list.map((m) => m.userId));
    return list;
  }

  @override
  String? nameOf(String userId) => everyone.where((m) => m.userId == userId).firstOrNull?.displayName;

  @override
  String? avatarUrl(String? avatar) => avatar == null ? null : 'https://example.invalid/attachments/$avatar';

  @override
  String? emojiNameOf(String emojiId) => emojiId == party.id ? party.name : null;

  @override
  Future<List<CustomEmoji>> customEmojis(ChatTarget target) async => target is RoomTarget ? const [party] : const [];

  @override
  Future<List<Sticker>> stickers(ChatTarget target) async => target is RoomTarget ? const [wave] : const [];

  /// Why the server refuses a new DM, if it does.
  String? dmRefused;

  /// How long the server takes to answer a new DM.
  Duration dmDelay = Duration.zero;

  @override
  Future<ConversationSummary> directMessage(String userId) async {
    directMessagesOpened.add(userId);
    if (dmDelay > Duration.zero) await Future<void>.delayed(dmDelay);
    if (dmRefused != null) throw ActionFailed(dmRefused!);
    return conversations.value.first;
  }

  @override
  Future<void> sendTyping(ChatTarget target) async {}

  @override
  void opened(ChatTarget target, String title, {ChatMessage? latest}) =>
      recentChats.opened(target, title, latest: latest);

  @override
  void markRead(ChatTarget target, String messageId) {
    reads.add((target, messageId));
    unread.value = {...unread.value}..remove(target.id);
    mentions.value = {...mentions.value}..remove(target.id);
  }

  @override
  void dispose() {
    voiceSignaling.dispose();
    _resumed.close();
    _signedOut.close();
    _events.close();
    _typing.close();
    recentChats.dispose();
    presence.dispose();
    mobileOnly.dispose();
  }
}
