import 'dart:async';
import 'dart:convert';

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
const _at = '2026-10-23T09:00:00Z';
const _dm = ConversationTarget('c-1');
const _room = RoomTarget(spaceId: 's-1', roomId: 'r-1');

Map<String, dynamic> _user(String id, String username) => {
  'id': id,
  'username': username,
  'custom': '',
  'status_id': 1,
  'created_at': _at,
  'updated_at': _at,
};

Map<String, dynamic> _dmMessage(String id, String content, {String author = _maya}) => {
  'id': id,
  'conversation_id': 'c-1',
  'author_id': author,
  'content': content,
  'type': 0,
  'created_at': _at,
  'updated_at': _at,
  'user': {'id': author, 'username': author == _me ? 'gaby' : 'maya'},
};

Map<String, dynamic> _roomMessage(String id, String content, {String room = 'r-1'}) => {
  'id': id,
  'room_id': room,
  'author_id': _maya,
  'content': content,
  'type': 0,
  'created_at': _at,
  'updated_at': _at,
  'user': _user(_maya, 'maya'),
};

/// SPACE_CREATE for [id], with r-1 in s-1.
Map<String, dynamic> _space(String id, String name) => {
  'space': {'id': id, 'name': name, 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
  'rooms': {
    if (id == 's-1')
      'r-1': {
        'id': 'r-1',
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
};

duvet.GatewayEventPayload _event(String type, Map<String, dynamic> data) => duvet.GatewayEnvelope.fromJson({
  'op': 0,
  's': 1,
  'event': type,
  'd': {'type': type, 'data': data},
}).d!;

Map<String, dynamic> _ready({List<String>? guilds}) => {
  'user': _user(_me, 'gaby'),
  'sessionToken': 'ws',
  'last_msg_rooms': {'r-1': '7'},
  'guild_ids': ?guilds,
};

/// What fetching ahead does: the chats likely to be opened next get their
/// page kept before they are, their previews filled, and the pages kept follow
/// what happens to their messages.
void main() {
  late List<http.Request> requests;
  late MemorySessionStore sessions;
  late MemoryChatCacheStore cache;
  late DuvetRepository repository;

  /// What `GET /api/rooms/<id>/messages` answers, by room; 404 for the rest.
  late Map<String, http.Response Function()> roomAnswers;

  /// While set, the DM's history waits for it.
  Completer<void>? holdDm;

  http.Response json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  late MockClient client;

  DuvetRepository make() => DuvetRepository(
    store: sessions,
    recentsStore: MemoryRecentChatsStore(),
    httpClient: () => client,
    connectGateway: false,
    preload: true,
    cacheStore: cache,
  );

  /// The messages fetched of [path], with the count asked.
  List<String?> fetched(String path) => [
    for (final r in requests)
      if (r.method == 'GET' && r.url.path == path) r.url.queryParameters['count'],
  ];

  setUp(() {
    requests = [];
    sessions = MemorySessionStore();
    cache = MemoryChatCacheStore();
    holdDm = null;
    roomAnswers = {
      'r-1': () => json([_roomMessage('7', 'seven'), _roomMessage('6', 'six')]),
    };
    client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (request.method == 'GET' && path.startsWith('/api/rooms/') && path.endsWith('/messages')) {
        return (roomAnswers[path.split('/')[3]] ?? () => http.Response('not found', 404))();
      }
      if (path == '/api/users/@me/conversations/c-1/messages') {
        await holdDm?.future;
        return json([_dmMessage('2', 'second', author: _me), _dmMessage('1', 'first')]);
      }
      return switch ((request.method, path)) {
        ('POST', '/api/auth/login') => json({'token': 'access-1', 'session_token': 'refresh-1'}),
        ('POST', '/api/auth/logout') => http.Response('', 204),
        ('GET', '/api/users/@me') => json({..._user(_me, 'gaby'), 'email_verified': true}),
        ('GET', '/api/users/@me/conversations') => json([
          {
            'id': 'c-1',
            'type': 1,
            'owner_id': _me,
            'created_at': _at,
            'updated_at': _at,
            'members': [
              for (final (id, name) in [(_me, 'gaby'), (_maya, 'maya')])
                {
                  'id': 'm-$id',
                  'conversation_id': 'c-1',
                  'user_id': id,
                  'created_at': _at,
                  'updated_at': _at,
                  'user': {'id': id, 'username': name},
                },
            ],
          },
        ]),
        _ => http.Response('not found', 404),
      };
    });
    repository = make();
  });

  tearDown(() => repository.dispose());

  test('READY fetches the newest chats\' pages ahead: they open on them, and the list previews them', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    repository.handleEvent(_event('READY', _ready()));
    await pumpEventQueue();

    // The conversation, never opened here: its whole page, kept.
    expect(fetched('/api/users/@me/conversations/c-1/messages'), ['${ChatCache.pageSize}']);
    expect([for (final m in (await repository.cachedMessages(_dm))!) m.content], ['first', 'second']);
    // Its preview, here and in the Chats tab, where it shows from now on.
    expect(repository.latest.value['c-1']?.content, 'second');
    expect(repository.recents.value.single.target, _dm);
    expect(repository.recents.value.single.previewText, 'second');
  });

  test('a Space\'s busiest rooms get their pages, the rest their newest message', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final rooms = [for (var i = 1; i <= 10; i++) RoomTarget(spaceId: 's-1', roomId: 'r-$i')];
    for (final r in rooms.skip(1)) {
      roomAnswers[r.roomId] = () => json([_roomMessage('${r.roomId}-new', 'hi', room: r.roomId)]);
    }
    repository.handleEvent(
      _event('READY', {
        ..._ready(),
        // r-10 and r-9 are the busiest; r-1 the least.
        'last_msg_rooms': {for (var i = 1; i <= 10; i++) 'r-$i': i.toString().padLeft(2, '0')},
      }),
    );
    requests.clear();
    await repository.loadLatest(rooms);

    final counts = {
      for (final r in requests)
        if (r.url.path.startsWith('/api/rooms/')) r.url.path.split('/')[3]: r.url.queryParameters['count'],
    };
    expect(counts, hasLength(10));
    expect([
      for (final i in [10, 9, 8, 7, 6, 5, 4, 3]) counts['r-$i'],
    ], everyElement('${ChatCache.pageSize}'));
    expect([counts['r-2'], counts['r-1']], ['1', '1']);
    expect(repository.latest.value['r-1']?.content, 'seven');
    expect((await repository.cachedMessages(const RoomTarget(spaceId: 's-1', roomId: 'r-10')))!.single.content, 'hi');
    expect(await repository.cachedMessages(_room), isNull);
  });

  test('a kept page that ends on the newest message isn\'t fetched again', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    repository.handleEvent(_event('READY', _ready()));
    await pumpEventQueue();
    await eventually(() => expect(cache.data.keys, contains('chat_c-1')));

    // The next launch, the DM's newest message as the list of conversations dates it.
    final next = make();
    addTearDown(next.dispose);
    requests.clear();
    await next.logIn('gaby@duvet.chat', 'secret');
    next.handleEvent(_event('READY', _ready()));
    await pumpEventQueue();
    expect(fetched('/api/users/@me/conversations/c-1/messages'), isEmpty);
    expect(next.latest.value['c-1']?.content, 'second');
  });

  test('the page kept follows new, edited, deleted and pinned messages, and reactions', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    await repository.messages(_dm);
    repository.handleEvent(_event('DM_MESSAGE_CREATE', _dmMessage('3', 'third')));
    repository.handleEvent(_event('DM_MESSAGE_UPDATE', {..._dmMessage('1', 'first, edited'), 'edited_at': _at}));
    repository.handleEvent(
      _event('DM_MESSAGE_CREATE', {
        ..._dmMessage('4', 'about the second'),
        'referenced_message': {'message_id': '2', 'author_id': _me, 'author_name': 'gaby', 'content': 'second'},
      }),
    );
    repository.handleEvent(_event('DM_MESSAGE_DELETE', {'id': '2', 'conversation_id': 'c-1'}));
    repository.handleEvent(_event('DM_MESSAGE_PIN_UPDATE', {'id': '1', 'conversation_id': 'c-1', 'pinned_at': _at}));
    // Two reactions to one message, at once: both count.
    repository.handleEvent(_event('DM_REACTION_ADD', {'message_id': '3', 'user_id': _maya, 'emoji_name': '👍'}));
    repository.handleEvent(_event('DM_REACTION_ADD', {'message_id': '3', 'user_id': _leo, 'emoji_name': '👍'}));

    await eventually(() async {
      final page = (await repository.cachedMessages(_dm))!;
      expect([for (final m in page) m.id], ['1', '3', '4']);
      expect((page[0].content, page[0].pinned), ('first, edited', true));
      expect(page[1].reactions.single.users, {_maya, _leo});
      expect(page[2].reply?.deleted, isTrue);
    });
    // The deleted one isn't the preview any more.
    expect(repository.latest.value['c-1']?.id, '4');
  });

  test('a page kept from before isn\'t added to, which would skip what came between: it\'s fetched again', () async {
    // Kept by an earlier session, days behind.
    ChatCache(cache).savePage(_dm.id, [
      ChatMessage(id: '0', authorId: _maya, authorName: 'maya', content: 'old', createdAt: DateTime.utc(2026, 10, 20)),
    ]);
    await eventually(() => expect(cache.data.keys, contains('chat_c-1')));
    await repository.logIn('gaby@duvet.chat', 'secret');
    repository.handleEvent(_event('DM_MESSAGE_CREATE', _dmMessage('3', 'third')));
    await pumpEventQueue();
    expect([for (final m in (await repository.cachedMessages(_dm))!) m.id], ['0']);

    repository.handleEvent(_event('READY', _ready()));
    await pumpEventQueue();
    expect(fetched('/api/users/@me/conversations/c-1/messages'), ['${ChatCache.pageSize}']);
    expect([for (final m in (await repository.cachedMessages(_dm))!) m.content], ['first', 'second']);
  });

  test('a 429 stops fetching ahead for a while', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final rooms = [for (var i = 1; i <= 6; i++) RoomTarget(spaceId: 's-1', roomId: 'r-$i')];
    for (final r in rooms) {
      roomAnswers[r.roomId] = () => http.Response(jsonEncode({'error': 'too many requests, try again later'}), 429);
    }
    int asked() => requests.where((r) => r.url.path.startsWith('/api/rooms/')).length;
    await repository.loadLatest(rooms);
    // The first ones at once; none after their 429s.
    expect(asked(), 4);
    await repository.loadLatest(rooms);
    expect(asked(), 4);
  });

  test('signing out drops the page on its way: nothing is kept after', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final held = holdDm = Completer<void>();
    final loading = repository.loadLatest([_dm]);
    await pumpEventQueue();
    await repository.logOut();
    held.complete();
    await loading;
    await pumpEventQueue();
    expect(await repository.cachedMessages(_dm), isNull);
    expect(repository.latest.value, isEmpty);
  });

  test('a saved session draws its kept Spaces and conversations at once, and keeps those READY names until they '
      'come', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    repository.handleEvent(_event('READY', _ready(guilds: ['s-1', 's-2'])));
    repository.handleEvent(_event('SPACE_CREATE', _space('s-1', 'Design Guild')));
    repository.handleEvent(_event('SPACE_CREATE', _space('s-2', 'Night Owls')));
    await pumpEventQueue();
    await eventually(() => expect((jsonDecode(cache.data['home'] ?? '{}') as Map)['spaces'], hasLength(2)));

    final next = make();
    addTearDown(next.dispose);
    expect(await next.restore(), isTrue);
    expect([for (final s in next.spaces.value) s.name], ['Design Guild', 'Night Owls']);
    expect(next.conversations.value.single.id, 'c-1');

    // The first to come doesn't take the other's place.
    next.handleEvent(_event('READY', _ready(guilds: ['s-1', 's-2'])));
    next.handleEvent(_event('SPACE_CREATE', _space('s-2', 'Night Owls 2')));
    expect([for (final s in next.spaces.value) s.name], ['Design Guild', 'Night Owls 2']);
    // One deleted meanwhile goes.
    next.handleEvent(_event('SPACE_DELETE', {'id': 's-1'}));
    expect([for (final s in next.spaces.value) s.name], ['Night Owls 2']);
  });

  test('the pages kept are bounded: the oldest written go', () {
    fakeAsync((async) {
      final store = MemoryChatCacheStore();
      final kept = ChatCache(store);
      for (var i = 0; i <= ChatCache.pagesKept; i++) {
        kept.savePage('c-$i', [
          ChatMessage(id: '$i', authorId: _maya, authorName: 'Maya', content: 'hi', createdAt: DateTime(2026, 10, 23)),
        ]);
        async.elapse(const Duration(seconds: 1));
      }
      final pages = store.data.keys.where((k) => k.startsWith('chat_'));
      expect(pages, hasLength(ChatCache.pagesKept));
      expect(pages, isNot(contains('chat_c-0')));
      expect(pages, contains('chat_c-${ChatCache.pagesKept}'));
    });
  });
}
