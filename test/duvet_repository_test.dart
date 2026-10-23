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

  setUp(() {
    requests = [];
    store = MemorySessionStore();
    recentsStore = MemoryRecentChatsStore();
    cache = MemoryChatCacheStore();
    client = MockClient((request) async {
      requests.add(request);
      final json = switch ((request.method, request.url.path)) {
        ('POST', '/api/auth/login') => {'token': 'access-1', 'session_token': 'refresh-1'},
        ('GET', '/api/users/@me') => {..._user(_me, 'gaby', alias: 'Gaby'), 'email_verified': true},
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
