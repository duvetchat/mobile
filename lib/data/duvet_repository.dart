import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'links.dart' show duvetDomain;
import 'cache.dart';
import 'message_tokens.dart';
import 'models.dart';
import 'recent_chats.dart';
import 'recent_chats.dart' as recent show previewOf;
import 'repository.dart';
import 'session_store.dart';
import 'voice_signaling.dart';

/// [ChatRepository] over the Duvet API (`duvet_client`): REST for history and
/// sending, the gateway for everything live.
///
/// Limits of duvet_client this works around or lives with:
/// - The gateway reconnects with the REST client's token, which renews only on
///   a REST 401: after a long idle it may retry with an expired one.
/// - A space left while offline stays listed until the next sign-in: READY
///   doesn't list the spaces, it's followed by a SPACE_CREATE for each.
class DuvetRepository implements ChatRepository {
  final SessionStore _store;
  final RecentChatsStore _recentsStore;
  late final RecentChats _recents = RecentChats(
    _recentsStore,
    readable: (content) => readableContent(content, nameOf: nameOf, emojiNameOf: emojiNameOf),
  );

  // Names seen this session: members, conversation members, message authors.
  final _names = <String, String>{};
  final _emojiNames = <String, String>{};

  @override
  String? nameOf(String userId) => _names[userId];

  @override
  String? emojiNameOf(String emojiId) => _emojiNames[emojiId];
  final ApiRouter _router;
  final http.Client Function() _httpClient;

  /// Off in tests, which push events through [handleEvent].
  final bool _connectsGateway;

  DuvetRepository({
    SessionStore? store,
    RecentChatsStore? recentsStore,
    ApiRouter router = const ApiRouter(),
    http.Client Function()? httpClient,
    @visibleForTesting bool connectGateway = true,
    ChatCacheStore? cacheStore,
  }) : _cache = ChatCache(cacheStore ?? FileChatCacheStore()),
       _store = store ?? const SecureSessionStore(),
       _recentsStore = recentsStore ?? const SecureRecentChatsStore(),
       _router = router,
       _httpClient = httpClient ?? http.Client.new,
       _connectsGateway = connectGateway;

  final ChatCache _cache;

  // Opened from the cache, the server unreachable: tries again now and then.
  Timer? _retry;

  @override
  final ValueNotifier<Profile?> profile = ValueNotifier(null);
  @override
  final ValueNotifier<List<Space>> spaces = ValueNotifier(const []);
  @override
  final ValueNotifier<List<ConversationSummary>> conversations = ValueNotifier(const []);
  @override
  ValueListenable<List<RecentChat>> get recents => _recents.chats;
  @override
  final ValueNotifier<Set<String>> unread = ValueNotifier(const {});
  @override
  final ValueNotifier<LiveStatus> status = ValueNotifier(LiveStatus.offline);

  // Outlives the sessions: each one's gateway is attached to it.
  final _voiceSignaling = GatewayVoiceSignaling();
  @override
  VoiceSignaling get voiceSignaling => _voiceSignaling;

  // Synchronous: its listeners act before the session closes.
  final _signedOut = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get signedOut => _signedOut.stream;
  @override
  final ValueNotifier<Map<String, ChatMessage>> latest = ValueNotifier(const {});
  @override
  final ValueNotifier<Map<String, int>> mentions = ValueNotifier(const {});
  @override
  final drafts = <String, ChatDraft>{};

  // The last message read in each room, from READY, then as the user reads.
  final _lastRead = <String, String>{};
  final _resumed = StreamController<void>.broadcast();
  StreamSubscription<duvet.GatewayConnectionState>? _states;
  bool _wasReady = false;

  @override
  Stream<void> get resumed => _resumed.stream;

  @override
  String? lastReadOf(ChatTarget target) => _lastRead[target.id];

  final _messageEvents = StreamController<(String, MessageEvent)>.broadcast();
  final _typing = StreamController<(String, TypingUser)>.broadcast();

  // A session's client: logging out (destroying the gateway) closes its HTTP
  // client, so each session gets a new one.
  duvet.RestClient? _api;
  duvet.GatewayManager? _gateway;
  StreamSubscription<duvet.GatewayEventPayload>? _events;
  StoredSession? _saved;

  @override
  final ValueNotifier<Map<String, Presence>> presence = ValueNotifier(const {});

  // Fetched once per session, by space or conversation ID.
  final _spaceMembers = <String, Future<List<Member>>>{};
  final _conversationMembers = <String, List<Member>>{};
  final _emojis = <String, Future<List<CustomEmoji>>>{};
  final _stickers = <String, Future<List<Sticker>>>{};

  // Spaces by ID, with their rooms as the gateway sends them.
  final _spaces = <String, ({duvet.GatewaySpace space, Map<String, duvet.GatewayRoom> rooms})>{};

  // Who's in each space, as far as known: SPACE_CREATE's member_statuses (the
  // members not offline), then the member list once fetched.
  final _spaceMemberIds = <String, Set<String>>{};

  duvet.RestClient get _rest => _api ?? (throw StateError('Not signed in'));

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  @override
  Future<bool> restore() async {
    final saved = await _store.read();
    if (saved == null) return false;
    _api = duvet.RestClient(_httpClient(), router: _router, token: saved.token, sessionToken: saved.sessionToken);
    _saved = saved;
    try {
      await _start();
      return true;
    } on duvet.DuvetAuthException {
      await _endSession();
      return false;
    } catch (_) {
      // Unreachable server: keep the tokens for the next try, and open with
      // what's saved if there is anything.
      _closeSession();
      final home = await _cache.loadHome();
      if (home == null) rethrow;
      _api = duvet.RestClient(_httpClient(), router: _router, token: saved.token, sessionToken: saved.sessionToken);
      profile.value = home.profile;
      conversations.value = home.conversations;
      spaces.value = home.spaces;
      status.value = LiveStatus.offline;
      unawaited(_recents.load(home.profile.id));
      _retry = Timer.periodic(const Duration(seconds: 20), (_) => _comeBack());
      return true;
    }
  }

  bool _comingBack = false;

  // Back online after opening from the cache: the session starts for real.
  Future<void> _comeBack() async {
    if (_comingBack) return;
    _comingBack = true;
    try {
      await _start();
      _retry?.cancel();
      _retry = null;
      if (_wasReady) _resumed.add(null);
    } on duvet.DuvetAuthException {
      _retry?.cancel();
      await _endSession();
    } catch (_) {
      // Still offline.
    } finally {
      _comingBack = false;
    }
  }

  void _saveHome() {
    final p = profile.value;
    if (p == null || status.value == LiveStatus.offline && _retry != null) return;
    _cache.saveHome(profile: p, conversations: conversations.value, spaces: spaces.value);
  }

  @override
  Future<void> logIn(String email, String password) async {
    _closeSession();
    final api = _api = duvet.RestClient(_httpClient(), router: _router);
    try {
      await api.logIn(email, password);
      await _start();
    } catch (_) {
      _closeSession();
      rethrow;
    }
  }

  @override
  Future<void> logOut() async {
    await _api?.logout();
    await _endSession();
  }

  Future<void> _start() async {
    final me = await _call((api) => api.me());
    _setProfile(me);
    _names[me.id] = profile.value!.displayName;
    unawaited(_recents.load(me.id));
    unawaited(refreshConversations().catchError((Object e) => debugPrint('conversations: $e')));
    if (_connectsGateway) _connectGateway();
  }

  Future<void> _endSession() async {
    // While the gateway is still attached; once (a refused session ends in
    // [_call], then again in [restore]).
    if (_api != null) _signedOut.add(null);
    // Previews are message text: signing out leaves none on the device.
    unawaited(_recents.close(forget: true));
    unawaited(_cache.clear());
    _closeSession();
    _saved = null;
    await _store.clear();
  }

  void _closeSession() {
    _retry?.cancel();
    _retry = null;
    _events?.cancel();
    _events = null;
    _states?.cancel();
    _states = null;
    _wasReady = false;
    _lastRead.clear();
    drafts.clear();
    mentions.value = const {};
    _voiceSignaling.detach();
    // Destroying the gateway closes the REST client's HTTP client too.
    if (_gateway case final gateway?) {
      gateway.destroy();
    } else {
      _api?.client.close();
    }
    _gateway = null;
    _api = null;
    _spaces.clear();
    _spaceMemberIds.clear();
    _spaceMembers.clear();
    _loadedMembers.clear();
    _roles.clear();
    _memberRoles.clear();
    _friendsLoaded = false;
    friends.value = Friends.none;
    _conversationMembers.clear();
    _names.clear();
    _emojiNames.clear();
    _emojis.clear();
    _stickers.clear();
    _uploadLimit = null;
    presence.value = const {};
    latest.value = const {};
    unawaited(_recents.close());
    profile.value = null;
    spaces.value = const [];
    conversations.value = const [];
    unread.value = const {};
    status.value = LiveStatus.offline;
  }

  /// Runs a request, then saves the tokens if the client renewed them on the
  /// way (it does so silently on a 401). A rejected renewal ends the session.
  Future<T> _call<T>(Future<T> Function(duvet.RestClient api) request) async {
    final api = _rest;
    try {
      return await request(api);
    } on duvet.DuvetAuthException {
      if (!api.isAuthenticated && identical(api, _api)) await _endSession();
      rethrow;
    } finally {
      if (identical(api, _api)) await _persist(api);
    }
  }

  Future<void> _persist(duvet.RestClient api) async {
    if (!api.isAuthenticated) return;
    final current = (token: api.token, sessionToken: api.sessionToken);
    if (current == _saved) return;
    _saved = current;
    await _store.write(current);
  }

  // ---------------------------------------------------------------------------
  // Gateway
  // ---------------------------------------------------------------------------

  void _connectGateway() {
    final gateway = _gateway = duvet.GatewayManager(
      _rest,
      router: _router,
      // No gateway log at all in release builds.
      log: kDebugMode ? (shard, msg) => debugPrint('[gateway:$shard] $msg') : (_, _) {},
    );
    _voiceSignaling.attach(gateway);
    // Listen before connecting: READY comes right after IDENTIFY, on a
    // broadcast stream.
    _events = gateway.onEvent.listen(handleEvent);
    _states = gateway.onConnectionState.listen(handleConnectionState);
    status.value = LiveStatus.connecting;
    gateway.connectAll().catchError((Object e) {
      debugPrint('gateway: $e');
      if (identical(gateway, _gateway)) status.value = LiveStatus.offline;
    });
  }

  /// A dropped socket shows until READY comes again.
  @visibleForTesting
  void handleConnectionState(duvet.GatewayConnectionState state) {
    if (state == duvet.GatewayConnectionState.reconnecting && _wasReady) status.value = LiveStatus.reconnecting;
  }

  /// Applies a gateway event.
  @visibleForTesting
  void handleEvent(duvet.GatewayEventPayload event) {
    final me = profile.value?.id;
    switch (event) {
      case duvet.ReadyEvent(:final data):
        status.value = LiveStatus.online;
        // Connected, the user shows the status they chose. A gateway from
        // before statuses doesn't say: online.
        if (_chosen(data.user.status) case final chosen?) {
          _choose(chosen);
          if (me != null) presence.value = {...presence.value, me: chosen};
        } else if (me != null && !presence.value.containsKey(me)) {
          presence.value = {...presence.value, me: Presence.online};
        }
        unread.value = {...?data.unreadRooms, ...?data.unreadConvs};
        _lastRead.addAll(data.lastReadRooms ?? const {});
        _lastMessage.addAll(data.lastMsgRooms ?? const {});
        if (_api != null) {
          unawaited(
            _call((api) => api.getMentionCounts()).then((counts) {
              mentions.value = {
                for (final e in counts.entries)
                  if (e.value > 0) e.key: e.value,
              };
            }, onError: (Object e) => debugPrint('mentions: $e')),
          );
        }
        // READY again after a drop: chats catch up.
        if (_wasReady) _resumed.add(null);
        _wasReady = true;

      case duvet.MentionCreatedEvent(:final data) when data.authorId != me:
        _mentioned(data.conversationId ?? data.roomId);
      case duvet.DMMentionCreatedEvent(:final data) when data.authorId != me:
        _mentioned(data.conversationId);

      case duvet.ReactionAddedEvent(:final data) || duvet.DMReactionAddedEvent(:final data):
        _messageEvents.add((
          _anyChat,
          ReactionChanged(
            messageId: data.messageId,
            userId: data.userId,
            emoji: data.emojiName,
            emojiId: data.emojiId,
            added: true,
          ),
        ));
      case duvet.ReactionRemovedEvent(:final data) || duvet.DMReactionRemovedEvent(:final data):
        _messageEvents.add((
          _anyChat,
          ReactionChanged(messageId: data.messageId, userId: data.userId, emoji: data.emojiName, added: false),
        ));

      case duvet.SpaceCreateEvent(:final data):
        _spaces[data.space.id] = (space: data.space, rooms: {...data.rooms});
        _roles[data.space.id] = {...data.rolesPermissions};
        _overwrites[data.space.id] = {
          for (final e in (data.overwrites ?? const <String, List<duvet.GatewayRoomOverwrite>>{}).entries)
            e.key: [...e.value],
        };
        _memberRoles[data.space.id] = {
          for (final e in data.memberRoles.entries) e.key: [...e.value],
        };
        // Presence as the gateway connects; live updates follow.
        (_spaceMemberIds[data.space.id] ??= {}).addAll(data.memberStatuses.keys);
        if (data.memberStatuses.isNotEmpty) {
          presence.value = {...presence.value, for (final e in data.memberStatuses.entries) e.key: _presence(e.value)};
        }
        _publishSpaces();
      case duvet.SpaceUpdateEvent(:final data):
        if (_spaces[data.id] case final known?) {
          _spaces[data.id] = (space: data, rooms: known.rooms);
          _publishSpaces();
        }
      case duvet.SpaceDeletedEvent(:final data):
        _forgetSpace(data.id);

      case duvet.RoomCreateEvent(:final data) || duvet.RoomUpdateEvent(:final data):
        if (_spaces[data.spaceId] case final known?) {
          known.rooms[data.id] = data;
          _publishSpaces();
        }
      case duvet.RoleCreatedEvent(:final data) || duvet.RoleUpdatedEvent(:final data):
        (_roles[data.spaceId] ??= {})[data.id] = data;
        _publishSpaces();
      case duvet.RoleDeletedEvent(:final data):
        _roles[data.spaceId]?.remove(data.id);
        for (final ids in _memberRoles[data.spaceId]?.values ?? const <List<String>>[]) {
          ids.remove(data.id);
        }
        _publishSpaces();
      case duvet.MemberRoleAddedEvent(:final data):
        if (data.spaceId case final spaceId?) {
          final ids = (_memberRoles[spaceId] ??= {})[data.memberId] ??= [];
          if (!ids.contains(data.roleId)) ids.add(data.roleId);
        }
      case duvet.MemberRoleRemovedEvent(:final data):
        for (final members in data.spaceId == null ? _memberRoles.values : [?_memberRoles[data.spaceId]]) {
          members[data.memberId]?.remove(data.roleId);
        }
      case duvet.RoomOverwriteUpdateEvent(:final data):
        for (final (:space, :rooms) in _spaces.values) {
          if (!rooms.containsKey(data.roomId)) continue;
          final list = (_overwrites[space.id] ??= {})[data.roomId] ??= [];
          list
            ..removeWhere((o) => o.targetId == data.targetId)
            ..add(data);
        }
      case duvet.RoomOverwriteDeletedEvent(:final data):
        for (final rooms in _overwrites.values) {
          rooms[data.roomId]?.removeWhere((o) => o.targetId == data.targetId);
        }

      case duvet.RoomDeletedEvent(:final data):
        _spaces[data.spaceId]?.rooms.remove(data.id);
        _publishSpaces();

      case duvet.MessageCreateEvent(:final data):
        if (data.deletedAt != null) break;
        if (data.authorId != me) _markUnread(data.roomId);
        final message = _roomMessage(data);
        _recents.roomMessage(data.roomId, message);
        _setLatest(data.roomId, message);
        _messageEvents.add((data.roomId, MessageCreated(message)));
      case duvet.MessageUpdateEvent(:final data):
        if (data.deletedAt != null) {
          _recents.deleted(data.roomId, data.id);
          _latestDeleted(data.roomId, data.id);
          _messageEvents.add((data.roomId, MessageDeleted(data.id)));
        } else {
          final message = _roomMessage(data);
          _recents.edited(data.roomId, message);
          if (latest.value[data.roomId]?.id == message.id) _setLatest(data.roomId, message);
          _messageEvents.add((data.roomId, MessageUpdated(message)));
        }
      case duvet.MessageDeletedEvent(:final data):
        _recents.deleted(data.roomId, data.id);
        _latestDeleted(data.roomId, data.id);
        _messageEvents.add((data.roomId, MessageDeleted(data.id)));

      case duvet.DMMessageCreatedEvent(:final data):
        final id = data.conversationId;
        if (id == null) break;
        if (data.authorId != me) _markUnread(id);
        final known = conversations.value.where((c) => c.id == id).firstOrNull;
        if (known == null) unawaited(refreshConversations().catchError((_) {}));
        final message = _directMessage(data);
        _recents.conversationMessage(id, message, title: known?.title);
        _setLatest(id, message);
        _messageEvents.add((id, MessageCreated(message)));
      case duvet.DMMessageUpdatedEvent(:final data):
        if (data.conversationId case final id?) {
          final message = _directMessage(data);
          _recents.edited(id, message);
          _messageEvents.add((id, MessageUpdated(message)));
        }
      case duvet.DMMessageDeletedEvent(:final data):
        _recents.deleted(data.conversationId, data.id);
        _messageEvents.add((data.conversationId, MessageDeleted(data.id)));

      case duvet.TypingStartedEvent(:final data) when data.userId != me:
        _typing.add((data.roomId, TypingUser(userId: data.userId, name: data.alias ?? data.username)));
      case duvet.DMTypingStartedEvent(:final data) when data.userId != me:
        _typing.add((data.conversationId, TypingUser(userId: data.userId, name: data.alias ?? data.username)));

      case duvet.UserStatusUpdatedEvent(:final data):
        presence.value = {...presence.value, data.userId: _presence(data.statusId)};
        // The user's own: the status they chose, on this device or another.
        if (_chosen(data.statusId) case final chosen? when data.userId == me) _choose(chosen);
        if (_spaceMemberIds.values.any((ids) => ids.contains(data.userId))) _publishSpaces();
      case duvet.SpaceEmojiCreatedEvent(:final data) || duvet.SpaceEmojiUpdatedEvent(:final data):
        _emojis.remove(data.spaceId);
      case duvet.SpaceEmojiDeletedEvent(:final data):
        _emojis.remove(data.spaceId);
      case duvet.SpaceStickerCreatedEvent(:final data) || duvet.SpaceStickerUpdatedEvent(:final data):
        _stickers.remove(data.spaceId);
      case duvet.SpaceStickerDeletedEvent(:final data):
        _stickers.remove(data.spaceId);
      case duvet.SpaceMemberAddedEvent() ||
          duvet.SpaceMemberRemovedEvent() ||
          duvet.GuildMemberAddedEvent() ||
          duvet.GuildMemberRemovedEvent():
        _spaceMembers.clear();

      case duvet.FriendRequestCreatedEvent() ||
          duvet.FriendRequestAcceptedEvent() ||
          duvet.FriendRequestRejectedEvent() ||
          duvet.FriendRemovedEvent():
        unawaited(_reloadFriends());

      case duvet.ConversationCreatedEvent() ||
          duvet.ConversationUpdatedEvent() ||
          duvet.ConversationDeletedEvent() ||
          duvet.ConversationMemberAddedEvent() ||
          duvet.ConversationMemberRemovedEvent():
        unawaited(refreshConversations().catchError((_) {}));

      case duvet.UserUpdatedEvent(:final data) when data.id == me:
        _call((api) => api.me()).then((me) {
          _setProfile(me);
        }, onError: (_) {});

      default:
    }
    // After the spaces and roles took it in: voice reads them.
    _voiceSignaling.deliver(event);
  }

  // Events for whichever chat has the message.
  static const _anyChat = '*';

  void _mentioned(String chatId) => mentions.value = {...mentions.value, chatId: (mentions.value[chatId] ?? 0) + 1};

  void _markUnread(String id) {
    if (!unread.value.contains(id)) unread.value = {...unread.value, id};
  }

  void _publishSpaces() {
    final now = presence.value;
    spaces.value = [
      for (final (:space, :rooms) in _spaces.values)
        Space(
          id: space.id,
          name: space.name,
          iconUrl: avatarUrl(space.icon),
          sections: _sections(space.id, rooms.values),
          onlineCount: switch (_spaceMemberIds[space.id]) {
            final ids? when ids.isNotEmpty =>
              ids.where((id) => (now[id] ?? Presence.offline) != Presence.offline).length,
            _ => null,
          },
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _saveHome();
  }

  void _setLatest(String chatId, ChatMessage m) {
    final known = latest.value[chatId];
    if (known != null && known.id != m.id && known.createdAt.isAfter(m.createdAt)) return;
    latest.value = {...latest.value, chatId: m};
  }

  // The one before it isn't known here: fetched again when next shown.
  void _latestDeleted(String chatId, String messageId) {
    if (latest.value[chatId]?.id == messageId) latest.value = {...latest.value}..remove(chatId);
  }

  final _loadingLatest = <String>{};

  @override
  Future<void> loadLatest(Iterable<ChatTarget> targets) async {
    final wanted = [
      for (final t in targets)
        if (!latest.value.containsKey(t.id) && _loadingLatest.add(t.id)) t,
    ];
    await Future.wait([
      for (final t in wanted)
        () async {
          try {
            final ChatMessage? newest = switch (t) {
              RoomTarget(:final roomId) => switch (await _call((api) => api.getMessages(roomId, count: 1))) {
                [final m, ...] when m.deletedAt == null => _roomMessage(m),
                _ => null,
              },
              ConversationTarget(:final conversationId) => (await _call(
                (api) => api.getDirectMessages(conversationId, count: 1),
              )).map(_directMessage).firstOrNull,
            };
            if (newest != null) _setLatest(t.id, newest);
          } catch (e) {
            debugPrint('latest: $e');
          } finally {
            _loadingLatest.remove(t.id);
          }
        }(),
    ]);
  }

  @override
  String previewOf(ChatMessage message) =>
      recent.previewOf(message, (content) => readableContent(content, nameOf: nameOf, emojiNameOf: emojiNameOf));

  /// The rooms outside any category, then each category's, by position.
  static List<RoomSection> _sections(String spaceId, Iterable<duvet.GatewayRoom> all) {
    int byPosition(duvet.GatewayRoom a, duvet.GatewayRoom b) => a.position.compareTo(b.position);
    final categories = all.where((r) => r.type == duvet.RoomType.category).toList()..sort(byPosition);
    final categoryIds = {for (final c in categories) c.id};
    final rooms = all.where((r) => r.type != duvet.RoomType.category && r.deletedAt == null).toList()..sort(byPosition);

    Room toRoom(duvet.GatewayRoom r) => Room(
      id: r.id,
      spaceId: spaceId,
      name: r.name,
      kind: r.type == duvet.RoomType.voice ? RoomKind.voice : RoomKind.text,
      position: r.position,
    );

    final loose = [
      for (final r in rooms)
        if (!categoryIds.contains(r.parentId)) toRoom(r),
    ];
    return [
      if (loose.isNotEmpty) RoomSection(name: null, rooms: loose),
      for (final c in categories)
        RoomSection(
          name: c.name,
          rooms: [
            for (final r in rooms)
              if (r.parentId == c.id) toRoom(r),
          ],
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Conversations and messages
  // ---------------------------------------------------------------------------

  @override
  Future<void> refreshConversations() async {
    final me = profile.value?.id;
    final list = await _call((api) => api.getConversations());
    conversations.value = [
      for (final c
          in list.where((c) => c.deletedAt == null).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
        _summary(c, me),
    ];
    _saveHome();
  }

  ConversationSummary _summary(duvet.Conversation c, String? me) {
    final members = _conversationMembers[c.id] = [
      for (final m in c.members)
        if (m.user case final u?)
          Member(userId: u.id, username: u.username, alias: u.alias, avatarUrl: avatarUrl(u.avatar), isBot: u.isBot),
    ];
    for (final m in members) {
      _names[m.userId] = m.displayName;
    }
    final others = [
      for (final m in c.members)
        if (m.userId != me && m.user != null) m.user!,
    ];
    String name(duvet.ConversationUser u) => u.alias?.isNotEmpty == true ? u.alias! : u.username;
    final isGroup = c.type == duvet.ConversationType.group;
    return ConversationSummary(
      id: c.id,
      title: isGroup
          ? (c.name?.isNotEmpty == true ? c.name! : (others.isEmpty ? 'Group' : others.map(name).join(', ')))
          : (others.isEmpty ? 'Direct message' : name(others.first)),
      isGroup: isGroup,
      avatarUrl: isGroup || others.isEmpty ? null : avatarUrl(others.first.avatar),
      otherUserId: isGroup ? null : others.firstOrNull?.id,
      memberCount: c.members.length,
      updatedAt: c.updatedAt.toLocal(),
      ownerId: c.ownerId,
      name: c.name?.isNotEmpty == true ? c.name : null,
    );
  }

  @override
  Future<List<ChatMessage>> messages(ChatTarget target, {String? before}) async {
    try {
      final page = await _fetchPage(target, before);
      if (before == null) _cache.savePage(target.id, page);
      return page;
    } on duvet.DuvetAuthException {
      rethrow;
    } catch (_) {
      // Offline: the last page seen here, if any.
      if (before == null) {
        if (await _cache.loadPage(target.id) case final cached?) return cached;
      }
      rethrow;
    }
  }

  Future<List<ChatMessage>> _fetchPage(ChatTarget target, String? before) async {
    // The API answers the newest first.
    final List<ChatMessage> page = switch (target) {
      RoomTarget(:final roomId) => [
        for (final m in await _call((api) => api.getMessages(roomId, before: before)))
          if (m.deletedAt == null) _roomMessage(m),
      ],
      ConversationTarget(:final conversationId) => [
        for (final m in await _call((api) => api.getDirectMessages(conversationId, before: before))) _directMessage(m),
      ],
    };
    return page.reversed.toList();
  }

  @override
  Stream<MessageEvent> messageEvents(ChatTarget target) =>
      _messageEvents.stream.where((e) => e.$1 == target.id || e.$1 == _anyChat).map((e) => e.$2);

  @override
  Future<List<ChatMessage>> messagesAfter(ChatTarget target, String messageId) async {
    final List<ChatMessage> page = switch (target) {
      RoomTarget(:final roomId) => [
        for (final m in await _call((api) => api.getMessagesAfter(roomId, messageId)))
          if (m.deletedAt == null) _roomMessage(m),
      ],
      ConversationTarget(:final conversationId) => [
        for (final m in await _call((api) => api.getDirectMessagesAfter(conversationId, messageId))) _directMessage(m),
      ],
    };
    // Whichever order the server answers in, oldest first.
    return page..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<ChatMessage> fetchMessage(ChatTarget target, String messageId) => switch (target) {
    RoomTarget(:final roomId) => _call((api) => api.getMessageById(roomId, messageId)).then(_roomMessage),
    ConversationTarget(:final conversationId) => _call(
      (api) => api.getDirectMessageById(conversationId, messageId),
    ).then(_directMessage),
  };

  @override
  Future<ChatMessage> edit(ChatTarget target, String messageId, String content) => switch (target) {
    RoomTarget(:final roomId) => _call((api) => api.updateMessage(messageId, content, roomId)).then(_roomMessage),
    ConversationTarget(:final conversationId) => _call(
      (api) => api.updateDirectMessage(conversationId, messageId, content),
    ).then(_directMessage),
  };

  @override
  Future<void> delete(ChatTarget target, String messageId) => switch (target) {
    RoomTarget(:final roomId) => _call((api) => api.deleteMessage(messageId, roomId)),
    ConversationTarget(:final conversationId) => _call((api) => api.deleteDirectMessage(conversationId, messageId)),
  };

  @override
  Future<void> react(ChatTarget target, String messageId, String emoji, {required bool add, String? emojiId}) =>
      switch ((target, add)) {
        (RoomTarget(:final roomId), true) => _call(
          (api) => api.addRoomReaction(roomId, messageId, emoji, emojiId: emojiId),
        ),
        (RoomTarget(:final roomId), false) => _call((api) => api.removeRoomReaction(roomId, messageId, emoji)),
        (ConversationTarget(:final conversationId), true) => _call(
          (api) => api.addConversationReaction(conversationId, messageId, emoji, emojiId: emojiId),
        ),
        (ConversationTarget(:final conversationId), false) => _call(
          (api) => api.removeConversationReaction(conversationId, messageId, emoji),
        ),
      };

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
    final upload = files.isEmpty ? null : [for (final f in files) File(f.path)];
    void progress(int sent, int total) => onProgress?.call(total == 0 ? 0 : sent / total);
    try {
      return await _sendTo(target, content, nonce, upload, sticker, replyTo, progress, cancel);
    } on duvet.DuvetApiException catch (e) {
      if (e.statusCode == 413) throw const UploadTooLarge();
      rethrow;
    }
  }

  Future<ChatMessage> _sendTo(
    ChatTarget target,
    String content,
    String nonce,
    List<File>? upload,
    Sticker? sticker,
    String? replyTo,
    void Function(int sent, int total) progress,
    Future<void>? cancel,
  ) {
    return switch (target) {
      RoomTarget(:final roomId) => _call(
        (api) => api.sendMessage(
          roomId,
          content,
          nonce: nonce,
          files: upload,
          stickerAttachmentId: sticker?.attachmentId,
          messageReference: replyTo == null
              ? null
              : duvet.MessageReference(type: duvet.MessageReferenceType.reply, messageId: replyTo, roomId: roomId),
          onProgress: upload == null ? null : progress,
          abortTrigger: upload == null ? null : cancel,
        ),
      ).then(_roomMessage),
      ConversationTarget(:final conversationId) => _call(
        (api) => api.sendDirectMessage(
          conversationId,
          content,
          nonce: nonce,
          files: upload,
          stickerAttachmentId: sticker?.attachmentId,
          messageReference: replyTo == null
              ? null
              : duvet.MessageReference(type: duvet.MessageReferenceType.reply, messageId: replyTo),
          onProgress: upload == null ? null : progress,
          abortTrigger: upload == null ? null : cancel,
        ),
      ).then(_directMessage),
    };
  }

  @override
  Future<ChatMessage> sendVoiceNote(
    ChatTarget target,
    List<int> audio, {
    required String nonce,
    String format = 'ogg',
  }) => switch (target) {
    RoomTarget(:final roomId) => _call(
      (api) => api.sendVoiceNote(roomId, audio, nonce: nonce, format: format),
    ).then(_roomMessage),
    ConversationTarget(:final conversationId) => _call(
      (api) => api.sendDMVoiceNote(conversationId, audio, nonce: nonce, format: format),
    ).then(_directMessage),
  };

  @override
  Future<void> sendRecording(ChatTarget target) async {
    try {
      await switch (target) {
        RoomTarget(:final roomId) => _call((api) => api.sendRecordingIndicator(roomId)),
        ConversationTarget(:final conversationId) => _call((api) => api.sendConversationRecording(conversationId)),
      };
    } on Exception {
      // Best effort.
    }
  }

  Future<int?>? _uploadLimit;

  @override
  Future<int?> uploadLimit() => _uploadLimit ??= _call((api) => api.getMyStorageStatus()).then(
    (s) => s.uploadLimitBytes > 0 ? s.uploadLimitBytes : null,
    onError: (Object e) {
      _uploadLimit = null;
      return null;
    },
  );

  @override
  Future<List<SearchHit>> search(SearchQuery q) async {
    final params = duvet.MessageSearch(
      query: q.text,
      roomIds: [?q.roomId],
      has: q.hasFile ? const ['file'] : const [],
      pinned: q.pinned ? true : null,
      authorIds: [?q.authorId],
    );
    if (q.conversationId case final id?) {
      final page = await _call((api) => api.searchConversationMessages(id, params));
      return [for (final m in page.messages) SearchHit(target: ConversationTarget(id), message: _directMessage(m))];
    }
    final spaceId = q.spaceId;
    if (spaceId == null) return const [];
    final page = await _call((api) => api.searchSpaceMessages(spaceId, params));
    return [
      for (final m in page.messages)
        if (m.deletedAt == null)
          SearchHit(
            target: RoomTarget(spaceId: spaceId, roomId: m.roomId),
            message: _roomMessage(m),
          ),
    ];
  }

  @override
  Future<List<ChatMessage>> pins(ChatTarget target) async => switch (target) {
    RoomTarget(:final roomId) => [for (final m in await _call((api) => api.getRoomPins(roomId))) _roomMessage(m)],
    ConversationTarget(:final conversationId) => [
      for (final m in await _call((api) => api.getConversationPins(conversationId))) _directMessage(m),
    ],
  };

  @override
  Future<void> pin(ChatTarget target, String messageId, {required bool pinned}) => switch ((target, pinned)) {
    (RoomTarget(:final roomId), true) => _call((api) => api.pinRoomMessage(roomId, messageId)),
    (RoomTarget(:final roomId), false) => _call((api) => api.unpinRoomMessage(roomId, messageId)),
    (ConversationTarget(:final conversationId), true) => _call(
      (api) => api.pinConversationMessage(conversationId, messageId),
    ),
    (ConversationTarget(:final conversationId), false) => _call(
      (api) => api.unpinConversationMessage(conversationId, messageId),
    ),
  };

  @override
  Future<List<ChatMessage>> thread(ChatTarget target, String messageId) async => switch (target) {
    RoomTarget(:final roomId) => [
      for (final m in await _call((api) => api.getMessageThread(roomId, messageId)))
        if (m.deletedAt == null) _roomMessage(m),
    ],
    ConversationTarget(:final conversationId) => [
      for (final m in await _call((api) => api.getConversationMessageThread(conversationId, messageId)))
        _directMessage(m),
    ],
  };

  // The member lists loaded so far, by Space.
  final _loadedMembers = <String, List<Member>>{};

  @override
  List<Member> get people {
    final byId = <String, Member>{};
    for (final list in [..._loadedMembers.values, ..._conversationMembers.values]) {
      for (final m in list) {
        byId.putIfAbsent(m.userId, () => m);
      }
    }
    return byId.values.toList();
  }

  @override
  Future<String> createSpace(String name, {String? description, String? iconPath}) async {
    final created = await _call((api) => api.createSpace(name, description: description));
    final id = created.id;
    // Shown at once: the gateway's SPACE_CREATE, with the rest, may come later.
    if (!_spaces.containsKey(id)) {
      _spaces[id] = (space: created.space, rooms: {for (final r in created.rooms) r.id: r});
      if (profile.value?.id case final me?) (_memberRoles[id] ??= {})[me] = [id];
      _publishSpaces();
    }
    if (iconPath != null) {
      try {
        await _call((api) => api.updateSpace(id, icon: File(iconPath)));
      } catch (e) {
        debugPrint('space icon: $e');
      }
    }
    return id;
  }

  @override
  Future<void> deleteSpace(String spaceId) async {
    try {
      await _call((api) => api.deleteSpace(spaceId));
    } on duvet.DuvetApiException catch (e) {
      debugPrint('delete space: $e');
      final missing = _routeMissing(e);
      // Gone already, its SPACE_DELETE missed (while offline, say): it goes
      // from here too.
      if (e.statusCode == 404 && !missing) _forgetSpace(spaceId);
      throw ActionFailed(switch (e.statusCode) {
        _ when missing => 'This server can’t delete Spaces yet: it needs the latest API',
        403 => 'Only the Space’s owner can delete it',
        404 => 'This Space is already gone',
        _ => 'Couldn’t delete the Space (${e.statusCode})',
      });
    } on TimeoutException {
      throw const ActionFailed('Duvet didn’t answer. Check your connection and try again.');
    }
    // SPACE_DELETE follows; it goes at once.
    _forgetSpace(spaceId);
  }

  /// A route this API doesn't have yet: its own 404s are JSON, and a route it
  /// lacks answers gin's plain text.
  static bool _routeMissing(duvet.DuvetApiException e) =>
      (e.statusCode == 404 || e.statusCode == 405) && !(e.body ?? '').trimLeft().startsWith('{');

  /// Forgets a deleted Space: its card, and its rooms in the Chats list, with
  /// their unread marks and mentions.
  void _forgetSpace(String spaceId) {
    final rooms = {...?_spaces.remove(spaceId)?.rooms.keys, ..._recents.forgetSpace(spaceId)};
    _spaceMemberIds.remove(spaceId);
    if (unread.value.any(rooms.contains)) unread.value = unread.value.difference(rooms);
    if (mentions.value.keys.any(rooms.contains)) {
      mentions.value = {...mentions.value}..removeWhere((id, _) => rooms.contains(id));
    }
    _publishSpaces();
  }

  @override
  Future<void> leaveSpace(String spaceId) async {
    await _call((api) => api.leaveSpace(spaceId));
    _spaces.remove(spaceId);
    _publishSpaces();
  }

  @override
  Future<String> createInvite(String spaceId, String roomId, {Duration? maxAge}) async {
    final String code;
    try {
      code = await _call((api) => api.createRoomInvite(spaceId, roomId, maxAge?.inSeconds ?? 0));
    } on duvet.DuvetApiException catch (e) {
      debugPrint('invite: $e');
      final room = _spaces[spaceId]?.rooms[roomId]?.name;
      throw ActionFailed(switch (e.statusCode) {
        403 => 'You can’t invite people${room == null ? '' : ' to #$room'}',
        400 => _serverReason(e) ?? 'The server refused the link',
        _ => 'The server couldn’t make a link (${e.statusCode})',
      });
    } on TimeoutException {
      throw const ActionFailed('Duvet didn’t answer. Check your connection and try again.');
    } on IOException catch (e) {
      debugPrint('invite: $e');
      throw const ActionFailed('No connection. Check it and try again.');
    }
    return '$duvetDomain/invite?code=${Uri.encodeQueryComponent(code)}';
  }

  // The `error` of an API error's JSON body, if it has one.
  static String? _serverReason(duvet.DuvetApiException e) {
    try {
      final reason = (jsonDecode(e.body ?? '') as Map<String, dynamic>)['error'];
      return reason is String && reason.isNotEmpty ? '${reason[0].toUpperCase()}${reason.substring(1)}' : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void markSpaceRead(String spaceId) {
    final space = spaces.value.where((s) => s.id == spaceId).firstOrNull;
    if (space == null) return;
    for (final room in space.rooms) {
      if (!unread.value.contains(room.id)) continue;
      final newest = latest.value[room.id]?.id ?? _lastMessage[room.id];
      if (newest != null) {
        markRead(room.target, newest);
      } else {
        unread.value = {...unread.value}..remove(room.id);
      }
    }
  }

  // Each room's newest message ID, as READY gives it.
  final _lastMessage = <String, String>{};

  // Each Space's roles, and its members' role IDs, from SPACE_CREATE.
  final _roles = <String, Map<String, duvet.GatewayRole>>{};
  final _memberRoles = <String, Map<String, List<String>>>{};

  // Each Space's rooms' overwrites, by room.
  final _overwrites = <String, Map<String, List<duvet.GatewayRoomOverwrite>>>{};

  @override
  List<RoleTag> rolesOf(String spaceId, String userId) {
    final roles = _roles[spaceId] ?? const {};
    final mine = [
      for (final id in _memberRoles[spaceId]?[userId] ?? const <String>[])
        if (roles[id] case final r? when r.name != '@everyone') r,
    ]..sort((a, b) => b.position.compareTo(a.position));
    return [for (final r in mine) RoleTag(r.name, color: r.colorFrom == null ? null : 0xFF000000 | r.colorFrom!)];
  }

  @override
  final ValueNotifier<Friends> friends = ValueNotifier(Friends.none);
  bool _friendsLoaded = false;

  Member _person(String id, String username, String? alias, String? avatar) =>
      Member(userId: id, username: username, alias: alias, avatarUrl: avatarUrl(avatar));

  @override
  Future<void> loadFriends() async {
    final me = profile.value?.id;
    final (list, incoming, outgoing) = await (
      _call((api) => api.getFriends()),
      _call((api) => api.getPendingRequests()),
      _call((api) => api.getSentRequests()),
    ).wait;
    _friendsLoaded = true;
    // Friends sharing no space with the user have no presence from the gateway
    // until it changes: the list's, for those it hasn't told about.
    final listed = {
      for (final f in list)
        if (f.statusId case final status?) (f.senderId == me ? f.recipientId : f.senderId): _presence(status),
    };
    if (listed.keys.any((id) => !presence.value.containsKey(id))) presence.value = {...listed, ...presence.value};
    friends.value = Friends(
      friends: [
        for (final f in list)
          _person(f.senderId == me ? f.recipientId : f.senderId, f.userUsername, f.userAlias, f.userAvatar),
      ]..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase())),
      incoming: [
        for (final r in incoming)
          FriendRequestItem(
            id: r.id,
            person: _person(r.senderId, r.userUsername ?? 'someone', r.userAlias, r.userAvatar),
            at: r.createdAt.toLocal(),
          ),
      ],
      outgoing: [
        for (final r in outgoing)
          FriendRequestItem(
            id: r.id,
            person: _person(r.recipientId, r.userUsername ?? 'someone', r.userAlias, r.userAvatar),
            at: r.createdAt.toLocal(),
          ),
      ],
    );
    for (final m in [
      ...friends.value.friends,
      for (final r in [...friends.value.incoming, ...friends.value.outgoing]) r.person,
    ]) {
      _names[m.userId] = m.displayName;
    }
  }

  Future<void> _reloadFriends() async {
    if (_friendsLoaded) await loadFriends().catchError((Object e) => debugPrint('friends: $e'));
  }

  @override
  Future<void> sendFriendRequest(String userId) async {
    await _call((api) => api.sendFriendRequest(userId));
    await _reloadFriends();
  }

  @override
  Future<void> acceptFriendRequest(String requestId) async {
    await _call((api) => api.acceptFriendRequest(requestId));
    await _reloadFriends();
  }

  @override
  Future<void> rejectFriendRequest(String requestId) async {
    await _call((api) => api.rejectFriendRequest(requestId));
    await _reloadFriends();
  }

  @override
  Future<void> unfriend(String userId) async {
    await _call((api) => api.unfriend(userId));
    await _reloadFriends();
  }

  @override
  Future<ConversationSummary> createGroup(String name, List<String> userIds) async {
    final group = await _call((api) => api.createGroup(name, userIds));
    await refreshConversations();
    return conversations.value.where((c) => c.id == group.id).firstOrNull ?? _summary(group, profile.value?.id);
  }

  @override
  Future<void> renameConversation(String conversationId, String name) async {
    await _call((api) => api.updateConversation(conversationId, name));
    await refreshConversations();
  }

  @override
  Future<void> addToConversation(String conversationId, String userId) async {
    await _call((api) => api.addConversationMember(conversationId, userId));
    await refreshConversations();
  }

  @override
  Future<void> removeFromConversation(String conversationId, String userId) async {
    await _call((api) => api.removeConversationMember(conversationId, userId));
    await refreshConversations();
  }

  @override
  Future<void> leaveConversation(String conversationId) async {
    await _call((api) => api.leaveConversation(conversationId));
    await refreshConversations();
  }

  void _setProfile(duvet.UserMeResult me) {
    profile.value = Profile(
      id: me.id,
      username: me.username,
      alias: me.alias,
      avatarUrl: avatarUrl(me.avatar),
      bannerUrl: avatarUrl(me.banner),
      bio: me.custom.trim().isEmpty ? null : me.custom,
      emailVerified: me.emailVerified,
      // An answer that doesn't say keeps the status known (READY's, say).
      status: _chosen(me.status) ?? (profile.value?.id == me.id ? profile.value?.status : null) ?? Presence.online,
    );
    _saveHome();
  }

  /// The status a user chose, as the API and the gateway number them: online
  /// (1) or do not disturb (2). Null for anything else: offline, or not said.
  static Presence? _chosen(duvet.UserStatus? status) => switch (status) {
    duvet.UserStatus.online => Presence.online,
    duvet.UserStatus.dnd => Presence.doNotDisturb,
    _ => null,
  };

  /// The user chose [status], here or on another device.
  void _choose(Presence status) {
    final p = profile.value;
    if (p == null || p.status == status) return;
    profile.value = p.withStatus(status);
    _saveHome();
  }

  @override
  Future<void> signUp({
    required String username,
    required String email,
    required String password,
    String? alias,
  }) async {
    _closeSession();
    final api = _api = duvet.RestClient(_httpClient(), router: _router);
    try {
      await api.signIn(username: username, alias: alias, password: password, email: email);
      await api.logIn(email, password);
      await _start();
    } catch (_) {
      _closeSession();
      rethrow;
    }
  }

  // Signed out, the requests go on a client of their own.
  Future<T> _anonymous<T>(Future<T> Function(duvet.RestClient api) request) async {
    final api = _api;
    if (api != null) return _call(request);
    final client = duvet.RestClient(_httpClient(), router: _router);
    try {
      return await request(client);
    } finally {
      client.client.close();
    }
  }

  @override
  Future<void> sendVerificationEmail() => _call((api) => api.sendVerificationEmail());

  @override
  Future<void> verifyEmail(String token) async {
    await _anonymous((api) => api.verifyEmail(token));
    if (_api != null) _setProfile(await _call((api) => api.me()));
  }

  @override
  Future<void> forgotPassword(String email) => _anonymous((api) => api.forgotPassword(email));

  @override
  Future<void> resetPassword(String token, String password) => _anonymous((api) => api.resetPassword(token, password));

  @override
  Future<void> sendChangeEmail(String email) => _call((api) => api.sendChangeEmail(email));

  @override
  Future<void> changeEmail(String token, String email) => _anonymous((api) => api.changeEmail(token, email));

  @override
  Future<void> updateProfile({required String alias, String? bio}) async {
    final trimmed = alias.trim();
    final about = bio?.trim();
    final me = await _call(
      (api) => api.updateUser(alias: trimmed.isEmpty ? null : trimmed, clearAlias: trimmed.isEmpty, custom: about),
    );
    _setProfile(me);
    // An API from before bios saves the rest, and answers the bio it had.
    if (about != null && me.custom != about) {
      throw const ActionFailed('This server can’t save a bio yet: it needs the latest API');
    }
  }

  @override
  Future<void> setStatus(Presence status) async {
    final chosen = switch (status) {
      Presence.online => duvet.UserStatus.online,
      Presence.doNotDisturb => duvet.UserStatus.dnd,
      Presence.offline => throw ArgumentError.value(status, 'status', 'offline isn’t a choice'),
    };
    final duvet.UserMeResult me;
    try {
      me = await _call((api) => api.setStatus(chosen));
    } on duvet.DuvetApiException catch (e) {
      debugPrint('status: $e');
      throw ActionFailed(
        _routeMissing(e)
            ? 'This server can’t set a status yet: it needs the latest API'
            : 'Couldn’t change your status (${e.statusCode})',
      );
    } on TimeoutException {
      throw const ActionFailed('Duvet didn’t answer. Check your connection and try again.');
    }
    _setProfile(me);
    // Shown at once while connected; the gateway's USER_STATUS_UPDATE follows.
    if (presence.value[me.id] case final shown? when shown != Presence.offline) {
      presence.value = {...presence.value, me.id: profile.value!.status};
    }
  }

  @override
  Future<void> uploadProfileImage(ProfileImage kind, String path, CropRect crop) async {
    final bytes = await File(path).readAsBytes();
    final me = await _call(
      (api) => api.uploadProfileImage(
        kind == ProfileImage.avatar ? duvet.ProfileImageKind.avatar : duvet.ProfileImageKind.banner,
        bytes,
        path.split(Platform.pathSeparator).last,
        (x: crop.x, y: crop.y, w: crop.w, h: crop.h),
      ),
    );
    _setProfile(me);
  }

  @override
  Future<List<MyFile>> myFiles() async => [
    for (final a in await _call((api) => api.getMyAttachments()))
      if (a.deletedAt == null && a.deleted != true)
        MyFile(
          id: a.id,
          name: a.filename,
          contentType: a.contentType,
          sizeBytes: a.sizeBytes,
          createdAt: a.createdAt.toLocal(),
          url: attachmentUrl(a.id),
        ),
  ];

  @override
  Future<void> deleteMyFile(String id) => _call((api) => api.deleteMyAttachment(id));

  @override
  Future<StorageInfo> storage() async {
    final (s, buckets) = await (_call((api) => api.getMyStorageStatus()), _call((api) => api.getMyBuckets())).wait;
    return StorageInfo(
      used: s.usedBytes,
      max: s.maxBytes,
      buckets: [for (final b in buckets) (name: b.name, used: b.usedBytes, max: b.maxBytes, active: b.isActive)],
    );
  }

  // ---------------------------------------------------------------------------
  // Running a Space
  // ---------------------------------------------------------------------------

  int _permsIn(String spaceId) {
    final space = _spaces[spaceId]?.space;
    final me = profile.value?.id;
    if (space == null || me == null) return 0;
    if (space.ownerId == me) return Perm.all;
    final roles = _roles[spaceId] ?? const {};
    var perms = roles[spaceId]?.permissions ?? 0;
    for (final id in _memberRoles[spaceId]?[me] ?? const <String>[]) {
      perms |= roles[id]?.permissions ?? 0;
    }
    return Perm.has(perms, Perm.administrator) ? Perm.all : perms;
  }

  // A room's permissions as desktop's `computeRoomPermissions` has them: the
  // roles', then @everyone's overwrite, the roles' together, the member's own.
  @override
  bool canInRoom(String spaceId, String roomId, int bit) {
    final me = profile.value?.id;
    final space = _spaces[spaceId]?.space;
    if (me == null || space == null) return false;
    if (space.ownerId == me) return true;
    final mine = _memberRoles[spaceId]?[me] ?? const <String>[];
    final roles = _roles[spaceId] ?? const {};
    var perms = 0;
    for (final id in mine) {
      perms |= roles[id]?.permissions ?? 0;
    }
    if (perms & Perm.administrator != 0) return true;
    final overwrites = [
      for (final o in _overwrites[spaceId]?[roomId] ?? const <duvet.GatewayRoomOverwrite>[])
        if (o.deletedAt == null) o,
    ];
    void apply(int deny, int allow) => perms = (perms & ~deny) | allow;
    var allow = 0, deny = 0;
    for (final o in overwrites) {
      if (o.targetType == 0 && o.targetId == spaceId && mine.contains(spaceId)) {
        allow |= o.allowFlags;
        deny |= o.denyFlags;
      }
    }
    apply(deny, allow);
    allow = 0;
    deny = 0;
    for (final o in overwrites) {
      if (o.targetType == 0 && o.targetId != spaceId && mine.contains(o.targetId)) {
        allow |= o.allowFlags;
        deny |= o.denyFlags;
      }
    }
    apply(deny, allow);
    if (overwrites.where((o) => o.targetType == 1 && o.targetId == me).firstOrNull case final o?) {
      apply(o.denyFlags, o.allowFlags);
    }
    return perms & bit == bit;
  }

  @override
  SpaceProfile? spaceProfile(String spaceId) {
    final space = _spaces[spaceId]?.space;
    if (space == null) return null;
    return SpaceProfile(
      id: space.id,
      name: space.name,
      description: space.description,
      iconUrl: avatarUrl(space.icon),
      bannerUrl: avatarUrl(space.banner),
      memberCount: _spaceMemberIds[spaceId]?.length ?? 0,
      owner: space.ownerId == profile.value?.id,
      perms: _permsIn(spaceId),
    );
  }

  @override
  Future<void> updateSpace(
    String spaceId, {
    String? name,
    String? description,
    String? iconPath,
    String? bannerPath,
  }) async {
    try {
      await _call(
        (api) => api.updateSpace(
          spaceId,
          name: name,
          description: description,
          icon: iconPath == null ? null : File(iconPath),
          banner: bannerPath == null ? null : File(bannerPath),
        ),
      );
    } on duvet.DuvetApiException catch (e) {
      // E.g. 422: pictures need the Space to have a storage bucket.
      if (e.statusCode == 400 || e.statusCode == 422) {
        if (_serverReason(e) case final reason?) throw ActionFailed(reason);
      }
      rethrow;
    }
    // SPACE_UPDATE brings the change.
  }

  @override
  List<AdminRoom> adminRooms(String spaceId) => [
    for (final r in (_spaces[spaceId]?.rooms.values.toList() ?? [])..sort((a, b) => a.position.compareTo(b.position)))
      AdminRoom(
        id: r.id,
        name: r.name,
        kind: switch (r.type) {
          duvet.RoomType.voice => AdminRoomKind.voice,
          duvet.RoomType.category => AdminRoomKind.category,
          _ => AdminRoomKind.text,
        },
        parentId: r.parentId,
        position: r.position,
      ),
  ];

  @override
  Future<void> createRoom(String spaceId, String name, AdminRoomKind kind, {String? parentId}) async {
    final room = await _call(
      (api) => api.createRoom(spaceId, name, switch (kind) {
        AdminRoomKind.voice => duvet.RoomType.voice,
        AdminRoomKind.category => duvet.RoomType.category,
        AdminRoomKind.text => duvet.RoomType.text,
      }, parentId: parentId),
    );
    _spaces[spaceId]?.rooms[room.id] = room;
    _publishSpaces();
  }

  @override
  Future<void> renameRoom(String spaceId, String roomId, String name) async {
    final room = await _call((api) => api.updateRoom(spaceId, roomId, name: name));
    _spaces[spaceId]?.rooms[room.id] = room;
    _publishSpaces();
  }

  @override
  Future<void> deleteRoom(String spaceId, String roomId) async {
    await _call((api) => api.deleteRoom(spaceId, roomId));
    _spaces[spaceId]?.rooms.remove(roomId);
    _publishSpaces();
  }

  @override
  Future<void> moveRoom(String spaceId, String roomId, int position) async {
    final room = await _call((api) => api.updateRoom(spaceId, roomId, position: position));
    _spaces[spaceId]?.rooms[room.id] = room;
    _publishSpaces();
  }

  @override
  List<RoomOverwrite> overwrites(String spaceId, String roomId) => [
    for (final o in _overwrites[spaceId]?[roomId] ?? const <duvet.GatewayRoomOverwrite>[])
      if (o.deletedAt == null)
        RoomOverwrite(targetId: o.targetId, targetType: o.targetType, allow: o.allowFlags, deny: o.denyFlags),
  ];

  @override
  Future<void> setOverwrite(String spaceId, String roomId, RoomOverwrite overwrite) async {
    final list = (_overwrites[spaceId] ??= {})[roomId] ??= [];
    if (overwrite.isEmpty) {
      await _call((api) => api.deleteRoomOverwrite(spaceId, roomId, overwrite.targetId));
      list.removeWhere((o) => o.targetId == overwrite.targetId);
      return;
    }
    final saved = await _call(
      (api) => api.upsertRoomOverwrite(
        spaceId,
        roomId,
        overwrite.targetId,
        overwrite.targetType,
        overwrite.allow,
        overwrite.deny,
      ),
    );
    list
      ..removeWhere((o) => o.targetId == overwrite.targetId)
      ..add(saved);
  }

  SpaceRole _role(String spaceId, duvet.GatewayRole r) => SpaceRole(
    id: r.id,
    name: r.name,
    color: r.colorFrom,
    perms: r.permissions,
    position: r.position,
    everyone: r.id == spaceId,
    memberCount: r.id == spaceId
        ? _spaceMemberIds[spaceId]?.length ?? 0
        : (_memberRoles[spaceId]?.values.where((ids) => ids.contains(r.id)).length ?? 0),
  );

  @override
  List<SpaceRole> roles(String spaceId) {
    final all = [for (final r in _roles[spaceId]?.values ?? const <duvet.GatewayRole>[]) _role(spaceId, r)];
    return all..sort((a, b) {
      if (a.everyone != b.everyone) return a.everyone ? 1 : -1;
      return b.position.compareTo(a.position);
    });
  }

  @override
  Future<SpaceRole> createRole(String spaceId, String name) async {
    final r = await _call((api) => api.createRole(spaceId, name));
    (_roles[spaceId] ??= {})[r.id] = r;
    return _role(spaceId, r);
  }

  @override
  Future<void> updateRole(
    String spaceId,
    String roleId, {
    String? name,
    int? color,
    bool clearColor = false,
    int? perms,
  }) async {
    final r = await _call(
      (api) =>
          api.updateRole(spaceId, roleId, name: name, colorFrom: color, permissions: perms, clearColors: clearColor),
    );
    (_roles[spaceId] ??= {})[r.id] = r;
    _publishSpaces();
  }

  @override
  Future<void> deleteRole(String spaceId, String roleId) async {
    await _call((api) => api.deleteRole(spaceId, roleId));
    _roles[spaceId]?.remove(roleId);
    for (final ids in _memberRoles[spaceId]?.values ?? const <List<String>>[]) {
      ids.remove(roleId);
    }
  }

  @override
  List<String> roleMembers(String spaceId, String roleId) => [
    for (final e in _memberRoles[spaceId]?.entries ?? const <MapEntry<String, List<String>>>[])
      if (e.value.contains(roleId)) e.key,
  ];

  @override
  Future<void> setRole(String spaceId, String roleId, String userId, {required bool has}) async {
    await _call(
      (api) =>
          has ? api.assignRoleToMember(spaceId, roleId, userId) : api.removeRoleFromMember(spaceId, roleId, userId),
    );
    final ids = (_memberRoles[spaceId] ??= {})[userId] ??= [];
    has ? (ids.contains(roleId) ? null : ids.add(roleId)) : ids.remove(roleId);
  }

  @override
  Future<List<SpaceInvite>> spaceInvites(String spaceId) async {
    final rooms = _spaces[spaceId]?.rooms ?? const {};
    return [
      for (final i in await _call((api) => api.listSpaceInvites(spaceId)))
        SpaceInvite(
          id: i.id,
          code: i.code,
          roomName: rooms[i.roomId]?.name ?? 'a room',
          createdBy: nameOf(i.createdBy) ?? 'Someone',
          createdAt: i.createdAt.toLocal(),
          expiresAt: i.expiresAt?.toLocal(),
        ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<void> revokeInvite(String spaceId, String inviteId) => _call((api) => api.revokeInvite(spaceId, inviteId));

  @override
  Future<List<SpaceAsset>> assets(String spaceId, AssetKind kind) async => switch (kind) {
    AssetKind.emoji => [
      for (final e in await _call((api) => api.listEmojis(spaceId)))
        if (e.deletedAt == null) SpaceAsset(id: e.id, name: e.name, url: attachmentUrl(e.attachmentId)),
    ],
    AssetKind.sticker => [
      for (final s in await _call((api) => api.listStickers(spaceId)))
        if (s.deletedAt == null) SpaceAsset(id: s.id, name: s.name, url: attachmentUrl(s.attachmentId)),
    ],
  };

  void _assetsChanged(String spaceId) {
    _emojis.remove(spaceId);
    _stickers.remove(spaceId);
  }

  @override
  Future<void> addAsset(String spaceId, AssetKind kind, String name, String path) async {
    await _call(
      (api) => kind == AssetKind.emoji
          ? api.createEmoji(spaceId, name, File(path))
          : api.createSticker(spaceId, name, File(path)),
    );
    _assetsChanged(spaceId);
  }

  @override
  Future<void> renameAsset(String spaceId, AssetKind kind, String id, String name) async {
    await _call(
      (api) => kind == AssetKind.emoji ? api.updateEmoji(spaceId, id, name) : api.updateSticker(spaceId, id, name),
    );
    _assetsChanged(spaceId);
  }

  @override
  Future<void> deleteAsset(String spaceId, AssetKind kind, String id) async {
    await _call((api) => kind == AssetKind.emoji ? api.deleteEmoji(spaceId, id) : api.deleteSticker(spaceId, id));
    _assetsChanged(spaceId);
  }

  @override
  Future<List<SpaceWebhook>> webhooks(String spaceId) async {
    final rooms = [
      for (final r in _spaces[spaceId]?.rooms.values ?? const <duvet.GatewayRoom>[])
        if (r.type == duvet.RoomType.text) r,
    ];
    final lists = await Future.wait([for (final r in rooms) _call((api) => api.listWebhooks(spaceId, r.id))]);
    return [
      for (final (i, list) in lists.indexed)
        for (final w in list)
          SpaceWebhook(
            id: w.id,
            roomId: w.roomId,
            roomName: rooms[i].name,
            name: w.username,
            avatarUrl: avatarUrl(w.avatar),
            createdAt: w.createdAt.toLocal(),
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  String _webhookUrl(String id, String token) => 'https://${_router.api}/api/webhooks/$id/$token';

  @override
  Future<String> createWebhook(String spaceId, String roomId, String name) async {
    final created = await _call((api) => api.createWebhook(spaceId, roomId, name));
    return _webhookUrl(created.webhook.id, created.token);
  }

  @override
  Future<String> resetWebhook(String spaceId, SpaceWebhook webhook) async {
    final token = await _call((api) => api.resetWebhookToken(spaceId, webhook.roomId, webhook.id));
    return _webhookUrl(webhook.id, token);
  }

  @override
  Future<void> deleteWebhook(String spaceId, SpaceWebhook webhook) =>
      _call((api) => api.deleteWebhook(spaceId, webhook.roomId, webhook.id));

  @override
  Future<SpaceStorage> spaceStorage(String spaceId) async {
    final (used, buckets, files) = await (
      _call((api) => api.getSpaceStorageUsed(spaceId)),
      _call((api) => api.getSpaceBuckets(spaceId)),
      _call((api) => api.getSpaceAttachments(spaceId)),
    ).wait;
    return SpaceStorage(
      used: used,
      buckets: [for (final b in buckets) (name: b.name, used: b.usedBytes, max: b.maxBytes, active: b.isActive)],
      files: [
        for (final f in files)
          if (f.deletedAt == null && f.deleted != true)
            (name: f.filename, contentType: f.contentType, size: f.sizeBytes, createdAt: f.createdAt.toLocal()),
      ]..sort((a, b) => b.size.compareTo(a.size)),
    );
  }

  @override
  Future<List<BotCommand>> commands(String spaceId) async {
    final all = await _call((api) => api.getSpaceCommands(spaceId));
    final apps = {for (final a in all.applications) a.id: a.name};
    return [
      for (final c in all.commands)
        if (c.type == 1)
          BotCommand(
            id: c.id,
            applicationId: c.applicationId,
            appName: apps[c.applicationId] ?? 'Bot',
            name: c.name,
            description: c.description,
            options: [
              for (final o in c.options)
                BotCommandOption(
                  type: o.type,
                  name: o.name,
                  description: o.description,
                  required: o.required,
                  choices: [
                    for (final ch in o.choices ?? const <duvet.CommandChoice>[]) (name: ch.name, value: ch.value),
                  ],
                  minValue: o.minValue,
                  maxValue: o.maxValue,
                  minLength: o.minLength,
                  maxLength: o.maxLength,
                ),
            ],
          ),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  BotModal? _modalOf(duvet.InteractionReply reply, String roomId, String? messageId) => reply.isModal
      ? BotModal.fromJson(reply.modal!, applicationId: reply.applicationId!, roomId: roomId, messageId: messageId)
      : null;

  @override
  Future<BotModal?> useComponent(
    RoomTarget target,
    String messageId,
    UiComponent component, {
    List<String>? values,
  }) async {
    final reply = await _call(
      (api) => api.useComponent(
        target.roomId,
        messageId,
        duvet.ComponentUse(customId: component.customId ?? '', componentType: component.type, values: values),
      ),
    );
    return _modalOf(reply, target.roomId, messageId);
  }

  @override
  Future<BotModal?> useCommand(RoomTarget target, BotCommand command, Map<String, Object> options) async {
    final types = {for (final o in command.options) o.name: o.type};
    final reply = await _call(
      (api) => api.useCommand(
        target.roomId,
        command.applicationId,
        duvet.CommandUse(
          id: command.id,
          name: command.name,
          options: [
            for (final e in options.entries) duvet.UsedOption(name: e.key, type: types[e.key] ?? 3, value: e.value),
          ],
        ),
      ),
    );
    return _modalOf(reply, target.roomId, null);
  }

  @override
  Future<void> submitModal(BotModal modal, List<Map<String, dynamic>> components) => _call(
    (api) => api.submitModal(modal.roomId, modal.applicationId, modal.customId, components, messageId: modal.messageId),
  );

  @override
  Future<BotInfo> bot(String userId) async {
    final b = await _call((api) => api.getBotUser(userId));
    return BotInfo(id: b.id, name: b.alias?.isNotEmpty == true ? b.alias! : b.username, avatarUrl: avatarUrl(b.avatar));
  }

  @override
  Future<void> addBot(String spaceId, String botId) => _call((api) => api.addBotToSpace(spaceId, botId));

  @override
  List<({String id, String name})> spaceRoles(String spaceId) => [
    for (final r in (_roles[spaceId]?.values.toList() ?? [])..sort((a, b) => b.position.compareTo(a.position)))
      if (r.name != '@everyone') (id: r.id, name: r.name),
  ];

  @override
  Future<InvitePreview> invite(String code) async {
    final info = await _call((api) => api.getInvite(code));
    return InvitePreview(
      code: info.code,
      spaceId: info.spaceId,
      spaceName: info.spaceName,
      description: info.description,
      memberCount: info.memberCount,
      joined: _spaces.containsKey(info.spaceId),
    );
  }

  @override
  Future<String> joinInvite(String code) async => (await _call((api) => api.joinInvite(code))).spaceId;

  @override
  Future<List<Member>> members(ChatTarget target, {bool refresh = false}) async {
    switch (target) {
      case ConversationTarget(:final conversationId):
        if (refresh || !_conversationMembers.containsKey(conversationId)) await refreshConversations();
        return _conversationMembers[conversationId] ?? const [];
      case RoomTarget(:final spaceId):
        if (refresh) _spaceMembers.remove(spaceId);
        final pending = _spaceMembers[spaceId] ??= _fetchSpaceMembers(spaceId);
        try {
          return await pending;
        } catch (_) {
          // Not cached: the next look tries again.
          if (identical(_spaceMembers[spaceId], pending)) _spaceMembers.remove(spaceId);
          rethrow;
        }
    }
  }

  // Every page, up to a few thousand members: the list and mentions need names.
  Future<List<Member>> _fetchSpaceMembers(String spaceId) async {
    final all = <duvet.SpaceMemberWithUser>[];
    while (all.length < 5000) {
      final page = await _call(
        (api) => api.getSpaceMembers(spaceId, afterId: all.lastOrNull?.id, afterPos: all.lastOrNull?.maxPos),
      );
      all.addAll(page);
      if (page.length < duvet.membersPageSize) break;
    }
    // Not the members' status_id, which isn't live: presence comes from
    // SPACE_CREATE's member_statuses and USER_STATUS_UPDATE.
    final members = [
      for (final m in all)
        Member(
          userId: m.user.id,
          username: m.user.username,
          alias: m.alias?.isNotEmpty == true ? m.alias : m.user.alias,
          avatarUrl: avatarUrl(m.user.avatar),
          isBot: m.user.isBot,
          bio: m.user.custom.trim().isEmpty ? null : m.user.custom,
          bannerUrl: avatarUrl(m.user.banner),
        ),
    ];
    for (final m in members) {
      _names[m.userId] = m.displayName;
    }
    (_spaceMemberIds[spaceId] ??= {}).addAll(members.map((m) => m.userId));
    _loadedMembers[spaceId] = members;
    _publishSpaces();
    return members;
  }

  static Presence _presence(duvet.UserStatus status) => switch (status) {
    duvet.UserStatus.online => Presence.online,
    duvet.UserStatus.dnd => Presence.doNotDisturb,
    _ => Presence.offline,
  };

  @override
  Future<List<CustomEmoji>> customEmojis(ChatTarget target) async {
    if (target is! RoomTarget) return const [];
    final spaceId = target.spaceId;
    final pending = _emojis[spaceId] ??= _call((api) => api.listEmojis(spaceId)).then(
      (list) => [
        for (final e in list)
          if (e.deletedAt == null) CustomEmoji(id: e.id, name: e.name, url: attachmentUrl(e.attachmentId)),
      ],
    );
    unawaited(
      pending.then((list) {
        for (final e in list) {
          _emojiNames[e.id] = e.name;
        }
      }, onError: (_) {}),
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_emojis[spaceId], pending)) _emojis.remove(spaceId);
      rethrow;
    }
  }

  @override
  Future<List<Sticker>> stickers(ChatTarget target) async {
    if (target is! RoomTarget) return const [];
    final spaceId = target.spaceId;
    final pending = _stickers[spaceId] ??= _call((api) => api.listStickers(spaceId)).then(
      (list) => [
        for (final s in list)
          if (s.deletedAt == null)
            Sticker(id: s.id, name: s.name, attachmentId: s.attachmentId, url: attachmentUrl(s.attachmentId)),
      ],
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_stickers[spaceId], pending)) _stickers.remove(spaceId);
      rethrow;
    }
  }

  @override
  Future<ConversationSummary> directMessage(String userId) async {
    final duvet.Conversation conversation;
    try {
      conversation = await _call((api) => api.createDM(userId));
    } on duvet.DuvetApiException catch (e) {
      // The server only opens DMs between friends.
      if (e.statusCode == 403) {
        final name = nameOf(userId);
        throw ActionFailed(
          'You can only message friends. ${name == null ? 'Send them' : 'Send $name'} a friend request first.',
        );
      }
      rethrow;
    } on TimeoutException {
      throw const ActionFailed('Duvet didn’t answer. Check your connection and try again.');
    }
    await refreshConversations();
    return conversations.value.where((c) => c.id == conversation.id).firstOrNull ??
        _summary(conversation, profile.value?.id);
  }

  @override
  Future<void> sendTyping(ChatTarget target) async {
    try {
      await switch (target) {
        RoomTarget(:final roomId) => _call((api) => api.sendTypingIndicator(roomId)),
        ConversationTarget(:final conversationId) => _call((api) => api.sendConversationTyping(conversationId)),
      };
    } on Exception {
      // Best effort.
    }
  }

  @override
  void opened(ChatTarget target, String title, {ChatMessage? latest}) => _recents.opened(target, title, latest: latest);

  @override
  void markRead(ChatTarget target, String messageId) {
    if (unread.value.contains(target.id)) unread.value = {...unread.value}..remove(target.id);
    if (mentions.value.containsKey(target.id)) mentions.value = {...mentions.value}..remove(target.id);
    if (target is RoomTarget) _lastRead[target.id] = messageId;
    final api = _api;
    if (api == null) return;
    unawaited(switch (target) {
      RoomTarget(:final roomId) => api.ackRoom(roomId, messageId),
      ConversationTarget(:final conversationId) => api.ackConversation(conversationId, messageId),
    });
  }

  ChatMessage _roomMessage(duvet.GatewayMessage m) {
    final name = m.memberAlias ?? m.user?.alias ?? m.user?.username;
    if (m.authorId != null && name != null) _names[m.authorId!] = name;
    return _roomMessageNamed(m, name ?? (m.webhookId != null ? 'Webhook' : 'Unknown'));
  }

  ChatMessage _roomMessageNamed(duvet.GatewayMessage m, String authorName) => ChatMessage(
    id: m.id,
    authorId: m.authorId,
    authorName: authorName,
    authorAvatarUrl: avatarUrl(m.user?.avatar),
    content: m.content ?? '',
    createdAt: m.createdAt.toLocal(),
    edited: m.updatedAt.difference(m.createdAt) > const Duration(seconds: 1),
    nonce: m.nonce,
    isNotice: m.type == duvet.MessageType.pinNotice,
    isVoice: m.type == duvet.MessageType.voice,
    pinned: m.pinnedAt != null,
    components: componentsFromJson(m.components),
    rawComponents: m.components ?? const [],
    fromBot: m.user?.isBot ?? false,
    fromWebhook: m.webhookId != null,
    attachments: _attachments(m.attachments),
    stickerUrl: m.stickerAttachmentId == null ? null : attachmentUrl(m.stickerAttachmentId!),
    embeds: _embeds(m.embeds),
    reply: _reply(m.referencedMessage, m.refMessageId),
    reactions: _reactions(m.reactions),
  );

  ChatMessage _directMessage(duvet.DirectMessage m) {
    final name = m.user?.alias ?? m.user?.username;
    if (name != null) _names[m.authorId] = name;
    return _directMessageNamed(m, name ?? 'Unknown');
  }

  ChatMessage _directMessageNamed(duvet.DirectMessage m, String authorName) => ChatMessage(
    id: m.id,
    authorId: m.authorId,
    authorName: authorName,
    authorAvatarUrl: avatarUrl(m.user?.avatar),
    content: m.content ?? '',
    createdAt: m.createdAt.toLocal(),
    edited: m.updatedAt.difference(m.createdAt) > const Duration(seconds: 1),
    nonce: m.nonce,
    isNotice: m.type == duvet.MessageType.pinNotice,
    isVoice: m.type == duvet.MessageType.voice,
    pinned: m.pinnedAt != null,
    fromBot: m.user?.isBot ?? false,
    attachments: _attachments(m.attachments),
    stickerUrl: m.stickerAttachmentId == null ? null : attachmentUrl(m.stickerAttachmentId!),
    embeds: _embeds(m.embeds),
    reply: _reply(m.referencedMessage, null),
    reactions: _reactions(m.reactions),
  );

  MessageReply? _reply(duvet.ReferencedMessage? ref, String? id) {
    final messageId = ref?.messageId ?? id;
    if (messageId == null) return null;
    final authorId = ref?.authorId;
    return MessageReply(
      messageId: messageId,
      authorId: authorId,
      authorName: ref?.authorName ?? (authorId == null ? null : nameOf(authorId)) ?? 'Someone',
      content: ref?.content ?? '',
    );
  }

  static List<Reaction> _reactions(List<duvet.MessageReaction>? list) => [
    for (final r in list ?? const <duvet.MessageReaction>[])
      if (r.users.isNotEmpty) Reaction(emoji: r.emojiName, emojiId: r.emojiId, users: {...r.users}),
  ];

  List<MessageAttachment> _attachments(List<duvet.Attachment>? list) => [
    for (final a in list ?? const <duvet.Attachment>[])
      if (a.deletedAt == null && a.deleted != true)
        MessageAttachment(
          id: a.id,
          filename: a.filename,
          contentType: a.contentType,
          url: switch (a.url) {
            final url? when url.startsWith('http') => url,
            final url? when url.startsWith('/') => 'https://${_router.api}$url',
            _ => attachmentUrl(a.id),
          },
          width: a.width,
          height: a.height,
          sizeBytes: a.sizeBytes,
        ),
  ];

  static List<MessageEmbed> _embeds(List<duvet.Embed>? list) => [
    for (final e in list ?? const <duvet.Embed>[])
      MessageEmbed(
        title: e.title ?? e.author?.name,
        description: e.description,
        url: e.url,
        imageUrl: e.image?.url ?? e.thumbnail?.url,
        provider: e.provider,
      ),
  ]..removeWhere((e) => e.isEmpty);

  /// An attachment's URL, served outside `/api`.
  String attachmentUrl(String id) => 'https://${_router.api}/attachments/$id';

  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

  /// An avatar's or icon's URL: the API names an attachment by its ID, served
  /// outside `/api`, as the desktop app's `getAvatarURL` does.
  String? avatarUrl(String? avatar) {
    if (avatar == null || avatar.isEmpty) return null;
    if (avatar.startsWith('https://') || avatar.startsWith('http://')) return avatar;
    return _uuid.hasMatch(avatar) ? 'https://${_router.api}/attachments/$avatar' : null;
  }

  @override
  void dispose() {
    _closeSession();
    _voiceSignaling.dispose();
    _signedOut.close();
    _resumed.close();
    mentions.dispose();
    _messageEvents.close();
    _typing.close();
    _recents.dispose();
    presence.dispose();
  }
}
