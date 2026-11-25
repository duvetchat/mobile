import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'links.dart' show duvetDomain;
import 'cache.dart';
import 'call_notices.dart';
import 'images.dart' show clearImageCache, prefetchImages;
import 'message_tokens.dart';
import 'models.dart';
import 'recent_chats.dart';
import 'recent_chats.dart' as recent show previewOf;
import 'repository.dart';
import 'session_store.dart';
import 'voice_signaling.dart';

// Someone who joined a Space, with their user ID, or left it (null).
typedef _MemberMove = ({String memberId, String? userId});

/// The API and the gateway the app reaches, picked at build time (README, Build flags); production by default.
const duvetRouter = ApiRouter(
  api: String.fromEnvironment('DUVET_API', defaultValue: 'api.duvet.chat'),
  ws: String.fromEnvironment('DUVET_GATEWAY', defaultValue: 'ws.duvet.chat'),
  secure: bool.fromEnvironment('DUVET_SECURE', defaultValue: true),
);

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

/// An avatar's or icon's URL on [router]'s API: the API names an attachment by its ID, served outside `/api`, as the
/// desktop app's `getAvatarURL` does, and a webhook's avatar may be a URL. Null for none, or for anything else.
String? avatarUrlOn(ApiRouter router, String? avatar) {
  if (avatar == null || avatar.isEmpty) return null;
  if (avatar.startsWith('https://') || avatar.startsWith('http://')) return avatar;
  return _uuid.hasMatch(avatar) ? '${router.secure ? 'https' : 'http'}://${router.api}/attachments/$avatar' : null;
}

/// [ChatRepository] over the Duvet API (`duvet_client`): REST for history and
/// sending, the gateway for everything live.
///
/// The session is renewed before it runs out, as the desktop app's is: as it
/// starts and when the app comes back to the front once its tokens are an
/// hour old, and at a check every 10 minutes once they're 23 hours old (they
/// last 24). The gateway identifies with the REST client's token, so it takes
/// each renewal on its next socket. A session that ended closes the socket
/// with 4004, or, ended while none was open, gets the next one refused at its
/// upgrade (401): either asks the API about it at once, which signs out of a
/// dead one.
///
/// Limits of duvet_client this works around or lives with:
/// - A space left while offline stays listed until the next sign-in: READY
///   doesn't list the spaces, it's followed by a SPACE_CREATE for each.
class DuvetRepository implements ChatRepository {
  final SessionStore _store;
  final RecentChatsStore _recentsStore;
  late final RecentChats _recents = RecentChats(
    _recentsStore,
    readable: (content) => readableContent(content, nameOf: nameOf, emojiNameOf: emojiNameOf, roomNameOf: _roomNameOf),
  );

  // The saved list's read, which previews catch up after; and the session's
  // first list of conversations, which the chats fetched ahead come from too.
  Future<void> _recentsLoaded = Future.value();
  Future<void> _conversationsLoaded = Future.value();

  // Whose lists kept on this device were read already this session.
  String? _keptLoadedFor;

  // What this device keeps for [userId], read once a session: the recent
  // chats, the folded categories and the pinned chats.
  void _loadKept(String userId) {
    if (_keptLoadedFor == userId) return;
    _keptLoadedFor = userId;
    _recentsLoaded = _recents.load(userId);
    unawaited(_loadCollapsed());
    unawaited(_loadPinned());
  }

  // Names seen this session: members, conversation members, message authors.
  final _names = <String, String>{};
  final _emojiNames = <String, String>{};

  @override
  String? nameOf(String userId) => _names[userId];

  @override
  String? emojiNameOf(String emojiId) => _emojiNames[emojiId];

  // A room the user may see, by name; null for one hidden or gone.
  String? _roomNameOf(String roomId) =>
      spaces.value.expand((s) => s.rooms).where((r) => r.id == roomId).firstOrNull?.name;
  final ApiRouter _router;
  final http.Client Function() _httpClient;

  /// Off in tests, which push events through [handleEvent].
  final bool _connectsGateway;

  /// Whether the chats likely to be opened next get their pages, and the
  /// pictures the lists show, fetched ahead ([_fetchLatest], [_warm]). Off
  /// with the gateway, in tests, unless asked: they'd see requests they
  /// don't expect.
  final bool _preloads;

  // Takes a chat's phone notification away as the chat shows (lib/push); none in tests that don't ask.
  final Future<void> Function(String chatId)? _forgetNotifications;

  DuvetRepository({
    SessionStore? store,
    RecentChatsStore? recentsStore,
    ApiRouter router = duvetRouter,
    http.Client Function()? httpClient,
    @visibleForTesting bool connectGateway = true,
    @visibleForTesting bool? preload,
    ChatCacheStore? cacheStore,
    Future<void> Function(String chatId)? forgetNotifications,
  }) : _cache = ChatCache(cacheStore ?? FileChatCacheStore()),
       _store = store ?? const SecureSessionStore(),
       _recentsStore = recentsStore ?? const SecureRecentChatsStore(),
       _router = router,
       _httpClient = httpClient ?? http.Client.new,
       _connectsGateway = connectGateway,
       _preloads = preload ?? connectGateway,
       _forgetNotifications = forgetNotifications {
    _typing.stream.listen((e) => _setTyping(e.$1, e.$2.userId, e.$2));
    _messageEvents.stream.listen((e) {
      if (e.$2 case MessageCreated(message: ChatMessage(:final authorId?))) _setTyping(e.$1, authorId);
      _keep(e.$1, e.$2);
    });
  }

  @override
  final ValueNotifier<Map<String, List<TypingUser>>> typingNow = ValueNotifier(const {});

  /// When each one typing stops showing, by chat ID and user ID.
  final _typingEnds = <(String, String), Timer>{};

  /// [user] typing in [chatId], for as long as the open chat shows it, or,
  /// without, [userId] no longer: their message came, or the time ran out.
  void _setTyping(String chatId, String userId, [TypingUser? user]) {
    _typingEnds.remove((chatId, userId))?.cancel();
    final was = typingNow.value[chatId] ?? const <TypingUser>[];
    if (user == null && was.every((u) => u.userId != userId)) return;
    if (user != null) {
      _typingEnds[(chatId, userId)] = Timer(const Duration(seconds: 5), () => _setTyping(chatId, userId));
    }
    typingNow.value = {
      ...typingNow.value,
      chatId: [
        for (final u in was)
          if (u.userId != userId) u,
        ?user,
      ],
    }..removeWhere((_, users) => users.isEmpty);
  }

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
  final ValueNotifier<Set<String>> collapsedCategories = ValueNotifier(const {});

  /// The user folded or opened one since the session began: what's saved,
  /// read later, mustn't undo it.
  bool _collapsedTouched = false;

  @override
  void setCategoryCollapsed(String categoryId, bool collapsed) {
    final now = collapsedCategories.value;
    if (now.contains(categoryId) == collapsed) return;
    _collapsedTouched = true;
    collapsedCategories.value = {
      for (final id in now)
        if (id != categoryId) id,
      if (collapsed) categoryId,
    };
    _cache.saveCollapsed(collapsedCategories.value);
  }

  // The folded categories saved on this device, as a session opens.
  Future<void> _loadCollapsed() async {
    final ids = await _cache.loadCollapsed();
    if (ids != null && !_collapsedTouched) collapsedCategories.value = ids;
  }

  @override
  final ValueNotifier<Set<String>> pinnedChats = ValueNotifier(const {});

  // As with [_collapsedTouched]: what's saved mustn't undo a pin made since.
  bool _pinnedTouched = false;

  @override
  void setChatPinned(String key, bool pinned) {
    if (pinnedChats.value.contains(key) == pinned) return;
    _pinnedTouched = true;
    pinnedChats.value = {
      for (final k in pinnedChats.value)
        if (k != key) k,
      if (pinned) key,
    };
    _cache.savePinned(pinnedChats.value);
  }

  Future<void> _loadPinned() async {
    final keys = await _cache.loadPinned();
    if (keys != null && !_pinnedTouched) pinnedChats.value = keys;
  }

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
  final ValueNotifier<Map<String, NotificationLevel>> notificationLevels = ValueNotifier(const {});
  @override
  final drafts = <String, ChatDraft>{};

  // The last message read in each room, from READY, then as the user reads.
  final _lastRead = <String, String>{};
  final _resumed = StreamController<void>.broadcast();
  StreamSubscription<duvet.GatewayConnectionState>? _states;
  StreamSubscription<duvet.GatewayResume>? _resumes;
  StreamSubscription<duvet.GatewayCloseReason>? _closes;
  StreamSubscription<duvet.GatewayConnectFailure>? _failures;
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

  @override
  final ValueNotifier<Set<String>> mobileOnly = ValueNotifier(const {});

  @override
  final ValueNotifier<Map<String, List<duvet.Activity>>> activities = ValueNotifier(const {});

  // Fetched once per session, by space or conversation ID.
  final _spaceMembers = <String, Future<List<Member>>>{};
  final _conversationMembers = <String, List<Member>>{};

  // The user's Spaces' emojis and stickers, all of them; fetched again once any change.
  Future<List<CustomEmoji>>? _emojis;
  Future<List<Sticker>>? _stickers;

  // Spaces by ID, with their rooms as the gateway sends them.
  final _spaces = <String, ({duvet.GatewaySpace space, Map<String, duvet.GatewayRoom> rooms})>{};

  /// The Spaces' order, as READY lists them.
  List<String> _spaceOrder = const [];

  // Who's in each space, as far as known: SPACE_CREATE's members (each has
  // @everyone's role), those SPACE_MEMBER_ADD and _REMOVE tell of, and the
  // member list once fetched.
  final _spaceMemberIds = <String, Set<String>>{};

  // Each space's members' user IDs, by member ID (`Members.id`), which the
  // API's role routes and events name: from the latest members list, and
  // SPACE_MEMBER_ADD since.
  final _memberUsers = <String, Map<String, String>>{};

  // Role changes for members not named yet, by space and member, in the order
  // they came: they apply once a members list or SPACE_MEMBER_ADD names the
  // member.
  final _waitingRoles = <String, Map<String, List<({String roleId, bool added})>>>{};

  // The members list on its way for them, by space.
  final _memberLookups = <String, Future<void>>{};

  // Who joined or left while a members list was on its way, one log per list,
  // by space: the list may be from before them, so it lands with them on top.
  // A list whose log is gone (the Space forgotten or left, or READY after a
  // drop) may be from before that, and names no member IDs.
  final _memberLogs = <String, List<List<_MemberMove>>>{};

  duvet.RestClient get _rest => _api ?? (throw StateError('Not signed in'));

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  @override
  Future<bool> restore() async {
    try {
      return await _restore();
    } finally {
      // A read that failed has nothing to show either.
      _restoreIsRead();
    }
  }

  /// Done once [restore] has read what the phone keeps, and knows what shows
  /// first: the kept home, signed in; the welcome, with no session; or a wait
  /// for the API. The first frame can wait for this, which no network is in,
  /// and draw the home rather than a spinner a moment before it.
  Future<void> get restoreRead => _restoreRead.future;
  final _restoreRead = Completer<void>();

  void _restoreIsRead() {
    if (!_restoreRead.isCompleted) _restoreRead.complete();
  }

  Future<bool> _restore() async {
    // Read while the session is: neither needs the other. Signed out, it was
    // read for nothing; a read that fails gives none, and throws nothing.
    final homeLoading = _cache.loadHome();
    final saved = await _store.read();
    final home = await homeLoading;
    // The pages of conversations a version before this one kept, their text
    // in the clear, go before anything shows: only rooms' are kept now.
    await _cache.keepRoomPages({
      for (final space in home?.spaces ?? const <Space>[])
        for (final room in space.rooms) room.id,
    });
    if (saved == null) return false;
    // What was kept draws the lists at once, until the API and the gateway
    // answer ([_publishSpaces] keeps the Spaces READY names until each comes).
    // Before [_start], whose profile saves the home with them, not empty.
    if (home != null) {
      conversations.value = home.conversations;
      spaces.value = home.spaces;
      // Theirs until READY names them: a list published before it keeps them.
      _spaceOrder = [for (final s in home.spaces) s.id];
    }
    _api = duvet.RestClient(_httpClient(), router: _router, token: saved.token, sessionToken: saved.sessionToken);
    _saved = saved;
    if (home != null && saved.userId == home.profile.id) {
      // The session's own home: it shows now, and the session starts behind
      // it. Connecting, not offline, which would say so over the chats until
      // the gateway is up. A home kept for another account, or a session that
      // doesn't say whose it is (an older version saved it), waits for the API
      // below: none of another account's shows under this one.
      _profileKept = true;
      _shownBeforeReady = true;
      profile.value = home.profile;
      status.value = LiveStatus.connecting;
      _loadKept(home.profile.id);
      unawaited(_startBehind().catchError((Object e) => debugPrint('session: $e')));
      return true;
    }
    _restoreIsRead();
    try {
      await _start(keptFor: home?.profile.id);
      return true;
    } catch (e) {
      if (e is duvet.DuvetAuthException && _sessionEnded) {
        await _endSession();
        return false;
      }
      // Unreachable server, or a refusal its renewal got no answer to: keep
      // the tokens for the next try, and open with what's saved if there is
      // anything. The tokens as they are now: a renewal may have replaced the
      // ones read.
      _closeSession();
      if (home == null) rethrow;
      final tokens = _saved ?? saved;
      _api = duvet.RestClient(_httpClient(), router: _router, token: tokens.token, sessionToken: tokens.sessionToken);
      profile.value = home.profile;
      conversations.value = home.conversations;
      spaces.value = home.spaces;
      _spaceOrder = [for (final s in home.spaces) s.id];
      _loadKept(home.profile.id);
      _shownBeforeReady = true;
      status.value = LiveStatus.offline;
      _retry = Timer.periodic(const Duration(seconds: 20), (_) => _comeBack());
      return true;
    }
  }

  // The profile showing is the kept one, shown before the API answered
  // ([restore]): until it has, nothing saves the home over what's kept.
  bool _profileKept = false;

  // The home showed from what was kept, before the gateway was up
  // ([restore]): a chat opened since got its page before the socket could
  // tell it of anything, and what came between is on neither. The first
  // READY tells the chats to catch up, as one after a drop does.
  bool _shownBeforeReady = false;

  // How many sessions closed: a start whose answer comes after its session
  // closed starts nothing.
  var _sessionsClosed = 0;

  // The session's start, behind the home [restore] shows already. A session
  // that ended signs out, as at any other time. With no answer from the
  // server it goes offline and tries again now and then, the session as it
  // is: the profile, the lists, drafts and recent chats are in use by now, and
  // a profile gone for a moment would look like a sign-out to those that
  // follow it (voice forgets its call history on one).
  Future<void> _startBehind() async {
    final closed = _sessionsClosed;
    _comingBack = true;
    try {
      await _start(keptFor: profile.value?.id);
    } catch (e) {
      // Signed out meanwhile, or ended by the refusal ([_call]).
      if (closed != _sessionsClosed) return;
      if (e is duvet.DuvetAuthException && _sessionEnded) {
        await _endSession();
        return;
      }
      // Nothing of it started: the renewal and `me()` come before the rest.
      status.value = LiveStatus.offline;
      _retry ??= Timer.periodic(const Duration(seconds: 20), (_) => _comeBack());
    } finally {
      _comingBack = false;
    }
  }

  bool _comingBack = false;

  // Back online after opening from the cache: the session starts for real.
  Future<void> _comeBack() async {
    if (_comingBack) return;
    _comingBack = true;
    try {
      await _start(keptFor: profile.value?.id);
      _retry?.cancel();
      _retry = null;
      if (_wasReady) _resumed.add(null);
    } on duvet.DuvetAuthException {
      // Still offline, unless that was the session's end.
      if (_sessionEnded) {
        _retry?.cancel();
        await _endSession();
      }
    } catch (_) {
      // Still offline.
    } finally {
      _comingBack = false;
    }
  }

  // Whether a refusal ([duvet.DuvetAuthException]) means the session ended:
  // the API refused its renewal, which takes the client's tokens ([_call] has
  // ended it already), or there's no session token to renew with. Otherwise
  // its renewal failed without the API refusing it, say on the network, and
  // the session may live on: the API may even have renewed it.
  bool get _sessionEnded => switch (_api) {
    final api? => !api.isAuthenticated || api.sessionToken.isEmpty,
    null => true,
  };

  void _saveHome() {
    final p = profile.value;
    if (p == null || _profileKept || status.value == LiveStatus.offline && _retry != null) return;
    _cache.saveHome(profile: p, conversations: conversations.value, spaces: spaces.value);
  }

  @override
  Future<void> logIn(String email, String password) async {
    _closeSession();
    // Another session's, if a start left one: whose it was isn't whose this is.
    _saved = null;
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
    // The background task renews the stored session itself when the app
    // doesn't answer it (lib/push/renewal.dart): its tokens are the session's
    // then, and the client's would end nothing.
    final stored = await _store.read().catchError((Object e) {
      debugPrint('session: the stored session: $e');
      return null;
    });
    if ((_api, stored) case (
      final api?,
      final stored?,
    ) when stored.sessionToken.isNotEmpty && stored.sessionToken != api.sessionToken) {
      final renewed = duvet.RestClient(
        _httpClient(),
        router: _router,
        token: stored.token,
        sessionToken: stored.sessionToken,
      );
      await renewed.logout();
      renewed.client.close();
    }
    await _api?.logout();
    await _endSession();
  }

  // [keptFor] is whose home was kept and shows already, if any.
  Future<void> _start({String? keptFor}) async {
    // Before the gateway connects: a renewal during its identify would revoke
    // the token it identifies with. One that timed out, the server
    // unreachable, throws: the session opens offline then, not once `me()`
    // has timed out too.
    final closed = _sessionsClosed;
    await _renewIfDue(renewInFrontAfter);
    final me = await _call((api) => api.me());
    // Signed out while it was asked, behind a home that shows already.
    if (closed != _sessionsClosed) return;
    // Another account's, left by a sign-out that never cleared it: none of it
    // shows under this one, nor stays on the device. Its lists may be read
    // already ([_loadKept]), and a read adds to the recent chats listed.
    if (keptFor != null && keptFor != me.id) {
      conversations.value = const [];
      spaces.value = const [];
      _spaceOrder = const [];
      collapsedCategories.value = const {};
      _collapsedTouched = false;
      pinnedChats.value = const {};
      _pinnedTouched = false;
      drafts.clear();
      _keptLoadedFor = null;
      await _recents.close();
      await _cache.clear();
      if (closed != _sessionsClosed) return;
    }
    _profileKept = false;
    _setProfile(me);
    _names[me.id] = profile.value!.displayName;
    _loadKept(me.id);
    unawaited(_conversationsLoaded = refreshConversations().catchError((Object e) => debugPrint('conversations: $e')));
    _renewals?.cancel();
    _renewals = Timer.periodic(renewalCheck, (_) => _renewQuietly(renewAfter));
    if (_connectsGateway) _connectGateway();
    await _noteOwner(me.id);
  }

  // Keeps whose session it is with its tokens, once the API said: the next
  // launch shows the home kept for them before the API answers ([restore]).
  // One that can't be kept only costs that.
  Future<void> _noteOwner(String userId) async {
    final saved = _saved;
    if (saved == null || saved.userId == userId) return;
    final owned = (
      token: saved.token,
      sessionToken: saved.sessionToken,
      refreshedAt: saved.refreshedAt,
      userId: userId,
    );
    _saved = owned;
    try {
      await _store.write(owned);
    } catch (e) {
      debugPrint('session: whose it is: $e');
    }
  }

  Future<void> _endSession() async {
    // While the gateway is still attached; once (a refused session ends in
    // [_call], then again in [restore]).
    if (_api != null) _signedOut.add(null);
    // Previews are message text: signing out leaves none on the device.
    unawaited(_recents.close(forget: true));
    unawaited(_cache.clear());
    unawaited(Future.sync(clearImageCache).catchError((Object e) => debugPrint('pictures: $e')));
    collapsedCategories.value = const {};
    _collapsedTouched = false;
    pinnedChats.value = const {};
    _pinnedTouched = false;
    _renewalRetry?.cancel();
    _renewalRetry = null;
    _closeSession();
    _saved = null;
    await _store.clear();
  }

  void _closeSession() {
    _sessionsClosed++;
    _profileKept = false;
    _shownBeforeReady = false;
    _keptLoadedFor = null;
    _retry?.cancel();
    _retry = null;
    _renewals?.cancel();
    _renewals = null;
    _events?.cancel();
    _events = null;
    _states?.cancel();
    _states = null;
    _resumes?.cancel();
    _resumes = null;
    _closes?.cancel();
    _closes = null;
    _failures?.cancel();
    _failures = null;
    _wasReady = false;
    _lastRead.clear();
    drafts.clear();
    _ephemeral.clear();
    _links.clear();
    _signedAt.clear();
    _renewing.clear();
    _linksSession++;
    mentions.value = const {};
    _levelsChangedMeanwhile = null;
    notificationLevels.value = const {};
    _forgetMentionNotices();
    _voiceSignaling.detach();
    // Destroying the gateway closes the REST client's HTTP client too.
    if (_gateway case final gateway?) {
      gateway.destroy();
    } else {
      _api?.client.close();
    }
    _gateway = null;
    _api = null;
    _adoptedFrom = null;
    _adoptedInto = null;
    _spaces.clear();
    _spaceOrder = const [];
    _nicknames.clear();
    _spaceMemberIds.clear();
    _memberUsers.clear();
    _waitingRoles.clear();
    _memberLookups.clear();
    _memberLogs.clear();
    _spaceMembers.clear();
    _loadedMembers.clear();
    _roles.clear();
    _memberRoles.clear();
    friends.value = Friends.none;
    teamInvites.value = const [];
    _answeredInvites.clear();
    _conversationMembers.clear();
    _names.clear();
    _authors.clear();
    _emojiNames.clear();
    _assetsChanged();
    _uploadLimit = null;
    presence.value = const {};
    mobileOnly.value = const {};
    activities.value = const {};
    _spaceEntries.clear();
    _ahead.clear();
    _heard.clear();
    _lastMessage.clear();
    latest.value = const {};
    unawaited(_recents.close());
    profile.value = null;
    spaces.value = const [];
    conversations.value = const [];
    unread.value = const {};
    status.value = LiveStatus.offline;
  }

  /// Runs a request, then saves the tokens if the client renewed them on the
  /// way (it does so silently on a 401). A rejected renewal ends the session,
  /// unless the stored session is another one: the background renewal
  /// (lib/push/renewal.dart) rotated it while this client held the old tokens,
  /// and the request goes once more with the stored ones. A renewal
  /// ([renews]) doesn't: the session it takes up was renewed just now. A
  /// request still on its way with the client such a look replaced goes once
  /// more too, refused or cut off as that client closed.
  Future<T> _call<T>(
    Future<T> Function(duvet.RestClient api) request, {
    bool again = false,
    bool renews = false,
  }) async {
    assert(!renews || null is T, 'a renewal gives nothing back');
    final api = _rest;
    try {
      return await request(api);
    } on duvet.DuvetAuthException {
      if (!api.isAuthenticated && identical(api, _api)) {
        if (!again && await _adoptStoredSession(api)) return renews ? null as T : _call(request, again: true);
        // Unless a sign-in started another session during the look.
        if (identical(api, _api)) await _endSession();
      } else if (!again && _adoptedAway(api)) {
        return renews ? null as T : _call(request, again: true);
      }
      rethrow;
    } on http.RequestAbortedException {
      rethrow;
    } on http.ClientException {
      if (!again && _adoptedAway(api)) return renews ? null as T : _call(request, again: true);
      rethrow;
    } finally {
      if (identical(api, _api)) await _persist(api);
    }
  }

  // Requests refused at once share one look at the stored session.
  Future<bool>? _adopting;

  // The client the last look replaced, and the one it made.
  duvet.RestClient? _adoptedFrom;
  duvet.RestClient? _adoptedInto;

  bool _adoptedAway(duvet.RestClient api) => identical(api, _adoptedFrom) && identical(_api, _adoptedInto);

  // Takes up the stored session when it isn't the one this isolate kept: a new client with its tokens, and, as the
  // gateway is built on the client, a gateway that connects again with it. False when it's the same, or none (the
  // session ended), when the store can't be read, and when [failed] isn't the session's client any more: a sign-in
  // came meanwhile.
  Future<bool> _adoptStoredSession(duvet.RestClient failed) => _adopting ??= () async {
    final stored = await _store.read().catchError((Object e) {
      debugPrint('session: the stored session: $e');
      return null;
    });
    final kept = _saved;
    if (!identical(failed, _api) || stored == null || stored.sessionToken.isEmpty) return false;
    if (kept != null && stored.token == kept.token && stored.sessionToken == kept.sessionToken) return false;
    _saved = stored;
    final adopted = _api = duvet.RestClient(
      _httpClient(),
      router: _router,
      token: stored.token,
      sessionToken: stored.sessionToken,
    );
    _adoptedFrom = failed;
    _adoptedInto = adopted;
    if (_gateway case final gateway?) {
      for (final sub in [_events, _states, _resumes, _closes, _failures]) {
        unawaited(sub?.cancel());
      }
      _voiceSignaling.detach();
      // Destroying it closes the old client's HTTP client too.
      gateway.destroy();
      _gateway = null;
      _connectGateway();
    } else {
      failed.client.close();
    }
    return true;
  }().whenComplete(() => _adopting = null);

  // Saves the client's tokens when they changed: the API issued them just now
  // (a login, or a renewal), which dates them for [_renewIfDue]. Whose session
  // it is stays as known: a renewal's tokens are the same session's.
  Future<void> _persist(duvet.RestClient api) async {
    if (!api.isAuthenticated) return;
    final saved = _saved;
    if (saved != null && saved.token == api.token && saved.sessionToken == api.sessionToken) return;
    final current = (token: api.token, sessionToken: api.sessionToken, refreshedAt: clock.now(), userId: saved?.userId);
    _saved = current;
    await _store.write(current);
  }

  /// How old the session's tokens get before the 10-minute check renews
  /// them: they last 24 hours from the login or the last renewal, so an hour
  /// early, as the desktop app renews them.
  static const renewAfter = Duration(hours: 23);

  /// How old they get before they're renewed as the session starts and when
  /// the app comes back to the front, as the desktop app has it.
  static const renewInFrontAfter = Duration(hours: 1);

  /// How often a session checks whether its renewal is due.
  static const renewalCheck = Duration(minutes: 10);

  /// When a renewal got no answer, it goes once more this much later: the API
  /// may have renewed the session and its answer been lost, and for 30
  /// seconds it answers the old session token with the same new tokens. As
  /// the desktop app waits: one that timed out (20 seconds) still goes again
  /// within them.
  static const renewalRetry = Duration(seconds: 3);

  Timer? _renewals;

  // The renewal going once more ([renewalRetry]), for all that got no answer
  // meanwhile. Signing out ends it; a session that opens offline keeps it:
  // its client has the same tokens.
  Timer? _renewalRetry;

  // Renews the session once its tokens are [after] old, or of unknown age: no
  // date, or one ahead of the clock (it was ahead then), which says nothing
  // of how long they have left. Tokens the client got since they were saved
  // (a login, a renewal on a 401) aren't due: the API issued them just now. A
  // refusal ends the session ([_call]) and is thrown; a renewal that got no
  // answer goes once more [renewalRetry] later, and is thrown if it timed
  // out: the server can't be reached. Any other failure waits for the next
  // check.
  Future<void> _renewIfDue(Duration after, {bool retry = true}) async {
    try {
      await _renewOnce(after);
    } on duvet.DuvetAuthException {
      rethrow;
    } catch (e) {
      if (retry) {
        _renewalRetry ??= Timer(renewalRetry, () {
          _renewalRetry = null;
          unawaited(_renewIfDue(after, retry: false).catchError((Object e) => debugPrint('session: $e')));
        });
      }
      if (e is TimeoutException) rethrow;
      debugPrint('session: $e');
    }
  }

  // One renewal, once due as [_renewIfDue] has it. A refusal ends the session
  // ([_call]) and is thrown, as is a renewal that got no answer; an error the
  // API answered is only logged.
  Future<void> _renewOnce(Duration after) async {
    final api = _api;
    final saved = _saved;
    if (api == null || saved == null || saved.token != api.token || api.sessionToken.isEmpty) return;
    final now = clock.now();
    if (saved.refreshedAt case final at? when !at.isAfter(now) && now.difference(at) < after) return;
    try {
      await _call<void>((api) => api.refreshSession(), renews: true);
    } on duvet.DuvetApiException catch (e) {
      if (e is duvet.DuvetAuthException) rethrow;
      debugPrint('session: $e');
    }
  }

  // From the timer, or the app coming to the front: a refusal has ended the
  // session already. Settles once the renewal, if one was due, is done.
  Future<void> _renewQuietly(Duration after) => _renewIfDue(after).catchError((Object e) => debugPrint('session: $e'));

  /// Renews the session in this isolate, for the background task
  /// (lib/push/renewal.dart), which asks the app before it renews the stored
  /// tokens itself, so the session keeps one owner and the gateway follows the
  /// renewal: once its tokens are [after] old, as [_renewIfDue] has it. A
  /// renewal that got no answer goes once more [renewalRetry] later, and this
  /// waits for it: the task keeps the phone awake until it ends.
  Future<void> renewForBackground(Duration after) async {
    try {
      await _renewOnce(after);
    } on duvet.DuvetAuthException {
      // The session ended ([_call]).
    } catch (_) {
      await Future<void>.delayed(renewalRetry);
      await _renewOnce(after).catchError((Object e) => debugPrint('session: $e'));
    }
  }

  // Whether the app is in front: in the background its own notices keep quiet.
  bool _inFront = true;

  @override
  void wentToBack() => _inFront = false;

  @override
  void cameToFront() {
    _inFront = true;
    final renewing = _renewQuietly(renewInFrontAfter);
    if (status.value == LiveStatus.online) return;
    // Cut off while away. Connecting goes again now, not at the end of its
    // wait, and asks the API about the session, which may have ended
    // meanwhile: the gateway's 401 at the socket's upgrade doesn't say so.
    if (_retry != null) {
      // Opened offline: starting again asks.
      unawaited(_comeBack());
    } else {
      _checkSession();
      // Once the renewal is done, as [_start] orders them: it revokes the
      // access token an attempt meanwhile would connect with, which the
      // gateway would refuse, and the wait after it grow.
      unawaited(renewing.whenComplete(() => _gateway?.retryNow()));
    }
  }

  // ---------------------------------------------------------------------------
  // Gateway
  // ---------------------------------------------------------------------------

  /// What the app tells the gateway it runs on as it identifies, which others
  /// see in the user's client status: the mobile app on Android and iOS; the
  /// web in a browser, a phone's included; a computer anywhere else, as the
  /// desktop app is.
  @visibleForTesting
  static duvet.ClientPlatform platformOf({bool web = kIsWeb, TargetPlatform? target}) {
    if (web) return duvet.ClientPlatform.web;
    return switch (target ?? defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => duvet.ClientPlatform.mobile,
      _ => duvet.ClientPlatform.desktop,
    };
  }

  void _connectGateway() {
    final gateway = _gateway = duvet.GatewayManager(
      _rest,
      router: _router,
      // No gateway log at all in release builds.
      log: kDebugMode ? (shard, msg) => debugPrint('[gateway:$shard] $msg') : (_, _) {},
      // A socket that replaces one that dropped takes the session up again,
      // as the desktop app's does: the gateway replays what it missed, with
      // no READY (see [handleResume]), when it still keeps the session.
      resume: true,
      platform: platformOf(),
    );
    _voiceSignaling.attach(gateway);
    // Listen before connecting: READY comes right after IDENTIFY, on a
    // broadcast stream.
    _events = gateway.onEvent.listen(handleEvent);
    _states = gateway.onConnectionState.listen(handleConnectionState);
    _resumes = gateway.onResume.listen((_) => handleResume());
    _closes = gateway.onCloseReason.listen(handleCloseReason);
    _failures = gateway.onConnectFailure.listen(handleConnectFailure);
    status.value = LiveStatus.connecting;
    gateway.connectAll().catchError((Object e) {
      debugPrint('gateway: $e');
      if (identical(gateway, _gateway)) status.value = LiveStatus.offline;
    });
  }

  /// A dropped socket shows until READY comes again, or the session resumes.
  @visibleForTesting
  void handleConnectionState(duvet.GatewayConnectionState state) {
    if (state == duvet.GatewayConnectionState.reconnecting && _wasReady) status.value = LiveStatus.reconnecting;
  }

  /// The gateway took the session up again on a new socket: what it missed
  /// came replayed before this, so it's live again as it was. Unlike after
  /// READY, nothing is rebuilt or fetched again: presence, the chats (no
  /// [resumed]), their previews, the mentions, the conversations, voice.
  @visibleForTesting
  void handleResume() => status.value = LiveStatus.online;

  /// The gateway refused the session's token (4004: unknown as it
  /// identified, or the session ended since): the API is asked about the
  /// session at once, as the desktop app does. A dead one gets a 401 there,
  /// which ends it ([_call]); a live one renews its tokens if it must, which
  /// the next socket identifies with. Any other reason only reconnects.
  @visibleForTesting
  void handleCloseReason(duvet.GatewayCloseReason close) {
    if (close.code == duvet.GatewayCloseCode.invalidCredentials) _checkSession();
  }

  /// An attempt to open a socket failed. A token the gateway doesn't know (a
  /// session that ended while no socket was open) is refused at the socket's
  /// upgrade, with a 401, not closed with 4004: the API is asked about the
  /// session at once on a 401, and on the first failure and every 5th
  /// otherwise, as the desktop asks on its socket's errors.
  @visibleForTesting
  void handleConnectFailure(duvet.GatewayConnectFailure failure) {
    if (failure.httpStatus == 401 || failure.failures % 5 == 1) _checkSession();
  }

  Future<void>? _sessionCheck;

  // Asks the API about the session, one question at a time: a dead session
  // gets a 401 there, which ends it ([_call]); a live one renews its tokens if
  // it must, which the next socket identifies with.
  void _checkSession() {
    if (_api == null || _sessionCheck != null) return;
    _sessionCheck = _call(
      (api) => api.me(),
    ).then<void>((_) {}, onError: (Object e) => debugPrint('session: $e')).whenComplete(() => _sessionCheck = null);
  }

  /// Applies a gateway event.
  @visibleForTesting
  void handleEvent(duvet.GatewayEventPayload event) {
    final me = profile.value?.id;
    final reconnected = event is duvet.ReadyEvent && _wasReady;
    switch (event) {
      case duvet.ReadyEvent(:final data):
        status.value = LiveStatus.online;
        // The Spaces' order, as the desktop lists them: the gateway's.
        _spaceOrder = data.guildIds;
        // A new session: the others' presence comes again with the
        // SPACE_CREATEs that follow, and the friends list, without whoever
        // went offline meanwhile, as the desktop does. A session the gateway
        // resumes keeps it ([handleResume]).
        presence.value = {
          for (final e in presence.value.entries)
            if (e.key == me) e.key: e.value,
        };
        // So does whether they're only on mobile, which comes with it; the
        // user's stays, as their presence does.
        if (mobileOnly.value.any((id) => id != me)) {
          mobileOnly.value = {if (me != null && mobileOnly.value.contains(me)) me};
        }
        // What they're doing comes again with them too.
        activities.value = const {};
        _spaceEntries.clear();
        // Profile changes made with no session went unheard: anyone's next
        // one reaches their messages, even with the name and avatar the one
        // before gave them.
        _authors.clear();
        // Connected, the user shows the status they chose. A gateway from
        // before statuses doesn't say: online.
        if (_chosen(data.user.status) case final chosen?) {
          _choose(chosen);
          if (me != null) presence.value = {...presence.value, me: chosen};
        } else if (me != null && !presence.value.containsKey(me)) {
          presence.value = {...presence.value, me: Presence.online};
        }
        // Kept ones it no longer names go now, not with the first SPACE_CREATE.
        if (_spaces.isNotEmpty || spaces.value.isNotEmpty) _publishSpaces();
        unread.value = {...?data.unreadRooms, ...?data.unreadConvs};
        _lastRead.addAll(data.lastReadRooms ?? const {});
        _lastMessage.addAll(data.lastMsgRooms ?? const {});
        // What came while no socket was open never reached the pages kept,
        // nor will a page asked for before it.
        _ahead.clear();
        _readies++;
        unawaited(_catchUpRooms());
        if (_api != null) {
          unawaited(
            _call((api) => api.getMentionCounts()).then((counts) {
              mentions.value = {
                for (final e in counts.entries)
                  if (e.value > 0) e.key: e.value,
              };
            }, onError: (Object e) => debugPrint('mentions: $e')),
          );
          unawaited(_loadNotificationLevels());
          // The friends and the requests, as the desktop fetches them on each
          // READY; FRIEND_* events keep them current.
          unawaited(_reloadFriends());
          unawaited(_reloadTeamInvites());
        }
        // READY again after a drop: chats catch up, and the conversations,
        // whose dates tell the DMs' previews behind. The first one too, for
        // the chats, behind a home that showed before it; its conversations
        // [_start] asked for.
        if (_wasReady || _shownBeforeReady) _resumed.add(null);
        _shownBeforeReady = false;
        if (_wasReady) {
          unawaited(
            _conversationsLoaded = refreshConversations().catchError((Object e) => debugPrint('conversations: $e')),
          );
        }
        if (_preloads) unawaited(_preloadLikeliest());
        _wasReady = true;

      case duvet.MentionCreatedEvent(:final data) when data.authorId != me:
        _mentioned(data.conversationId ?? data.roomId);
        if (data.conversationId case final id?) {
          _mentionNotice(ConversationTarget(id), data.messageId);
        } else if (spaces.value.where((s) => s.rooms.any((r) => r.id == data.roomId)).firstOrNull case final space?) {
          _mentionNotice(RoomTarget(spaceId: space.id, roomId: data.roomId), data.messageId);
        }
      case duvet.DMMentionCreatedEvent(:final data) when data.authorId != me:
        _mentioned(data.conversationId);
        _mentionNotice(ConversationTarget(data.conversationId), data.messageId);

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
          ReactionChanged(
            messageId: data.messageId,
            userId: data.userId,
            emoji: data.emojiName,
            emojiId: data.emojiId,
            added: false,
          ),
        ));

      case duvet.SpaceCreateEvent(:final data):
        _warm([avatarUrl(data.space.icon)]);
        // A Space joined: its emojis and stickers are the user's now.
        _assetsChanged();
        _spaces[data.space.id] = (space: data.space, rooms: {...data.rooms});
        _roles[data.space.id] = {...data.rolesPermissions};
        _overwrites[data.space.id] = {
          for (final e in (data.overwrites ?? const <String, List<duvet.GatewayRoomOverwrite>>{}).entries)
            e.key: [...e.value],
        };
        _memberRoles[data.space.id] = {
          for (final e in data.memberRoles.entries) e.key: [...e.value],
        };
        // Who's in it (each member has @everyone's role), and their presence
        // as the gateway connects; live updates follow. It lists only who's
        // connected: the rest are offline.
        final spaceId = data.space.id;
        final members = _spaceMemberIds[spaceId] = {...data.memberRoles.keys, ...data.memberStatuses.keys};
        final here = {
          for (final id in members)
            if (id != me) id: data.memberStatuses[id] == null ? Presence.offline : _presence(data.memberStatuses[id]!),
        };
        final before = presence.value;
        final next = {
          for (final e in here.entries)
            if (e.value == Presence.offline) e.key: e.value,
          ...before,
          for (final e in data.memberStatuses.entries) e.key: _presence(e.value),
        };
        // The Space's own entry only where its status isn't the user's, as a
        // bot's whose shard here isn't connected: a person's status is the
        // same in every Space. Where this changed the user's, the Spaces
        // that had theirs as it was keep that.
        for (final MapEntry(key: id, value: status) in here.entries) {
          if (before[id] case final old? when old != next[id]) {
            for (final MapEntry(key: other, value: ids) in _spaceMemberIds.entries) {
              if (other != spaceId && ids.contains(id) && !next.containsKey(spacePresenceKey(id, other))) {
                next[spacePresenceKey(id, other)] = old;
                _entered(id, other);
              }
            }
          }
          if (status != next[id]) {
            next[spacePresenceKey(id, spaceId)] = status;
            _entered(id, spaceId);
          } else if (next.remove(spacePresenceKey(id, spaceId)) != null) {
            _spaceEntries[id]?.remove(spaceId);
          }
        }
        // And whether those it has connected are only on mobile, as their
        // status everywhere is now the one it gives; the others keep theirs.
        _keepPlatforms({for (final id in data.memberStatuses.keys) id: data.memberClientStatus[id]});
        presence.value = next;
        // What those it has connected are doing; its other members, nothing.
        activities.value = {
          for (final e in activities.value.entries)
            if (!members.contains(e.key)) e.key: e.value,
          for (final e in data.activities.entries)
            if (e.value.isNotEmpty) e.key: e.value,
        };
        _readStates(data.readStates);
        _publishSpaces();
      case duvet.SpaceUpdateEvent(:final data):
        _warm([avatarUrl(data.icon)]);
        if (_spaces[data.id] case final known?) {
          _spaces[data.id] = (space: data, rooms: known.rooms);
          _publishSpaces();
        }
      case duvet.SpaceDeletedEvent(:final data):
        _forgetSpace(data.id);
        _assetsChanged();

      case duvet.RoomCreateEvent(:final data) || duvet.RoomUpdateEvent(:final data):
        if (_spaces[data.spaceId] case final known?) {
          known.rooms[data.id] = data;
          if (data.readState case final state?) _readStates({data.id: state});
          _publishSpaces();
        }
      // Every room of a Space after one moved: their places, as the desktop
      // takes them.
      case duvet.RoomReorderedEvent(:final data):
        for (final moved in data.rooms) {
          for (final (space: _, :rooms) in _spaces.values) {
            if (rooms[moved.id] case final r?) {
              rooms[moved.id] = _placed(r, parentId: moved.parentId, position: moved.position);
            }
          }
        }
        _publishSpaces();
      case duvet.RoleCreatedEvent(:final data) || duvet.RoleUpdatedEvent(:final data):
        (_roles[data.spaceId] ??= {})[data.id] = data;
        _publishSpaces();
      case duvet.RoleDeletedEvent(:final data):
        _roles[data.spaceId]?.remove(data.id);
        for (final ids in _memberRoles[data.spaceId]?.values ?? const <List<String>>[]) {
          ids.remove(data.id);
        }
        _publishSpaces();
      // They name the member by member ID; MEMBER_ROLE_REMOVE names no space,
      // which the role tells.
      case duvet.MemberRoleAddedEvent(:final data):
        if (data.spaceId ?? _spaceOfRole(data.roleId) case final spaceId?) {
          _memberRoleChanged(spaceId, data.memberId, data.roleId, added: true);
        }
      case duvet.MemberRoleRemovedEvent(:final data):
        if (data.spaceId ?? _spaceOfRole(data.roleId) case final spaceId?) {
          _memberRoleChanged(spaceId, data.memberId, data.roleId, added: false);
        }
      case duvet.RoomOverwriteUpdateEvent(:final data):
        for (final (:space, :rooms) in _spaces.values) {
          if (!rooms.containsKey(data.roomId)) continue;
          final list = (_overwrites[space.id] ??= {})[data.roomId] ??= [];
          list
            ..removeWhere((o) => o.targetId == data.targetId)
            ..add(data);
        }
        // It may change which rooms the user sees.
        _publishSpaces();
      case duvet.RoomOverwriteDeletedEvent(:final data):
        for (final rooms in _overwrites.values) {
          rooms[data.roomId]?.removeWhere((o) => o.targetId == data.targetId);
        }
        _publishSpaces();

      case duvet.RoomDeletedEvent(:final data):
        _roomGone(data.spaceId, data.id);

      case duvet.MessageCreateEvent(:final data):
        if (data.deletedAt != null) break;
        final message = _roomMessage(data);
        // A bot's answer to the user alone isn't one of the room's: it leaves
        // the room read, and isn't its preview.
        if (message.isEphemeral) {
          _keepEphemeral(data.roomId, message);
        } else {
          if (data.authorId != me) _markUnread(data.roomId);
          _recents.roomMessage(data.roomId, message);
          _setLatest(data.roomId, message);
          _arrivedForNotice(message);
          if (_spaceOfRoom(data.roomId) case final spaceId?) {
            _noticeEveryMessage(RoomTarget(spaceId: spaceId, roomId: data.roomId), message);
          }
        }
        _messageEvents.add((data.roomId, MessageCreated(message)));
      case duvet.MessageUpdateEvent(:final data):
        if (data.deletedAt != null) {
          _dropEphemeral(data.roomId, data.id);
          _dropMentionNotice(data.id);
          _recents.deleted(data.roomId, data.id);
          _latestDeleted(data.roomId, data.id);
          _messageEvents.add((data.roomId, MessageDeleted(data.id)));
        } else {
          final update = _roomMessage(data);
          final kept = _ephemeral[data.roomId];
          if (!update.isEphemeral) {
            _updated(data.roomId, update);
          } else if (kept?.indexWhere((m) => m.id == data.id) case final i? when i >= 0) {
            // Only while it's shown: one dismissed stays gone, as on the desktop.
            kept![i] = kept[i].updatedBy(update);
            _messageEvents.add((data.roomId, MessageUpdated(update)));
          }
        }
      case duvet.MessageDeletedEvent(:final data):
        _dropEphemeral(data.roomId, data.id);
        _dropMentionNotice(data.id);
        _recents.deleted(data.roomId, data.id);
        _latestDeleted(data.roomId, data.id);
        _messageEvents.add((data.roomId, MessageDeleted(data.id)));

      case duvet.DMMessageCreatedEvent(:final data):
        final id = data.conversationId;
        if (id == null) break;
        final message = _directMessage(data);
        if (message.call case final call?) {
          _readCallNotice(id, message.id, call, me);
        } else if (data.authorId != me) {
          _markUnread(id);
        }
        final known = conversations.value.where((c) => c.id == id).firstOrNull;
        if (known == null) unawaited(refreshConversations().catchError((_) {}));
        _recents.conversationMessage(id, message, title: known?.title);
        _setLatest(id, message);
        _arrivedForNotice(message);
        _noticeEveryMessage(ConversationTarget(id), message);
        _messageEvents.add((id, MessageCreated(message)));
      case duvet.DMMessageUpdatedEvent(:final data):
        if (data.conversationId case final id?) _updated(id, _directMessage(data));
      case duvet.DMMessageDeletedEvent(:final data):
        _dropMentionNotice(data.id);
        _recents.deleted(data.conversationId, data.id);
        _latestDeleted(data.conversationId, data.id);
        _messageEvents.add((data.conversationId, MessageDeleted(data.id)));

      // The calls the user answered from one of their devices, whose notices
      // leave the conversation read for them, as the API does. A new call
      // ringing them there is one they haven't answered yet.
      case duvet.CallAcceptedEvent(:final data) || duvet.CallDeclinedEvent(:final data) when data.userId == me:
        _callAnswers.add(data.conversationId);
      case duvet.CallIncomingPayloadEvent(:final data):
        _callAnswers.remove(data.conversationId);

      case duvet.MessagePinUpdatedEvent(:final data):
        _messageEvents.add((data.roomId, MessagePinned(data.id, pinned: data.pinnedAt != null)));
      case duvet.DMMessagePinUpdatedEvent(:final data):
        _messageEvents.add((data.conversationId, MessagePinned(data.id, pinned: data.pinnedAt != null)));

      case duvet.TypingStartedEvent(:final data) when data.userId != me:
        _typing.add((data.roomId, TypingUser(userId: data.userId, name: data.alias ?? data.username)));
      case duvet.DMTypingStartedEvent(:final data) when data.userId != me:
        _typing.add((data.conversationId, TypingUser(userId: data.userId, name: data.alias ?? data.username)));
      case duvet.RecordingStartedEvent(:final data) when data.userId != me:
        _typing.add((data.roomId, TypingUser(userId: data.userId, name: data.alias ?? data.username, recording: true)));
      case duvet.DMRecordingStartedEvent(:final data) when data.userId != me:
        _typing.add((
          data.conversationId,
          TypingUser(userId: data.userId, name: data.alias ?? data.username, recording: true),
        ));

      case duvet.UserStatusUpdatedEvent(:final data):
        final status = _presence(data.statusId);
        // With their platforms, where the status holds everywhere: one in a
        // single Space is a bot's, whose connections all count as a computer's.
        if (data.spaceId == null) _keepPlatforms({data.userId: data.clientStatus});
        presence.value = switch (data.spaceId) {
          // A bot's in one Space (its shard's there), as the desktop keeps it.
          final spaceId? => {...presence.value, spacePresenceKey(data.userId, _entered(data.userId, spaceId)): status},
          null => _presentEverywhere(data.userId, status),
        };
        // The user's own: the status they chose, on this device or another.
        if (_chosen(data.statusId) case final chosen? when data.userId == me && data.spaceId == null) {
          _choose(chosen);
        }
        if (_spaceMemberIds.values.any((ids) => ids.contains(data.userId))) _publishSpaces();
        // Gone offline, they lose their activities with no USER_ACTIVITY_UPDATE.
        if (status == Presence.offline && data.spaceId == null && activities.value.containsKey(data.userId)) {
          activities.value = {...activities.value}..remove(data.userId);
        }
      case duvet.UserActivityUpdatedEvent(:final data):
        activities.value = {
          for (final e in activities.value.entries)
            if (e.key != data.userId) e.key: e.value,
          if (data.activities.isNotEmpty) data.userId: data.activities,
        };
      case duvet.SpaceEmojiCreatedEvent() || duvet.SpaceEmojiUpdatedEvent() || duvet.SpaceEmojiDeletedEvent():
        _emojis = null;
      case duvet.SpaceBanAddedEvent(:final data):
        _bansChanged.add(data.spaceId);
      case duvet.SpaceBanRemovedEvent(:final data):
        _bansChanged.add(data.spaceId);
      case duvet.SpaceStickerCreatedEvent() || duvet.SpaceStickerUpdatedEvent() || duvet.SpaceStickerDeletedEvent():
        _stickers = null;
      case duvet.SpaceMemberAddedEvent(:final data):
        _spaceMembers.clear();
        if (data.userId case final userId?) {
          (_spaceMemberIds[data.spaceId] ??= {}).add(userId);
          // Their status as they join, which USER_STATUS_UPDATE carries on;
          // a bot's is its status in this Space alone.
          final status = data.statusId == null ? Presence.offline : _presence(data.statusId!);
          if (data.user?.isBot ?? false) {
            presence.value = {...presence.value, spacePresenceKey(userId, _entered(userId, data.spaceId)): status};
          } else if (data.statusId != null) {
            _keepPlatforms({userId: data.clientStatus});
            presence.value = _presentEverywhere(userId, status);
          } else if (!presence.value.containsKey(userId)) {
            presence.value = {...presence.value, userId: status};
          }
          _publishSpaces();
        }
      case duvet.SpaceMemberRemovedEvent(:final data):
        _spaceMembers.clear();
        if (data.userId case final userId? when _spaceMemberIds[data.spaceId]?.remove(userId) ?? false) {
          if (_spaceEntries[userId]?.remove(data.spaceId) ?? false) {
            presence.value = {...presence.value}..remove(spacePresenceKey(userId, data.spaceId));
          }
          _publishSpaces();
        }
      case duvet.GuildMemberAddedEvent() || duvet.GuildMemberRemovedEvent():
        _spaceMembers.clear();

      // A request made, taken, turned down or taken back, or a friendship
      // ended, by either side, from any device: the lists again, as the
      // desktop fetches them (the newest load's answer stands).
      case duvet.FriendRequestCreatedEvent() ||
          duvet.FriendRequestAcceptedEvent() ||
          duvet.FriendRequestRejectedEvent() ||
          duvet.FriendRemovedEvent():
        unawaited(_reloadFriends());

      // Reloaded rather than added: the same invite twice stays one row.
      case duvet.TeamInviteCreatedEvent():
        unawaited(_reloadTeamInvites());

      case duvet.ConversationCreatedEvent() ||
          duvet.ConversationUpdatedEvent() ||
          duvet.ConversationDeletedEvent() ||
          duvet.ConversationMemberAddedEvent() ||
          duvet.ConversationMemberRemovedEvent():
        // The added member's status as they're added, which USER_STATUS_UPDATE
        // carries on.
        if (event case duvet.ConversationMemberAddedEvent(:final data) when data.userId != me) {
          if (data.statusId case final status?) {
            _keepPlatforms({data.userId: data.clientStatus});
            presence.value = _presentEverywhere(data.userId, _presence(status));
          }
        }
        unawaited(refreshConversations().catchError((_) {}));

      case duvet.UserUpdatedEvent(:final data):
        _userUpdated(data);
        if (data.id == me) {
          _call((api) => api.me()).then((me) {
            _setProfile(me);
          }, onError: (_) {});
        }

      case duvet.NotificationSettingsUpdatedEvent(:final data):
        final level = switch (data.level) {
          final level? => _level(level),
          null => null,
        };
        _levelsChangedMeanwhile?[data.targetId] = level;
        notificationLevels.value = switch (level) {
          final level? => {...notificationLevels.value, data.targetId: level},
          null => {...notificationLevels.value}..remove(data.targetId),
        };

      default:
    }
    _trackMembers(event, reconnected: reconnected);
    // After the spaces and roles took it in: voice reads them.
    _voiceSignaling.deliver(event);
  }

  // Whatever else they do, these events keep the member IDs that role
  // changes name, and the role changes waiting for them.
  void _trackMembers(duvet.GatewayEventPayload event, {required bool reconnected}) {
    switch (event) {
      // Who joined or left while the socket was down comes only in the
      // members lists fetched from now on, not in those on their way, so a
      // lookup on its way doesn't hold up the next one.
      case duvet.ReadyEvent() when reconnected:
        _spaceMembers.clear();
        _memberUsers.clear();
        _memberLogs.clear();
        _memberLookups.clear();
      // A new session's member roles include what the waiting changes did,
      // and what happened after them.
      case duvet.SpaceCreateEvent(:final data):
        _waitingRoles.remove(data.space.id);
      case duvet.SpaceMemberAddedEvent(:final data) when data.userId != null:
        _memberMoved(data.spaceId, (memberId: data.memberId, userId: data.userId));
        if (_applyWaitingRoles(data.spaceId)) _publishSpaces();
      case duvet.SpaceMemberRemovedEvent(:final data):
        _memberMoved(data.spaceId, (memberId: data.memberId, userId: null));
      default:
    }
  }

  /// Someone joined or left: their member ID, kept for role changes, and in
  /// the logs of the members lists on their way.
  void _memberMoved(String spaceId, _MemberMove move) {
    if (move.userId != null) _memberUsers[spaceId] ??= {};
    if (_memberUsers[spaceId] case final users?) _move(users, move);
    for (final log in _memberLogs[spaceId] ?? const <List<_MemberMove>>[]) {
      log.add(move);
    }
  }

  static void _move(Map<String, String> users, _MemberMove move) {
    if (move.userId case final userId?) {
      users[move.memberId] = userId;
    } else {
      users.remove(move.memberId);
    }
  }

  /// Ends a members list's [log]; answers whether it was still kept: a list
  /// whose log the Space's forgetting, or READY after a drop, took away may
  /// be from before it.
  bool _endMemberLog(String spaceId, List<_MemberMove> log) {
    final logs = _memberLogs[spaceId];
    if (logs == null || !logs.remove(log)) return false;
    if (logs.isEmpty) _memberLogs.remove(spaceId);
    return true;
  }

  /// A Space forgotten or left: who's in it by member ID, and the role changes
  /// and members lists that waited for them. If the user comes back, they come
  /// anew: someone may have left and come back meanwhile, with another ID.
  void _forgetMembers(String spaceId) {
    _memberUsers.remove(spaceId);
    _waitingRoles.remove(spaceId);
    _memberLookups.remove(spaceId);
    _memberLogs.remove(spaceId);
  }

  String? _spaceOfRole(String roleId) => _roles.entries.where((e) => e.value.containsKey(roleId)).firstOrNull?.key;

  /// A member was given a role, or lost one. One not named yet waits for a
  /// members list: a role of the user's own changes what they may do.
  void _memberRoleChanged(String spaceId, String memberId, String roleId, {required bool added}) {
    final userId = _memberUsers[spaceId]?[memberId];
    if (userId != null && !(_waitingRoles[spaceId]?.containsKey(memberId) ?? false)) {
      _applyRole(spaceId, userId, roleId, added: added);
      return _publishSpaces();
    }
    // Behind the member's earlier changes, to apply in order.
    ((_waitingRoles[spaceId] ??= {})[memberId] ??= []).add((roleId: roleId, added: added));
    _lookUpMembers(spaceId);
  }

  void _applyRole(String spaceId, String userId, String roleId, {required bool added}) {
    final ids = (_memberRoles[spaceId] ??= {})[userId] ??= [];
    if (added && !ids.contains(roleId)) ids.add(roleId);
    if (!added) ids.remove(roleId);
  }

  /// Fetches the members list again for the waiting role changes: the one
  /// cached may be from before someone joined while the app wasn't
  /// listening. Changes it doesn't name, or all of them when it fails, wait
  /// for the next list or SPACE_MEMBER_ADD.
  void _lookUpMembers(String spaceId) {
    if (_memberLookups.containsKey(spaceId)) return;
    final lookup = _spaceMemberList(
      spaceId,
      refresh: true,
    ).then((_) {}, onError: (Object e) => debugPrint('members for roles: $e'));
    _memberLookups[spaceId] = lookup;
    unawaited(
      lookup.whenComplete(() {
        if (identical(_memberLookups[spaceId], lookup)) _memberLookups.remove(spaceId);
      }),
    );
  }

  /// Applies the waiting role changes of the members now named; answers
  /// whether there were any.
  bool _applyWaitingRoles(String spaceId) {
    final waiting = _waitingRoles[spaceId];
    final users = _memberUsers[spaceId];
    if (waiting == null || users == null || !_spaces.containsKey(spaceId)) return false;
    var applied = false;
    for (final memberId in [...waiting.keys]) {
      final userId = users[memberId];
      if (userId == null) continue;
      for (final change in waiting.remove(memberId)!) {
        _applyRole(spaceId, userId, change.roleId, added: change.added);
      }
      applied = true;
    }
    if (waiting.isEmpty) _waitingRoles.remove(spaceId);
    return applied;
  }

  // Events for whichever chat has the message.
  static const _anyChat = '*';

  void _mentioned(String chatId) => mentions.value = {...mentions.value, chatId: (mentions.value[chatId] ?? 0) + 1};

  // ---------------------------------------------------------------------------
  // Mention notices
  // ---------------------------------------------------------------------------

  @override
  final ValueNotifier<List<MentionNotice>> mentionNotices = ValueNotifier(const []);

  /// How long a mention's notice shows, and how many show at once: a new one
  /// goes on top, and the oldest goes past them, as on the desktop.
  static const noticeTime = Duration(seconds: 6);
  static const noticesShown = 3;

  ({String chatId, String? threadOf})? _onScreen;

  // The newest messages that came, by ID: a mention's comes over another
  // subscription, in no set order, and neither event carries the other.
  final _arrived = <String, ChatMessage>{};
  static const _arrivedKept = 200;

  // Mentions whose message hasn't come, by its ID: it's being fetched.
  final _awaited = <String, ChatTarget>{};

  // The messages whose notice showed, or never will (deleted), the newest
  // last: each shows once. The API sends a mention once and a resume replays
  // only what came after it, so this is only a guard.
  final _settled = <String>{};
  static const _settledKept = 500;
  final _noticeTimers = <String, Timer>{};

  @override
  void chatShown(ChatTarget target, {String? threadOf, bool opened = true}) {
    _onScreen = (chatId: target.id, threadOf: threadOf);
    // Its phone notification tells of nothing the chat doesn't show.
    if (threadOf == null) {
      unawaited(_forgetNotifications?.call(target.id).catchError((Object e) => debugPrint('push: $e')));
    }
    // The chat itself is here now: its notices would only open it again.
    if (opened && threadOf == null) {
      for (final notice in [...mentionNotices.value.where((n) => n.target == target)]) {
        dismissMentionNotice(notice.messageId);
      }
    }
  }

  @override
  void chatHidden(ChatTarget target, {String? threadOf}) {
    if (_onScreen == (chatId: target.id, threadOf: threadOf)) _onScreen = null;
  }

  // [messageId] mentions the user in [target]: its notice shows once the
  // message is here, fetched if it hasn't come.
  void _mentionNotice(ChatTarget target, String messageId) {
    if (_settled.contains(messageId) || _awaited.containsKey(messageId)) return;
    if (_arrived[messageId] case final message?) return _showNotice(target, message);
    _awaited[messageId] = target;
    fetchMessage(target, messageId).then(
      // Unless it came meanwhile, or was deleted.
      (message) {
        if (_awaited.remove(messageId) != null) _showNotice(target, message);
      },
      onError: (Object e) {
        // Deleted first, which the API no longer has, or offline: nothing shows.
        _awaited.remove(messageId);
        debugPrint('mention: $e');
      },
    );
  }

  void _arrivedForNotice(ChatMessage message) {
    _arrived[message.id] = message;
    if (_arrived.length > _arrivedKept) _arrived.remove(_arrived.keys.first);
    if (_awaited.remove(message.id) case final target?) _showNotice(target, message);
  }

  // A place at every message shows each message as a mention: not the user's
  // own, nor one of Duvet's notices (a pin's, a call's). A mention of it
  // shows once all the same ([_settled]).
  void _noticeEveryMessage(ChatTarget target, ChatMessage message) {
    if (message.authorId == profile.value?.id || message.isNotice) return;
    final level = switch (target) {
      RoomTarget(:final roomId) => roomLevel(roomId),
      ConversationTarget(:final conversationId) => conversationLevel(conversationId),
    };
    if (level == NotificationLevel.all) _showNotice(target, message);
  }

  void _showNotice(ChatTarget target, ChatMessage message) {
    // In the background the phone's notification tells of it (lib/push): this one, settled, never shows.
    if (!_inFront) return _settle(message.id);
    // Nor for a chat at nothing ([quiet]): no notice, so no sound either.
    if (_settled.contains(message.id) || profile.value?.status == Presence.doNotDisturb || quiet(target.id)) return;
    // The chat on screen shows it already; a thread of it, its replies.
    if (_onScreen case (
      :final chatId,
      :final threadOf,
    ) when chatId == target.id && (threadOf == null || message.reply?.messageId == threadOf)) {
      return;
    }
    final ({String title, String where})? place = switch (target) {
      RoomTarget(:final spaceId, :final roomId) => () {
        final space = spaces.value.where((s) => s.id == spaceId).firstOrNull;
        final room = space?.rooms.where((r) => r.id == roomId).firstOrNull;
        return room == null ? null : (title: '# ${room.name}', where: 'in #${room.name} · ${space!.name}');
      }(),
      ConversationTarget(:final conversationId) => () {
        final conversation = conversations.value.where((c) => c.id == conversationId).firstOrNull;
        return (
          title: conversation?.title ?? 'Direct message',
          where: conversation != null && conversation.isGroup ? 'in ${conversation.title}' : 'in a direct message',
        );
      }(),
    };
    if (place == null) return;
    _settle(message.id);
    final notice = MentionNotice(
      messageId: message.id,
      target: target,
      title: place.title,
      authorName: message.authorName,
      authorAvatarUrl: message.authorAvatarUrl,
      where: place.where,
      text: previewOf(message),
    );
    final shown = [notice, ...mentionNotices.value];
    for (final gone in shown.skip(noticesShown)) {
      _noticeTimers.remove(gone.messageId)?.cancel();
    }
    mentionNotices.value = shown.take(noticesShown).toList();
    _noticeTimers[message.id] = Timer(noticeTime, () => dismissMentionNotice(message.id));
  }

  void _settle(String messageId) {
    _settled
      ..remove(messageId)
      ..add(messageId);
    if (_settled.length > _settledKept) _settled.remove(_settled.first);
  }

  @override
  void dismissMentionNotice(String messageId) {
    _noticeTimers.remove(messageId)?.cancel();
    if (mentionNotices.value.any((n) => n.messageId == messageId)) {
      mentionNotices.value = [...mentionNotices.value.where((n) => n.messageId != messageId)];
    }
  }

  // A message was deleted: its notice goes, and one on its way never shows.
  void _dropMentionNotice(String messageId) {
    _settle(messageId);
    _arrived.remove(messageId);
    _awaited.remove(messageId);
    dismissMentionNotice(messageId);
  }

  void _forgetMentionNotices() {
    for (final timer in _noticeTimers.values) {
      timer.cancel();
    }
    _noticeTimers.clear();
    _arrived.clear();
    _awaited.clear();
    _settled.clear();
    _onScreen = null;
    mentionNotices.value = const [];
  }

  /// [userId]'s presence everywhere, a person's: it outdates the Spaces' own
  /// entries a SPACE_CREATE gave them.
  Map<String, Presence> _presentEverywhere(String userId, Presence status) {
    final next = {...presence.value, userId: status};
    for (final spaceId in _spaceEntries.remove(userId) ?? const <String>{}) {
      next.remove(spacePresenceKey(userId, spaceId));
    }
    return next;
  }

  /// Whether each user in [statuses] is connected only from the mobile app
  /// ([mobileOnly]), by the client status that comes with a status of theirs
  /// that holds everywhere: null while they're offline, and from a server
  /// before client statuses.
  void _keepPlatforms(Map<String, duvet.ClientStatus?> statuses) {
    final now = mobileOnly.value;
    final next = {
      for (final id in now)
        if (!statuses.containsKey(id)) id,
      for (final MapEntry(key: id, value: status) in statuses.entries)
        if (status?.isMobileOnly ?? false) id,
    };
    if (!setEquals(next, now)) mobileOnly.value = next;
  }

  /// The Spaces each user has an entry of their own in ([spacePresenceKey]):
  /// few, bots' mostly, so a Space's or a person's are found without going
  /// through every entry.
  final _spaceEntries = <String, Set<String>>{};

  /// [userId] has an entry of their own in [spaceId] now; answers [spaceId].
  String _entered(String userId, String spaceId) {
    (_spaceEntries[userId] ??= {}).add(spaceId);
    return spaceId;
  }

  /// Rooms' read states that came after READY, as READY's mark them. A
  /// newer message heard meanwhile keeps an unread room unread.
  void _readStates(Map<String, duvet.RoomReadState> states) {
    if (states.isEmpty) return;
    final marked = {...unread.value};
    for (final MapEntry(key: id, value: state) in states.entries) {
      if (state.lastRead case final read?) _lastRead[id] = read;
      if (state.lastMsg case final newest?) _lastMessage[id] = newest;
      final heard = latest.value[id]?.id;
      final newer = heard != null && heard.compareTo(state.lastMsg ?? '') > 0 && marked.contains(id);
      if (state.unread || newer) {
        marked.add(id);
      } else {
        marked.remove(id);
      }
    }
    if (!setEquals(marked, unread.value)) unread.value = marked;
  }

  void _markUnread(String id) {
    if (!unread.value.contains(id)) unread.value = {...unread.value, id};
  }

  // The conversations whose call the user answered from one of their devices
  // (CALL_ACCEPTED or CALL_DECLINED with their own ID); the call's notice
  // uses the answer up.
  final _callAnswers = <String>{};

  /// A call notice came: one the user saw ([callNoticeSeen]) leaves the
  /// conversation read, as the API leaves it read up to the notice, unless a
  /// newer message is known; one they missed is news like any message.
  void _readCallNotice(String conversationId, String noticeId, CallNotice call, String? me) {
    final answered = _callAnswers.remove(conversationId);
    if (me == null || !callNoticeSeen(call, me, answered: answered)) {
      _markUnread(conversationId);
      return;
    }
    final newest = latest.value[conversationId]?.id;
    if (newest != null && newest != noticeId && newest.compareTo(noticeId) > 0) return;
    if (unread.value.contains(conversationId)) unread.value = {...unread.value}..remove(conversationId);
    if (mentions.value.containsKey(conversationId)) mentions.value = {...mentions.value}..remove(conversationId);
  }

  void _publishSpaces() {
    final now = presence.value;
    final published = [
      for (final (:space, :rooms) in _spaces.values)
        Space(
          id: space.id,
          name: space.name,
          iconUrl: avatarUrl(space.icon),
          bannerUrl: avatarUrl(space.banner),
          ownerId: space.ownerId,
          sections: _sections(space.id, _visibleRooms(space.id, rooms.values)),
          onlineCount: switch (_spaceMemberIds[space.id]) {
            final ids? when ids.isNotEmpty =>
              ids
                  .where((id) => (presenceIn(now, id, spaceId: space.id) ?? Presence.offline) != Presence.offline)
                  .length,
            _ => null,
          },
        ),
      // Those READY names whose SPACE_CREATE hasn't come yet, as they were
      // kept ([restore]): the list doesn't shrink to the first one to come.
      for (final s in spaces.value)
        if (!_spaces.containsKey(s.id) && _spaceOrder.contains(s.id)) s,
    ];
    // In the gateway's order (READY's guild_ids); one made or joined since
    // goes after, as it came. Sorting them is the Launchpad's, by the user's
    // choice.
    final index = {for (final (i, id) in _spaceOrder.indexed) id: i};
    final arrival = {for (final (i, s) in published.indexed) s.id: i};
    int place(Space s) => index[s.id] ?? _spaceOrder.length + arrival[s.id]!;
    spaces.value = published..sort((a, b) => place(a).compareTo(place(b)));
    _saveHome();
  }

  void _setLatest(String chatId, ChatMessage m) {
    final known = latest.value[chatId];
    if (known != null && known.id != m.id && known.createdAt.isAfter(m.createdAt)) return;
    latest.value = {...latest.value, chatId: m};
  }

  // Each room's ephemeral messages, the oldest first.
  final _ephemeral = <String, List<ChatMessage>>{};

  @override
  List<ChatMessage> ephemeralIn(ChatTarget target) => [...?_ephemeral[target.id]];

  @override
  void dismissEphemeral(ChatTarget target, String messageId) => _dropEphemeral(target.id, messageId);

  void _keepEphemeral(String roomId, ChatMessage m) {
    final kept = _ephemeral[roomId] ??= [];
    final i = kept.indexWhere((k) => k.id == m.id);
    i < 0 ? kept.add(m) : kept[i] = m;
  }

  void _dropEphemeral(String roomId, String messageId) => _ephemeral[roomId]?.removeWhere((m) => m.id == messageId);

  // An edit, or a link preview that came late. The event carries no files,
  // reactions, reply or pin: the newest message keeps them, as the chat does,
  // and the Chats tab previews it as merged (a picture's stays "Sent a
  // photo"), or as the event has it when the newest message isn't known.
  void _updated(String chatId, ChatMessage update) {
    final known = latest.value[chatId];
    final merged = known != null && known.id == update.id ? known.updatedBy(update) : null;
    if (merged != null) latest.value = {...latest.value, chatId: merged};
    _recents.edited(chatId, merged ?? update);
    _messageEvents.add((chatId, MessageUpdated(update)));
  }

  // The one before it isn't known here: fetched again when next shown.
  void _latestDeleted(String chatId, String messageId) {
    if (latest.value[chatId]?.id == messageId) latest.value = {...latest.value}..remove(chatId);
  }

  final _loadingLatest = <String>{};

  // The busiest first ([_lastMessage], as message IDs sort by time): they get
  // the whole pages, even those whose newest message is known.
  @override
  Future<void> loadLatest(Iterable<ChatTarget> targets) {
    final busiest = [...targets]..sort((a, b) => (_lastMessage[b.id] ?? '').compareTo(_lastMessage[a.id] ?? ''));
    final ahead = _preloads ? busiest.take(_pagesAhead).toList() : const <ChatTarget>[];
    return _fetchLatest([
      ...ahead.where((t) => !_ahead.contains(t.id)),
      ...busiest.skip(ahead.length).where((t) => !latest.value.containsKey(t.id)),
    ]);
  }

  // The chats whose page kept was fetched, or found to end on the newest
  // message, since READY: live events keep it so ([_keep]). One kept from
  // before isn't added to: its page would skip what came between.
  final _ahead = <String>{};

  /// How many chats a pass fetches at once, and how many of those it fetches
  /// the whole first page of rather than the newest message alone: the chats
  /// most likely to be opened next, which then open with their messages
  /// there. A phone shows about 8 rows of a list; 4 at a time leave the
  /// network to what the person opens meanwhile, and stay far below the
  /// API's limits (64 a minute per route and chat, 50 a second in all). Each
  /// pass has its own [_pagesAhead]: READY starts up to three (the likeliest
  /// chats, the rooms behind, the DMs behind), 24 pages at most, each chat's
  /// once, still [_fetchingAtOnce] a pass.
  static const _fetchingAtOnce = 4;
  static const _pagesAhead = 8;

  /// After a 429, no chat's newest message or page is fetched for this long,
  /// fetching ahead or not: the API asked for fewer requests.
  // shortcut: a fixed wait, as the client drops the Retry-After header the API sends; read it once the client gives it.
  static const _rateLimitWait = Duration(minutes: 1);
  DateTime? _waitUntil;

  // After READY: the newest chats of the Chats tab and of the conversations,
  // whatever the newest message shown.
  Future<void> _preloadLikeliest() async {
    await Future.wait([_recentsLoaded, _conversationsLoaded]);
    final dated = <String, (ChatTarget, DateTime)>{
      for (final c in conversations.value)
        if (c.updatedAt case final at?) c.id: (c.target, at),
      for (final c in _recents.chats.value) c.target.id: (c.target, c.at),
    };
    final newest = dated.values.toList()..sort((a, b) => b.$2.compareTo(a.$2));
    await _fetchLatest([
      for (final (target, _) in newest.take(_pagesAhead))
        if (!_ahead.contains(target.id)) target,
    ]);
  }

  /// Fetches the pictures [urls] name ahead of their rows ([_preloads]).
  void _warm(Iterable<String?> urls) {
    if (!_preloads) return;
    unawaited(Future.sync(() => prefetchImages(urls)).catchError((Object e) => debugPrint('pictures: $e')));
  }

  /// [m], a kept page's last, is [target]'s newest message as far as known:
  /// its page is current since READY ([_ahead]), or, for a room, it's the
  /// very one READY, its Space or a live event named last (message IDs sort
  /// by time). Not one newer than that: it was deleted while the app was
  /// closed, and the API names the one before it. Nothing names a
  /// conversation's newest message (deleting it leaves its date), so a page
  /// of one kept from before is always fetched again.
  // shortcut: READY's last_msg_convs would tell for DMs, which duvet_client 2.7.0 doesn't parse; use it once it does.
  bool _isNewest(ChatTarget target, ChatMessage m) =>
      _ahead.contains(target.id) ||
      switch (target) {
        RoomTarget(:final roomId) => switch ((_lastMessage[roomId], latest.value[roomId]?.id)) {
          (final named?, final heard?) => m.id == (named.compareTo(heard) > 0 ? named : heard),
          (final id, null) || (null, final id) => m.id == id,
        },
        ConversationTarget() => false,
      };

  // How many times READY came, and how many message events each chat had: a
  // page asked for before one of them and answered after may lack it, or
  // have what it took away.
  // shortcut: a reaction's event doesn't say its chat, so one during a fetch isn't counted; the page is fetched again when its chat opens.
  var _readies = 0;
  final _heard = <String, int>{};

  /// Answers, later, whether a page of [chatId] asked for now is still what
  /// the chat holds: no READY and none of its messages' events came since.
  bool Function() _undisturbed(String chatId) {
    final (readies, heard) = (_readies, _heard[chatId]);
    return () => readies == _readies && heard == _heard[chatId];
  }

  /// What a live event does to the page kept of its chat, as the open chat
  /// does it ([AuthorChanged] and [AttachmentRenewed] change them where they
  /// come from): a chat opens on its page as it is now, not as last fetched.
  void _keep(String chatId, MessageEvent event) {
    // Signed out meanwhile: the cache is cleared, and stays so.
    if (_api == null) return;
    _heard[chatId] = (_heard[chatId] ?? 0) + 1;
    List<ChatMessage> each(List<ChatMessage> page, String id, ChatMessage Function(ChatMessage m) change) => [
      for (final m in page) m.id == id ? change(m) : m,
    ];
    switch (event) {
      case MessageCreated(:final message) when !message.isEphemeral && _ahead.contains(chatId):
        unawaited(
          _cache.changePage(
            chatId,
            (page) => page.any((m) => m.id == message.id) ? each(page, message.id, (_) => message) : [...page, message],
          ),
        );
      case MessageUpdated(message: final update):
        unawaited(_cache.changePage(chatId, (page) => each(page, update.id, (m) => m.updatedBy(update))));
      case MessagePinned(:final messageId, :final pinned):
        unawaited(_cache.changePage(chatId, (page) => each(page, messageId, (m) => m.copyWith(pinned: pinned))));
      // Gone, and the replies quoting it say so.
      case MessageDeleted(:final messageId):
        unawaited(
          _cache.changePage(
            chatId,
            (page) => [
              for (final m in page)
                if (m.id != messageId)
                  switch (m.reply) {
                    final reply? when reply.messageId == messageId && !reply.deleted => m.copyWith(
                      reply: reply.asDeleted,
                    ),
                    _ => m,
                  },
            ],
          ),
        );
      // The event doesn't say in which chat: the pages with the message.
      case ReactionChanged(:final messageId, :final userId, :final emoji, :final emojiId, :final added):
        unawaited(
          _cache.changeMessages(
            messageId,
            (_, m) => m.id == messageId && m.reactedWith(userId, emojiId ?? emoji) != added
                ? m.reacted(emoji, userId, add: added, emojiId: emojiId)
                : m,
          ),
        );
      default:
    }
  }

  // Messages sent while the app wasn't listening (closed, or offline too long
  // to resume) never reached the previews, which still show the last one it
  // saw: the rooms whose newest message, as READY names it, isn't the one
  // shown fetch it again, for the Chats tab and their Space's list.
  Future<void> _catchUpRooms() async {
    await _recentsLoaded;
    bool behind(String roomId, String? shown) => _lastMessage[roomId] != null && _lastMessage[roomId] != shown;
    await _fetchLatest({
      for (final c in _recents.chats.value)
        if (c.target case RoomTarget(:final roomId) when behind(roomId, c.previewId)) c.target,
      for (final (:space, :rooms) in _spaces.values)
        for (final id in rooms.keys)
          if (latest.value[id] case final m? when behind(id, m.id)) RoomTarget(spaceId: space.id, roomId: id),
    });
  }

  // The same for DMs, which the list of conversations dates by their newest
  // message.
  Future<void> _catchUpConversations() async {
    await _recentsLoaded;
    final updated = {for (final c in conversations.value) c.id: c.updatedAt};
    bool behind(String conversationId, DateTime shown) => updated[conversationId]?.isAfter(shown) ?? false;
    await _fetchLatest([
      for (final c in _recents.chats.value)
        if (c.target case ConversationTarget(:final conversationId) when behind(conversationId, c.at)) c.target,
    ]);
  }

  // Each chat's newest message, for its preview here and in the Chats tab,
  // [_fetchingAtOnce] at a time, in the order given: the first
  // [_pagesAhead] fetched get their whole page, kept ([cachedMessages]),
  // unless a kept one ends on the newest message already, which then needs
  // no fetch. Signing out, or a 429, stops it.
  Future<void> _fetchLatest(Iterable<ChatTarget> targets) async {
    final api = _api;
    final wanted = [
      for (final t in targets)
        if (_loadingLatest.add(t.id)) t,
    ];
    var pages = _preloads ? _pagesAhead : 0;
    var next = 0;
    // Opened offline, or the network failed on the way: none of the rest.
    var unreachable = _retry != null;
    bool going() => identical(api, _api) && !unreachable && !(_waitUntil?.isAfter(clock.now()) ?? false);

    Future<void> fetch(ChatTarget t) async {
      final current = _undisturbed(t.id);
      // Only while whole pages are left to fetch: reading a kept one costs
      // more than asking for the newest message alone.
      if (pages > 0) {
        if (await _cache.loadPage(t.id) case [..., final last] when current() && _isNewest(t, last)) {
          if (!identical(api, _api)) return;
          _ahead.add(t.id);
          _newest(t, last);
          return;
        }
      }
      final whole = pages-- > 0;
      final page = await _fetchPage(t, null, count: whole ? ChatCache.pageSize : 1);
      if (!identical(api, _api)) return;
      // Not one something happened to on its way: the page kept, if current,
      // has that already, and this one may not.
      if (whole && current()) {
        _ahead.add(t.id);
        _keepPage(t, page);
        _warm({for (final m in page) m.authorAvatarUrl});
      }
      if (page.lastOrNull case final newest?) _newest(t, newest);
    }

    await Future.wait([
      for (var i = 0; i < _fetchingAtOnce; i++)
        () async {
          while (next < wanted.length && going()) {
            final t = wanted[next++];
            try {
              await fetch(t);
            } on duvet.DuvetApiException catch (e) {
              if (e.statusCode == 429) _waitUntil = clock.now().add(_rateLimitWait);
              debugPrint('latest: $e');
            } on SocketException catch (e) {
              unreachable = true;
              debugPrint('latest: $e');
            } on http.ClientException catch (e) {
              unreachable = true;
              debugPrint('latest: $e');
            } on TimeoutException catch (e) {
              unreachable = true;
              debugPrint('latest: $e');
            } catch (e) {
              debugPrint('latest: $e');
            } finally {
              _loadingLatest.remove(t.id);
            }
          }
        }(),
    ]);
    for (final t in wanted.skip(next)) {
      _loadingLatest.remove(t.id);
    }
  }

  // [m] is [target]'s newest message: its preview here and in the Chats tab,
  // where a conversation that wasn't listed for one shows it from now on.
  void _newest(ChatTarget target, ChatMessage m) {
    _setLatest(target.id, m);
    if (target is ConversationTarget && _recents.chats.value.every((c) => c.target.id != target.id)) {
      final known = conversations.value.where((c) => c.id == target.id).firstOrNull;
      _recents.conversationMessage(target.id, m, title: known?.title);
    } else {
      _recents.caughtUp(target.id, m);
    }
  }

  @override
  String previewOf(ChatMessage message) => recent.previewOf(
    message,
    (content) => readableContent(content, nameOf: nameOf, emojiNameOf: emojiNameOf, roomNameOf: _roomNameOf),
  );

  /// The rooms the user may see, as the desktop lists them: those they have
  /// ViewChannels in, and the categories with one of those, whether or not
  /// they may see the category itself (its header shows, with only those
  /// rooms). An empty category shows when they may see it.
  List<duvet.GatewayRoom> _visibleRooms(String spaceId, Iterable<duvet.GatewayRoom> all) {
    final rooms = [
      for (final r in all)
        if (r.deletedAt == null) r,
    ];
    final seen = {
      for (final r in rooms)
        if (canInRoom(spaceId, r.id, Perm.viewChannels)) r.id,
    };
    bool shown(duvet.GatewayRoom r) => r.type != duvet.RoomType.category
        ? seen.contains(r.id)
        : rooms.any((c) => c.parentId == r.id && seen.contains(c.id)) ||
              (seen.contains(r.id) && !rooms.any((c) => c.parentId == r.id));
    return rooms.where(shown).toList();
  }

  /// Rooms by position, then by ID: two that share a position (from before
  /// the API kept them apart, or two changes at once) keep one order, where
  /// Dart's sort, which isn't stable, could swap them between rebuilds.
  static int _byPosition(duvet.GatewayRoom a, duvet.GatewayRoom b) =>
      a.position != b.position ? a.position.compareTo(b.position) : a.id.compareTo(b.id);

  /// The rooms outside any category, then each category's, by position.
  static List<RoomSection> _sections(String spaceId, Iterable<duvet.GatewayRoom> all) {
    final categories = all.where((r) => r.type == duvet.RoomType.category).toList()..sort(_byPosition);
    final categoryIds = {for (final c in categories) c.id};
    final rooms = all.where((r) => r.type != duvet.RoomType.category && r.deletedAt == null).toList()
      ..sort(_byPosition);

    Room toRoom(duvet.GatewayRoom r) => Room(
      id: r.id,
      spaceId: spaceId,
      name: r.name,
      kind: r.type == duvet.RoomType.voice ? RoomKind.voice : RoomKind.text,
      position: r.position,
      description: _described(r.description),
    );

    final loose = [
      for (final r in rooms)
        if (!categoryIds.contains(r.parentId)) toRoom(r),
    ];
    return [
      if (loose.isNotEmpty) RoomSection(name: null, rooms: loose),
      for (final c in categories)
        RoomSection(
          id: c.id,
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
    // Members who share only a DM or a group with the user have no presence
    // from the gateway until it changes: the list's, for those it hasn't told
    // about.
    final listed = {
      for (final c in list)
        for (final m in c.members)
          if (m.statusId case final status? when m.userId != me) m.userId: _presence(status),
    };
    if (listed.keys.any((id) => !presence.value.containsKey(id))) {
      // And whether they're only on mobile, as the list has them.
      _keepPlatforms({
        for (final c in list)
          for (final m in c.members)
            if (m.statusId != null && m.userId != me && !presence.value.containsKey(m.userId)) m.userId: m.clientStatus,
      });
      presence.value = {...listed, ...presence.value};
    }
    _fillFriendBanners();
    _saveHome();
    // As many as the Chats tab lists.
    _warm([for (final c in conversations.value.take(RecentChats.limit)) c.avatarUrl]);
    unawaited(_catchUpConversations());
  }

  ConversationSummary _summary(duvet.Conversation c, String? me) {
    final members = _conversationMembers[c.id] = [
      for (final m in c.members)
        if (m.user case final u?)
          Member(
            userId: u.id,
            username: u.username,
            alias: u.alias,
            avatarUrl: avatarUrl(u.avatar),
            isBot: u.isBot,
            bio: u.custom.trim().isEmpty ? null : u.custom,
            bannerUrl: avatarUrl(u.banner),
          ),
    ];
    for (final m in members) {
      _names[m.userId] = m.displayName;
    }
    return _titled(
      ConversationSummary(
        id: c.id,
        title: '',
        isGroup: c.type == duvet.ConversationType.group,
        memberCount: c.members.length,
        updatedAt: c.updatedAt.toLocal(),
        ownerId: c.ownerId,
        name: c.name?.isNotEmpty == true ? c.name : null,
      ),
      members,
      me,
    );
  }

  // [c] as its members show it: a DM by the other person's name and avatar, a
  // group without a name of its own by everyone else's names.
  ConversationSummary _titled(ConversationSummary c, List<Member> members, String? me) {
    final others = [
      for (final m in members)
        if (m.userId != me) m,
    ];
    return ConversationSummary(
      id: c.id,
      title: c.isGroup
          ? (c.name ?? (others.isEmpty ? 'Group' : others.map((m) => m.displayName).join(', ')))
          : (others.isEmpty ? 'Direct message' : others.first.displayName),
      isGroup: c.isGroup,
      avatarUrl: c.isGroup ? null : others.firstOrNull?.avatarUrl,
      otherUserId: c.isGroup ? null : others.firstOrNull?.userId,
      memberCount: c.memberCount,
      updatedAt: c.updatedAt,
      ownerId: c.ownerId,
      name: c.name,
    );
  }

  // Someone changed their profile: every list that shows them takes it, as
  // the desktop's do, the conversations they're in are named again, and
  // their messages show their new name and avatar ([_authorChanged]).
  // (Members' own names in a Space can't be set: a Space's list shows the
  // user's.)
  void _userUpdated(duvet.UserUpdateEvent u) {
    Member updated(Member m) => Member(
      userId: m.userId,
      username: u.username,
      alias: u.alias,
      avatarUrl: avatarUrl(u.avatar),
      isBot: m.isBot,
      // An API from before bios leaves it out: the one known stays.
      bio: switch (u.custom) {
        null => m.bio,
        final bio => bio.trim().isEmpty ? null : bio,
      },
      bannerUrl: avatarUrl(u.banner),
    );
    // In place: [members] answers these very lists.
    bool patch(List<Member> list) {
      var found = false;
      for (var i = 0; i < list.length; i++) {
        if (list[i].userId != u.id) continue;
        list[i] = updated(list[i]);
        found = true;
      }
      return found;
    }

    final name = _names[u.id] = u.alias?.isNotEmpty == true ? u.alias! : u.username;
    _authorChanged(u.id, name, avatarUrl(u.avatar));
    for (final list in _loadedMembers.values) {
      patch(list);
    }
    final renamed = {
      for (final MapEntry(key: id, value: list) in _conversationMembers.entries)
        if (patch(list)) id,
    };
    if (renamed.isNotEmpty) {
      final me = profile.value?.id;
      conversations.value = [
        for (final c in conversations.value) renamed.contains(c.id) ? _titled(c, _conversationMembers[c.id]!, me) : c,
      ];
      _saveHome();
    }
    final f = friends.value;
    if ([
      ...f.friends,
      for (final r in [...f.incoming, ...f.outgoing]) r.person,
    ].any((m) => m.userId == u.id)) {
      FriendRequestItem request(FriendRequestItem r) =>
          r.person.userId == u.id ? FriendRequestItem(id: r.id, person: updated(r.person), at: r.at) : r;
      friends.value = Friends(
        friends: [for (final m in f.friends) m.userId == u.id ? updated(m) : m]
          ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase())),
        incoming: [for (final r in f.incoming) request(r)],
        outgoing: [for (final r in f.outgoing) request(r)],
      );
    }
  }

  // The name and avatar each user's messages were last given
  // ([_authorChanged]), by user ID, this gateway session.
  final _authors = <String, (String, String?)>{};

  // [userId] goes by [name] now, with the avatar at [avatar]: their messages
  // show it wherever the app holds them, as the desktop renames the messages
  // it has, and so do the replies' quotes of theirs, each chat naming them
  // as [_nameIn] says. The open chats, each chat's newest message, the bots'
  // answers to the user alone, the Chats tab's previews, and the pages kept
  // for offline.
  void _authorChanged(String userId, String name, String? avatar) {
    // USER_UPDATE comes once per Space the user shares with them, and for a
    // new bio or badges too: the name and avatar last given to their messages
    // change nothing again, and the pages kept aren't read again for them.
    if (_authors[userId] == (name, avatar)) return;
    _authors[userId] = (name, avatar);
    AuthorChanged changeIn(String chatId) =>
        AuthorChanged(userId, name: _nameIn(chatId, userId, name), avatarUrl: avatar);
    // [messageEvents] names them as each chat does.
    _messageEvents.add((_anyChat, AuthorChanged(userId, name: name, avatarUrl: avatar)));
    final renamed = {for (final MapEntry(key: id, value: m) in latest.value.entries) id: m.changedBy(changeIn(id))};
    if (renamed.entries.any((e) => !identical(e.value, latest.value[e.key]))) latest.value = renamed;
    for (final MapEntry(key: roomId, value: kept) in _ephemeral.entries) {
      for (var i = 0; i < kept.length; i++) {
        kept[i] = kept[i].changedBy(changeIn(roomId));
      }
    }
    _recents.renamed(userId, (target) => changeIn(target.id).name);
    unawaited(_cache.changeMessages(userId, (chatId, m) => m.changedBy(changeIn(chatId))));
  }

  // [name], the one [userId] goes by, as the chat [chatId] names them: a
  // room by their nickname in its Space, if they have one there, as its
  // history does.
  String _nameIn(String chatId, String userId, String name) => _nicknames[_spaceOfRoom(chatId)]?[userId] ?? name;

  @override
  Future<List<ChatMessage>> messages(ChatTarget target, {String? before}) async {
    final api = _api;
    final current = _undisturbed(target.id);
    try {
      final page = await _fetchPage(target, before);
      // Not once signed out: nothing is kept after. Nor one something
      // happened to on its way ([_undisturbed]).
      if (before == null && identical(api, _api) && current()) {
        _keepPage(target, page);
        _ahead.add(target.id);
      }
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

  @override
  Future<List<ChatMessage>?> cachedMessages(ChatTarget target) => _cache.loadPage(target.id);

  // A room's newest page is kept for offline; a conversation's never is: it's
  // end-to-end encrypted, and what it says stays in the core's database alone.
  void _keepPage(ChatTarget target, List<ChatMessage> page) {
    if (target is RoomTarget) _cache.savePage(target.id, page);
  }

  // [count] is the client's default.
  Future<List<ChatMessage>> _fetchPage(ChatTarget target, String? before, {int count = 100}) async {
    // The API answers the newest first.
    final List<ChatMessage> page = switch (target) {
      RoomTarget(:final roomId) => [
        for (final m in await _call((api) => api.getMessages(roomId, before: before, count: count)))
          if (m.deletedAt == null) _roomMessage(m),
      ],
      ConversationTarget(:final conversationId) => [
        for (final m in await _call((api) => api.getDirectMessages(conversationId, before: before, count: count)))
          _directMessage(m),
      ],
    };
    return page.reversed.toList();
  }

  @override
  Stream<MessageEvent> messageEvents(ChatTarget target) => _messageEvents.stream
      .where((e) => e.$1 == target.id || e.$1 == _anyChat)
      .map(
        (e) => switch (e.$2) {
          // As this chat names them.
          AuthorChanged(:final userId, :final name, :final avatarUrl) => AuthorChanged(
            userId,
            name: _nameIn(target.id, userId, name),
            avatarUrl: avatarUrl,
          ),
          final event => event,
        },
      );

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

  // The links the API signed again this session, by attachment ID, when it
  // signed each, and those it's signing: a file asked for twice at once is
  // signed once.
  final _links = <String, String>{};
  final _signedAt = <String, DateTime>{};
  final _renewing = <String, Future<String>>{};
  // Counts the sessions: a renewal that ends after the one it began in is
  // kept nowhere.
  var _linksSession = 0;

  /// How long after the API signed a file's link it isn't asked again: a
  /// link that fails for another reason (a file that won't decode, a
  /// storage's own refusal) mustn't spend the API's 64 a minute.
  static const resignCooldown = Duration(minutes: 1);

  @override
  Future<String> attachmentLink(MessageAttachment attachment, {bool refused = false}) async {
    final own = attachment.linkExpires;
    if (own == null) return attachment.url;
    // A copy of the message older than one renewed here (a gallery opened
    // before, a bot's answer kept aside) has the old link.
    final renewed = _links[attachment.id];
    final known = switch (renewed) {
      final url? when attachment.withUrl(url).linkExpires?.isAfter(own) ?? false => url,
      _ => attachment.url,
    };
    final now = clock.now();
    final due = attachment.withUrl(known).linkDueAt(now);
    // [attachment] has the link that failed: a newer one may not have.
    if (!due && (!refused || known != attachment.url)) return known;
    final signedAt = _signedAt[attachment.id];
    if (!_renewing.containsKey(attachment.id) && signedAt != null && now.difference(signedAt) < resignCooldown) {
      return known;
    }
    try {
      return await (_renewing[attachment.id] ??= () {
        final renewing = _renew(attachment.id);
        // A block: whenComplete would wait for the future remove() answers,
        // which is this one. One of a session since ended leaves the next's.
        renewing.whenComplete(() {
          if (identical(_renewing[attachment.id], renewing)) _renewing.remove(attachment.id);
        }).ignore();
        return renewing;
      }());
    } catch (e) {
      // Not found, or offline: its link is all there is.
      debugPrint('attachment link: $e');
      return known;
    }
  }

  // Asks the API to sign [attachmentId]'s link again; the messages here with
  // the file load it from the new one, as do the pages kept for offline.
  Future<String> _renew(String attachmentId) async {
    final session = _linksSession;
    final url = _absolute(await _call((api) => api.resignAttachment(attachmentId)), attachmentId);
    if (session != _linksSession) return url;
    _links[attachmentId] = url;
    _signedAt[attachmentId] = clock.now();
    _messageEvents.add((_anyChat, AttachmentRenewed(attachmentId, url)));
    unawaited(_cache.changeMessages(attachmentId, (_, m) => m.withAttachmentLink(attachmentId, url)));
    return url;
  }

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
        // A custom emoji's by its ID: another Space's emoji can have its name.
        (RoomTarget(:final roomId), false) => _call(
          (api) => api.removeRoomReaction(roomId, messageId, emojiId ?? emoji),
        ),
        (ConversationTarget(:final conversationId), true) => _call(
          (api) => api.addConversationReaction(conversationId, messageId, emoji, emojiId: emojiId),
        ),
        (ConversationTarget(:final conversationId), false) => _call(
          (api) => api.removeConversationReaction(conversationId, messageId, emojiId ?? emoji),
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
    bool? mentionRepliedUser,
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    // The folders of the links [_named] makes: deleted once sent, or not.
    final links = <Directory>[];
    void progress(int sent, int total) => onProgress?.call(total == 0 ? 0 : sent / total);
    try {
      final upload = files.isEmpty ? null : [for (final f in files) await _named(f, links)];
      return await _sendTo(target, content, nonce, upload, sticker, replyTo, mentionRepliedUser, progress, cancel);
    } on duvet.DuvetApiException catch (e) {
      if (e.statusCode == 413) throw const UploadTooLarge();
      if (_refusal(e) case final reason?) throw ActionFailed(reason);
      rethrow;
    } finally {
      // The links go, not the files they point to.
      for (final dir in links) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException catch (e) {
          debugPrint('upload link: $e');
        }
      }
    }
  }

  // duvet_client names an upload after its path's last part: a file named
  // otherwise (marked as a spoiler, say) goes through a link of its name, in
  // a folder of its own added to [links]. A name that can't be one file's
  // (empty, or with a slash) goes as the path names it.
  static Future<File> _named(OutgoingFile f, List<Directory> links) async {
    final file = File(f.path);
    if (f.name.isEmpty || f.name.contains('/') || f.name == '.' || f.name == '..') return file;
    if (file.uri.pathSegments.last == f.name) return file;
    final dir = await Directory.systemTemp.createTemp('upload');
    links.add(dir);
    return File((await Link('${dir.path}/${f.name}').create(f.path)).path);
  }

  // Why the API refused a request, for the user to read: its reason, as the
  // desktop's `getApiError` shows it, for any error but a 401, which ends the
  // session (a 403 comes as a DuvetAuthException too).
  static String? _refusal(duvet.DuvetApiException e) => e.statusCode == 401 ? null : _serverReason(e);

  Future<ChatMessage> _sendTo(
    ChatTarget target,
    String content,
    String nonce,
    List<File>? upload,
    Sticker? sticker,
    String? replyTo,
    bool? mentionRepliedUser,
    void Function(int sent, int total) progress,
    Future<void>? cancel,
  ) {
    // Left out, the API pings the replied author.
    final allowedMentions = mentionRepliedUser == null ? null : duvet.AllowedMentions(repliedUser: mentionRepliedUser);
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
          allowedMentions: allowedMentions,
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
          allowedMentions: allowedMentions,
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
  }) async {
    try {
      return await switch (target) {
        RoomTarget(:final roomId) => _call(
          (api) => api.sendVoiceNote(roomId, audio, nonce: nonce, format: format),
        ).then(_roomMessage),
        ConversationTarget(:final conversationId) => _call(
          (api) => api.sendDMVoiceNote(conversationId, audio, nonce: nonce, format: format),
        ).then(_directMessage),
      };
    } on duvet.DuvetApiException catch (e) {
      if (_refusal(e) case final reason?) throw ActionFailed(reason);
      rethrow;
    }
  }

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
  Future<SearchPage> search(SearchQuery q) async {
    final params = duvet.MessageSearch(
      query: q.text,
      roomIds: q.roomIds,
      authorIds: q.authorIds,
      mentions: q.mentionIds,
      has: q.has,
      pinned: q.pinned,
      before: q.before,
      after: q.after,
      cursor: q.cursor,
    );
    if (q.conversationId case final id?) {
      final page = await _call((api) => api.searchConversationMessages(id, params));
      return (
        hits: [for (final m in page.messages) SearchHit(target: ConversationTarget(id), message: _directMessage(m))],
        total: page.totalResults,
      );
    }
    final spaceId = q.spaceId;
    if (spaceId == null) return (hits: const <SearchHit>[], total: 0);
    final page = await _call((api) => api.searchSpaceMessages(spaceId, params));
    return (
      hits: [
        for (final m in page.messages)
          SearchHit(
            target: RoomTarget(spaceId: spaceId, roomId: m.roomId),
            message: _roomMessage(m),
          ),
      ],
      total: page.totalResults,
    );
  }

  @override
  Future<List<ChatMessage>> pins(ChatTarget target) async => switch (target) {
    RoomTarget(:final roomId) => [for (final m in await _call((api) => api.getRoomPins(roomId))) _roomMessage(m)],
    ConversationTarget(:final conversationId) => [
      for (final m in await _call((api) => api.getConversationPins(conversationId))) _directMessage(m),
    ],
  };

  @override
  Future<void> pin(ChatTarget target, String messageId, {required bool pinned}) async {
    try {
      await switch ((target, pinned)) {
        (RoomTarget(:final roomId), true) => _call((api) => api.pinRoomMessage(roomId, messageId)),
        (RoomTarget(:final roomId), false) => _call((api) => api.unpinRoomMessage(roomId, messageId)),
        (ConversationTarget(:final conversationId), true) => _call(
          (api) => api.pinConversationMessage(conversationId, messageId),
        ),
        (ConversationTarget(:final conversationId), false) => _call(
          (api) => api.unpinConversationMessage(conversationId, messageId),
        ),
      };
    } on duvet.DuvetApiException catch (e) {
      if (_refusal(e) case final reason?) throw ActionFailed(reason);
      rethrow;
    }
  }

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
    // Unanswered, it may have been made, and trying again would make another.
    final created = await _explained(
      (api) => api.createSpace(name, description: description),
      unanswered: 'Duvet didn’t answer. Check Spaces before trying again: it may have been made.',
    );
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
    _spaceOrder = [..._spaceOrder.where((id) => id != spaceId)];
    _nicknames.remove(spaceId);
    _spaceMemberIds.remove(spaceId);
    _forgetMembers(spaceId);
    final entered = [
      for (final MapEntry(key: userId, value: spaces) in _spaceEntries.entries)
        if (spaces.remove(spaceId)) userId,
    ];
    if (entered.isNotEmpty) {
      final next = {...presence.value};
      for (final userId in entered) {
        next.remove(spacePresenceKey(userId, spaceId));
      }
      presence.value = next;
    }
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
    _spaceOrder = [..._spaceOrder.where((id) => id != spaceId)];
    _forgetMembers(spaceId);
    _publishSpaces();
  }

  @override
  Future<String> createInvite(String spaceId, String roomId, {Duration? maxAge}) async {
    final String code;
    try {
      code = await _explained((api) => api.createRoomInvite(spaceId, roomId, maxAge?.inSeconds ?? 0));
    } on duvet.DuvetApiException catch (e) {
      // One without the API's reason.
      final room = _spaces[spaceId]?.rooms[roomId]?.name;
      throw ActionFailed(switch (e.statusCode) {
        403 => 'You can’t invite people${room == null ? '' : ' to #$room'}',
        400 => 'The server refused the link',
        _ => 'The server couldn’t make a link (${e.statusCode})',
      });
    }
    return '$duvetDomain/invite?code=${Uri.encodeQueryComponent(code)}';
  }

  /// Runs a request whose refusal the user should read: the API's reason, as
  /// the desktop's `getApiError` shows it, or that Duvet couldn't be reached.
  /// A 401 is the session's, which [_call] renews or ends. With [unanswered],
  /// a request whose answer never came says that instead: it timed out, or
  /// its connection failed, before or after it reached the server, which the
  /// HTTP client doesn't tell apart. It may have gone through.
  Future<T> _explained<T>(Future<T> Function(duvet.RestClient api) request, {String? unanswered}) async {
    try {
      return await _call(request);
    } on duvet.DuvetApiException catch (e) {
      if (e.statusCode == 401) rethrow;
      debugPrint('refused: $e');
      if (_serverReason(e) case final reason?) throw ActionFailed(reason);
      rethrow;
    } on TimeoutException {
      throw ActionFailed(unanswered ?? 'Duvet didn’t answer. Check your connection and try again.');
    } on http.RequestAbortedException {
      rethrow;
    } on SocketException catch (e) {
      throw _offline(e, unanswered);
    } on http.ClientException catch (e) {
      throw _offline(e, unanswered);
    }
  }

  // The server out of reach: the socket's errors, and the HTTP client's for
  // them. Not other I/O, a file that can't be read, say. A request that may
  // have gone through says [unanswered] instead.
  static ActionFailed _offline(Object e, String? unanswered) {
    debugPrint('offline: $e');
    return ActionFailed(unanswered ?? 'No connection. Check it and try again.');
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
    // Not the default role, which everyone has: its ID is the Space's.
    final mine = [
      for (final id in _memberRoles[spaceId]?[userId] ?? const <String>[])
        if (roles[id] case final r? when r.id != spaceId) r,
    ]..sort((a, b) => b.position.compareTo(a.position));
    return [
      for (final r in mine)
        RoleTag(
          r.name,
          color: r.colorFrom == null ? null : 0xFF000000 | r.colorFrom!,
          colorVia: r.colorVia == null ? null : 0xFF000000 | r.colorVia!,
          colorTo: r.colorTo == null ? null : 0xFF000000 | r.colorTo!,
          id: r.id,
          position: r.position,
          hoisted: r.hoisted,
        ),
    ];
  }

  @override
  bool isMember(String spaceId, String userId) => _spaceMemberIds[spaceId]?.contains(userId) ?? false;

  @override
  final ValueNotifier<Friends> friends = ValueNotifier(Friends.none);

  // The friends lists' loads, counted, and the newest one shown: an older
  // one that answers late (an event came while it was under way) is dropped.
  int _friendsLoads = 0;
  int _friendsShown = 0;

  Member _person(String id, String username, String? alias, String? avatar, String? banner) =>
      Member(userId: id, username: username, alias: alias, avatarUrl: avatarUrl(avatar), bannerUrl: avatarUrl(banner));

  @override
  Future<void> loadFriends() async {
    final api = _api;
    final load = ++_friendsLoads;
    final me = profile.value?.id;
    final (list, incoming, outgoing) = await (
      _call((api) => api.getFriends()),
      _call((api) => api.getPendingRequests()),
      _call((api) => api.getSentRequests()),
    ).wait;
    if (!identical(api, _api) || load < _friendsShown) return;
    _friendsShown = load;
    // Friends sharing no space with the user have no presence from the gateway
    // until it changes: the list's, for those it hasn't told about.
    final listed = {
      for (final f in list)
        if (f.statusId case final status?) (f.senderId == me ? f.recipientId : f.senderId): _presence(status),
    };
    if (listed.keys.any((id) => !presence.value.containsKey(id))) {
      // And whether they're only on mobile, as the list has them.
      _keepPlatforms({
        for (final f in list)
          if ((f.senderId == me ? f.recipientId : f.senderId) case final id
              when f.statusId != null && !presence.value.containsKey(id))
            id: f.clientStatus,
      });
      presence.value = {...listed, ...presence.value};
    }
    final loaded = Friends(
      friends: [
        for (final f in list)
          _person(
            f.senderId == me ? f.recipientId : f.senderId,
            f.userUsername,
            f.userAlias,
            f.userAvatar,
            f.userBanner,
          ),
      ]..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase())),
      incoming: [
        for (final r in incoming)
          FriendRequestItem(
            id: r.id,
            person: _person(r.senderId, r.userUsername ?? 'someone', r.userAlias, r.userAvatar, r.userBanner),
            at: r.createdAt.toLocal(),
          ),
      ],
      outgoing: [
        for (final r in outgoing)
          FriendRequestItem(
            id: r.id,
            person: _person(r.recipientId, r.userUsername ?? 'someone', r.userAlias, r.userAvatar, r.userBanner),
            at: r.createdAt.toLocal(),
          ),
      ],
    );
    friends.value = _withBanners(loaded);
    for (final m in [
      ...friends.value.friends,
      for (final r in [...friends.value.incoming, ...friends.value.outgoing]) r.person,
    ]) {
      _names[m.userId] = m.displayName;
    }
  }

  // The friends lists have banners since api#63; from an API before, they
  // come without (#15), and a Space's or a conversation's members have them. [f] with the banners known for its
  // people, or [f] itself when none is new.
  Friends _withBanners(Friends f) {
    final banners = {for (final p in people) p.userId: ?p.bannerUrl};
    Member filled(Member m) => switch (banners[m.userId]) {
      final banner? when m.bannerUrl == null => Member(
        userId: m.userId,
        username: m.username,
        alias: m.alias,
        avatarUrl: m.avatarUrl,
        isBot: m.isBot,
        bio: m.bio,
        bannerUrl: banner,
      ),
      _ => m,
    };
    FriendRequestItem request(FriendRequestItem r) => switch (filled(r.person)) {
      final person when !identical(person, r.person) => FriendRequestItem(id: r.id, person: person, at: r.at),
      _ => r,
    };
    final friends = [for (final m in f.friends) filled(m)];
    final incoming = [for (final r in f.incoming) request(r)];
    final outgoing = [for (final r in f.outgoing) request(r)];
    bool same<T>(List<T> a, List<T> b) => Iterable.generate(a.length).every((i) => identical(a[i], b[i]));
    return same(friends, f.friends) && same(incoming, f.incoming) && same(outgoing, f.outgoing)
        ? f
        : Friends(friends: friends, incoming: incoming, outgoing: outgoing);
  }

  // Members loaded: the friends among them take their banners.
  void _fillFriendBanners() {
    final f = friends.value;
    final filled = _withBanners(f);
    if (!identical(filled, f)) friends.value = filled;
  }

  Future<void> _reloadFriends() => loadFriends().catchError((Object e) => debugPrint('friends: $e'));

  @override
  Future<void> sendFriendRequest(String userId) async {
    await _attempt((api) => api.sendFriendRequest(userId));
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
    final group = await _attempt((api) => api.createGroup(name, userIds));
    await refreshConversations();
    return conversations.value.where((c) => c.id == group.id).firstOrNull ?? _summary(group, profile.value?.id);
  }

  @override
  Future<void> renameConversation(String conversationId, String name) async {
    await _attempt((api) => api.updateConversation(conversationId, name));
    await refreshConversations();
  }

  @override
  Future<void> addToConversation(String conversationId, String userId) async {
    await _attempt((api) => api.addConversationMember(conversationId, userId));
    await refreshConversations();
  }

  @override
  Future<void> removeFromConversation(String conversationId, String userId) async {
    await _attempt((api) => api.removeConversationMember(conversationId, userId));
    await refreshConversations();
  }

  @override
  Future<void> leaveConversation(String conversationId) async {
    await _attempt((api) => api.leaveConversation(conversationId));
    await refreshConversations();
  }

  // [_call], for what the API may refuse: its reason, as it says it, is the
  // [ActionFailed] to show, as the desktop shows it.
  Future<T> _attempt<T>(Future<T> Function(duvet.RestClient api) request) async {
    try {
      return await _call(request);
    } on duvet.DuvetApiException catch (e) {
      if (_refusal(e) case final reason?) throw ActionFailed(reason);
      rethrow;
    }
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
    _warm([profile.value!.avatarUrl]);
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
    } on duvet.DuvetApiException catch (e) {
      _closeSession();
      // The API's own reason for a username or an email it refuses.
      if (_refusal(e) case final reason? when e.statusCode < 500) throw ActionFailed(reason);
      rethrow;
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
  Future<void> sendResetPasswordEmail() => _call((api) => api.sendResetPasswordEmail());

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
  Future<void> updateProfile({required String alias, String? bio, String? username}) async {
    final trimmed = alias.trim();
    final about = bio?.trim();
    final me = await _attempt(
      (api) => api.updateUser(
        username: username?.trim(),
        alias: trimmed.isEmpty ? null : trimmed,
        clearAlias: trimmed.isEmpty,
        custom: about,
      ),
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
  Future<void> uploadProfileImage(ProfileImage kind, String path, {void Function(double progress)? onProgress}) async {
    final bytes = await File(path).readAsBytes();
    final me = await _attempt(
      (api) => api.uploadProfileImage(
        kind == ProfileImage.avatar ? duvet.ProfileImageKind.avatar : duvet.ProfileImageKind.banner,
        bytes,
        path.split(Platform.pathSeparator).last,
        onProgress: _bytesSent(onProgress),
      ),
    );
    _setProfile(me);
  }

  @override
  Future<void> removeProfileImage(ProfileImage kind) async {
    final me = await _attempt(
      (api) => api.updateUser(clearAvatar: kind == ProfileImage.avatar, clearBanner: kind == ProfileImage.banner),
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
  // roles', then @everyone's overwrite, the roles' together, the member's own;
  // and none at all without ViewChannels, the owner and Administrators aside.
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
    if (perms & Perm.viewChannels == 0) perms = 0;
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
      locale: space.locale,
      memberCount: _spaceMemberIds[spaceId]?.length ?? 0,
      owner: space.ownerId == profile.value?.id,
      perms: _permsIn(spaceId),
      managesRooms: adminRooms(spaceId).any((r) => canInRoom(spaceId, r.id, Perm.manageChannels)),
    );
  }

  @override
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
  }) async {
    final removesBanner = removeBanner && bannerPath == null;
    final removesIcon = removeIcon && iconPath == null;
    // Pictures, or taking one away, go as a form, where the API skips an
    // empty description or locale: those cleared go first, on their own.
    final multipart = iconPath != null || bannerPath != null || removesBanner || removesIcon;
    final clearsDescription = description != null && description.isEmpty && multipart;
    final clearsLocale = locale != null && locale.isEmpty && multipart;
    try {
      if (clearsDescription || clearsLocale) {
        await _call(
          (api) =>
              api.updateSpace(spaceId, description: clearsDescription ? '' : null, locale: clearsLocale ? '' : null),
        );
      }
      await _call(
        (api) => api.updateSpace(
          spaceId,
          name: name,
          description: clearsDescription ? null : description,
          locale: clearsLocale ? null : locale,
          icon: iconPath == null ? null : File(iconPath),
          banner: bannerPath == null ? null : File(bannerPath),
          removeBanner: removesBanner,
          removeIcon: removesIcon,
          defaultNotifications: switch (defaultNotifications) {
            NotificationLevel.all => duvet.NotificationLevel.all,
            NotificationLevel.mentions => duvet.NotificationLevel.mentions,
            // Not a default: the client refuses it before sending anything.
            NotificationLevel.nothing => duvet.NotificationLevel.nothing,
            null => null,
          },
          // Pictures' alone: taking the banner away goes as a form too, whose
          // few bytes would say "Uploading · 100%" with nothing going up.
          onProgress: iconPath != null || bannerPath != null ? _bytesSent(onProgress) : null,
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
    for (final r in _visibleRooms(spaceId, _spaces[spaceId]?.rooms.values ?? const [])..sort(_byPosition))
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
        description: r.type == duvet.RoomType.category ? null : _described(r.description),
      ),
  ];

  /// A room's description as shown: none when blank.
  static String? _described(String? text) => text == null || text.trim().isEmpty ? null : text.trim();

  @override
  Future<void> createRoom(String spaceId, String name, AdminRoomKind kind, {String? parentId}) async {
    final room = await _explained(
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
    final room = await _explained((api) => api.updateRoom(spaceId, roomId, name: name));
    _spaces[spaceId]?.rooms[room.id] = room;
    _publishSpaces();
  }

  @override
  Future<void> setRoomDescription(String spaceId, String roomId, String? description) async {
    // Blank clears it: null as the API takes it, which `clear_description`
    // isn't (the desktop's, which the API ignores).
    final text = _described(description);
    final room = await _explained(
      (api) => api.updateRoom(spaceId, roomId, description: text, clearDescription: text == null),
    );
    _spaces[spaceId]?.rooms[room.id] = room;
    _publishSpaces();
  }

  @override
  Future<void> deleteRoom(String spaceId, String roomId) async {
    await _explained((api) => api.deleteRoom(spaceId, roomId));
    _roomGone(spaceId, roomId);
  }

  /// A room was deleted. The API numbers its level 0, 1, 2… again, and moves a
  /// category's rooms out of it, after the last place of the top level, in the
  /// order they had: here they go there too, outside any category, until
  /// ROOM_REORDER, which follows ROOM_DELETE whenever the deletion moved
  /// others, gives every room its place. Left at their old places, they'd
  /// share them with the top level's rooms, and go among them by ID.
  ///
  /// ROOM_DELETE also takes away a room the user can no longer view. Its
  /// overwrites go with it: no event about them comes while it's away, and
  /// when the user can view it again, ROOM_CREATE brings it back, followed by
  /// the overwrites it has then.
  void _roomGone(String spaceId, String roomId) {
    _overwrites[spaceId]?.remove(roomId);
    final rooms = _spaces[spaceId]?.rooms;
    if (rooms == null) return;
    rooms.remove(roomId);
    final moved = rooms.values.where((r) => r.parentId == roomId).toList()..sort(_byPosition);
    var next =
        rooms.values.where((r) => r.parentId == null).fold(-1, (last, r) => r.position > last ? r.position : last) + 1;
    for (final r in moved) {
      rooms[r.id] = _placed(r, parentId: null, position: next++);
    }
    _publishSpaces();
  }

  /// [r] at another [position], in [parentId] (null: outside any category).
  static duvet.GatewayRoom _placed(duvet.GatewayRoom r, {required String? parentId, required int position}) =>
      duvet.GatewayRoom(
        id: r.id,
        spaceId: r.spaceId,
        parentId: parentId,
        type: r.type,
        name: r.name,
        description: r.description,
        position: position,
        nsfw: r.nsfw,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        deletedAt: r.deletedAt,
      );

  @override
  Future<void> moveRoom(String spaceId, String roomId, {String? parentId, required int position}) async {
    final rooms = _spaces[spaceId]?.rooms;
    // Each room this moved: where it was, and where it went.
    final shifted = <String, ({int from, String? fromParent, int to, String? toParent})>{};
    // Moved here as the API moves it, so the list doesn't jump back while
    // the change is on its way; ROOM_REORDER confirms it.
    final moved = rooms?[roomId];
    if (rooms != null && moved != null) {
      final to = moved.type == duvet.RoomType.category ? null : parentId;
      var at = position;
      if (moved.parentId == to && at > moved.position) at--;
      for (final r in rooms.values.toList()) {
        if (r.id == roomId) continue;
        var p = r.position;
        if (r.parentId == moved.parentId && p > moved.position) p--;
        if (r.parentId == to && p >= at) p++;
        if (p != r.position) {
          rooms[r.id] = _placed(r, parentId: r.parentId, position: p);
          shifted[r.id] = (from: r.position, fromParent: r.parentId, to: p, toParent: r.parentId);
        }
      }
      rooms[roomId] = _placed(moved, parentId: to, position: at);
      shifted[roomId] = (from: moved.position, fromParent: moved.parentId, to: at, toParent: to);
      _publishSpaces();
    }
    try {
      final room = await _explained(
        (api) => api.updateRoom(spaceId, roomId, parentId: parentId, clearParent: parentId == null, position: position),
      );
      _spaces[spaceId]?.rooms[room.id] = room;
    } catch (_) {
      // Back where they were: only the rooms this moved, and only where
      // nothing else has moved them since.
      for (final MapEntry(key: id, value: m) in shifted.entries) {
        final r = rooms?[id];
        if (r != null && r.position == m.to && r.parentId == m.toParent) {
          rooms![id] = _placed(r, parentId: m.fromParent, position: m.from);
        }
      }
      rethrow;
    } finally {
      _publishSpaces();
    }
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
      // Without one it's as the roles say already, and the API would answer
      // a 404.
      if (!list.any((o) => o.targetId == overwrite.targetId && o.deletedAt == null)) return;
      await _explained((api) => api.deleteRoomOverwrite(spaceId, roomId, overwrite.targetId));
      list.removeWhere((o) => o.targetId == overwrite.targetId);
      _publishSpaces();
      return;
    }
    final saved = await _explained(
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
    _publishSpaces();
  }

  SpaceRole _role(String spaceId, duvet.GatewayRole r) => SpaceRole(
    id: r.id,
    name: r.name,
    color: r.colorFrom,
    colorVia: r.colorVia,
    colorTo: r.colorTo,
    perms: r.permissions,
    position: r.position,
    everyone: r.id == spaceId,
    hoisted: r.hoisted,
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
    final r = await _explained((api) => api.createRole(spaceId, name));
    (_roles[spaceId] ??= {})[r.id] = r;
    return _role(spaceId, r);
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
    final r = await _explained(
      (api) => api.updateRole(
        spaceId,
        roleId,
        name: name,
        // All three with clearColors, as the desktop saves them: a null stop is cleared.
        colorFrom: colors?.from,
        colorVia: colors?.via,
        colorTo: colors?.to,
        permissions: perms,
        clearColors: colors != null,
        hoisted: hoisted,
      ),
    );
    (_roles[spaceId] ??= {})[r.id] = r;
    _publishSpaces();
  }

  @override
  Future<void> moveRole(String spaceId, String roleId, int position) async {
    final roles = _roles[spaceId];
    final moved = roles?[roleId];
    if (roles == null || moved == null) return;
    // As the API will: clamped above @everyone, the roles between shifted one
    // place. Shown at once; its ROLE_UPDATEs then say the same.
    final to = position.clamp(1, roles.length - 1);
    final from = moved.position;
    // What this move shifted, from and to: undone alone if it fails, and only
    // where nothing since (another move, a ROLE_UPDATE) has moved it again.
    final shifts = <String, (int, int)>{};
    for (final r in roles.values.toList()) {
      final shifted = r.id == roleId
          ? to
          : to < from && r.position >= to && r.position < from
          ? r.position + 1
          : to > from && r.position > from && r.position <= to
          ? r.position - 1
          : r.position;
      if (shifted == r.position) continue;
      shifts[r.id] = (r.position, shifted);
      roles[r.id] = _atPosition(r, shifted);
    }
    _publishSpaces();
    try {
      await _explained((api) => api.updateRole(spaceId, roleId, position: to));
    } catch (_) {
      final now = _roles[spaceId];
      for (final MapEntry(key: id, value: (was, shifted)) in shifts.entries) {
        if (now?[id] case final r? when r.position == shifted) now![id] = _atPosition(r, was);
      }
      _publishSpaces();
      rethrow;
    }
  }

  duvet.GatewayRole _atPosition(duvet.GatewayRole r, int position) => duvet.GatewayRole(
    id: r.id,
    spaceId: r.spaceId,
    name: r.name,
    colorFrom: r.colorFrom,
    colorVia: r.colorVia,
    colorTo: r.colorTo,
    flags: r.flags,
    permissions: r.permissions,
    hoisted: r.hoisted,
    position: position,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    deletedAt: r.deletedAt,
  );

  @override
  Future<void> deleteRole(String spaceId, String roleId) async {
    await _explained((api) => api.deleteRole(spaceId, roleId));
    _roles[spaceId]?.remove(roleId);
    for (final ids in _memberRoles[spaceId]?.values ?? const <List<String>>[]) {
      ids.remove(roleId);
    }
    _publishSpaces();
  }

  @override
  List<String> roleMembers(String spaceId, String roleId) => [
    for (final e in _memberRoles[spaceId]?.entries ?? const <MapEntry<String, List<String>>>[])
      if (e.value.contains(roleId)) e.key,
  ];

  @override
  Future<void> setRole(String spaceId, String roleId, String userId, {required bool has}) async {
    final memberId = await _memberId(spaceId, userId);
    await _explained(
      (api) =>
          has ? api.assignRoleToMember(spaceId, roleId, memberId) : api.removeRoleFromMember(spaceId, roleId, memberId),
    );
    final ids = (_memberRoles[spaceId] ??= {})[userId] ??= [];
    has ? (ids.contains(roleId) ? null : ids.add(roleId)) : ids.remove(roleId);
    // The user's own roles change what they may do.
    _publishSpaces();
  }

  // The API names a member by member ID, which the members list gives.
  Future<String> _memberId(String spaceId, String userId) async {
    String? memberIdOf() => _memberUsers[spaceId]?.entries.where((e) => e.value == userId).firstOrNull?.key;
    if (memberIdOf() == null) await _spaceMemberList(spaceId, refresh: true);
    // What the API answers for someone who isn't in the Space.
    return memberIdOf() ?? (throw const ActionFailed('Member not found'));
  }

  @override
  Future<void> kick(String spaceId, String userId) async {
    final memberId = await _memberId(spaceId, userId);
    await _explained((api) => api.kickMember(spaceId, memberId));
  }

  @override
  Future<void> ban(String spaceId, String userId, {String? reason}) =>
      _explained((api) => api.banUser(spaceId, userId, reason: reason));

  @override
  Future<List<SpaceBan>> bans(String spaceId) async {
    final all = <duvet.SpaceBan>[];
    // Every page, as the members list: by user ID, a hundred at a time.
    while (all.length < 5000) {
      final page = await _call((api) => api.getSpaceBans(spaceId, after: all.lastOrNull?.userId, count: 100));
      all.addAll(page);
      if (page.length < 100) break;
    }
    return [
      for (final b in all)
        SpaceBan(
          user: Member(
            userId: b.userId,
            username: b.user.username,
            alias: b.user.alias,
            avatarUrl: avatarUrl(b.user.avatar),
            isBot: b.user.isBot,
          ),
          reason: b.reason,
          bannedBy: nameOf(b.bannedBy) ?? 'Unknown user',
          at: b.createdAt.toLocal(),
        ),
    ]..sort((a, b) => b.at.compareTo(a.at));
  }

  @override
  Future<void> unban(String spaceId, String userId) => _explained((api) => api.unbanUser(spaceId, userId));

  final _bansChanged = StreamController<String>.broadcast();

  @override
  Stream<String> get bansChanged => _bansChanged.stream;

  @override
  Future<List<SpaceInvite>> spaceInvites(String spaceId) async {
    final rooms = _spaces[spaceId]?.rooms ?? const {};
    return [
      for (final i in await _call((api) => api.listSpaceInvites(spaceId)))
        SpaceInvite(
          id: i.id,
          code: i.code,
          roomName: rooms[i.roomId]?.name ?? 'a room',
          createdBy: nameOf(i.createdBy) ?? 'Unknown user',
          createdAt: i.createdAt.toLocal(),
          expiresAt: i.expiresAt?.toLocal(),
        ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<void> revokeInvite(String spaceId, String inviteId) =>
      _explained((api) => api.revokeInvite(spaceId, inviteId));

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

  void _assetsChanged() {
    _emojis = null;
    _stickers = null;
  }

  @override
  Future<void> addAsset(
    String spaceId,
    AssetKind kind,
    String name,
    String path, {
    void Function(double progress)? onProgress,
  }) async {
    await _explained(
      (api) => kind == AssetKind.emoji
          ? api.createEmoji(spaceId, name, File(path), onProgress: _bytesSent(onProgress))
          : api.createSticker(spaceId, name, File(path), onProgress: _bytesSent(onProgress)),
    );
    _assetsChanged();
  }

  @override
  Future<void> renameAsset(String spaceId, AssetKind kind, String id, String name) async {
    await _explained(
      (api) => kind == AssetKind.emoji ? api.updateEmoji(spaceId, id, name) : api.updateSticker(spaceId, id, name),
    );
    _assetsChanged();
  }

  @override
  Future<void> deleteAsset(String spaceId, AssetKind kind, String id) async {
    await _explained((api) => kind == AssetKind.emoji ? api.deleteEmoji(spaceId, id) : api.deleteSticker(spaceId, id));
    _assetsChanged();
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

  String _webhookUrl(String id, String token) => '$_origin/api/webhooks/$id/$token';

  @override
  Future<String> createWebhook(String spaceId, String roomId, String name) async {
    final created = await _explained((api) => api.createWebhook(spaceId, roomId, name));
    return _webhookUrl(created.webhook.id, created.token);
  }

  @override
  Future<String> resetWebhook(String spaceId, SpaceWebhook webhook) async {
    final token = await _explained((api) => api.resetWebhookToken(spaceId, webhook.roomId, webhook.id));
    return _webhookUrl(webhook.id, token);
  }

  @override
  Future<void> deleteWebhook(String spaceId, SpaceWebhook webhook) =>
      _explained((api) => api.deleteWebhook(spaceId, webhook.roomId, webhook.id));

  @override
  Future<void> updateWebhook(
    String spaceId,
    SpaceWebhook webhook, {
    String? name,
    String? avatarPath,
    bool removeAvatar = false,
  }) => _explained(
    (api) => api.updateWebhook(
      spaceId,
      webhook.roomId,
      webhook.id,
      username: name,
      avatar: avatarPath == null ? null : File(avatarPath),
      removeAvatar: removeAvatar,
    ),
  );

  @override
  final ValueNotifier<List<TeamInvite>> teamInvites = ValueNotifier(const []);

  // A load that answers after a newer one is dropped; one that answers after
  // the user accepted or declined an invite may still list it, and doesn't.
  int _invitesVersion = 0;
  final _answeredInvites = <String>{};

  Future<void> _reloadTeamInvites() async {
    final api = _api;
    final version = ++_invitesVersion;
    try {
      final list = await _call((api) => api.listMyTeamInvites());
      if (!identical(api, _api) || version != _invitesVersion) return;
      teamInvites.value = [
        for (final i in list)
          if (!_answeredInvites.contains(i.id))
            TeamInvite(id: i.id, teamName: i.teamName, invitedBy: i.invitedByUsername),
      ];
    } catch (e) {
      debugPrint('team invites: $e');
    }
  }

  void _dropTeamInvite(String id) {
    _answeredInvites.add(id);
    teamInvites.value = [
      for (final i in teamInvites.value)
        if (i.id != id) i,
    ];
  }

  @override
  Future<void> acceptTeamInvite(String inviteId) async {
    await _explained((api) => api.acceptTeamInvite(inviteId));
    _dropTeamInvite(inviteId);
  }

  @override
  Future<void> declineTeamInvite(String inviteId) async {
    await _explained((api) => api.declineTeamInvite(inviteId));
    _dropTeamInvite(inviteId);
  }

  DevTeam _team(duvet.Team t) => DevTeam(id: t.id, name: t.name, ownerId: t.ownerId);

  DevApp _app(duvet.Application a) => DevApp(
    id: a.id,
    teamId: a.teamId,
    name: a.name,
    description: a.description,
    public: a.public,
    botUserId: a.botUserId,
  );

  @override
  Future<List<DevTeam>> teams() async => [for (final t in await _call((api) => api.listTeams())) _team(t)];

  @override
  Future<DevTeam> createTeam(String name) async => _team(await _explained((api) => api.createTeam(name)));

  @override
  Future<void> renameTeam(String teamId, String name) => _explained((api) => api.updateTeam(teamId, name));

  @override
  Future<void> deleteTeam(String teamId) => _explained((api) => api.deleteTeam(teamId));

  @override
  Future<List<Member>> teamMembers(String teamId) async => [
    for (final m in await _call((api) => api.listTeamMembers(teamId)))
      _person(m.userId, m.username, null, m.avatar, null),
  ];

  @override
  Future<void> inviteToTeam(String teamId, String email) => _explained((api) => api.inviteToTeam(teamId, email));

  @override
  Future<void> removeTeamMember(String teamId, String userId) =>
      _explained((api) => api.removeTeamMember(teamId, userId));

  @override
  Future<List<DevApp>> applications(String teamId) async => [
    for (final a in await _call((api) => api.listApplications(teamId))) _app(a),
  ];

  @override
  Future<DevApp> createApplication(String teamId, String name, {String? description}) async =>
      _app(await _explained((api) => api.createApplication(teamId, name, description: description)));

  @override
  Future<DevApp> updateApplication(DevApp app, {String? name, String? description, bool? public}) async => _app(
    await _explained(
      (api) => api.updateApplication(app.teamId, app.id, name: name, description: description, public: public),
    ),
  );

  @override
  Future<void> deleteApplication(DevApp app) => _explained((api) => api.deleteApplication(app.teamId, app.id));

  @override
  Future<String> createBot(DevApp app) => _explained((api) => api.createBot(app.teamId, app.id));

  @override
  Future<String> resetBotToken(DevApp app) => _explained((api) => api.resetBotToken(app.teamId, app.id));

  @override
  Future<void> deleteBot(DevApp app) => _explained((api) => api.deleteBot(app.teamId, app.id));

  @override
  Future<Member> botProfile(String botUserId) async {
    final b = await _call((api) => api.getBotUser(botUserId));
    return _person(b.id, b.username, b.alias, b.avatar, b.banner);
  }

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
  }) => _explained(
    (api) => api.updateBot(
      app.teamId,
      app.id,
      username: username,
      alias: alias,
      clearAlias: clearAlias,
      avatar: avatarPath == null ? null : File(avatarPath),
      banner: bannerPath == null ? null : File(bannerPath),
      removeAvatar: removeAvatar,
      removeBanner: removeBanner,
    ),
  );

  @override
  Future<SpaceStorage> spaceStorage(String spaceId) async {
    // The files and what they take are any member's to read; the buckets take
    // ManageSpaceBuckets, which the page may show without.
    final (used, buckets, files) = await (
      _call((api) => api.getSpaceStorageUsed(spaceId)),
      Perm.has(_permsIn(spaceId), Perm.manageBuckets)
          ? _call((api) => api.getSpaceBuckets(spaceId))
          : Future.value(const <duvet.StorageBucket>[]),
      _call((api) => api.getSpaceAttachments(spaceId)),
    ).wait;
    return SpaceStorage(
      used: used,
      buckets: [
        for (final b in buckets)
          Bucket(
            id: b.id,
            name: b.name,
            region: b.region,
            endpoint: b.endpoint,
            bucketName: b.bucketName,
            accessKey: b.accessKeyId,
            pathStyle: b.usePathStyle,
            active: b.isActive,
            used: b.usedBytes,
            max: b.maxBytes,
            uploadLimit: b.uploadLimitBytes,
          ),
      ],
      files: [
        for (final f in files)
          if (f.deletedAt == null && f.deleted != true)
            MyFile(
              id: f.id,
              name: f.filename,
              contentType: f.contentType,
              sizeBytes: f.sizeBytes,
              createdAt: f.createdAt.toLocal(),
              url: attachmentUrl(f.id),
              inMessage: f.messageId != null,
            ),
      ]..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes)),
    );
  }

  static duvet.BucketPayload _bucketPayload(BucketDraft d) => duvet.BucketPayload(
    name: d.name,
    endpoint: d.endpoint,
    region: d.region.isEmpty ? 'auto' : d.region,
    bucketName: d.bucketName,
    accessKeyId: d.accessKey,
    secretAccessKey: d.secret,
    usePathStyle: d.pathStyle,
    maxBytes: d.max,
    uploadLimitBytes: d.uploadLimit,
  );

  @override
  Future<void> createSpaceBucket(String spaceId, BucketDraft draft) =>
      _explained((api) => api.createSpaceBucket(spaceId, _bucketPayload(draft)));

  @override
  Future<void> updateSpaceBucket(String spaceId, String bucketId, BucketDraft draft) =>
      _explained((api) => api.updateSpaceBucket(spaceId, bucketId, _bucketPayload(draft)));

  @override
  Future<void> deleteSpaceBucket(String spaceId, String bucketId) => _explained((api) async {
    try {
      await api.deleteSpaceBucket(spaceId, bucketId);
    } on duvet.DuvetApiException catch (e) {
      // Its files would break: the API answers 409 {error, files} and keeps it.
      if (_filesIn(e) case final n? when e.statusCode == 409) {
        throw ActionFailed('This bucket still holds $n ${n == 1 ? 'file' : 'files'}. Delete them first.');
      }
      rethrow;
    }
  });

  static int? _filesIn(duvet.DuvetApiException e) {
    try {
      final body = jsonDecode(e.body ?? '') as Map<String, dynamic>;
      return body['error'] == 'bucket has files' && body['files'] is int ? body['files'] as int : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setSpaceBucketActive(String spaceId, String bucketId, bool active) => _explained(
    (api) => active ? api.activateSpaceBucket(spaceId, bucketId) : api.deactivateSpaceBucket(spaceId, bucketId),
  );

  @override
  Future<void> deleteSpaceFile(String spaceId, String fileId) =>
      _explained((api) => api.deleteSpaceAttachment(spaceId, fileId));

  @override
  Future<void> deleteAllSpaceFiles(String spaceId) => _explained((api) => api.deleteAllSpaceAttachments(spaceId));

  @override
  Future<List<BotCommand>> commands(String spaceId) async {
    final all = await _call((api) => api.getSpaceCommands(spaceId));
    final apps = {for (final a in all.applications) a.id: a.name};
    BotCommand entry(duvet.ApplicationCommand c, BotCommandOption? sub, {String? group}) => BotCommand(
      id: c.id,
      applicationId: c.applicationId,
      appName: apps[c.applicationId] ?? 'Bot',
      name: c.name,
      description: sub == null || sub.description.isEmpty ? c.description : sub.description,
      options: sub?.options ?? [for (final o in c.options) _optionOf(o)],
      subcommandGroup: group,
      subcommand: sub?.name,
    );
    return [
      for (final c in all.commands)
        if (c.type == 1)
          // A command with subcommands is used through one of them: each is
          // its own entry, as `/perms user get`.
          if (c.options.map(_optionOf).where((o) => o.isSubcommand).toList() case final subs when subs.isNotEmpty)
            for (final o in subs)
              if (o.type == OptionKind.subcommandGroup)
                for (final s in o.options) entry(c, s, group: o.name)
              else
                entry(c, o)
          else
            entry(c, null),
    ]..sort((a, b) => a.path.compareTo(b.path));
  }

  static BotCommandOption _optionOf(duvet.CommandOption o) => BotCommandOption(
    type: o.type,
    name: o.name,
    description: o.description,
    required: o.required,
    choices: [for (final ch in o.choices ?? const <duvet.CommandChoice>[]) (name: ch.name, value: ch.value)],
    minValue: o.minValue,
    maxValue: o.maxValue,
    minLength: o.minLength,
    maxLength: o.maxLength,
    roomTypes: [for (final t in o.roomTypes ?? const <duvet.RoomType>[]) t.value],
    options: [for (final s in o.options ?? const <duvet.CommandOption>[]) _optionOf(s)],
  );

  // What's empty goes as null, which the API's omitempty leaves out.
  static duvet.CommandOption _wireOption(BotCommandOption o) => duvet.CommandOption(
    type: o.type,
    name: o.name,
    description: o.description,
    required: o.required,
    choices: o.choices.isEmpty ? null : [for (final c in o.choices) duvet.CommandChoice(name: c.name, value: c.value)],
    options: o.options.isEmpty ? null : [for (final s in o.options) _wireOption(s)],
    minValue: o.minValue,
    maxValue: o.maxValue,
    minLength: o.minLength,
    maxLength: o.maxLength,
    roomTypes: o.roomTypes.isEmpty ? null : [for (final t in o.roomTypes) duvet.RoomType.fromInt(t)],
  );

  BotCommand _appCommand(DevApp app, duvet.ApplicationCommand c) => BotCommand(
    id: c.id,
    applicationId: app.id,
    appName: app.name,
    name: c.name,
    description: c.description,
    options: [for (final o in c.options) _optionOf(o)],
  );

  @override
  Future<List<BotCommand>> appCommands(DevApp app) async =>
      [for (final c in await _call((api) => api.listCommands(app.teamId, app.id))) _appCommand(app, c)]
        ..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<BotCommand> saveAppCommand(DevApp app, BotCommand command) async {
    final options = [for (final o in command.options) _wireOption(o)];
    return _appCommand(
      app,
      await _explained(
        (api) => command.id.isEmpty
            ? api.createCommand(
                app.teamId,
                app.id,
                duvet.NewCommand(name: command.name, description: command.description, options: options),
              )
            : api.updateCommand(
                app.teamId,
                app.id,
                command.id,
                name: command.name,
                description: command.description,
                options: options,
              ),
      ),
    );
  }

  @override
  Future<void> deleteAppCommand(DevApp app, String commandId) =>
      _explained((api) => api.deleteCommand(app.teamId, app.id, commandId));

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
    final reply = await _interaction(
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
    final reply = await _interaction(
      (api) => api.useCommand(
        target.roomId,
        command.applicationId,
        duvet.CommandUse(
          id: command.id,
          name: command.name,
          subcommandGroup: command.subcommandGroup,
          subcommand: command.subcommand,
          options: [
            for (final e in options.entries) duvet.UsedOption(name: e.key, type: types[e.key] ?? 3, value: e.value),
          ],
        ),
      ),
    );
    return _modalOf(reply, target.roomId, null);
  }

  @override
  Future<void> submitModal(BotModal modal, List<Map<String, dynamic>> components) => _interaction(
    (api) => api.submitModal(modal.roomId, modal.applicationId, modal.customId, components, messageId: modal.messageId),
  );

  /// A command, a component or a modal sent to a bot, failing with the
  /// desktop's texts: a 504 is the API giving up waiting on the bot.
  Future<T> _interaction<T>(Future<T> Function(duvet.RestClient api) request) async {
    try {
      return await _call(request);
    } catch (e) {
      throw ActionFailed(
        e is duvet.DuvetApiException && e.statusCode == 504
            ? 'The application did not respond'
            : 'This interaction failed',
      );
    }
  }

  @override
  Future<BotInfo> bot(String userId) async {
    final b = await _call((api) => api.getBotUser(userId));
    // The route answers any user: a link to someone else's isn't a bot's
    // invite, which the desktop refuses with this.
    if (!b.isBot) throw const ActionFailed('This user is not a bot.');
    return BotInfo(id: b.id, name: b.alias?.isNotEmpty == true ? b.alias! : b.username, avatarUrl: avatarUrl(b.avatar));
  }

  @override
  Future<Member> user(String userId) async {
    final u = await _call((api) => api.getBotUser(userId));
    return Member(
      userId: u.id,
      username: u.username,
      alias: u.alias,
      avatarUrl: avatarUrl(u.avatar),
      isBot: u.isBot,
      bannerUrl: avatarUrl(u.banner),
    );
  }

  @override
  Future<void> addBot(String spaceId, String botId) => _explained((api) => api.addBotToSpace(spaceId, botId));

  @override
  Future<void> removeBot(String spaceId, String botId) => _explained((api) => api.removeBotFromSpace(spaceId, botId));

  @override
  List<({String id, String name})> spaceRoles(String spaceId) => [
    for (final r in (_roles[spaceId]?.values.toList() ?? [])..sort((a, b) => b.position.compareTo(a.position)))
      if (r.id != spaceId) (id: r.id, name: r.name),
  ];

  @override
  Future<InvitePreview> invite(String code) async {
    final info = await _explained((api) => api.getInvite(code));
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
  Future<String> joinInvite(String code) async => (await _explained((api) => api.joinInvite(code))).spaceId;

  @override
  Future<List<Member>> members(ChatTarget target, {bool refresh = false}) async {
    switch (target) {
      case ConversationTarget(:final conversationId):
        if (refresh || !_conversationMembers.containsKey(conversationId)) await refreshConversations();
        return _conversationMembers[conversationId] ?? const [];
      case RoomTarget(:final spaceId):
        return _spaceMemberList(spaceId, refresh: refresh);
    }
  }

  Future<List<Member>> _spaceMemberList(String spaceId, {bool refresh = false}) async {
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

  // Every page, up to a few thousand members: the list and mentions need names.
  Future<List<Member>> _fetchSpaceMembers(String spaceId) async {
    // Who joins or leaves while the pages come, which they may not show.
    final moves = <_MemberMove>[];
    (_memberLogs[spaceId] ??= []).add(moves);
    final all = <duvet.SpaceMemberWithUser>[];
    final bool kept;
    try {
      while (all.length < 5000) {
        final page = await _call(
          (api) => api.getSpaceMembers(spaceId, afterId: all.lastOrNull?.id, afterPos: all.lastOrNull?.maxPos),
        );
        all.addAll(page);
        if (page.length < duvet.membersPageSize) break;
      }
    } finally {
      kept = _endMemberLog(spaceId, moves);
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
    _nicknames[spaceId] = {
      for (final m in all)
        if (m.alias case final alias? when alias.isNotEmpty) m.user.id: alias,
    };
    (_spaceMemberIds[spaceId] ??= {}).addAll(members.map((m) => m.userId));
    // Made again: a member who left and came back has another ID. Who joined
    // or left meanwhile goes on top.
    if (kept) {
      final users = _memberUsers[spaceId] = {for (final m in all) m.id: m.userId};
      for (final move in moves) {
        _move(users, move);
      }
    }
    _applyWaitingRoles(spaceId);
    _loadedMembers[spaceId] = members;
    _fillFriendBanners();
    _publishSpaces();
    return members;
  }

  static Presence _presence(duvet.UserStatus status) => switch (status) {
    duvet.UserStatus.online => Presence.online,
    duvet.UserStatus.dnd => Presence.doNotDisturb,
    _ => Presence.offline,
  };

  @override
  Future<List<CustomEmoji>> customEmojis() async {
    final pending = _emojis ??= _call((api) => api.listMyEmojis()).then(
      (list) => [
        for (final e in list)
          if (e.deletedAt == null)
            CustomEmoji(id: e.id, name: e.name, url: attachmentUrl(e.attachmentId), spaceId: e.spaceId),
      ],
    );
    try {
      final list = await pending;
      for (final e in list) {
        _emojiNames[e.id] = e.name;
      }
      return list;
    } catch (_) {
      if (identical(_emojis, pending)) _emojis = null;
      rethrow;
    }
  }

  @override
  Future<List<Sticker>> stickers() async {
    final pending = _stickers ??= _call((api) => api.listMyStickers()).then(
      (list) => [
        for (final s in list)
          if (s.deletedAt == null)
            Sticker(
              id: s.id,
              name: s.name,
              attachmentId: s.attachmentId,
              url: attachmentUrl(s.attachmentId),
              spaceId: s.spaceId,
            ),
      ],
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_stickers, pending)) _stickers = null;
      rethrow;
    }
  }

  @override
  String emojiUrl(String emojiId) =>
      _router.urlFromPath('/emojis/${Uri.encodeComponent(emojiId)}', root: true).toString();

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
      if (_refusal(e) case final reason?) throw ActionFailed(reason);
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

  // The history names an author by their Space nickname (member_alias),
  // which the gateway's events don't carry: a live message takes the one
  // known, so an author reads the same in both. Events without a user (a link
  // preview's update) name the author as seen before.
  ChatMessage _roomMessage(duvet.GatewayMessage m) {
    final authorId = m.authorId;
    final spaceId = _spaceOfRoom(m.roomId);
    final alias = m.memberAlias?.isNotEmpty == true ? m.memberAlias : null;
    if (authorId != null && spaceId != null && alias != null) (_nicknames[spaceId] ??= {})[authorId] = alias;
    final nickname = authorId == null ? null : _nicknames[spaceId]?[authorId];
    final name = alias ?? nickname ?? m.user?.alias ?? m.user?.username;
    if (authorId != null && name != null) _names[authorId] = name;
    final known = authorId == null ? null : _names[authorId];
    return _roomMessageNamed(m, name ?? known ?? (m.webhookId != null ? 'Webhook' : 'Unknown'));
  }

  // Each Space's members' nicknames, by user: from the history's
  // member_alias, then the member list, which has them all.
  final _nicknames = <String, Map<String, String>>{};

  String? _spaceOfRoom(String roomId) =>
      _spaces.entries.where((e) => e.value.rooms.containsKey(roomId)).firstOrNull?.key;

  @override
  NotificationLevel spaceLevel(String spaceId) => notificationLevels.value[spaceId] ?? spaceDefault(spaceId);

  @override
  NotificationLevel spaceDefault(String spaceId) =>
      _level(_spaces[spaceId]?.space.defaultNotifications ?? duvet.NotificationLevel.mentions);

  @override
  NotificationLevel roomLevel(String roomId) =>
      notificationLevels.value[roomId] ??
      switch (_spaceOfRoom(roomId)) {
        final spaceId? => spaceLevel(spaceId),
        null => NotificationLevel.mentions,
      };

  @override
  NotificationLevel conversationLevel(String conversationId) =>
      notificationLevels.value[conversationId] ?? NotificationLevel.all;

  @override
  bool quiet(String chatId) =>
      (_spaceOfRoom(chatId) == null ? conversationLevel(chatId) : roomLevel(chatId)) == NotificationLevel.nothing;

  @override
  Future<void> setPushRegistration(String fid) => _call((api) => api.setPushRegistration(fid));

  @override
  Future<void> deletePushRegistration() => _call((api) => api.deletePushRegistration());

  @override
  Future<void> setNotificationLevel(String targetId, NotificationTarget target, NotificationLevel? level) =>
      switch (level) {
        final level? => _explained(
          (api) => api.setNotificationLevel(
            targetId,
            switch (target) {
              NotificationTarget.space => duvet.NotificationTarget.space,
              NotificationTarget.room => duvet.NotificationTarget.room,
              NotificationTarget.conversation => duvet.NotificationTarget.conversation,
            },
            switch (level) {
              NotificationLevel.all => duvet.NotificationLevel.all,
              NotificationLevel.mentions => duvet.NotificationLevel.mentions,
              NotificationLevel.nothing => duvet.NotificationLevel.nothing,
            },
          ),
        ),
        null => _explained((api) => api.clearNotificationLevel(targetId)),
      };

  // READY's load of the levels the user chose. One that answers after a newer load, or once the session ended, is
  // dropped; the changes that came while it was on its way go back on top of its answer, which may have been read
  // before them. One that fails keeps those it had, as the desktop does: they rarely change.
  int _levelsLoads = 0;
  Map<String, NotificationLevel?>? _levelsChangedMeanwhile;

  Future<void> _loadNotificationLevels() async {
    final api = _api;
    final load = ++_levelsLoads;
    final meanwhile = _levelsChangedMeanwhile = {};
    try {
      final settings = await _call((api) => api.getNotificationSettings());
      if (!identical(api, _api) || load != _levelsLoads) return;
      final levels = {for (final s in settings) s.targetId: _level(s.level)};
      for (final MapEntry(key: targetId, value: level) in meanwhile.entries) {
        if (level == null) {
          levels.remove(targetId);
        } else {
          levels[targetId] = level;
        }
      }
      notificationLevels.value = levels;
    } catch (e) {
      debugPrint('notification levels: $e');
    } finally {
      if (identical(_levelsChangedMeanwhile, meanwhile)) _levelsChangedMeanwhile = null;
    }
  }

  // A server's level; one a later server adds notifies of every message, as a level it can't name.
  static NotificationLevel _level(duvet.NotificationLevel level) => switch (level) {
    duvet.NotificationLevel.mentions => NotificationLevel.mentions,
    duvet.NotificationLevel.nothing => NotificationLevel.nothing,
    _ => NotificationLevel.all,
  };

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
    components: componentsFromJson(_wholeMedia(m.components)),
    rawComponents: _wholeMedia(m.components),
    fromBot: m.user?.isBot ?? false,
    fromWebhook: m.webhookId != null,
    webhookId: m.webhookId,
    isEphemeral: m.flags & duvet.MessageFlag.ephemeral != 0,
    isLoading: m.flags & duvet.MessageFlag.loading != 0,
    isComponentsV2: m.flags & duvet.MessageFlag.isComponentsV2 != 0,
    interaction: switch (m.interactionMetadata) {
      final i? => MessageInteraction(
        userName: i.user.alias ?? i.user.username,
        userAvatarUrl: avatarUrl(i.user.avatar),
        command: i.name,
        interactedMessageId: i.interactedMessageId,
      ),
      null => null,
    },
    attachments: _attachments(m.attachments),
    deletedAttachments: _attachments(m.attachments, deleted: true),
    stickerUrl: m.stickerAttachmentId == null ? null : attachmentUrl(m.stickerAttachmentId!),
    embeds: _embeds(m.embeds),
    reply: _reply(m.referencedMessage, m.refMessageId),
    reactions: _reactions(m.reactions),
  );

  ChatMessage _directMessage(duvet.DirectMessage m) {
    final name = m.user?.alias ?? m.user?.username;
    if (name != null) _names[m.authorId] = name;
    return _directMessageNamed(m, name ?? _names[m.authorId] ?? 'Unknown');
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
    isNotice: m.type == duvet.MessageType.pinNotice || m.call != null,
    call: switch (m.call) {
      final c? => CallNotice(
        participants: c.participants,
        startedAt: c.startedAt.toLocal(),
        endedAt: c.endedAt.toLocal(),
      ),
      null => null,
    },
    isVoice: m.type == duvet.MessageType.voice,
    pinned: m.pinnedAt != null,
    fromBot: m.user?.isBot ?? false,
    attachments: _attachments(m.attachments),
    deletedAttachments: _attachments(m.attachments, deleted: true),
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
      mentionAuthor: ref?.mentionAuthor ?? false,
    );
  }

  static List<Reaction> _reactions(List<duvet.MessageReaction>? list) => [
    for (final r in list ?? const <duvet.MessageReaction>[])
      if (r.users.isNotEmpty) Reaction(emoji: r.emojiName, emojiId: r.emojiId, users: {...r.users}),
  ];

  // Those still there, or with [deleted] those deleted since.
  List<MessageAttachment> _attachments(List<duvet.Attachment>? list, {bool deleted = false}) => [
    for (final a in list ?? const <duvet.Attachment>[])
      if ((a.deletedAt != null || a.deleted == true) == deleted)
        MessageAttachment(
          id: a.id,
          filename: a.filename,
          contentType: a.contentType,
          url: _absolute(a.url, a.id),
          width: a.width,
          height: a.height,
          sizeBytes: a.sizeBytes,
        ),
  ];

  // An attachment's link as the API gives it, a path on its host most often,
  // made whole.
  String _absolute(String? url, String attachmentId) => switch (url) {
    final url? when url.startsWith('http') => url,
    final url? when url.startsWith('/') => '$_origin$url',
    _ => attachmentUrl(attachmentId),
  };

  // A component's file that the message carries (a gallery's picture, a
  // file) comes as a signed path on the API's host, as the desktop's
  // `mediaSrc` takes it: made whole, so the components and the offline cache
  // have a link that loads.
  List<Map<String, dynamic>> _wholeMedia(List<Map<String, dynamic>>? list) {
    Object? whole(Object? j) => switch (j) {
      Map<String, dynamic>() => {
        for (final MapEntry(:key, :value) in j.entries)
          key: switch (value) {
            {'url': final String url} when (key == 'media' || key == 'file') && url.startsWith('/') => {
              ...value as Map<String, dynamic>,
              'url': _absolute(url, ''),
            },
            _ => whole(value),
          },
      },
      List() => [for (final e in j) whole(e)],
      _ => j,
    };
    return [for (final c in list ?? const <Map<String, dynamic>>[]) whole(c)! as Map<String, dynamic>];
  }

  static List<MessageEmbed> _embeds(List<duvet.Embed>? list) => [
    for (final e in list ?? const <duvet.Embed>[])
      MessageEmbed(
        title: e.title,
        description: e.description,
        url: e.url,
        imageUrl: e.image?.url,
        imageWidth: e.image?.width,
        imageHeight: e.image?.height,
        thumbnailUrl: e.thumbnail?.url,
        videoUrl: e.video?.url,
        videoContentType: e.video?.contentType,
        provider: e.provider,
        colors: [
          if (e.color case duvet.EmbedColor(colorFrom: final from?, :final colorVia, :final colorTo)) ...[
            from,
            if (colorTo != null) ...[?colorVia, colorTo],
          ],
        ],
        authorName: e.author?.name,
        authorUrl: e.author?.url,
        authorIconUrl: e.author?.iconUrl,
        fields: [
          for (final f in e.fields ?? const <duvet.EmbedField>[]) (name: f.name, value: f.value, inline: f.inline),
        ],
        footer: e.footer?.text,
        timestamp: DateTime.tryParse(e.timestamp ?? '')?.toLocal(),
      ),
  ]..removeWhere((e) => e.isEmpty);

  /// An attachment's URL, served outside `/api`.
  String attachmentUrl(String id) => '$_origin/attachments/$id';

  // The API's scheme and host, as the client reaches it.
  String get _origin => '${_router.secure ? 'https' : 'http'}://${_router.api}';

  /// An avatar's or icon's URL ([avatarUrlOn]).
  @override
  String? avatarUrl(String? avatar) => avatarUrlOn(_router, avatar);

  @override
  void dispose() {
    _renewalRetry?.cancel();
    _closeSession();
    _voiceSignaling.dispose();
    _signedOut.close();
    _resumed.close();
    _bansChanged.close();
    mentions.dispose();
    for (final timer in _noticeTimers.values) {
      timer.cancel();
    }
    mentionNotices.dispose();
    _messageEvents.close();
    _typing.close();
    for (final t in _typingEnds.values) {
      t.cancel();
    }
    typingNow.dispose();
    _recents.dispose();
    presence.dispose();
    mobileOnly.dispose();
    activities.dispose();
    collapsedCategories.dispose();
    pinnedChats.dispose();
  }
}

/// [onProgress] as duvet_client's uploads report it: the bytes sent so far, and
/// their total.
void Function(int sent, int total)? _bytesSent(void Function(double progress)? onProgress) =>
    onProgress == null ? null : (sent, total) => onProgress(total == 0 ? 0 : sent / total);
