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

import '../support/eventually.dart';

// The chats cache keeps no text of a conversation (PLAN-E2E-CLIENTES.md, Review Focus 10): conversations are
// end-to-end encrypted, and only the core's database keeps what they say. Rooms' pages are kept as before.
const _me = '00000000-0000-4000-8000-000000000001';
const _maya = '00000000-0000-4000-8000-000000000002';
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

// Numbered by its ID, as an encrypted message's row: an honest API serves a conversation nothing else but its notices.
Map<String, dynamic> _dmMessage(String id, String content) => {
  'id': id,
  'conversation_id': 'c-1',
  'author_id': _maya,
  'content': content,
  'type': 0,
  'seq': int.parse(id),
  'created_at': _at,
  'updated_at': _at,
  'user': {'id': _maya, 'username': 'maya'},
};

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

duvet.GatewayEventPayload _event(String type, Map<String, dynamic> data) => duvet.GatewayEnvelope.fromJson({
  'op': 0,
  's': 1,
  'event': type,
  'd': {'type': type, 'data': data},
}).d!;

http.Response _json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

/// A page as the cache writes one.
String _page(String id, String content) => jsonEncode({
  'messages': [
    messageToJson(
      ChatMessage(id: id, authorId: _maya, authorName: 'maya', content: content, createdAt: DateTime(2026)),
    ),
  ],
});

void main() {
  late MemoryChatCacheStore cache;
  late MemorySessionStore sessions;
  final client = MockClient((request) async {
    return switch ((request.method, request.url.path)) {
      ('POST', '/api/auth/login') => _json({'token': 'access-1', 'session_token': 'refresh-1'}),
      ('GET', '/api/users/@me') => _json({..._user(_me, 'gaby'), 'email_verified': true}),
      ('GET', '/api/users/@me/conversations') => _json([
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
      ('GET', '/api/users/@me/conversations/c-1/messages') => _json([
        _dmMessage('2', 'the second secret'),
        _dmMessage('1', 'the first secret'),
      ]),
      ('GET', '/api/rooms/r-1/messages') => _json([_roomMessage('7', 'seven')]),
      _ => http.Response('not found', 404),
    };
  });
  setUp(() {
    cache = MemoryChatCacheStore();
    sessions = MemorySessionStore();
  });
  DuvetRepository make() {
    final repository = DuvetRepository(
      store: sessions,
      recentsStore: MemoryRecentChatsStore(),
      httpClient: () => client,
      connectGateway: false,
      preload: true,
      cacheStore: cache,
    );
    addTearDown(repository.dispose);
    return repository;
  }

  test('old_chat_pages_are_purged', () async {
    // What a version before this one kept: the home, and the pages of a room, of a conversation, its text in the
    // clear, and of a chat no Space the home keeps lists.
    cache.data['home'] = jsonEncode({
      'profile': {'id': _me, 'username': 'gaby'},
      'conversations': [
        {'id': 'c-1', 'title': 'maya', 'isGroup': false},
      ],
      'spaces': [
        {
          'id': 's-1',
          'name': 'Design Guild',
          'sections': [
            {
              'id': null,
              'name': null,
              'rooms': [
                {'id': 'r-1', 'name': 'general', 'voice': false, 'position': 0},
              ],
            },
          ],
        },
      ],
    });
    cache.data['chat_c-1'] = _page('1', 'the first secret');
    cache.data['chat_r-1'] = _page('7', 'seven');
    cache.data['chat_r-9'] = _page('9', 'nine');
    // Renewed lately: the start behind the home asks for no renewal.
    await sessions.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: DateTime.now(), userId: _me));

    final repository = make();
    expect(await repository.restore(), isTrue);
    // Gone before the app opens on its home.
    expect(cache.data.keys.where((key) => key.startsWith('chat_')), ['chat_r-1']);
    expect(cache.data.values.where((value) => value.contains('secret')), isEmpty);
    expect(cache.data['chat_r-1'], _page('7', 'seven'));
    expect((await repository.cachedMessages(_room))!.single.content, 'seven');
    expect(await repository.cachedMessages(_dm), isNull);
  });

  test('conversation_pages_are_never_written', () async {
    final repository = make();
    await repository.logIn('gaby@duvet.chat', 'secret');
    // Fetched ahead, opened, changed by the gateway, its author renamed: nothing of the conversation is kept.
    repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'}));
    await pumpEventQueue();
    expect(await repository.messages(_dm), hasLength(2));
    repository.handleEvent(_event('DM_MESSAGE_CREATE', _dmMessage('3', 'the third secret')));
    repository.handleEvent(_event('DM_MESSAGE_UPDATE', {..._dmMessage('1', 'the edited secret'), 'edited_at': _at}));
    repository.handleEvent(_event('DM_REACTION_ADD', {'message_id': '3', 'user_id': _me, 'emoji_name': 'ok'}));
    repository.handleEvent(_event('USER_UPDATE', {'id': _maya, 'username': 'maya', 'alias': 'Maya O.'}));
    // A room's page is kept as before.
    expect(await repository.messages(_room), hasLength(1));
    await eventually(() => expect(cache.data.keys, contains('chat_r-1')));
    // Past the half second the cache waits before it writes.
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(cache.data.keys.where((key) => key.startsWith('chat_')), ['chat_r-1']);
    expect(cache.data.values.where((value) => value.contains('secret')), isEmpty);
    expect(await repository.cachedMessages(_dm), isNull);
  });

  // M4 of step 4's closing review: as the app starts on the home it kept, the list of recent chats a version before
  // this one kept is written again, without a conversation's preview, its text in the clear.
  test("an_older_version's_conversation_previews_go_from_the_kept_list_as_the_app_starts", () async {
    final recents = MemoryRecentChatsStore();
    await recents.write(
      _me,
      jsonEncode([
        {'kind': 'conversation', 'id': 'c-1', 'title': 'maya', 'at': _at, 'previewId': '1', 'previewText': 'a secret'},
      ]),
    );
    cache.data['home'] = jsonEncode({
      'profile': {'id': _me, 'username': 'gaby'},
      'conversations': [
        {'id': 'c-1', 'title': 'maya', 'isGroup': false},
      ],
      'spaces': <Object?>[],
    });
    await sessions.write((token: 'access-1', sessionToken: 'refresh-1', refreshedAt: DateTime.now(), userId: _me));
    final repository = DuvetRepository(
      store: sessions,
      recentsStore: recents,
      httpClient: () => client,
      connectGateway: false,
      cacheStore: cache,
    );
    addTearDown(repository.dispose);
    expect(await repository.restore(), isTrue);
    await pumpEventQueue();
    final kept = await recents.read(_me);
    expect(kept, contains('c-1'));
    expect(kept, isNot(contains('secret')));
  });

  // Step 5's review, Minor 1 (mobile#366): a version before this one kept a conversation's preview, its text in the
  // clear, in the keystore's list of recent chats, which a load read past and left there.
  test("an_older_version's_conversation_previews_go_from_the_kept_list_as_it_loads", () async {
    final store = MemoryRecentChatsStore();
    await store.write(
      _me,
      jsonEncode([
        {'kind': 'conversation', 'id': 'c-1', 'title': 'maya', 'at': _at, 'previewId': '1', 'previewText': 'a secret'},
        {'kind': 'room', 'id': 'r-1', 'spaceId': 's-1', 'title': 'general', 'at': _at, 'previewText': 'seven'},
      ]),
    );
    final recents = RecentChats(store);
    addTearDown(recents.dispose);
    await recents.load(_me);
    await pumpEventQueue();
    final kept = await store.read(_me);
    expect(kept, isNot(contains('secret')));
    // The room's preview stays, as rooms' pages do.
    expect(kept, contains('seven'));
    expect([for (final chat in recents.chats.value) chat.target.id], ['c-1', 'r-1']);
  });
}
