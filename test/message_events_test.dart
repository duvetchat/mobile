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
const _at = '2026-10-23T09:00:00Z';
const _room = RoomTarget(spaceId: 's-1', roomId: 'r-1');
const _dm = ConversationTarget('c-1');

Map<String, dynamic> _user(String id, String username, {String? alias}) => {
  'id': id,
  'username': username,
  'alias': alias,
  'custom': '',
  'status_id': 1,
  'created_at': _at,
  'updated_at': _at,
};

/// A room message as MESSAGE_CREATE carries it: Maya's in r-1, with a file
/// and a reaction.
Map<String, dynamic> _roomMessage(String id, String content) => {
  'id': id,
  'room_id': 'r-1',
  'author_id': _maya,
  'content': content,
  'type': 0,
  'created_at': _at,
  'updated_at': _at,
  'user': _user(_maya, 'maya', alias: 'Maya'),
  'attachments': [
    {
      'id': 'a-1',
      'filename': 'notes.pdf',
      'content_type': 'application/pdf',
      'size_bytes': 2048,
      'created_at': _at,
      'url': 'https://api.duvet.chat/attachments/a-1',
    },
  ],
  'reactions': [
    {
      'emoji_name': '👍',
      'count': 1,
      'users': [_me],
    },
  ],
};

/// What MESSAGE_UPDATE carries when a link's preview comes: the text and the
/// embeds, no user, files, reactions or reply.
Map<String, dynamic> _preview(String id, String content) => {
  'id': id,
  'room_id': 'r-1',
  'author_id': _maya,
  'content': content,
  'type': 0,
  'created_at': _at,
  'updated_at': _at,
  'embeds': [
    {'title': 'Duvet', 'url': 'https://duvet.chat'},
  ],
};

const _ballot = '00000000-0000-4000-8000-0000000000b0';

/// A bot's answer in r-1, with [flags] (64: ephemeral, 128: loading).
Map<String, dynamic> _answer(String id, String content, {int flags = 64}) => {
  'id': id,
  'room_id': 'r-1',
  'author_id': _ballot,
  'content': content,
  'type': 0,
  'created_at': _at,
  'updated_at': _at,
  'user': {..._user(_ballot, 'ballot', alias: 'Ballot'), 'is_bot': true},
  'flags': flags,
};

Map<String, dynamic> _dmMessage(String id, String content, {bool withUser = true}) => {
  'id': id,
  'conversation_id': 'c-1',
  'author_id': _maya,
  'content': content,
  'type': 0,
  'created_at': _at,
  'updated_at': _at,
  if (withUser) 'user': {'id': _maya, 'username': 'maya', 'alias': 'Maya'},
};

/// SPACE_CREATE for s-1, which has r-1.
Map<String, dynamic> _space() => {
  'space': {'id': 's-1', 'name': 'Design Guild', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
  'rooms': {
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

/// The gateway's envelope for [type], parsed as the client parses it.
duvet.GatewayEventPayload _event(String type, Map<String, dynamic> data) => duvet.GatewayEnvelope.fromJson({
  'op': 0,
  's': 1,
  'event': type,
  'd': {'type': type, 'data': data},
}).d!;

/// The repository's side of a chat's messages: what the gateway's message
/// events do to the open chats, the previews and the Chats tab.
void main() {
  late List<http.Request> requests;
  late DuvetRepository repository;

  setUp(() {
    requests = [];
    final client = MockClient((request) async {
      requests.add(request);
      final json = switch ((request.method, request.url.path)) {
        ('POST', '/api/auth/login') => {'token': 'access-1', 'session_token': 'refresh-1'},
        ('GET', '/api/users/@me') => {..._user(_me, 'gaby', alias: 'Gaby'), 'email_verified': true},
        ('GET', '/api/users/@me/conversations') => <Object>[],
        // Maya's Space nickname, which the history and the member list give.
        ('GET', '/api/rooms/r-1/messages') => [
          {..._roomMessage('7', 'first'), 'member_alias': 'Nick'},
        ],
        ('GET', '/api/spaces/s-1/members') => [
          {
            'id': 'mb-1',
            'space_id': 's-1',
            'user_id': _maya,
            'alias': 'Nick',
            'created_at': _at,
            'updated_at': _at,
            'user': _user(_maya, 'maya', alias: 'Maya'),
          },
        ],
        ('GET', '/api/spaces/s-1/commands') => {
          'applications': [
            {
              'id': 'app-1',
              'name': 'Ballot',
              'bot': {'id': _ballot, 'username': 'ballot'},
            },
          ],
          'commands': [
            {
              'id': 'cmd-go',
              'type': 1,
              'application_id': 'app-1',
              'name': 'go',
              'options': [
                {
                  'type': 7,
                  'name': 'where',
                  'description': 'A room',
                  'room_types': [1, 3],
                },
              ],
            },
          ],
        },
        // Refusals, as the API words them: a 403 (which the client raises as
        // an auth error), a 400, and a failure with no reason.
        ('POST', '/api/rooms/r-1/messages') => http.Response(
          jsonEncode({'error': "you don't have permission to send messages in this room"}),
          403,
        ),
        ('PUT', '/api/rooms/r-1/pins/7') => http.Response(
          jsonEncode({'error': 'a room has 250 pinned messages at most'}),
          400,
        ),
        ('PUT', '/api/rooms/r-1/pins/8') => http.Response('upstream timed out', 504),
        _ => null,
      };
      if (json is http.Response) return json;
      if (json == null) return http.Response('not found', 404);
      return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json'});
    });
    repository = DuvetRepository(
      store: MemorySessionStore(),
      recentsStore: MemoryRecentChatsStore(),
      httpClient: () => client,
      connectGateway: false,
      cacheStore: MemoryChatCacheStore(),
    );
  });

  tearDown(() => repository.dispose());

  Future<List<MessageEvent>> listen(ChatTarget target) async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final events = <MessageEvent>[];
    final sub = repository.messageEvents(target).listen(events.add);
    addTearDown(sub.cancel);
    return events;
  }

  group('updates', () {
    test('a link preview\'s update keeps the files, reactions and author of the newest message', () async {
      final events = await listen(_room);
      repository.opened(_room, '# general');
      repository.handleEvent(_event('MESSAGE_CREATE', _roomMessage('7', 'see https://duvet.chat')));
      repository.handleEvent(_event('MESSAGE_UPDATE', _preview('7', 'see https://duvet.chat')));
      await pumpEventQueue();

      final latest = repository.latest.value['r-1']!;
      expect(latest.authorName, 'Maya');
      expect(latest.attachments.single.filename, 'notes.pdf');
      expect(latest.reactions.single.emoji, '👍');
      expect(latest.embeds.single.title, 'Duvet');
      expect(repository.recents.value.single.previewAuthor, 'Maya');

      // The chat merges it into its own copy, which keeps its author.
      expect((events.last as MessageUpdated).message.content, 'see https://duvet.chat');
    });

    test('the Chats tab previews the message as merged: a picture stays a photo once edited', () async {
      await listen(_room);
      repository.opened(_room, '# general');
      repository.handleEvent(
        _event('MESSAGE_CREATE', {
          ..._answer('7', '', flags: 0),
          'attachments': [
            {
              'id': 'a-1',
              'filename': 'chart.png',
              'content_type': 'image/png',
              'size_bytes': 10,
              'created_at': _at,
              'url': 'https://api.duvet.chat/attachments/a-1',
            },
          ],
        }),
      );
      expect(repository.recents.value.single.previewText, 'Sent a photo');
      // Its bot edits it: the event has no files.
      repository.handleEvent(
        _event('MESSAGE_UPDATE', {..._answer('7', '', flags: 0), 'updated_at': '2026-10-23T09:00:30Z'}),
      );
      await pumpEventQueue();
      expect(repository.recents.value.single.previewText, 'Sent a photo');
    });

    test('an edit of a DM keeps its author in the Chats tab, also when the event has no user', () async {
      final events = await listen(_dm);
      repository.handleEvent(_event('DM_MESSAGE_CREATE', _dmMessage('9', 'first try')));
      repository.handleEvent(_event('DM_MESSAGE_UPDATE', _dmMessage('9', 'see https://duvet.chat', withUser: false)));
      await pumpEventQueue();

      expect(repository.recents.value.single.previewAuthor, 'Maya');
      expect(repository.recents.value.single.previewText, 'see https://duvet.chat');
      expect(repository.latest.value['c-1']!.content, 'see https://duvet.chat');
      expect(repository.latest.value['c-1']!.authorName, 'Maya');
      expect((events.last as MessageUpdated).message.content, 'see https://duvet.chat');
    });
  });

  group('names', () {
    test('a live message takes its author\'s Space nickname from the history, and an edit keeps it', () async {
      final events = await listen(_room);
      repository.handleEvent(_event('SPACE_CREATE', _space()));
      final page = await repository.messages(_room);
      expect(page.single.authorName, 'Nick');
      // The gateway's events name her without it.
      repository.handleEvent(_event('MESSAGE_CREATE', _roomMessage('8', 'second')));
      repository.handleEvent(
        _event('MESSAGE_UPDATE', {..._roomMessage('7', 'first, edited'), 'updated_at': '2026-10-23T09:00:30Z'}),
      );
      await pumpEventQueue();
      expect((events.first as MessageCreated).message.authorName, 'Nick');
      expect(page.single.updatedBy((events.last as MessageUpdated).message).authorName, 'Nick');
    });

    test('or from the member list, with no history loaded', () async {
      final events = await listen(_room);
      repository.handleEvent(_event('SPACE_CREATE', _space()));
      await repository.members(_room);
      repository.handleEvent(_event('MESSAGE_CREATE', _roomMessage('8', 'second')));
      await pumpEventQueue();
      expect((events.single as MessageCreated).message.authorName, 'Nick');
    });
  });

  group('bots\' answers', () {
    test('one to the user alone is kept apart: the room stays read, and it isn\'t the preview', () async {
      final events = await listen(_room);
      repository.opened(_room, '# general');
      repository.handleEvent(_event('MESSAGE_CREATE', _answer('8', 'Only for you')));
      await pumpEventQueue();
      expect(repository.unread.value, isEmpty);
      expect(repository.latest.value, isEmpty);
      expect(repository.recents.value.single.previewId, isNull);
      expect((events.single as MessageCreated).message.isEphemeral, isTrue);
      expect(repository.ephemeralIn(_room).map((m) => m.content), ['Only for you']);

      // Edited while it's shown; not once it's dismissed.
      repository.handleEvent(_event('MESSAGE_UPDATE', _answer('8', 'Still only for you')));
      expect(repository.ephemeralIn(_room).single.content, 'Still only for you');
      repository.dismissEphemeral(_room, '8');
      repository.handleEvent(_event('MESSAGE_UPDATE', _answer('8', 'Back again?')));
      await pumpEventQueue();
      expect(repository.ephemeralIn(_room), isEmpty);
      expect(events.whereType<MessageUpdated>().map((e) => e.message.content), ['Still only for you']);

      // Its bot deletes it.
      repository.handleEvent(_event('MESSAGE_CREATE', _answer('9', 'Another')));
      repository.handleEvent(_event('MESSAGE_DELETE', {'id': '9', 'room_id': 'r-1'}));
      expect(repository.ephemeralIn(_room), isEmpty);
    });

    test('a deferred one is loading until its bot completes it', () async {
      final events = await listen(_room);
      repository.handleEvent(_event('MESSAGE_CREATE', _answer('10', '', flags: 128)));
      repository.handleEvent(_event('MESSAGE_UPDATE', _answer('10', 'Done', flags: 0)));
      await pumpEventQueue();
      expect((events.first as MessageCreated).message.isLoading, isTrue);
      expect((events.last as MessageUpdated).message.isLoading, isFalse);
      expect(repository.latest.value['r-1']!.isLoading, isFalse);
      expect(repository.latest.value['r-1']!.content, 'Done');
    });
  });

  test('pins and voice messages being recorded reach their chats as they happen', () async {
    final roomEvents = await listen(_room);
    final dmEvents = <MessageEvent>[];
    final roomTyping = <TypingUser>[];
    final dmTyping = <TypingUser>[];
    final subs = [
      repository.messageEvents(_dm).listen(dmEvents.add),
      repository.typing(_room).listen(roomTyping.add),
      repository.typing(_dm).listen(dmTyping.add),
    ];
    addTearDown(() => Future.wait([for (final s in subs) s.cancel()]));

    repository.handleEvent(_event('MESSAGE_PIN_UPDATE', {'id': '7', 'room_id': 'r-1', 'pinned_at': _at}));
    repository.handleEvent(_event('DM_MESSAGE_PIN_UPDATE', {'id': '9', 'conversation_id': 'c-1', 'pinned_at': null}));
    repository.handleEvent(
      _event('RECORDING', {'user_id': _maya, 'username': 'maya', 'alias': 'Maya', 'room_id': 'r-1'}),
    );
    // The user's own, from another device: not shown.
    repository.handleEvent(_event('RECORDING', {'user_id': _me, 'username': 'gaby', 'room_id': 'r-1'}));
    repository.handleEvent(_event('DM_RECORDING', {'user_id': _maya, 'username': 'maya', 'conversation_id': 'c-1'}));
    await pumpEventQueue();

    final pin = roomEvents.single as MessagePinned;
    expect((pin.messageId, pin.pinned), ('7', true));
    final unpin = dmEvents.single as MessagePinned;
    expect((unpin.messageId, unpin.pinned), ('9', false));
    expect([for (final t in roomTyping) (t.name, t.recording)], [('Maya', true)]);
    expect([for (final t in dmTyping) (t.name, t.recording)], [('maya', true)]);
  });

  test('a reply says whether it mentions the author it answers, and a v2 message its text displays', () async {
    final events = await listen(_room);
    repository.handleEvent(
      _event('MESSAGE_CREATE', {
        ..._roomMessage('11', 'agreed'),
        'referenced_message': {'message_id': '1', 'author_id': _me, 'author_name': 'Gaby', 'mention_author': true},
      }),
    );
    repository.handleEvent(
      _event('MESSAGE_CREATE', {
        ..._answer('12', '', flags: 1 << 15),
        'components': [
          {
            'type': 17,
            'components': [
              {'type': 10, 'content': 'Your turn, <@$_me>'},
            ],
          },
        ],
      }),
    );
    await pumpEventQueue();
    final reply = (events[0] as MessageCreated).message.reply!;
    expect((reply.authorId, reply.mentionAuthor), (_me, true));
    final v2 = (events[1] as MessageCreated).message;
    expect((v2.isComponentsV2, v2.text), (true, 'Your turn, <@$_me>'));
    // The offline cache keeps both.
    final reread = messageFromJson(jsonDecode(jsonEncode(messageToJson(v2))) as Map<String, Object?>);
    expect(reread.isComponentsV2, isTrue);
    final replyBack = messageFromJson(
      jsonDecode(jsonEncode(messageToJson((events[0] as MessageCreated).message))) as Map<String, Object?>,
    );
    expect(replyBack.reply!.mentionAuthor, isTrue);
  });

  test('a webhook\'s message keeps its webhook, which tells it from another\'s', () async {
    final events = await listen(_room);
    repository.handleEvent(
      _event('MESSAGE_CREATE', {
        'id': '13',
        'room_id': 'r-1',
        'author_id': null,
        'webhook_id': 'w-1',
        'content': 'Deployed',
        'type': 0,
        'created_at': _at,
        'updated_at': _at,
        'user': {..._user('w-1', 'Deploys'), 'is_bot': true},
      }),
    );
    await pumpEventQueue();
    final m = (events.single as MessageCreated).message;
    expect((m.webhookId, m.fromWebhook, m.authorId), ('w-1', true, null));
    expect(messageFromJson(jsonDecode(jsonEncode(messageToJson(m))) as Map<String, Object?>).webhookId, 'w-1');
  });

  test('a command\'s room option keeps the room types it takes', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    final go = (await repository.commands('s-1')).single;
    expect(go.options.single.roomTypes, [1, 3]);
  });

  test('a send or a pin the API refuses says why, as the desktop shows it', () async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    Matcher refused(String reason) => throwsA(isA<ActionFailed>().having((e) => e.message, 'message', reason));
    await expectLater(
      repository.send(_room, 'hello', nonce: 'n-1'),
      refused('You don\'t have permission to send messages in this room'),
    );
    await expectLater(
      repository.sendVoiceNote(_room, const [1, 2, 3], nonce: 'n-2'),
      refused('You don\'t have permission to send messages in this room'),
    );
    await expectLater(repository.pin(_room, '7', pinned: true), refused('A room has 250 pinned messages at most'));
    // No reason given: the client's own error, which the chat words itself.
    await expectLater(repository.pin(_room, '8', pinned: true), throwsA(isA<duvet.DuvetApiException>()));
    // The session goes on: a 403 is no 401.
    expect(repository.profile.value, isNotNull);
  });

  test('ChatMessage.updatedBy keeps what the event leaves out, and who wrote it', () {
    final original = ChatMessage(
      id: '7',
      authorId: _maya,
      // As the history names her.
      authorName: 'Nick',
      content: 'old',
      createdAt: DateTime(2026, 10, 23),
      pinned: true,
      fromBot: true,
      reply: const MessageReply(messageId: '1', authorName: 'Gaby', content: 'ship it?'),
      reactions: [
        Reaction(emoji: '👍', users: {_me}),
      ],
      attachments: const [
        MessageAttachment(id: 'a', filename: 'notes.pdf', contentType: 'application/pdf', url: 'https://x/a'),
      ],
    );
    final update = ChatMessage(
      id: '7',
      authorId: _maya,
      // As the gateway names her.
      authorName: 'Maya',
      content: 'new',
      createdAt: DateTime(2026, 10, 23),
      edited: true,
      embeds: const [MessageEmbed(title: 'Duvet')],
    );
    final merged = original.updatedBy(update);
    expect((merged.content, merged.edited, merged.embeds.single.title), ('new', true, 'Duvet'));
    expect((merged.authorName, merged.fromBot, merged.pinned), ('Nick', true, true));
    expect(merged.reply?.content, 'ship it?');
    expect(merged.reactions.single.emoji, '👍');
    expect(merged.attachments.single.filename, 'notes.pdf');
  });
}
