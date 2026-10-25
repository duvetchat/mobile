import 'dart:convert';
import 'dart:io';

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
const _at = '2026-10-24T09:00:00Z';

/// The gateway's envelope for [type], parsed as the client parses it.
duvet.GatewayEventPayload _event(String type, Map<String, dynamic> data) => duvet.GatewayEnvelope.fromJson({
  'op': 0,
  's': 1,
  'event': type,
  'd': {'type': type, 'data': data},
}).d!;

Map<String, dynamic> _user(String id, String username, {bool bot = false}) => {
  'id': id,
  'username': username,
  'custom': '',
  'status_id': 1,
  'is_bot': bot,
  'created_at': _at,
  'updated_at': _at,
};

Map<String, dynamic> _room(String id, {int type = 1, int position = 0, String? parent}) => {
  'id': id,
  'space_id': 's-1',
  'parent_id': parent,
  'type': type,
  'name': id,
  'position': position,
  'created_at': _at,
  'updated_at': _at,
};

Map<String, dynamic> _role(String id, String name, int perms, {int position = 1}) => {
  'id': id,
  'space_id': 's-1',
  'name': name,
  'permissions': perms,
  'position': position,
  'created_at': _at,
  'updated_at': _at,
};

Map<String, dynamic> _overwrite(String room, String target, {int type = 0, int allow = 0, int deny = 0}) => {
  'id': '$room-$target',
  'room_id': room,
  'target_id': target,
  'target_type': type,
  'allow_flags': allow,
  'deny_flags': deny,
  'created_at': _at,
  'updated_at': _at,
};

/// A member of s-1, as the members list gives them.
Map<String, dynamic> _member(String memberId, String userId, String username) => {
  'id': memberId,
  'space_id': 's-1',
  'user_id': userId,
  'created_at': _at,
  'updated_at': _at,
  'user': _user(userId, username),
  'max_pos': -1,
};

/// Maya's Space, where the user has [roles] beside the default one (whose ID
/// is the Space's).
Map<String, dynamic> _space({
  Map<String, Map<String, dynamic>>? rooms,
  Map<String, int> roles = const {},
  List<String> mine = const [],
  Map<String, List<Map<String, dynamic>>>? overwrites,
  int everyone = Perm.viewChannels | Perm.sendMessages,
}) => {
  'space': {'id': 's-1', 'name': 'Duvet Official', 'owner_id': _maya, 'created_at': _at, 'updated_at': _at},
  'rooms': rooms ?? {'r-general': _room('r-general')},
  'roles_permissions': {
    's-1': _role('s-1', 'everyone', everyone, position: 0),
    for (final e in roles.entries) e.key: _role(e.key, e.key, e.value),
  },
  'member_roles': {
    _me: ['s-1', ...mine],
    _maya: ['s-1'],
  },
  'overwrites': ?overwrites,
  'owner_id': _maya,
};

void main() {
  late List<http.Request> requests;
  late Map<(String, String), Object? Function(http.Request request)> routes;
  late DuvetRepository repository;

  setUp(() {
    requests = [];
    routes = {
      ('POST', '/api/auth/login'): (_) => {'token': 'access-1', 'session_token': 'refresh-1'},
      ('GET', '/api/users/@me'): (_) => {..._user(_me, 'gaby'), 'email_verified': true},
      ('GET', '/api/users/@me/conversations'): (_) => <Object>[],
    };
    final client = MockClient((request) async {
      requests.add(request);
      final json = routes[(request.method, request.url.path)]?.call(request);
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

  Future<void> signIn() async {
    await repository.logIn('gaby@duvet.chat', 'secret');
    await pumpEventQueue();
  }

  group('roles', () {
    test('the default role is left out by its ID: the API names it "everyone"', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages}, mine: ['role-mod'])));
      expect(repository.rolesOf('s-1', _me).map((r) => r.name), ['role-mod']);
      expect(repository.spaceRoles('s-1').map((r) => r.id), ['role-mod']);
    });

    // The members list names each member's ID, which the API's role routes and
    // events take.
    void members() => routes[('GET', '/api/spaces/s-1/members')] = (_) => [
      _member('mem-me', _me, 'gaby'),
      _member('mem-maya', _maya, 'maya'),
    ];
    int memberFetches() => requests.where((r) => r.url.path == '/api/spaces/s-1/members').length;

    test('giving and taking a role names the member by their member ID', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      members();
      routes[('PUT', '/api/spaces/s-1/members/mem-maya/roles/role-mod')] = (_) => http.Response('', 204);
      routes[('DELETE', '/api/spaces/s-1/members/mem-maya/roles/role-mod')] = (_) => http.Response('', 204);

      // The members list wasn't loaded: it is, for the ID.
      await repository.setRole('s-1', 'role-mod', _maya, has: true);
      expect(
        (requests.last.method, requests.last.url.path),
        ('PUT', '/api/spaces/s-1/members/mem-maya/roles/role-mod'),
      );
      expect(repository.roleMembers('s-1', 'role-mod'), [_maya]);

      await repository.setRole('s-1', 'role-mod', _maya, has: false);
      expect(requests.last.url.path, '/api/spaces/s-1/members/mem-maya/roles/role-mod');
      expect(repository.roleMembers('s-1', 'role-mod'), isEmpty);
      expect(memberFetches(), 1);
    });

    test('someone the members list doesn\'t have can\'t be given a role', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      members();
      await expectLater(
        repository.setRole('s-1', 'role-mod', _leo, has: true),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'Member not found')),
      );
      expect(requests.where((r) => r.method == 'PUT'), isEmpty);
    });

    test('live role changes reach the member they name, by member ID', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      members();
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));

      repository.handleEvent(
        _event('MEMBER_ROLE_ADD', {'member_id': 'mem-maya', 'role_id': 'role-mod', 'space_id': 's-1'}),
      );
      expect(repository.rolesOf('s-1', _maya).map((r) => r.name), ['role-mod']);
      expect(repository.roleMembers('s-1', 'role-mod'), [_maya]);

      // MEMBER_ROLE_REMOVE names no Space: the role's own tells it.
      repository.handleEvent(_event('MEMBER_ROLE_REMOVE', {'member_id': 'mem-maya', 'role_id': 'role-mod'}));
      expect(repository.rolesOf('s-1', _maya), isEmpty);
      expect(memberFetches(), 1);
    });

    test('a role of the user\'s own, before the members list named them, changes what they may do', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      members();
      expect(repository.canInRoom('s-1', 'r-general', Perm.pinMessages), isFalse);

      repository.handleEvent(
        _event('MEMBER_ROLE_ADD', {'member_id': 'mem-me', 'role_id': 'role-mod', 'space_id': 's-1'}),
      );
      await pumpEventQueue();
      expect(repository.canInRoom('s-1', 'r-general', Perm.pinMessages), isTrue);
      expect(memberFetches(), 1);
    });

    test('role changes waiting for the members list apply in the order they came', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      members();
      // Leo's role comes first, then his arrival names him, then he loses it.
      repository.handleEvent(
        _event('MEMBER_ROLE_ADD', {'member_id': 'mem-leo', 'role_id': 'role-mod', 'space_id': 's-1'}),
      );
      repository.handleEvent(
        _event('SPACE_MEMBER_ADD', {'space_id': 's-1', 'user_id': _leo, 'member_id': 'mem-leo', 'status_id': 1}),
      );
      repository.handleEvent(_event('MEMBER_ROLE_REMOVE', {'member_id': 'mem-leo', 'role_id': 'role-mod'}));
      await pumpEventQueue();
      expect(repository.rolesOf('s-1', _leo), isEmpty);
    });

    test('someone who joins brings their member ID: their roles need no members list', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      repository.handleEvent(
        _event('SPACE_MEMBER_ADD', {'space_id': 's-1', 'user_id': _leo, 'member_id': 'mem-leo', 'status_id': 1}),
      );
      repository.handleEvent(
        _event('MEMBER_ROLE_ADD', {'member_id': 'mem-leo', 'role_id': 'role-mod', 'space_id': 's-1'}),
      );
      expect(repository.rolesOf('s-1', _leo).map((r) => r.name), ['role-mod']);
      expect(memberFetches(), 0);
    });
  });

  group('rooms the user can\'t see', () {
    List<String> listed() => [for (final r in repository.spaces.value.single.rooms) r.id];
    List<String?> sections() => [for (final s in repository.spaces.value.single.sections) s.name];

    // #mods is for the mods: @everyone can't see it.
    Map<String, dynamic> guild({List<String> mine = const []}) => _space(
      rooms: {
        'r-general': _room('r-general'),
        'r-mods': _room('r-mods', position: 1),
        'r-voice': _room('r-voice', type: 2, position: 2),
      },
      roles: {'role-mod': Perm.pinMessages},
      mine: mine,
      overwrites: {
        'r-mods': [
          _overwrite('r-mods', 's-1', deny: Perm.viewChannels),
          _overwrite('r-mods', 'role-mod', allow: Perm.viewChannels),
        ],
      },
    );

    test('aren\'t listed, and show once the user may see them', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      expect(listed(), ['r-general', 'r-voice']);
      expect(repository.adminRooms('s-1').map((r) => r.id), ['r-general', 'r-voice']);

      // Given the role: the gateway names the user's member.
      routes[('GET', '/api/spaces/s-1/members')] = (_) => [_member('mem-me', _me, 'gaby')];
      repository.handleEvent(
        _event('MEMBER_ROLE_ADD', {'member_id': 'mem-me', 'role_id': 'role-mod', 'space_id': 's-1'}),
      );
      await pumpEventQueue();
      expect(listed(), ['r-general', 'r-mods', 'r-voice']);
    });

    test('an overwrite that hides a room takes it away, and one that\'s gone brings it back', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      repository.handleEvent(_event('ROOM_OVERWRITE_UPDATE', _overwrite('r-voice', 's-1', deny: Perm.viewChannels)));
      expect(listed(), ['r-general']);
      repository.handleEvent(_event('ROOM_OVERWRITE_DELETE', {'room_id': 'r-voice', 'target_id': 's-1'}));
      expect(listed(), ['r-general', 'r-voice']);
    });

    test('a category shows while it has no rooms or one the user sees, as on the desktop', () async {
      await signIn();
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            rooms: {
              'c-talk': _room('c-talk', type: 3),
              'r-general': _room('r-general', parent: 'c-talk'),
              'c-staff': _room('c-staff', type: 3, position: 1),
              'r-mods': _room('r-mods', parent: 'c-staff'),
              'c-empty': _room('c-empty', type: 3, position: 2),
            },
            overwrites: {
              'r-mods': [_overwrite('r-mods', 's-1', deny: Perm.viewChannels)],
            },
          ),
        ),
      );
      expect(sections(), ['c-talk', 'c-empty']);
      expect(listed(), ['r-general']);
      expect(repository.adminRooms('s-1').map((r) => r.id), ['c-talk', 'r-general', 'c-empty']);
    });

    test('a room the user may see stays listed when its category can\'t be', () async {
      await signIn();
      // @everyone sees nothing: categories take no overwrites, so none shows,
      // but the mods' room lets them in.
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            everyone: Perm.sendMessages,
            rooms: {
              'c-staff': _room('c-staff', type: 3),
              'r-mods': _room('r-mods', parent: 'c-staff'),
              'r-general': _room('r-general', position: 1),
            },
            roles: {'role-mod': Perm.pinMessages},
            mine: ['role-mod'],
            overwrites: {
              'r-mods': [_overwrite('r-mods', 'role-mod', allow: Perm.viewChannels)],
            },
          ),
        ),
      );
      expect(sections(), [null]);
      expect(listed(), ['r-mods']);
    });
  });

  group('rooms in order', () {
    // A Space with a room outside any category, and a category of two.
    Map<String, dynamic> guild() => _space(
      rooms: {
        'r-general': _room('r-general'),
        'c-talk': _room('c-talk', type: 3, position: 1),
        'r-crit': _room('r-crit', parent: 'c-talk'),
        'r-lounge': _room('r-lounge', type: 2, position: 1, parent: 'c-talk'),
      },
    );
    Map<String?, List<String>> sections() => {
      for (final s in repository.spaces.value.single.sections) s.name: [for (final r in s.rooms) r.id],
    };

    test('a deleted category leaves its rooms outside any, as the API does', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      expect(sections(), {
        null: ['r-general'],
        'c-talk': ['r-crit', 'r-lounge'],
      });
      repository.handleEvent(_event('ROOM_DELETE', {'id': 'c-talk', 'space_id': 's-1'}));
      expect(sections(), {
        null: ['r-general', 'r-crit', 'r-lounge'],
      });
      expect(repository.adminRooms('s-1').map((r) => (r.id, r.parentId)), [
        ('r-general', null),
        ('r-crit', null),
        ('r-lounge', null),
      ]);
    });

    test('deleting a category here does the same', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      routes[('DELETE', '/api/spaces/s-1/rooms/c-talk')] = (_) => http.Response('', 204);
      await repository.deleteRoom('s-1', 'c-talk');
      expect(sections(), {
        null: ['r-general', 'r-crit', 'r-lounge'],
      });
      expect(repository.adminRooms('s-1').map((r) => r.parentId), [null, null, null]);
    });

    test('ROOM_REORDER moves every room it lists, into or out of categories', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      // Someone moved #lounge to the top, and #general into Talk, first.
      repository.handleEvent(
        _event('ROOM_REORDER', {
          'rooms': [
            _room('r-lounge', type: 2),
            _room('c-talk', type: 3, position: 1),
            _room('r-general', parent: 'c-talk'),
            _room('r-crit', position: 1, parent: 'c-talk'),
          ],
        }),
      );
      expect(sections(), {
        null: ['r-lounge'],
        'c-talk': ['r-general', 'r-crit'],
      });
    });

    // The rooms' PATCH, answering the room as the API would.
    void patches() => routes[('PATCH', '/api/spaces/s-1/rooms/r-general')] = (request) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return {..._room('r-general'), 'parent_id': body['parent_id'], 'position': body['position'] ?? 0};
    };
    Map<String, dynamic> sent() => jsonDecode(requests.last.body) as Map<String, dynamic>;

    test('a room moves into a category first, as the desktop drops one in', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      patches();
      await repository.setRoomCategory('s-1', 'r-general', 'c-talk');
      expect(requests.last.method, 'PATCH');
      expect(sent(), {'parent_id': 'c-talk', 'position': 0});
    });

    test('a room leaves its category for the end of the rooms outside any', () async {
      await signIn();
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            rooms: {
              'c-talk': _room('c-talk', type: 3),
              'r-general': _room('r-general', parent: 'c-talk'),
              'r-news': _room('r-news', position: 4),
              'r-rules': _room('r-rules', position: 2),
            },
          ),
        ),
      );
      patches();
      await repository.setRoomCategory('s-1', 'r-general', null);
      expect(sent(), {'parent_id': null, 'position': 5});
    });

    test('moving a room sends the position as the API takes it', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      patches();
      await repository.moveRoom('s-1', 'r-general', 2);
      expect(sent(), {'position': 2});
    });
  });

  test('ManageChannels counts room by room: a room\'s overwrite lets the user run it, and Space settings', () async {
    await signIn();
    repository.handleEvent(
      _event(
        'SPACE_CREATE',
        _space(
          rooms: {'r-general': _room('r-general'), 'r-mods': _room('r-mods', position: 1)},
          roles: {'role-mod': Perm.pinMessages},
          mine: ['role-mod'],
          overwrites: {
            'r-mods': [_overwrite('r-mods', 'role-mod', allow: Perm.manageChannels)],
          },
        ),
      ),
    );
    final profile = repository.spaceProfile('s-1')!;
    // Not in the Space: no new rooms.
    expect(profile.can(Perm.manageChannels), isFalse);
    expect(repository.canInRoom('s-1', 'r-mods', Perm.manageChannels), isTrue);
    expect(repository.canInRoom('s-1', 'r-general', Perm.manageChannels), isFalse);
    expect(profile.managesRooms, isTrue);
    expect(profile.helpsRun, isTrue);
  });

  test('"As the role says" deletes an overwrite only where there is one: the API answers 404 otherwise', () async {
    await signIn();
    repository.handleEvent(
      _event(
        'SPACE_CREATE',
        _space(
          roles: {'role-mod': Perm.pinMessages},
          overwrites: {
            'r-general': [_overwrite('r-general', 's-1', deny: Perm.sendMessages)],
          },
        ),
      ),
    );
    routes[('DELETE', '/api/spaces/s-1/rooms/r-general/overwrites/s-1')] = (_) => http.Response('', 204);
    final before = requests.length;
    await repository.setOverwrite('s-1', 'r-general', const RoomOverwrite(targetId: 'role-mod'));
    expect(requests.length, before);

    await repository.setOverwrite('s-1', 'r-general', const RoomOverwrite(targetId: 's-1'));
    expect(
      (requests.last.method, requests.last.url.path),
      ('DELETE', '/api/spaces/s-1/rooms/r-general/overwrites/s-1'),
    );
    expect(repository.overwrites('s-1', 'r-general'), isEmpty);
  });

  group('a refusal says why, as the desktop shows the API\'s reason', () {
    late String upload;

    setUp(() {
      final dir = Directory.systemTemp.createTempSync('duvet_refusals');
      addTearDown(() => dir.deleteSync(recursive: true));
      upload = '${dir.path}/party.png';
      File(upload).writeAsBytesSync(const [1, 2, 3]);
    });

    Future<void> refuses(
      String method,
      String path,
      Future<void> Function() call, {
      int status = 403,
      String reason = 'you don\'t have permission to do that',
    }) async {
      routes[(method, path)] = (_) =>
          http.Response(jsonEncode({'error': reason}), status, headers: {'content-type': 'application/json'});
      await expectLater(
        call(),
        throwsA(
          isA<ActionFailed>().having((e) => e.message, 'message', '${reason[0].toUpperCase()}${reason.substring(1)}'),
        ),
        reason: '$method $path',
      );
    }

    test('rooms, overwrites, roles, emojis, stickers, invites, joining and bots', () async {
      await signIn();
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            roles: {'role-mod': Perm.pinMessages},
            overwrites: {
              'r-general': [_overwrite('r-general', 's-1', deny: Perm.sendMessages)],
            },
          ),
        ),
      );
      routes[('GET', '/api/spaces/s-1/members')] = (_) => [_member('mem-maya', _maya, 'maya')];

      await refuses('POST', '/api/spaces/s-1/rooms', () => repository.createRoom('s-1', 'crit', AdminRoomKind.text));
      await refuses('PATCH', '/api/spaces/s-1/rooms/r-general', () => repository.renameRoom('s-1', 'r-general', 'x'));
      await refuses('PATCH', '/api/spaces/s-1/rooms/r-general', () => repository.moveRoom('s-1', 'r-general', 1));
      await refuses(
        'PATCH',
        '/api/spaces/s-1/rooms/r-general',
        () => repository.setRoomCategory('s-1', 'r-general', null),
        status: 400,
        reason: 'parent_id must be a category of this space',
      );
      await refuses('DELETE', '/api/spaces/s-1/rooms/r-general', () => repository.deleteRoom('s-1', 'r-general'));
      await refuses(
        'PUT',
        '/api/spaces/s-1/rooms/r-general/overwrites',
        () => repository.setOverwrite(
          's-1',
          'r-general',
          const RoomOverwrite(targetId: 'role-mod', allow: Perm.pinMessages),
        ),
        reason: 'you cannot grant or deny permissions you don\'t have',
      );
      await refuses(
        'DELETE',
        '/api/spaces/s-1/rooms/r-general/overwrites/s-1',
        () => repository.setOverwrite('s-1', 'r-general', const RoomOverwrite(targetId: 's-1')),
      );
      await refuses('POST', '/api/spaces/s-1/roles', () => repository.createRole('s-1', 'Hosts'));
      await refuses(
        'PATCH',
        '/api/spaces/s-1/roles/role-mod',
        () => repository.updateRole('s-1', 'role-mod', name: 'Mods'),
        reason: 'you cannot manage a role higher than or equal to your highest role',
      );
      await refuses('DELETE', '/api/spaces/s-1/roles/role-mod', () => repository.deleteRole('s-1', 'role-mod'));
      await refuses(
        'PUT',
        '/api/spaces/s-1/members/mem-maya/roles/role-mod',
        () => repository.setRole('s-1', 'role-mod', _maya, has: true),
      );
      await refuses(
        'POST',
        '/api/spaces/s-1/rooms/r-general/invites',
        () => repository.createInvite('s-1', 'r-general'),
        reason: 'you don\'t have permission to create invite links for this space',
      );
      await refuses('DELETE', '/api/spaces/s-1/invites/i-1', () => repository.revokeInvite('s-1', 'i-1'));
      await refuses(
        'POST',
        '/api/spaces/s-1/emojis',
        () => repository.addAsset('s-1', AssetKind.emoji, 'party', upload),
        status: 422,
        reason: 'this space does not have a storage bucket configured',
      );
      await refuses(
        'POST',
        '/api/spaces/s-1/stickers',
        () => repository.addAsset('s-1', AssetKind.sticker, 'party', upload),
        status: 400,
        reason: 'invalid image: sticker images can be 512 KiB at most',
      );
      await refuses(
        'PATCH',
        '/api/spaces/s-1/emojis/e-1',
        () => repository.renameAsset('s-1', AssetKind.emoji, 'e-1', 'cake'),
      );
      await refuses(
        'DELETE',
        '/api/spaces/s-1/stickers/st-1',
        () => repository.deleteAsset('s-1', AssetKind.sticker, 'st-1'),
      );
      await refuses(
        'GET',
        '/api/invites/k7Qe2m',
        () => repository.invite('k7Qe2m'),
        status: 404,
        reason: 'invite link not found or has expired',
      );
      await refuses(
        'POST',
        '/api/invites/k7Qe2m/join',
        () => repository.joinInvite('k7Qe2m'),
        status: 400,
        reason: 'you cannot be in more than 100 spaces',
      );
      await refuses(
        'POST',
        '/api/spaces/s-1/bots/b-1',
        () => repository.addBot('s-1', 'b-1'),
        reason: 'this bot is private — only team members can add it',
      );
    });

    test('without a connection, it says so', () async {
      await signIn();
      routes[('POST', '/api/invites/k7Qe2m/join')] = (_) => throw const SocketException('no network');
      await expectLater(
        repository.joinInvite('k7Qe2m'),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'No connection. Check it and try again.')),
      );
    });
  });

  group('a Space\'s storage', () {
    void storage() {
      routes[('GET', '/api/spaces/s-1/attachments/storage')] = (_) => {'total_size': 3072};
      routes[('GET', '/api/spaces/s-1/attachments')] = (_) => [
        {'id': 'a-1', 'filename': 'poster.png', 'content_type': 'image/png', 'size_bytes': 3072, 'created_at': _at},
      ];
      routes[('GET', '/api/spaces/s-1/buckets')] = (_) => [
        {
          'id': 'b-1',
          'owner_id': 's-1',
          'name': 'Guild bucket',
          'endpoint': 'https://s3.example.com',
          'bucket_name': 'guild',
          'access_key_id': 'key',
          'is_active': true,
          'used_bytes': 3072,
          'created_at': _at,
          'updated_at': _at,
        },
      ];
    }

    int bucketReads() => requests.where((r) => r.url.path == '/api/spaces/s-1/buckets').length;

    test('with ManageSpaceAttachments alone: its files, and no buckets, which take ManageSpaceBuckets', () async {
      await signIn();
      repository.handleEvent(
        _event('SPACE_CREATE', _space(roles: {'role-files': Perm.manageAttachments}, mine: ['role-files'])),
      );
      storage();
      // As the API answers them.
      routes[('GET', '/api/spaces/s-1/buckets')] = (_) => http.Response(
        jsonEncode({'error': 'you don\'t have permission to manage storage buckets for this space'}),
        403,
        headers: {'content-type': 'application/json'},
      );
      final s = await repository.spaceStorage('s-1');
      expect((s.used, s.files.single.name), (3072, 'poster.png'));
      expect(s.buckets, isEmpty);
      expect(bucketReads(), 0);
    });

    test('with ManageSpaceBuckets: its buckets too', () async {
      await signIn();
      repository.handleEvent(
        _event('SPACE_CREATE', _space(roles: {'role-store': Perm.manageBuckets}, mine: ['role-store'])),
      );
      storage();
      final s = await repository.spaceStorage('s-1');
      expect(s.buckets.single.name, 'Guild bucket');
      expect(bucketReads(), 1);
    });
  });

  test('a bot\'s invite card is for bots: anyone else is refused, as on the desktop', () async {
    await signIn();
    routes[('GET', '/api/users/u-maya')] = (_) => _user('u-maya', 'maya');
    routes[('GET', '/api/users/u-ballot')] = (_) => _user('u-ballot', 'ballot', bot: true);
    expect((await repository.bot('u-ballot')).name, 'ballot');
    await expectLater(
      repository.bot('u-maya'),
      throwsA(isA<ActionFailed>().having((e) => e.message, 'message', 'This user is not a bot.')),
    );
  });
}
