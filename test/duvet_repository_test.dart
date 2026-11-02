import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:duvet/data/cache.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/eventually.dart';

const _me = '00000000-0000-4000-8000-000000000001';
const _maya = '00000000-0000-4000-8000-000000000002';
const _leo = '00000000-0000-4000-8000-000000000003';
const _avatar = '00000000-0000-4000-8000-0000000000aa';
const _banner = '00000000-0000-4000-8000-0000000000bb';
const _at = '2026-10-23T09:00:00Z';

Map<String, dynamic> _user(String id, String username, {String? alias, String? avatar}) => {
  'id': id,
  'username': username,
  'alias': alias,
  'avatar': avatar,
  'custom': '',
  'status_id': 1,
  'created_at': _at,
  'updated_at': _at,
};

Map<String, dynamic> _dm(String id, String author, String content, {String? nonce}) => {
  'id': id,
  'conversation_id': 'c-1',
  'author_id': author,
  'content': content,
  'type': 0,
  'nonce': nonce,
  'created_at': _at,
  'updated_at': _at,
  'user': {'id': author, 'username': author == _me ? 'gaby' : 'maya'},
};

/// A friend request to the user, as the API lists it.
Map<String, dynamic> _asks(String id, String sender, String username) => {
  'id': id,
  'sender_id': sender,
  'recipient_id': _me,
  'created_at': _at,
  'updated_at': _at,
  'user_username': username,
};

/// The gateway's envelope for [type], parsed as the client parses it.
duvet.GatewayEventPayload _event(String type, Map<String, dynamic> data) => duvet.GatewayEnvelope.fromJson({
  'op': 0,
  's': 1,
  'event': type,
  'd': {'type': type, 'data': data},
}).d!;

void main() {
  late List<http.Request> requests;
  late MockClient client;
  late MemorySessionStore store;
  late MemoryRecentChatsStore recentsStore;
  late DuvetRepository repository;
  late MemoryChatCacheStore cache;

  // What the API in use has: bios and statuses came after the deployed one.
  late bool apiHasBios;
  late bool apiHasStatus;
  late String bio;

  /// What `DELETE /api/spaces/s-1` answers.
  late http.Response deleteReply;

  /// The newest message of `r-general`.
  late Map<String, dynamic> roomNewest;

  /// How many times the session was renewed: each gives `access-N` and
  /// `refresh-N`, from 2.
  late int refreshes;

  /// The renewals made, by the session token each replaced: within its grace,
  /// the API answers that token with the same new tokens again.
  late Map<String?, int> renewed;

  /// How many of the next renewals' answers get lost on the way, though the
  /// API renews the session.
  late int renewalAnswersLost;

  /// The API fails the renewals (500).
  late bool renewalsBroken;

  /// The session ended on the server: it refuses its tokens, a renewal too.
  late bool sessionDead;

  /// An access token the API no longer takes, though the session lives.
  String? expiredToken;

  /// The friend requests to the user, as `GET …/friends/requests` answers.
  late List<Map<String, dynamic>> asking;

  /// Members of `s-1` besides Maya.
  late List<Map<String, dynamic>> moreSpaceMembers;
  // Maya's status_id in c-1, as the API gives a conversation's members theirs.
  int? mayaInConversation;
  // An API since api#63 gives the friends list their banners.
  late bool friendBanners;

  /// While set, holds that answer, as it was when asked.
  Completer<void>? holdAsking;

  /// The team invites to the user, as `GET …/team-invites` answers.
  late List<Map<String, dynamic>> teamInviting;

  /// While set, holds that answer, as it was when asked.
  Completer<void>? holdInvites;

  /// What a new avatar or banner gets, when not the user.
  http.Response? pictureRefusal;

  /// `GET /api/users/@me` gets no answer: the network failed on the way.
  late bool meUnreachable;

  /// Nothing comes back from the server, not even an error: each request
  /// times out.
  late bool blackHoled;

  /// Holds a room's move until the test answers it.
  late Completer<http.Response> moveReply;

  setUp(() {
    requests = [];
    store = MemorySessionStore();
    recentsStore = MemoryRecentChatsStore();
    cache = MemoryChatCacheStore();
    apiHasBios = true;
    apiHasStatus = true;
    bio = '';
    deleteReply = http.Response('', 204);
    roomNewest = _roomMessage('last', 'newest');
    refreshes = 0;
    renewed = {};
    renewalAnswersLost = 0;
    renewalsBroken = false;
    sessionDead = false;
    expiredToken = null;
    asking = [];
    teamInviting = [];
    moreSpaceMembers = [];
    mayaInConversation = null;
    friendBanners = false;
    holdAsking = null;
    pictureRefusal = null;
    meUnreachable = false;
    blackHoled = false;
    moveReply = Completer();
    client = MockClient((request) async {
      requests.add(request);
      if (blackHoled) await Completer<void>().future;
      if (request.method == 'PATCH' && request.url.path.startsWith('/api/spaces/s-m/rooms/')) return moveReply.future;
      Map<String, dynamic> body() => jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path == '/api/auth/refresh') {
        if (sessionDead) return http.Response('{"error":"invalid or expired session"}', 401);
        if (renewalsBroken) return http.Response('{"error":"internal server error"}', 500);
        final n = renewed[request.headers['X-Session-Token']] ??= ++refreshes + 1;
        if (renewalAnswersLost > 0) {
          renewalAnswersLost--;
          throw const SocketException('connection reset');
        }
        return http.Response(jsonEncode({'token': 'access-$n', 'session_token': 'refresh-$n'}), 200);
      }
      if (meUnreachable && request.url.path == '/api/users/@me') throw const SocketException('connection reset');
      final refused = sessionDead || request.headers['Authorization'] == 'Bearer $expiredToken';
      if (refused && !request.url.path.startsWith('/api/auth/')) return http.Response('', 401);
      if (request.url.path == '/api/users/@me/friends/requests') {
        final answer = jsonEncode(asking);
        if (holdAsking case final hold?) await hold.future;
        return http.Response(answer, 200, headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/api/users/@me/team-invites') {
        final answer = jsonEncode(teamInviting);
        if (holdInvites case final hold?) await hold.future;
        return http.Response(answer, 200, headers: {'content-type': 'application/json'});
      }
      final json = switch ((request.method, request.url.path)) {
        ('POST', '/api/auth/login') => {'token': 'access-1', 'session_token': 'refresh-1'},
        ('GET', '/api/users/@me') => {..._user(_me, 'gaby', alias: 'Gaby'), 'email_verified': true},
        ('PATCH', '/api/users/@me') when (request.headers['content-type'] ?? '').startsWith('multipart/') =>
          pictureRefusal ?? _user(_me, 'gaby', avatar: _avatar),
        // The API counts the display name's characters, as code points, once
        // trimmed (api#55: it counted bytes before).
        ('PATCH', '/api/users/@me') when (body()['alias'] as String? ?? '').trim().runes.length > 32 => http.Response(
          jsonEncode({'error': 'display name must be at most 32 characters'}),
          400,
        ),
        // An API from before bios ignores `custom`, and answers the bio it had.
        ('PATCH', '/api/users/@me') => {
          ..._user(_me, 'gaby', alias: body()['alias'] as String?),
          'custom': bio = apiHasBios ? (body()['custom'] as String? ?? bio).trim() : bio,
        },
        ('PUT', '/api/users/@me/status') when apiHasStatus => {..._user(_me, 'gaby'), 'status': body()['status']},
        ('DELETE', '/api/spaces/s-1') => deleteReply,
        // Between friends alone; and a server error.
        ('POST', '/api/users/@me/conversations') => http.Response(
          jsonEncode({'error': 'you must be friends with $_leo'}),
          403,
        ),
        ('POST', '/api/users/@me/conversations/c-1/members') => http.Response(
          jsonEncode({'error': 'internal server error'}),
          500,
        ),
        ('GET', '/api/users/@me/conversations') => [
          {
            'id': 'c-1',
            'type': 1,
            'owner_id': _me,
            'created_at': _at,
            'updated_at': _at,
            'members': [
              for (final (id, name, avatar) in [(_me, 'gaby', null), (_maya, 'maya', _avatar)])
                {
                  'id': 'm-$id',
                  'conversation_id': 'c-1',
                  'user_id': id,
                  'created_at': _at,
                  'updated_at': _at,
                  if (id == _maya) 'status_id': ?mayaInConversation,
                  'user': {
                    'id': id,
                    'username': name,
                    'alias': name == 'maya' ? 'Maya' : null,
                    'avatar': avatar,
                    'custom': name == 'maya' ? 'Night runner' : '',
                    'banner': name == 'maya' ? _banner : null,
                  },
                },
            ],
          },
        ],
        // The API answers the newest first.
        ('GET', '/api/users/@me/conversations/c-1/messages') => [_dm('2', _me, 'second'), _dm('1', _maya, 'first')],
        ('POST', '/api/users/@me/conversations/c-1/messages') => _dm(
          '3',
          _me,
          (jsonDecode(request.body) as Map)['content'] as String,
          nonce: (jsonDecode(request.body) as Map)['nonce'] as String?,
        ),
        ('GET', '/api/users/@me/mentions/counts') => {'r-general': 2, 'c-1': 0},
        ('GET', '/api/users/@me/friends') => [
          for (final (id, name, status) in [(_maya, 'maya', 2), (_leo, 'leo', 0)])
            {
              'id': 'f-$id',
              'request_id': 'q-$id',
              'sender_id': _me,
              'recipient_id': id,
              'user_username': name,
              'status_id': status,
              if (friendBanners && name == 'leo') 'user_banner': _banner,
            },
        ],
        ('GET', '/api/users/@me/friends/requests/sent') => <Object>[],
        ('POST', '/api/users/@me/team-invites/ti-1/accept') => http.Response('', 204),
        ('POST', '/api/users/@me/teams/t-1/applications/a-1/bot') => {'token': 'bot-token'},
        ('GET', '/api/rooms/r-general/messages') => [roomNewest],
        ('GET', '/api/spaces/s-1/members') => [
          {
            'id': 'm-maya',
            'space_id': 's-1',
            'user_id': _maya,
            'created_at': _at,
            'updated_at': _at,
            'user': _user(_maya, 'maya', alias: 'Maya'),
          },
          ...moreSpaceMembers,
        ],
        ('POST', '/api/spaces') => {
          'space': {'id': 's-new', 'name': 'Testing lair', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
          for (final (key, id, type, name) in [
            ('text_room', 'r-new', 1, 'general'),
            ('voice_room', 'v-new', 2, 'General'),
          ])
            key: {
              'id': id,
              'space_id': 's-new',
              'type': type,
              'name': name,
              'position': 0,
              'created_at': _at,
              'updated_at': _at,
            },
        },
        _ => null,
      };
      if (json is http.Response) return json;
      if (json == null) return http.Response('not found', 404);
      return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json'});
    });
    repository = DuvetRepository(
      store: store,
      recentsStore: recentsStore,
      httpClient: () => client,
      connectGateway: false,
      cacheStore: cache,
    );
  });

  tearDown(() => repository.dispose());

  test('logging in loads the profile and conversations, and keeps the tokens', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');

    expect(repository.profile.value?.displayName, 'Gaby');
    final saved = await store.read();
    expect((saved?.token, saved?.sessionToken), ('access-1', 'refresh-1'));
    // Issued just now, by the login: a renewal is 23 hours away.
    expect(DateTime.now().difference(saved!.refreshedAt!), lessThan(const Duration(minutes: 1)));
    expect(requests.last.headers['Authorization'], 'Bearer access-1');

    await pumpEventQueue();
    final chat = repository.conversations.value.single;
    expect(chat.title, 'Maya');
    expect(chat.isGroup, isFalse);
    expect(chat.avatarUrl, 'https://api.duvet.chat/attachments/$_avatar');
    expect(chat.otherUserId, _maya);
  });

  test('a conversation\'s members come with their bio and banner, for their profiles', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final members = await repository.members(const ConversationTarget('c-1'));
    final maya = members.firstWhere((m) => m.userId == _maya);
    expect(maya.bio, 'Night runner');
    expect(maya.bannerUrl, 'https://api.duvet.chat/attachments/$_banner');
    final gaby = members.firstWhere((m) => m.userId == _me);
    expect((gaby.bio, gaby.bannerUrl), (null, null));
  });

  test('friends take the banner a Space\'s or a conversation\'s members have for them (#15)', () async {
    const banner = 'https://api.duvet.chat/attachments/$_banner';
    Map<String, String?> banners() => {for (final f in repository.friends.value.friends) f.username: f.bannerUrl};
    await repository.logIn('gaby@duvet.chat', 'secret');
    await repository.loadFriends();
    // Maya's, from the DM loaded first; their list has neither.
    expect(banners(), {'leo': null, 'maya': banner});

    // Leo's comes with a Space's members, loaded after: the list shown takes
    // it, and says so.
    moreSpaceMembers = [
      {
        'id': 'm-leo',
        'space_id': 's-1',
        'user_id': _leo,
        'created_at': _at,
        'updated_at': _at,
        'user': {..._user(_leo, 'leo'), 'banner': _banner},
      },
    ];
    var told = 0;
    void tell() => told++;
    repository.friends.addListener(tell);
    addTearDown(() => repository.friends.removeListener(tell));
    await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
    expect(banners(), {'leo': banner, 'maya': banner});
    expect(told, 1);

    // Members loaded again with nothing new: nothing to say.
    await repository.refreshConversations();
    expect(told, 1);
  });

  test('someone else\'s profile change shows wherever they do', () async {
    const avatar = '00000000-0000-4000-8000-0000000000cc';
    const general = RoomTarget(spaceId: 's-1', roomId: 'r-general');
    await repository.logIn('gaby@duvet.chat', 'secret');
    repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
    await pumpEventQueue();
    await repository.members(general);
    expect(repository.conversations.value.single.title, 'Maya');

    repository.handleEvent(
      _event('USER_UPDATE', {
        'id': _maya,
        'username': 'maya',
        'alias': 'Maya O.',
        'avatar': avatar,
        'banner': _banner,
        'custom': 'Night owl',
      }),
    );
    final dm = repository.conversations.value.single;
    expect((dm.title, dm.avatarUrl), ('Maya O.', 'https://api.duvet.chat/attachments/$avatar'));
    expect(repository.nameOf(_maya), 'Maya O.');
    final inDm = (await repository.members(const ConversationTarget('c-1'))).firstWhere((m) => m.userId == _maya);
    expect(
      (inDm.displayName, inDm.bio, inDm.bannerUrl),
      ('Maya O.', 'Night owl', 'https://api.duvet.chat/attachments/$_banner'),
    );
    final inSpace = (await repository.members(general)).single;
    expect(
      (inSpace.displayName, inSpace.avatarUrl, inSpace.bio),
      ('Maya O.', 'https://api.duvet.chat/attachments/$avatar', 'Night owl'),
    );
    expect([for (final f in repository.friends.value.friends) f.displayName], ['leo', 'Maya O.']);

    // An API from before bios leaves the bio out: the one known stays.
    repository.handleEvent(_event('USER_UPDATE', {'id': _maya, 'username': 'maya', 'alias': 'Maya'}));
    final again = (await repository.members(const ConversationTarget('c-1'))).firstWhere((m) => m.userId == _maya);
    expect((again.displayName, again.bio, again.avatarUrl), ('Maya', 'Night owl', null));
    expect(repository.conversations.value.single.title, 'Maya');
  });

  test('a group the API refuses to make or change says why, as the API says it', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    await expectLater(
      repository.createGroup('Crew', [_maya, _leo]),
      throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'You must be friends with $_leo')),
    );
    // A server error says the API's words too, as the desktop shows them.
    await expectLater(
      repository.addToConversation('c-1', _leo),
      throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'Internal server error')),
    );
  });

  test('the friends list gives friends their presence, where the gateway hasn\'t told it', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    repository.presence.value = {_leo: Presence.online};
    await repository.loadFriends();
    expect(repository.presence.value, {_leo: Presence.online, _maya: Presence.doNotDisturb});
  });

  test('a DM\'s or a group\'s members have their presence, where the gateway hasn\'t told it (#86)', () async {
    mayaInConversation = 1;
    await repository.logIn('gaby@duvet.chat', 'secret');
    await pumpEventQueue();
    expect(repository.presence.value[_maya], Presence.online);
    // One added later: as CONVERSATION_MEMBER_ADD has it.
    repository.handleEvent(
      _event('CONVERSATION_MEMBER_ADD', {
        'conversation_id': 'c-1',
        'user_id': _leo,
        'member_id': 'm-leo',
        'status_id': 2,
      }),
    );
    expect(repository.presence.value[_leo], Presence.doNotDisturb);
  });

  test('friends come with their banner from the friends list (#127)', () async {
    friendBanners = true;
    await repository.logIn('gaby@duvet.chat', 'secret');
    await repository.loadFriends();
    final leo = repository.friends.value.friends.firstWhere((m) => m.userId == _leo);
    expect(leo.bannerUrl, endsWith(_banner));
  });

  test('READY loads the friend requests, and FRIEND_* events keep them current', () async {
    List<String> askingIds() => [for (final r in repository.friends.value.incoming) r.id];
    asking = [_asks('q-1', _maya, 'maya')];
    await repository.logIn('gaby@duvet.chat', 'secret');
    expect(askingIds(), isEmpty);
    repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
    await pumpEventQueue();
    expect(askingIds(), ['q-1']);
    expect(repository.friends.value.incoming.single.person.displayName, 'maya');
    expect([for (final f in repository.friends.value.friends) f.username], ['leo', 'maya']);

    // A load under way when a request comes: its answer, from before the
    // request, comes after the next load's and doesn't hide it.
    final hold = holdAsking = Completer<void>();
    repository.handleEvent(_event('FRIEND_REQUEST_REJECT', {'id': 'q-0'}));
    await pumpEventQueue();
    holdAsking = null;
    asking = [...asking, _asks('q-2', _leo, 'leo')];
    repository.handleEvent(_event('FRIEND_REQUEST_CREATE', {'id': 'q-2', 'sender_id': _leo, 'username': 'leo'}));
    await pumpEventQueue();
    expect(askingIds(), ['q-1', 'q-2']);
    hold.complete();
    await pumpEventQueue();
    expect(askingIds(), ['q-1', 'q-2']);

    // Taken back by its sender.
    asking = [_asks('q-2', _leo, 'leo')];
    repository.handleEvent(_event('FRIEND_REQUEST_REJECT', {'id': 'q-1'}));
    await pumpEventQueue();
    expect(askingIds(), ['q-2']);
  });

  test('READY loads the team invites, TEAM_INVITE_CREATE again, and an accepted one goes', () async {
    Map<String, dynamic> invite(String id, String team) => {
      'id': id,
      'team_id': 't-$id',
      'user_id': _me,
      'invited_by': _maya,
      'created_at': _at,
      'team_name': team,
      'invited_by_username': 'maya',
    };
    List<String> ids() => [for (final i in repository.teamInvites.value) i.id];
    teamInviting = [invite('ti-1', 'Acme')];
    await repository.logIn('gaby@duvet.chat', 'secret');
    repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
    await pumpEventQueue();
    expect(ids(), ['ti-1']);
    expect(repository.teamInvites.value.single.teamName, 'Acme');
    expect(repository.teamInvites.value.single.invitedBy, 'maya');

    // The same invite twice stays one row: the list is fetched, not added to.
    teamInviting = [invite('ti-1', 'Acme'), invite('ti-2', 'Globex')];
    repository.handleEvent(_event('TEAM_INVITE_CREATE', invite('ti-2', 'Globex')));
    repository.handleEvent(_event('TEAM_INVITE_CREATE', invite('ti-2', 'Globex')));
    await pumpEventQueue();
    expect(ids(), ['ti-1', 'ti-2']);

    // A load under way when the user accepts: its answer, from before, still
    // lists the invite, and doesn't bring it back.
    final hold = holdInvites = Completer<void>();
    repository.handleEvent(_event('TEAM_INVITE_CREATE', invite('ti-2', 'Globex')));
    await pumpEventQueue();
    holdInvites = null;
    await repository.acceptTeamInvite('ti-1');
    expect(ids(), ['ti-2']);
    hold.complete();
    await pumpEventQueue();
    expect(ids(), ['ti-2']);

    // An older load that answers after a newer one is dropped.
    final older = holdInvites = Completer<void>();
    repository.handleEvent(_event('TEAM_INVITE_CREATE', invite('ti-2', 'Globex')));
    await pumpEventQueue();
    holdInvites = null;
    teamInviting = [invite('ti-2', 'Globex'), invite('ti-3', 'Initech')];
    repository.handleEvent(_event('TEAM_INVITE_CREATE', invite('ti-3', 'Initech')));
    await pumpEventQueue();
    expect(ids(), ['ti-2', 'ti-3']);
    older.complete();
    await pumpEventQueue();
    expect(ids(), ['ti-2', 'ti-3']);

    // A bot's token is the API's `token`.
    expect(await repository.createBot(const DevApp(id: 'a-1', teamId: 't-1', name: 'Helper')), 'bot-token');
  });

  test('a saved session resumes; a rejected one is forgotten', () async {
    await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: DateTime.now()));
    expect(await repository.restore(), isTrue);
    expect(repository.profile.value?.username, 'gaby');

    final rejecting = DuvetRepository(
      store: store,
      recentsStore: MemoryRecentChatsStore(),
      httpClient: () => MockClient((_) async => http.Response('', 401)),
      connectGateway: false,
    );
    addTearDown(rejecting.dispose);
    expect(await rejecting.restore(), isFalse);
    expect(await store.read(), isNull);
  });

  test('offline, a saved session opens from the cache, history too', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    await repository.messages(const ConversationTarget('c-1'));
    // The cache writes a moment after the changes.
    await eventually(() => expect(cache.data.keys, containsAll(['home', 'chat_c-1'])));

    final offline = DuvetRepository(
      store: store,
      recentsStore: MemoryRecentChatsStore(),
      httpClient: () => MockClient((_) async => throw const SocketException('no network')),
      connectGateway: false,
      cacheStore: cache,
    );
    addTearDown(offline.dispose);
    expect(await offline.restore(), isTrue);
    expect(offline.status.value, LiveStatus.offline);
    expect(offline.profile.value?.username, 'gaby');
    expect(offline.conversations.value.single.title, 'Maya');
    final page = await offline.messages(const ConversationTarget('c-1'));
    expect(page.map((m) => m.content), ['first', 'second']);
  });

  test('history comes oldest first, and sending passes the nonce', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    const target = ConversationTarget('c-1');

    final history = await repository.messages(target);
    expect(history.map((m) => m.content), ['first', 'second']);
    expect(history.first.authorName, 'maya');

    final sent = await repository.send(target, 'hello', nonce: 'n-1');
    expect(sent.content, 'hello');
    expect(sent.nonce, 'n-1');
  });

  test('gateway events build spaces, unread state and live messages', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');

    Map<String, dynamic> room(String id, String name, int type, int position, {String? parent}) => {
      'id': id,
      'space_id': 's-1',
      'parent_id': parent,
      'type': type,
      'name': name,
      'position': position,
      'created_at': _at,
      'updated_at': _at,
    };

    repository.handleEvent(
      _event('READY', {
        'user': _user(_me, 'gaby'),
        'sessionToken': 'ws',
        'unread_rooms': ['r-general'],
      }),
    );
    expect(repository.status.value, LiveStatus.online);
    expect(repository.unread.value, {'r-general'});

    repository.handleEvent(
      _event('SPACE_CREATE', {
        'space': {'id': 's-1', 'name': 'Design Guild', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
        'rooms': {
          'cat': room('cat', 'Talk', 3, 1),
          'r-voice': room('r-voice', 'lounge', 2, 2, parent: 'cat'),
          'r-general': room('r-general', 'general', 1, 0),
        },
        'roles_permissions': <String, dynamic>{},
        'owner_id': _me,
      }),
    );
    final space = repository.spaces.value.single;
    expect(space.name, 'Design Guild');
    expect(space.sections.map((s) => s.name), [null, 'Talk']);
    expect(space.sections.first.rooms.single.name, 'general');
    expect(space.sections.last.rooms.single.kind, RoomKind.voice);

    final events = <MessageEvent>[];
    final sub = repository.messageEvents(const ConversationTarget('c-1')).listen(events.add);
    addTearDown(sub.cancel);
    repository.handleEvent(_event('DM_MESSAGE_CREATE', _dm('9', _maya, 'live')));
    await pumpEventQueue();
    expect((events.single as MessageCreated).message.content, 'live');
    expect(repository.unread.value, contains('c-1'));

    repository.markRead(const ConversationTarget('c-1'), '9');
    expect(repository.unread.value, isNot(contains('c-1')));
  });

  test('who\'s typing, outside the open chat: 6 seconds after each says so, or until their message (#92)', () {
    fakeAsync((async) {
      // Made in the fake clock's zone, so its timers run on that clock.
      final repository = DuvetRepository(
        store: store,
        recentsStore: recentsStore,
        httpClient: () => client,
        connectGateway: false,
        cacheStore: cache,
      );
      Map<String, List<String>> typing() => {
        for (final MapEntry(:key, :value) in repository.typingNow.value.entries)
          key: [for (final u in value) '${u.name}${u.recording ? ' (recording)' : ''}'],
      };
      void typed(String type, String userId, String username) {
        repository.handleEvent(_event(type, {'conversation_id': 'c-1', 'user_id': userId, 'username': username}));
        async.flushMicrotasks();
      }

      typed('DM_TYPING', _maya, 'maya');
      typed('DM_RECORDING', 'u-leo', 'leo');
      expect(typing(), {
        'c-1': ['maya', 'leo (recording)'],
      });

      // Typing again starts the 6 seconds over.
      async.elapse(const Duration(seconds: 4));
      typed('DM_TYPING', _maya, 'maya');
      async.elapse(const Duration(seconds: 2));
      expect(typing(), {
        'c-1': ['maya'],
      });

      repository.handleEvent(_event('DM_MESSAGE_CREATE', _dm('9', _maya, 'done')));
      async.flushMicrotasks();
      expect(typing(), isEmpty);
      repository.dispose();
      async.flushMicrotasks();
    });
  });

  test('voice gets the gateway\'s voice and call events, and READY, and nothing else', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final voice = <duvet.GatewayEventPayload>[];
    final sub = repository.voiceSignaling.events.listen(voice.add);
    addTearDown(sub.cancel);

    repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
    repository.handleEvent(_event('DM_MESSAGE_CREATE', _dm('9', _maya, 'not for voice')));
    repository.handleEvent(
      _event('VOICE_STATE_UPDATE', {'room_id': 'r-voice', 'user_id': _maya, 'joined': true, 'version': 1}),
    );
    repository.handleEvent(
      _event('CALL_INCOMING', {'conversation_id': 'c-1', 'initiator_id': _maya, 'initiator_name': 'maya'}),
    );
    repository.handleEvent(_event('VOICE_SESSION_REPLACED', {'room_id': 'r-voice'}));
    // A call across the user's devices: theirs, and one that rings them no more.
    repository.handleEvent(_event('CALL_OUTGOING', {'conversation_id': 'c-2'}));
    repository.handleEvent(_event('CALL_ONGOING', {'conversation_id': 'c-1', 'initiator_id': _maya}));
    await pumpEventQueue();
    expect(voice.map((e) => e.runtimeType), [
      duvet.ReadyEvent,
      duvet.VoiceStateUpdatedEvent,
      duvet.CallIncomingPayloadEvent,
      duvet.VoiceSessionReplacedPayloadEvent,
      duvet.CallOutgoingPayloadEvent,
      duvet.CallOngoingPayloadEvent,
    ]);

    // No gateway (it's off in these tests): nothing can go out.
    expect(repository.voiceSignaling.connection, isNull);
    expect(repository.voiceSignaling.acceptCall('c-1'), isFalse);
  });

  test('a new Space shows at once, before the gateway tells of it', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final id = await repository.createSpace('Testing lair');
    expect(id, 's-new');
    final space = repository.spaces.value.singleWhere((s) => s.id == 's-new');
    expect(space.name, 'Testing lair');
    expect(space.rooms.map((r) => r.name), containsAll(['general', 'General']));
    expect(repository.spaceProfile('s-new')!.owner, isTrue);
  });

  test('deleting a Space on a server without the route says it needs the latest API', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    await repository.createSpace('Testing lair');
    // The mock answers unknown routes as gin does: a plain-text 404.
    await expectLater(
      repository.deleteSpace('s-new'),
      throwsA(isA<ActionFailed>().having((e) => e.message, 'message', contains('latest API'))),
    );
    expect(repository.spaces.value.map((s) => s.id), contains('s-new'));
  });

  test('logging out forgets the session', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    await repository.logOut();
    expect(repository.profile.value, isNull);
    expect(await store.read(), isNull);
    expect(requests.last.url.path, '/api/auth/logout');
  });

  test('the end of a session is told before it closes: voice can still leave over its gateway', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final profiles = <String?>[];
    repository.signedOut.listen((_) => profiles.add(repository.profile.value?.id));
    await repository.logOut();
    expect(profiles, [_me]);
  });

  test('a session refused at launch leaves no account\'s recent chats on the phone', () async {
    const someone = '00000000-0000-4000-8000-0000000000ff';
    await recentsStore.write(someone, '[]');
    await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: DateTime.now()));
    final rejecting = DuvetRepository(
      store: store,
      recentsStore: recentsStore,
      httpClient: () => MockClient((_) async => http.Response('', 401)),
      connectGateway: false,
    );
    addTearDown(rejecting.dispose);
    var ended = 0;
    rejecting.signedOut.listen((_) => ended++);
    expect(await rejecting.restore(), isFalse);
    await pumpEventQueue();
    expect(ended, 1);
    expect(await recentsStore.read(someone), isNull);
  });

  test('recent chats list opened rooms and DMs with news, and outlive a restart', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    await pumpEventQueue();
    const general = RoomTarget(spaceId: 's-1', roomId: 'r-1');

    // A room's message lists nothing until the room is opened.
    repository.handleEvent(_event('MESSAGE_CREATE', _roomMessage('5', 'unseen')));
    expect(repository.recents.value, isEmpty);

    repository.opened(general, '# general');
    repository.handleEvent(_event('MESSAGE_CREATE', _roomMessage('6', 'hello room')));
    // Newer than the room, which opening without history dates now.
    repository.handleEvent(
      _event('DM_MESSAGE_CREATE', {..._dm('9', _maya, 'hi there'), 'created_at': '2999-01-01T00:00:00Z'}),
    );
    expect(repository.recents.value.map((c) => c.target.id), ['c-1', 'r-1']);
    expect(repository.recents.value.first.title, 'Maya');
    expect(repository.recents.value.last.previewText, 'hello room');

    repository.handleEvent(_event('DM_MESSAGE_DELETE', {'id': '9', 'conversation_id': 'c-1'}));
    expect(repository.recents.value.first.previewText, 'Message deleted');
    await pumpEventQueue();

    final restarted = DuvetRepository(
      store: store,
      recentsStore: recentsStore,
      httpClient: () => client,
      connectGateway: false,
    );
    addTearDown(restarted.dispose);
    expect(await restarted.restore(), isTrue);
    await pumpEventQueue();
    expect(restarted.recents.value.map((c) => c.target), [const ConversationTarget('c-1'), general]);

    await restarted.logOut();
    await pumpEventQueue();
    expect(restarted.recents.value, isEmpty);
    expect(await recentsStore.read(_me), isNull);
  });

  group('session', () {
    // Another repository on the same API and stores; made in a fake clock's
    // zone, its timers run on that clock.
    DuvetRepository newRepository() => DuvetRepository(
      store: store,
      recentsStore: recentsStore,
      httpClient: () => client,
      connectGateway: false,
      cacheStore: cache,
    );

    StoredSession? saved(FakeAsync async) {
      StoredSession? session;
      store.read().then((s) => session = s);
      async.flushMicrotasks();
      return session;
    }

    test('it\'s renewed 23 hours after its tokens were issued, as checked every 10 minutes', () {
      fakeAsync((async) {
        final repository = newRepository();
        repository.logIn('gaby@duvet.chat', 'secret');
        async.flushMicrotasks();
        final issued = saved(async)!.refreshedAt!;
        expect(issued, clock.now());

        async.elapse(const Duration(hours: 22, minutes: 59));
        expect(refreshes, 0);
        async.elapse(const Duration(minutes: 1));
        expect(refreshes, 1);
        // With the session token, and the new tokens kept, dated now.
        final renewal = requests.lastWhere((r) => r.url.path == '/api/auth/refresh');
        expect(renewal.headers['X-Session-Token'], 'refresh-1');
        expect(saved(async), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: clock.now()));

        // The next one, 23 hours after this one.
        async.elapse(const Duration(hours: 22, minutes: 59));
        expect(refreshes, 1);
        async.elapse(const Duration(minutes: 1));
        expect(refreshes, 2);
        expect(saved(async)!.token, 'access-3');
        repository.dispose();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 10, 24, 9));
    });

    test('a saved session over an hour old, or of unknown age, is renewed before it starts', () async {
      final now = DateTime.now();
      final ages = [const Duration(hours: 23), const Duration(minutes: 61)];
      for (final refreshedAt in [for (final age in ages) now.subtract(age), null]) {
        requests.clear();
        refreshes = 0;
        renewed.clear();
        await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: refreshedAt));
        final restored = newRepository();
        addTearDown(restored.dispose);
        expect(await restored.restore(), isTrue);
        expect(requests.take(2).map((r) => r.url.path), ['/api/auth/refresh', '/api/users/@me']);
        expect(requests[1].headers['Authorization'], 'Bearer access-2');
        expect((await store.read())!.token, 'access-2');
        // Its conversations, which come after.
        await pumpEventQueue();
      }

      // One renewed less than an hour ago isn't.
      requests.clear();
      final recent = DateTime.now().subtract(const Duration(minutes: 59));
      await store.write((token: 'access-5', sessionToken: 'refresh-5', refreshedAt: recent));
      final fresh = newRepository();
      addTearDown(fresh.dispose);
      expect(await fresh.restore(), isTrue);
      expect(requests.first.url.path, '/api/users/@me');
      expect(requests.any((r) => r.url.path == '/api/auth/refresh'), isFalse);
    });

    test('opened offline after a renewal at launch, it goes on with the renewed tokens', () async {
      // A session that loaded once, which the cache opens offline.
      await repository.logIn('gaby@duvet.chat', 'secret');
      await eventually(() => expect(cache.data.keys, contains('home')));
      await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: null));
      meUnreachable = true;
      final offline = newRepository();
      addTearDown(offline.dispose);
      expect(await offline.restore(), isTrue);
      expect(offline.status.value, LiveStatus.offline);
      expect(refreshes, 1);

      // The old ones the API revoked as it renewed them.
      await offline.messages(const ConversationTarget('c-1'));
      expect(requests.last.headers['Authorization'], 'Bearer access-2');
      expect(requests.last.headers['X-Session-Token'], 'refresh-2');
    });

    test('opened offline, back in front it tries the server again at once', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      await eventually(() => expect(cache.data.keys, contains('home')));
      var reachable = false;
      final asked = <String>[];
      final offline = DuvetRepository(
        store: store,
        recentsStore: MemoryRecentChatsStore(),
        httpClient: () => MockClient((request) async {
          asked.add(request.url.path);
          if (!reachable) throw const SocketException('no network');
          return http.Response.fromStream(await client.send(request));
        }),
        connectGateway: false,
        cacheStore: cache,
      );
      addTearDown(offline.dispose);
      expect(await offline.restore(), isTrue);
      expect(offline.status.value, LiveStatus.offline);

      // Not at the next try, 20 seconds on.
      reachable = true;
      asked.clear();
      offline.cameToFront();
      await pumpEventQueue();
      expect(asked, contains('/api/users/@me'));
    });

    test('a renewal at launch that times out opens offline at once, rather than after me() times out too', () {
      fakeAsync((async) {
        // A session that loaded once, which the cache opens offline.
        final first = newRepository();
        first.logIn('gaby@duvet.chat', 'secret');
        async.elapse(const Duration(seconds: 1));
        first.dispose();
        store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: null));
        blackHoled = true;
        requests.clear();
        final restored = newRepository();
        bool? opened;
        restored.restore().then((r) => opened = r);
        async.elapse(duvet.defaultRequestTimeout);
        expect(opened, isTrue);
        expect(restored.status.value, LiveStatus.offline);
        expect([for (final r in requests) r.url.path], ['/api/auth/refresh']);
        restored.dispose();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 10, 24, 9));
    });

    test('a 401 whose renewal got no answer opens offline, signed in still, at launch as at each try after', () {
      fakeAsync((async) {
        // A session that loaded once, which the cache opens offline.
        final first = newRepository();
        first.logIn('gaby@duvet.chat', 'secret');
        async.elapse(const Duration(seconds: 1));
        first.dispose();
        store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: null));
        // The API renews the session, which revokes the old access token, but
        // its answer is lost; and the answer to the renewal `me()`'s 401 asks
        // for.
        renewalAnswersLost = 2;
        expiredToken = 'access-1';
        requests.clear();
        final restored = newRepository();
        var ended = 0;
        restored.signedOut.listen((_) => ended++);
        bool? opened;
        restored.restore().then((r) => opened = r);
        async.flushMicrotasks();
        List<String> paths() => [for (final r in requests) r.url.path];
        expect(paths(), ['/api/auth/refresh', '/api/users/@me', '/api/auth/refresh']);
        expect(opened, isTrue);
        expect(restored.status.value, LiveStatus.offline);
        expect(restored.profile.value?.username, 'gaby');

        // The same when it tries the server again, 20 seconds on, once its
        // renewal went once more.
        renewalAnswersLost = 3;
        async.elapse(const Duration(seconds: 20));
        expect(paths().skip(3), ['/api/auth/refresh', '/api/auth/refresh', '/api/users/@me', '/api/auth/refresh']);
        expect(restored.profile.value?.username, 'gaby');
        expect(ended, 0);
        expect(saved(async), (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: null));

        // Its renewal goes once more, and gets the tokens the API made, which
        // the next try starts with.
        async.elapse(DuvetRepository.renewalRetry);
        expect(saved(async)!.token, 'access-2');
        async.elapse(const Duration(seconds: 20));
        final me = requests.lastWhere((r) => r.url.path == '/api/users/@me');
        expect(me.headers['Authorization'], 'Bearer access-2');
        expect(ended, 0);
        restored.dispose();
        async.flushMicrotasks();

        // With no session token to renew with, a 401 is the session's end.
        store.write((token: 'access-1', sessionToken: '', refreshedAt: clock.now()));
        final unrenewable = newRepository();
        unrenewable.restore().then((r) => opened = r);
        async.flushMicrotasks();
        expect(opened, isFalse);
        expect(saved(async), isNull);
        unrenewable.dispose();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 10, 24, 9));
    });

    test('a saved session whose renewal the API refuses at launch is forgotten, not opened offline', () async {
      await store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: null));
      sessionDead = true;
      final dead = newRepository();
      addTearDown(dead.dispose);
      var ended = 0;
      dead.signedOut.listen((_) => ended++);
      expect(await dead.restore(), isFalse);
      expect(ended, 1);
      expect(dead.profile.value, isNull);
      expect(await store.read(), isNull);
      expect(requests.map((r) => r.url.path), ['/api/auth/refresh']);
    });

    test('back in front, it\'s renewed once its tokens are an hour old, its timer having run or not', () async {
      var now = DateTime(2026, 10, 24, 9);
      await withClock(Clock(() => now), () async {
        await repository.logIn('gaby@duvet.chat', 'secret');
        now = now.add(const Duration(minutes: 59));
        repository.cameToFront();
        await pumpEventQueue();
        expect(refreshes, 0);

        now = now.add(const Duration(minutes: 2));
        repository.cameToFront();
        await pumpEventQueue();
        expect(refreshes, 1);
        expect(await store.read(), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: now));

        // Asleep for a day: no timer ran meanwhile.
        now = now.add(const Duration(hours: 23));
        repository.cameToFront();
        await pumpEventQueue();
        expect(refreshes, 2);
      });
    });

    test('a renewal that got no answer goes once more, 3 seconds on, and gets the tokens the API made', () {
      fakeAsync((async) {
        final repository = newRepository();
        repository.logIn('gaby@duvet.chat', 'secret');
        async.flushMicrotasks();
        List<String?> renewals() => [
          for (final r in requests)
            if (r.url.path == '/api/auth/refresh') r.headers['X-Session-Token'],
        ];

        renewalAnswersLost = 1;
        async.elapse(const Duration(hours: 23));
        expect(renewals(), ['refresh-1']);
        expect(saved(async)!.token, 'access-1');
        async.elapse(const Duration(seconds: 2));
        expect(renewals(), hasLength(1));
        async.elapse(const Duration(seconds: 1));
        // The same session token, which the API answers with what it made.
        expect(renewals(), ['refresh-1', 'refresh-1']);
        expect(refreshes, 1);
        expect(saved(async), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: clock.now()));
        repository.dispose();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 10, 24, 9));
    });

    test('once only, and not when the API answered: those wait for the next check', () {
      fakeAsync((async) {
        final repository = newRepository();
        repository.logIn('gaby@duvet.chat', 'secret');
        async.flushMicrotasks();
        int renewals() => requests.where((r) => r.url.path == '/api/auth/refresh').length;

        // No answer twice: no third try until the next check.
        renewalAnswersLost = 2;
        async.elapse(const Duration(hours: 23, seconds: 5));
        expect(renewals(), 2);
        async.elapse(const Duration(minutes: 9, seconds: 50));
        expect(renewals(), 2);
        async.elapse(const Duration(seconds: 10));
        expect(renewals(), 3);
        expect(saved(async)!.token, 'access-2');

        // An error the API answered isn\'t a lost answer.
        renewalsBroken = true;
        async.elapse(const Duration(hours: 23));
        expect(renewals(), 4);
        async.elapse(const Duration(seconds: 30));
        expect(renewals(), 4);
        repository.dispose();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 10, 24, 9));
    });

    test('renewals that get no answer meanwhile share that once more, which signing out ends', () {
      fakeAsync((async) {
        final repository = newRepository();
        repository.logIn('gaby@duvet.chat', 'secret');
        async.flushMicrotasks();
        int renewals() => requests.where((r) => r.url.path == '/api/auth/refresh').length;
        List<FakeTimer> waiting() => [
          for (final t in async.pendingTimers)
            if (t.duration == DuvetRepository.renewalRetry) t,
        ];

        // The check's renewal, then the one back in front, before the first
        // goes again: once more for both.
        renewalAnswersLost = 3;
        async.elapse(const Duration(hours: 23));
        async.elapse(const Duration(seconds: 1));
        repository.cameToFront();
        async.flushMicrotasks();
        expect(renewals(), 2);
        expect(waiting(), hasLength(1));
        async.elapse(const Duration(seconds: 10));
        expect(renewals(), 3);

        renewalAnswersLost = 1;
        repository.cameToFront();
        async.flushMicrotasks();
        expect(waiting(), hasLength(1));
        repository.logOut();
        async.flushMicrotasks();
        expect(waiting(), isEmpty);
        repository.dispose();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 10, 24, 9));
    });

    test('tokens dated ahead of the clock, as it was then, are of unknown age: renewed at once, until it works', () {
      fakeAsync((async) {
        final ahead = clock.now().add(const Duration(days: 2));
        store.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: ahead));
        final repository = newRepository();
        renewalsBroken = true;
        repository.restore();
        async.flushMicrotasks();
        expect(repository.profile.value, isNotNull);
        expect(requests.take(2).map((r) => r.url.path), ['/api/auth/refresh', '/api/users/@me']);
        expect(saved(async)!.refreshedAt, ahead);

        // Not 23 hours on, maybe past their end: at the next check.
        renewalsBroken = false;
        async.elapse(const Duration(minutes: 10));
        expect(refreshes, 1);
        expect(saved(async), (token: 'access-2', sessionToken: 'refresh-2', refreshedAt: clock.now()));
        async.elapse(const Duration(minutes: 10));
        expect(refreshes, 1);
        repository.dispose();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 10, 24, 9));
    });

    test('a renewal the API refuses ends it, as the next request would', () {
      fakeAsync((async) {
        final repository = newRepository();
        var ended = 0;
        repository.signedOut.listen((_) => ended++);
        repository.logIn('gaby@duvet.chat', 'secret');
        async.flushMicrotasks();

        sessionDead = true;
        async.elapse(const Duration(hours: 23));
        expect(ended, 1);
        expect(repository.profile.value, isNull);
        expect(saved(async), isNull);
        repository.dispose();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 10, 24, 9));
    });

    test(
      'a failed attempt to connect asks the API about the session: on a 401 at once, else the 1st and every 5th',
      () async {
        await repository.logIn('gaby@duvet.chat', 'secret');
        await pumpEventQueue();
        int asked() => requests.where((r) => r.url.path == '/api/users/@me').length;
        final before = asked();
        for (var failures = 1; failures <= 11; failures++) {
          repository.handleConnectFailure(
            duvet.GatewayConnectFailure(failures: failures, error: const SocketException('no network')),
          );
          await pumpEventQueue();
        }
        expect(asked() - before, 3);

        // The gateway didn\'t know the token.
        repository.handleConnectFailure(
          duvet.GatewayConnectFailure(failures: 2, httpStatus: 401, error: const SocketException('401')),
        );
        await pumpEventQueue();
        expect(asked() - before, 4);
      },
    );

    test('back in front while not connected, it asks the API about the session', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
      await pumpEventQueue();
      int asked() => requests.where((r) => r.url.path == '/api/users/@me').length;
      final before = asked();
      repository.cameToFront();
      await pumpEventQueue();
      expect(asked(), before);

      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      repository.cameToFront();
      await pumpEventQueue();
      expect(asked(), before + 1);
    });

    test('the gateway\'s 4004 asks the API about the session at once', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      await pumpEventQueue();
      var ended = 0;
      repository.signedOut.listen((_) => ended++);

      // Other reasons only reconnect.
      final before = requests.length;
      repository.handleCloseReason(const duvet.GatewayCloseReason(code: 4000, reason: 'invalid shard'));
      await pumpEventQueue();
      expect(requests, hasLength(before));

      // A live session whose access token is no longer taken renews it there,
      // for the next socket.
      expiredToken = 'access-1';
      repository.handleCloseReason(const duvet.GatewayCloseReason(code: 4004, reason: 'authentication failed'));
      await pumpEventQueue();
      expect(requests.skip(before).map((r) => r.url.path), ['/api/users/@me', '/api/auth/refresh', '/api/users/@me']);
      expect((await store.read())!.token, 'access-2');
      expect(repository.profile.value, isNotNull);

      // A dead one ends.
      sessionDead = true;
      repository.handleCloseReason(const duvet.GatewayCloseReason(code: 4004, reason: 'session ended'));
      await pumpEventQueue();
      expect(ended, 1);
      expect(repository.profile.value, isNull);
      expect(await store.read(), isNull);
    });
  });

  group('M2', () {
    // Its members by their role IDs (each has @everyone's, the Space's ID),
    // and those not offline by their status.
    Map<String, dynamic> space({Map<String, int>? statuses, List<String>? members}) => {
      'space': {'id': 's-1', 'name': 'Design Guild', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
      'rooms': {
        'r-general': {
          'id': 'r-general',
          'space_id': 's-1',
          'type': 1,
          'name': 'general',
          'position': 0,
          'created_at': _at,
          'updated_at': _at,
        },
      },
      'roles_permissions': <String, dynamic>{},
      'member_roles': {
        for (final id in members ?? const <String>[]) id: ['s-1'],
      },
      'owner_id': _me,
      'member_statuses': ?statuses,
    };

    test('room permissions: roles, then @everyone\'s, the roles\' and the member\'s overwrites', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      Map<String, dynamic> room(String id, int position) => {
        'id': id,
        'space_id': 's-1',
        'type': 1,
        'name': id,
        'position': position,
        'created_at': _at,
        'updated_at': _at,
      };
      Map<String, dynamic> role(String id, int perms) => {
        'id': id,
        'space_id': 's-1',
        'name': id,
        'permissions': perms,
        'created_at': _at,
        'updated_at': _at,
      };
      Map<String, dynamic> overwrite(String room, String target, int type, {int allow = 0, int deny = 0}) => {
        'id': '$room-$target',
        'room_id': room,
        'target_id': target,
        'target_type': type,
        'allow_flags': allow,
        'deny_flags': deny,
        'created_at': _at,
        'updated_at': _at,
      };
      final payload = {
        // Someone else's Space: no owner's bypass.
        'space': {'id': 's-1', 'name': 'Duvet Official', 'owner_id': _maya, 'created_at': _at, 'updated_at': _at},
        'rooms': {'r-logs': room('r-logs', 0), 'r-general': room('r-general', 1), 'r-mods': room('r-mods', 2)},
        'roles_permissions': {
          's-1': role('s-1', Perm.viewChannels | Perm.sendMessages | Perm.createInvites),
          'role-mod': role('role-mod', Perm.pinMessages),
        },
        'member_roles': {
          _me: ['s-1', 'role-mod'],
        },
        'overwrites': {
          // Nobody invites to #r-logs.
          'r-logs': [overwrite('r-logs', 's-1', 0, deny: Perm.createInvites | Perm.sendMessages)],
          // Mods may, in #r-mods, though @everyone can't; and I'm denied pins there.
          'r-mods': [
            overwrite('r-mods', 's-1', 0, deny: Perm.createInvites),
            overwrite('r-mods', 'role-mod', 0, allow: Perm.createInvites),
            overwrite('r-mods', _me, 1, deny: Perm.pinMessages),
          ],
        },
        'owner_id': _maya,
      };
      repository.handleEvent(_event('SPACE_CREATE', payload));
      expect(repository.canInRoom('s-1', 'r-general', Perm.createInvites), isTrue);
      expect(repository.canInRoom('s-1', 'r-logs', Perm.createInvites), isFalse);
      expect(repository.canInRoom('s-1', 'r-logs', Perm.viewChannels), isTrue);
      expect(repository.canInRoom('s-1', 'r-mods', Perm.createInvites), isTrue);
      expect(repository.canInRoom('s-1', 'r-mods', Perm.pinMessages), isFalse);
      expect(repository.canInRoom('s-1', 'r-general', Perm.pinMessages), isTrue);
    });

    test('SPACE_CREATE seeds presence and the online count', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('SPACE_CREATE', space(statuses: {_maya: 1, _me: 2})));
      expect(repository.presence.value[_maya], Presence.online);
      expect(repository.presence.value[_me], Presence.doNotDisturb);
      expect(repository.spaces.value.single.onlineCount, 2);

      repository.handleEvent(_event('USER_STATUS_UPDATE', {'user_id': _maya, 'status_id': 0}));
      expect(repository.spaces.value.single.onlineCount, 1);
    });

    test('a member offline as the gateway connects counts once they come online', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('SPACE_CREATE', space(statuses: {_me: 1}, members: [_me, _leo])));
      expect(repository.spaces.value.single.onlineCount, 1);
      repository.handleEvent(_event('USER_STATUS_UPDATE', {'user_id': _leo, 'status_id': 1}));
      expect(repository.spaces.value.single.onlineCount, 2);
    });

    test('a new member\'s status comes with SPACE_MEMBER_ADD; the online count follows them in and out', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('SPACE_CREATE', space(statuses: {_me: 1}, members: [_me])));
      expect(repository.spaces.value.single.onlineCount, 1);

      repository.handleEvent(
        _event('SPACE_MEMBER_ADD', {'member_id': 'm-leo', 'space_id': 's-1', 'user_id': _leo, 'status_id': 2}),
      );
      expect(repository.presence.value[_leo], Presence.doNotDisturb);
      expect(repository.spaces.value.single.onlineCount, 2);

      repository.handleEvent(_event('SPACE_MEMBER_REMOVE', {'member_id': 'm-leo', 'space_id': 's-1', 'user_id': _leo}));
      expect(repository.spaces.value.single.onlineCount, 1);
    });

    test('a bot\'s status in one Space comes first there, and its overall one elsewhere', () async {
      const bot = '00000000-0000-4000-8000-0000000000b0';
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('SPACE_CREATE', space(statuses: {_me: 1}, members: [_me, bot])));
      repository.handleEvent(
        _event('SPACE_CREATE', {
          ...space(statuses: {_me: 1}, members: [_me, bot]),
          'space': {'id': 's-2', 'name': 'Bot lab', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
        }),
      );
      int? online(String spaceId) => repository.spaces.value.firstWhere((s) => s.id == spaceId).onlineCount;

      // The shard holding s-1 is connected; the one holding s-2 isn\'t.
      repository.handleEvent(_event('USER_STATUS_UPDATE', {'user_id': bot, 'status_id': 1, 'space_id': 's-1'}));
      repository.handleEvent(_event('USER_STATUS_UPDATE', {'user_id': bot, 'status_id': 0, 'space_id': 's-2'}));
      final now = repository.presence.value;
      expect(presenceIn(now, bot, spaceId: 's-1'), Presence.online);
      expect(presenceIn(now, bot, spaceId: 's-2'), Presence.offline);
      expect(presenceIn(now, bot), Presence.offline);
      expect((online('s-1'), online('s-2')), (2, 1));

      // The user\'s own status comes without a Space.
      repository.handleEvent(_event('USER_STATUS_UPDATE', {'user_id': _me, 'status_id': 2, 'space_id': 's-1'}));
      expect(repository.profile.value!.status, Presence.online);
    });

    test('who\'s in a Space: SPACE_CREATE\'s members, the ones who join, not the ones who leave', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('SPACE_CREATE', space(statuses: {_me: 1}, members: [_me, _maya])));
      expect(repository.isMember('s-1', _maya), isTrue);
      expect(repository.isMember('s-1', _leo), isFalse);
      expect(repository.isMember('s-2', _maya), isFalse);

      repository.handleEvent(_event('SPACE_MEMBER_ADD', {'member_id': 'm-leo', 'space_id': 's-1', 'user_id': _leo}));
      expect(repository.isMember('s-1', _leo), isTrue);
      repository.handleEvent(
        _event('SPACE_MEMBER_REMOVE', {'member_id': 'm-maya', 'space_id': 's-1', 'user_id': _maya}),
      );
      expect(repository.isMember('s-1', _maya), isFalse);
    });

    test('a new session\'s READY clears the others\' presence, which its SPACE_CREATEs bring again', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      final members = [_me, _maya, _leo];
      repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
      repository.handleEvent(_event('SPACE_CREATE', space(statuses: {_maya: 1, _leo: 2, _me: 1}, members: members)));
      expect(repository.spaces.value.single.onlineCount, 3);

      // Back after a drop too long to resume, during which Leo went offline.
      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      // Everyone's own, not their entries in single Spaces.
      Map<String, Presence> people() => {
        for (final e in repository.presence.value.entries)
          if (!e.key.contains(':')) e.key: e.value,
      };
      repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws2'}));
      expect(people(), {_me: Presence.online});
      expect(repository.spaces.value.single.onlineCount, 1);
      // Leo isn't connected: a member it doesn't name is offline (#87).
      repository.handleEvent(_event('SPACE_CREATE', space(statuses: {_maya: 1, _me: 1}, members: members)));
      expect(people(), {_me: Presence.online, _maya: Presence.online, _leo: Presence.offline});
      expect(repository.spaces.value.single.onlineCount, 2);

      // The friends list changes none of it: what the gateway says is newer.
      await pumpEventQueue();
      expect(people(), {_me: Presence.online, _maya: Presence.online, _leo: Presence.offline});
    });

    test('mentions: counted from READY and MENTION_CREATE, cleared on reading', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
      await pumpEventQueue();
      expect(repository.mentions.value, {'r-general': 2});

      repository.handleEvent(
        _event('DM_MENTION_CREATE', {'message_id': 'x', 'conversation_id': 'c-1', 'author_id': _maya}),
      );
      repository.handleEvent(_event('MENTION_CREATE', {'message_id': 'y', 'room_id': 'r-general', 'author_id': _maya}));
      expect(repository.mentions.value, {'r-general': 3, 'c-1': 1});

      repository.markRead(const ConversationTarget('c-1'), 'x');
      expect(repository.mentions.value, {'r-general': 3});
    });

    test('READY records the last read; a second READY after a drop fires resumed', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      var resumed = 0;
      final sub = repository.resumed.listen((_) => resumed++);
      addTearDown(sub.cancel);
      final ready = _event('READY', {
        'user': _user(_me, 'gaby'),
        'sessionToken': 'ws',
        'unread_rooms': ['r-general'],
        'last_read_rooms': {'r-general': 'm-41'},
      });
      repository.handleEvent(ready);
      expect(repository.lastReadOf(const RoomTarget(spaceId: 's-1', roomId: 'r-general')), 'm-41');

      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      expect(repository.status.value, LiveStatus.reconnecting);
      repository.handleEvent(ready);
      await pumpEventQueue();
      expect(repository.status.value, LiveStatus.online);
      expect(resumed, 1);
    });

    test('a resumed session is live again as it was: nothing fetched again, chats not told to catch up', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      var resumed = 0;
      final sub = repository.resumed.listen((_) => resumed++);
      addTearDown(sub.cancel);
      repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
      repository.handleEvent(_event('SPACE_CREATE', space(statuses: {_maya: 1, _me: 1})));
      await pumpEventQueue();
      final fetched = requests.length;

      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      expect(repository.status.value, LiveStatus.reconnecting);
      repository.handleResume();
      await pumpEventQueue();
      expect(repository.status.value, LiveStatus.online);
      expect(resumed, 0);
      expect(requests, hasLength(fetched));
      // What was missed came replayed: the presence known stays.
      expect(repository.presence.value[_maya], Presence.online);
      expect(repository.spaces.value.single.onlineCount, 2);
    });

    test('reactions reach whichever chat has the message', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      final events = <MessageEvent>[];
      final sub = repository.messageEvents(const ConversationTarget('c-1')).listen(events.add);
      addTearDown(sub.cancel);
      repository.handleEvent(_event('REACTION_ADD', {'message_id': 'm1', 'user_id': _maya, 'emoji_name': '👍'}));
      repository.handleEvent(_event('DM_REACTION_REMOVE', {'message_id': 'm1', 'user_id': _maya, 'emoji_name': '👍'}));
      await pumpEventQueue();
      expect(
        [for (final e in events.cast<ReactionChanged>()) (e.messageId, e.emoji, e.added)],
        [('m1', '👍', true), ('m1', '👍', false)],
      );
    });

    test('replies and reactions come with messages; a reply goes out as a reference', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      final events = <MessageEvent>[];
      final sub = repository.messageEvents(const ConversationTarget('c-1')).listen(events.add);
      addTearDown(sub.cancel);
      repository.handleEvent(
        _event('DM_MESSAGE_CREATE', {
          ..._dm('9', _maya, 'agreed'),
          'referenced_message': {'message_id': '1', 'author_id': _me, 'author_name': 'Gaby', 'content': 'ship it?'},
          'reactions': [
            {
              'emoji_name': '🎉',
              'count': 2,
              'users': [_me, _maya],
            },
          ],
        }),
      );
      await pumpEventQueue();
      final m = (events.single as MessageCreated).message;
      expect((m.reply?.messageId, m.reply?.authorName, m.reply?.content), ('1', 'Gaby', 'ship it?'));
      expect((m.reactions.single.emoji, m.reactions.single.count), ('🎉', 2));

      await repository.send(const ConversationTarget('c-1'), 'yes', nonce: 'n1', replyTo: '9');
      final send = requests.lastWhere((r) => r.method == 'POST');
      final body = jsonDecode(send.body) as Map;
      expect((body['message_reference'] as Map)['message_id'], '9');
    });

    test('the newest message of a room is fetched alone, and kept live', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      const general = RoomTarget(spaceId: 's-1', roomId: 'r-general');
      await repository.loadLatest([general]);
      expect(requests.last.url.queryParameters['count'], '1');
      expect(repository.latest.value['r-general']?.content, 'newest');
      expect(repository.previewOf(repository.latest.value['r-general']!), 'newest');
    });

    Map<String, dynamic> ready(String newest) => {
      'user': _user(_me, 'gaby'),
      'sessionToken': 'ws',
      'last_msg_rooms': {'r-general': newest},
    };

    test('the Chats tab catches up with what came while the app wasn\'t listening', () async {
      // Saved by the last launch, a day behind: a room's preview and a DM's.
      await recentsStore.write(
        _me,
        jsonEncode([
          for (final (kind, id, preview) in [('room', 'r-general', 'old'), ('conversation', 'c-1', '1')])
            {
              'kind': kind,
              'id': id,
              'spaceId': 's-1',
              'title': id,
              'at': '2026-10-22T09:00:00Z',
              'previewId': preview,
              'previewText': 'from yesterday',
            },
        ]),
      );
      int fetches() => requests.where((r) => r.method == 'GET' && r.url.path.endsWith('/messages')).length;
      String? preview(String id) => repository.recents.value.firstWhere((c) => c.target.id == id).previewText;

      // The list of conversations dates the DM after its preview.
      await repository.logIn('gaby@duvet.chat', 'secret');
      await pumpEventQueue();
      expect(preview('c-1'), 'second');

      // READY names a newer message than the room's preview.
      repository.handleEvent(_event('READY', ready('last')));
      await pumpEventQueue();
      expect(preview('r-general'), 'newest');
      expect(fetches(), 2);

      // Back after a drop with nothing new: nothing is fetched again.
      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      repository.handleEvent(_event('READY', ready('last')));
      await pumpEventQueue();
      expect(fetches(), 2);

      // A live message can come before the fetch's answer, which is older.
      roomNewest = {..._roomMessage('later', 'even newer'), 'created_at': '2026-10-24T09:00:00Z'};
      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      repository.handleEvent(_event('READY', ready('later')));
      repository.handleEvent(
        _event('MESSAGE_CREATE', {
          ..._roomMessage('live', 'live one'),
          'room_id': 'r-general',
          'created_at': '2026-10-25T09:00:00Z',
        }),
      );
      await pumpEventQueue();
      expect(fetches(), 3);
      expect(preview('r-general'), 'live one');
    });

    test('a Space\'s list of rooms catches up after a drop', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('READY', ready('last')));
      repository.handleEvent(_event('SPACE_CREATE', space()));
      await repository.loadLatest([const RoomTarget(spaceId: 's-1', roomId: 'r-general')]);
      expect(repository.latest.value['r-general']?.content, 'newest');

      // The drop lasted too long to resume: READY names a newer message.
      roomNewest = {..._roomMessage('later', 'even newer'), 'created_at': '2026-10-24T09:00:00Z'};
      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      repository.handleEvent(_event('READY', ready('later')));
      await pumpEventQueue();
      expect(repository.latest.value['r-general']?.content, 'even newer');
    });
  });

  group('moving a room', () {
    Map<String, dynamic> room(String id, int position, {String? name}) => {
      'id': id,
      'space_id': 's-m',
      'type': 1,
      'name': name ?? id,
      'position': position,
      'created_at': _at,
      'updated_at': _at,
    };

    List<String> order() => [for (final r in repository.adminRooms('s-m')) '${r.name}:${r.position}'];

    setUp(() async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(
        _event('SPACE_CREATE', {
          'space': {'id': 's-m', 'name': 'Moves', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
          'rooms': {
            for (final (i, id) in ['a', 'b', 'c'].indexed) id: room(id, i),
          },
          'roles_permissions': <String, dynamic>{},
          'owner_id': _me,
        }),
      );
    });

    test('it shows at once, as the API will move it', () async {
      final move = repository.moveRoom('s-m', 'c', position: 0);
      expect(order(), ['c:0', 'a:1', 'b:2']);
      moveReply.complete(http.Response(jsonEncode(room('c', 0)), 200, headers: {'content-type': 'application/json'}));
      await move;
      expect(order(), ['c:0', 'a:1', 'b:2']);
    });

    test('refused, only what it moved goes back: what came meanwhile stays', () async {
      final move = repository.moveRoom('s-m', 'c', position: 0);
      // While it's on its way: b renamed where the move put it, d created.
      repository.handleEvent(_event('ROOM_UPDATE', room('b', 2, name: 'bee')));
      repository.handleEvent(_event('ROOM_CREATE', room('d', 3)));
      moveReply.complete(http.Response('{"error":"no"}', 500));
      await expectLater(move, throwsA(anything));
      expect(order(), ['a:0', 'bee:1', 'c:2', 'd:3']);
    });
  });

  group('deleting a Space', () {
    Map<String, dynamic> space(String id, String roomId) => {
      'space': {'id': id, 'name': 'Space $id', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
      'rooms': {
        roomId: {
          'id': roomId,
          'space_id': id,
          'type': 1,
          'name': 'general',
          'position': 0,
          'created_at': _at,
          'updated_at': _at,
        },
      },
      'roles_permissions': <String, dynamic>{},
      'owner_id': _me,
    };

    // Two Spaces, a room of each opened, unread and with mentions.
    Future<void> twoSpaces() async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('SPACE_CREATE', space('s-1', 'r-general')));
      repository.handleEvent(_event('SPACE_CREATE', space('s-2', 'r-other')));
      repository.opened(const RoomTarget(spaceId: 's-1', roomId: 'r-general'), '# general');
      repository.opened(const RoomTarget(spaceId: 's-2', roomId: 'r-other'), '# general');
      repository.handleEvent(
        _event('READY', {
          'user': _user(_me, 'gaby'),
          'sessionToken': 'ws',
          'unread_rooms': ['r-general', 'r-other'],
        }),
      );
      // READY's mention counts first, then one more live.
      await pumpEventQueue();
      repository.handleEvent(_event('MENTION_CREATE', {'message_id': 'x', 'room_id': 'r-other', 'author_id': _maya}));
      expect(repository.mentions.value, {'r-general': 2, 'r-other': 1});
    }

    void expectOnlyTheOther() {
      expect(repository.spaces.value.map((s) => s.id), ['s-2']);
      expect(repository.recents.value.map((c) => c.target.id), ['r-other']);
      expect(repository.unread.value, {'r-other'});
      expect(repository.mentions.value, {'r-other': 1});
    }

    test('it goes with its rooms\' chats, unread marks and mentions', () async {
      await twoSpaces();
      await repository.deleteSpace('s-1');
      expect((requests.last.method, requests.last.url.path), ('DELETE', '/api/spaces/s-1'));
      expectOnlyTheOther();
    });

    test('only its owner may: a refusal keeps it', () async {
      await twoSpaces();
      deleteReply = http.Response('{"error":"only the space\'s owner can delete it"}', 403);
      await expectLater(
        repository.deleteSpace('s-1'),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'Only the Space’s owner can delete it')),
      );
      expect(repository.spaces.value.map((s) => s.id), ['s-1', 's-2']);
      expect(repository.recents.value, hasLength(2));
    });

    test('gone already (the API\'s JSON 404): it goes from here too', () async {
      await twoSpaces();
      deleteReply = http.Response('{"error":"space not found"}', 404);
      await expectLater(
        repository.deleteSpace('s-1'),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'This Space is already gone')),
      );
      expectOnlyTheOther();
    });

    test('SPACE_DELETE takes it away, with its rooms\' chats', () async {
      await twoSpaces();
      repository.handleEvent(_event('SPACE_DELETE', {'id': 's-1'}));
      expectOnlyTheOther();
    });
  });

  group('profile', () {
    test('the bio saves, trimmed; left out, it stays; empty clears it', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      await repository.updateProfile(alias: 'Gaby', bio: '  Night runner 😀 ');
      expect(jsonDecode(requests.last.body), {'alias': 'Gaby', 'custom': 'Night runner 😀'});
      expect(repository.profile.value!.bio, 'Night runner 😀');

      await repository.updateProfile(alias: 'Gabriela');
      expect(jsonDecode(requests.last.body), {'alias': 'Gabriela'});
      expect(repository.profile.value!.bio, 'Night runner 😀');

      await repository.updateProfile(alias: 'Gabriela', bio: '');
      expect(repository.profile.value!.bio, isNull);
    });

    test('a profile change or a picture the API refuses says why, as the API says it', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      // 32 characters, as the app counts them too, whatever their bytes.
      await repository.updateProfile(alias: '😀' * 32);
      expect(repository.profile.value!.displayName, '😀' * 32);
      await expectLater(
        repository.updateProfile(alias: 'a' * 33),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'Display name must be at most 32 characters')),
      );

      final dir = Directory.systemTemp.createTempSync('duvet_picture');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/me.png';
      File(path).writeAsBytesSync([1, 2, 3]);
      final progress = <double>[];
      await repository.uploadProfileImage(ProfileImage.avatar, path, onProgress: progress.add);
      expect(repository.profile.value!.avatarUrl, 'https://api.duvet.chat/attachments/$_avatar');
      expect(progress.last, 1);
      pictureRefusal = http.Response(jsonEncode({'error': 'file is too large'}), 413);
      await expectLater(
        repository.uploadProfileImage(ProfileImage.banner, path),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'File is too large')),
      );
    });

    test('an API from before bios saves the rest, and says it needs the latest API', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      apiHasBios = false;
      await expectLater(
        repository.updateProfile(alias: 'Gabriela', bio: 'Night runner'),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', contains('latest API'))),
      );
      expect(repository.profile.value!.displayName, 'Gabriela');
      expect(repository.profile.value!.bio, isNull);
    });

    test('the status: chosen here, and from READY and USER_STATUS_UPDATE', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      expect(repository.profile.value!.status, Presence.online);

      // Connected in do not disturb: READY says so.
      repository.handleEvent(
        _event('READY', {
          'user': {..._user(_me, 'gaby'), 'status': 2},
          'sessionToken': 'ws',
        }),
      );
      expect(repository.profile.value!.status, Presence.doNotDisturb);
      expect(repository.presence.value[_me], Presence.doNotDisturb);

      // Changed on another device.
      repository.handleEvent(_event('USER_STATUS_UPDATE', {'user_id': _me, 'status_id': 1}));
      expect(repository.profile.value!.status, Presence.online);
      expect(repository.presence.value[_me], Presence.online);
      // Someone else's is theirs alone.
      repository.handleEvent(_event('USER_STATUS_UPDATE', {'user_id': _maya, 'status_id': 2}));
      expect(repository.profile.value!.status, Presence.online);
      expect(repository.presence.value[_maya], Presence.doNotDisturb);

      await repository.setStatus(Presence.doNotDisturb);
      expect((requests.last.method, requests.last.url.path), ('PUT', '/api/users/@me/status'));
      expect(jsonDecode(requests.last.body), {'status': 2});
      expect(repository.profile.value!.status, Presence.doNotDisturb);
      expect(repository.presence.value[_me], Presence.doNotDisturb);
      await expectLater(repository.setStatus(Presence.offline), throwsArgumentError);

      // Offline is shown, but never taken for a choice.
      repository.handleEvent(_event('USER_STATUS_UPDATE', {'user_id': _me, 'status_id': 0}));
      expect(repository.presence.value[_me], Presence.offline);
      expect(repository.profile.value!.status, Presence.doNotDisturb);
    });

    test('an answer without the status keeps the one known', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(
        _event('READY', {
          'user': {..._user(_me, 'gaby'), 'status': 2},
          'sessionToken': 'ws',
        }),
      );
      // The mock's PATCH answers no status.
      await repository.updateProfile(alias: 'Gabriela');
      expect(repository.profile.value!.status, Presence.doNotDisturb);
    });

    test('a gateway from before statuses shows the user online; an API without the route says so', () async {
      await repository.logIn('gaby@duvet.chat', 'secret');
      repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
      expect(repository.presence.value[_me], Presence.online);
      expect(repository.profile.value!.status, Presence.online);

      apiHasStatus = false;
      await expectLater(
        repository.setStatus(Presence.doNotDisturb),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', contains('latest API'))),
      );
      expect(repository.profile.value!.status, Presence.online);
    });

    test('the cache keeps the status chosen', () {
      const p = Profile(id: _me, username: 'gaby', status: Presence.doNotDisturb);
      expect(profileFromJson(profileToJson(p)).status, Presence.doNotDisturb);
      expect(profileFromJson(profileToJson(const Profile(id: _me, username: 'gaby'))).status, Presence.online);
    });
  });
}

Map<String, dynamic> _roomMessage(String id, String content) => {
  'id': id,
  'room_id': 'r-1',
  'author_id': _maya,
  'content': content,
  'type': 0,
  'created_at': _at,
  'updated_at': _at,
  'user': _user(_maya, 'maya'),
};
