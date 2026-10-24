import 'dart:io';
import 'dart:convert';

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/duvet_repository.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/recent_chats.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _me = '00000000-0000-4000-8000-000000000001';
const _maya = '00000000-0000-4000-8000-000000000002';
const _leo = '00000000-0000-4000-8000-000000000003';
const _avatar = '00000000-0000-4000-8000-0000000000aa';
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

  setUp(() {
    requests = [];
    store = MemorySessionStore();
    recentsStore = MemoryRecentChatsStore();
    cache = MemoryChatCacheStore();
    apiHasBios = true;
    apiHasStatus = true;
    bio = '';
    deleteReply = http.Response('', 204);
    client = MockClient((request) async {
      requests.add(request);
      Map<String, dynamic> body() => jsonDecode(request.body) as Map<String, dynamic>;
      final json = switch ((request.method, request.url.path)) {
        ('POST', '/api/auth/login') => {'token': 'access-1', 'session_token': 'refresh-1'},
        ('GET', '/api/users/@me') => {..._user(_me, 'gaby', alias: 'Gaby'), 'email_verified': true},
        // An API from before bios ignores `custom`, and answers the bio it had.
        ('PATCH', '/api/users/@me') => {
          ..._user(_me, 'gaby', alias: body()['alias'] as String?),
          'custom': bio = apiHasBios ? (body()['custom'] as String? ?? bio).trim() : bio,
        },
        ('PUT', '/api/users/@me/status') when apiHasStatus => {..._user(_me, 'gaby'), 'status': body()['status']},
        ('DELETE', '/api/spaces/s-1') => deleteReply,
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
                  'user': {'id': id, 'username': name, 'alias': name == 'maya' ? 'Maya' : null, 'avatar': avatar},
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
            },
        ],
        ('GET', '/api/users/@me/friends/requests') || ('GET', '/api/users/@me/friends/requests/sent') => <Object>[],
        ('GET', '/api/rooms/r-general/messages') => [_roomMessage('last', 'newest')],
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
    expect(await store.read(), (token: 'access-1', sessionToken: 'refresh-1'));
    expect(requests.last.headers['Authorization'], 'Bearer access-1');

    await pumpEventQueue();
    final chat = repository.conversations.value.single;
    expect(chat.title, 'Maya');
    expect(chat.isGroup, isFalse);
    expect(chat.avatarUrl, 'https://api.duvet.chat/attachments/$_avatar');
    expect(chat.otherUserId, _maya);
  });

  test('the friends list gives friends their presence, where the gateway hasn\'t told it', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    repository.presence.value = {_leo: Presence.online};
    await repository.loadFriends();
    expect(repository.presence.value, {_leo: Presence.online, _maya: Presence.doNotDisturb});
  });

  test('a saved session resumes; a rejected one is forgotten', () async {
    await store.write((token: 'access-1', sessionToken: 'refresh-1'));
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
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(cache.data.keys, containsAll(['home', 'chat_c-1']));

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
    await pumpEventQueue();
    expect(voice.map((e) => e.runtimeType), [
      duvet.ReadyEvent,
      duvet.VoiceStateUpdatedEvent,
      duvet.CallIncomingPayloadEvent,
      duvet.VoiceSessionReplacedPayloadEvent,
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
    await store.write((token: 'access-1', sessionToken: 'refresh-1'));
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

  group('M2', () {
    Map<String, dynamic> space({Map<String, int>? statuses}) => {
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
