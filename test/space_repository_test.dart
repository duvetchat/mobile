import 'dart:async';
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

import 'support/eventually.dart';

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

Map<String, dynamic> _room(String id, {int type = 1, int position = 0, String? parent, String? description}) => {
  'id': id,
  'space_id': 's-1',
  'parent_id': parent,
  'type': type,
  'name': id,
  'description': ?description,
  'position': position,
  'created_at': _at,
  'updated_at': _at,
};

Map<String, dynamic> _role(String id, String name, int perms, {int position = 1, bool hoisted = false}) => {
  'id': id,
  'space_id': 's-1',
  'name': name,
  'permissions': perms,
  'position': position,
  'hoisted': hoisted,
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

/// Another of the user's Spaces, with no rooms: [id] and [name] are all that
/// tells it apart.
Map<String, dynamic> _spaceOf(String id, String name, {String? banner}) => {
  'space': {'id': id, 'name': name, 'owner_id': _maya, 'banner': ?banner, 'created_at': _at, 'updated_at': _at},
  'rooms': <String, dynamic>{},
  'roles_permissions': {id: _role(id, 'everyone', Perm.viewChannels, position: 0)},
  'member_roles': {
    _me: [id],
  },
  'owner_id': _maya,
};

/// A cache store whose read of the folded categories waits for [release].
class _SlowCollapsed extends MemoryChatCacheStore {
  final release = Completer<void>();
  @override
  Future<String?> read(String key) async {
    if (key == 'collapsed') await release.future;
    return super.read(key);
  }
}

void main() {
  late List<http.Request> requests;
  late Map<(String, String), Object? Function(http.Request request)> routes;
  late DuvetRepository repository;
  late http.Client client;
  late MemoryChatCacheStore cache;

  setUp(() {
    requests = [];
    routes = {
      ('POST', '/api/auth/login'): (_) => {'token': 'access-1', 'session_token': 'refresh-1'},
      ('GET', '/api/users/@me'): (_) => {..._user(_me, 'gaby'), 'email_verified': true},
      ('GET', '/api/users/@me/conversations'): (_) => <Object>[],
    };
    client = MockClient((request) async {
      requests.add(request);
      var json = routes[(request.method, request.url.path)]?.call(request);
      // A route may answer later, as a request still on its way.
      if (json is Future<Object?>) json = await json;
      if (json is http.Response) return json;
      if (json == null) return http.Response('not found', 404);
      return http.Response(jsonEncode(json), 200, headers: {'content-type': 'application/json'});
    });
    repository = DuvetRepository(
      store: MemorySessionStore(),
      recentsStore: MemoryRecentChatsStore(),
      httpClient: () => client,
      connectGateway: false,
      cacheStore: cache = MemoryChatCacheStore(),
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

    // Who the API lists, as it changes; while [down], the list fails.
    late List<Map<String, dynamic>> listed;
    late bool down;
    void changingMembers() {
      listed = [_member('mem-me', _me, 'gaby'), _member('mem-maya', _maya, 'maya')];
      down = false;
      routes[('GET', '/api/spaces/s-1/members')] = (_) => down
          ? http.Response(
              jsonEncode({'error': 'internal server error'}),
              500,
              headers: {'content-type': 'application/json'},
            )
          : listed;
    }

    Map<String, dynamic> roleAdd(String member) => {'member_id': member, 'role_id': 'role-mod', 'space_id': 's-1'};

    test('the members list cached before someone joined unseen is fetched again for their role', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      changingMembers();
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      // Leo joins while the app isn't listening: no SPACE_MEMBER_ADD.
      listed.add(_member('mem-leo', _leo, 'leo'));
      repository.handleEvent(_event('MEMBER_ROLE_ADD', roleAdd('mem-leo')));
      await pumpEventQueue();
      expect(repository.rolesOf('s-1', _leo).map((r) => r.name), ['role-mod']);
      expect(memberFetches(), 2);
    });

    test('a role change whose members list fails waits for the next list', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      changingMembers();
      down = true;
      repository.handleEvent(_event('MEMBER_ROLE_ADD', roleAdd('mem-maya')));
      await pumpEventQueue();
      expect(repository.rolesOf('s-1', _maya), isEmpty);

      // The next list, whoever asks for it, names her.
      down = false;
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      expect(repository.rolesOf('s-1', _maya).map((r) => r.name), ['role-mod']);
    });

    test('a role change that can\'t be placed yet waits for its member\'s SPACE_MEMBER_ADD', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      changingMembers();
      down = true;
      repository.handleEvent(_event('MEMBER_ROLE_ADD', roleAdd('mem-leo')));
      await pumpEventQueue();
      repository.handleEvent(
        _event('SPACE_MEMBER_ADD', {'space_id': 's-1', 'user_id': _leo, 'member_id': 'mem-leo', 'status_id': 1}),
      );
      expect(repository.rolesOf('s-1', _leo).map((r) => r.name), ['role-mod']);
    });

    test('a new session\'s SPACE_CREATE outdates the role changes still waiting', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      changingMembers();
      down = true;
      repository.handleEvent(_event('MEMBER_ROLE_ADD', roleAdd('mem-maya')));
      await pumpEventQueue();
      // The role was taken back while the app was away: the new snapshot says so.
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      down = false;
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      expect(repository.rolesOf('s-1', _maya), isEmpty);
    });

    test('READY after a drop forgets the members lists: who joined or left meanwhile shows', () async {
      await signIn();
      final ready = _event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'});
      repository.handleEvent(ready);
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      changingMembers();
      routes[('PUT', '/api/spaces/s-1/members/mem-maya-2/roles/role-mod')] = (_) => http.Response('', 204);
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      // Maya left and came back while the socket was down: a new member ID.
      listed[1] = _member('mem-maya-2', _maya, 'maya');
      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      repository.handleEvent(ready);
      await repository.setRole('s-1', 'role-mod', _maya, has: true);
      expect(requests.last.url.path, '/api/spaces/s-1/members/mem-maya-2/roles/role-mod');
      expect(memberFetches(), 2);
    });

    test('a members list fetched again replaces the member IDs it had', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      changingMembers();
      routes[('PUT', '/api/spaces/s-1/members/mem-maya-2/roles/role-mod')] = (_) => http.Response('', 204);
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      listed[1] = _member('mem-maya-2', _maya, 'maya');
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'), refresh: true);
      await repository.setRole('s-1', 'role-mod', _maya, has: true);
      expect(requests.last.url.path, '/api/spaces/s-1/members/mem-maya-2/roles/role-mod');
    });

    Map<String, dynamic> joined(String user, String member) => {
      'space_id': 's-1',
      'user_id': user,
      'member_id': member,
      'status_id': 1,
    };

    test('who joins while the members list comes keeps their member ID: the list may be from before', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      routes[('GET', '/api/spaces/s-1/members')] = (_) {
        // Read before Leo joined, the list lands after his SPACE_MEMBER_ADD.
        if (memberFetches() == 1) repository.handleEvent(_event('SPACE_MEMBER_ADD', joined(_leo, 'mem-leo')));
        return [_member('mem-me', _me, 'gaby'), _member('mem-maya', _maya, 'maya')];
      };
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      repository.handleEvent(_event('MEMBER_ROLE_ADD', roleAdd('mem-leo')));
      expect(repository.rolesOf('s-1', _leo).map((r) => r.name), ['role-mod']);
      expect(memberFetches(), 1);
    });

    test('who leaves and comes back while the members list comes goes by their new member ID', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      routes[('GET', '/api/spaces/s-1/members')] = (_) {
        // The list has Maya's old member ID: she left and came back before it
        // landed.
        if (memberFetches() == 1) {
          repository.handleEvent(
            _event('SPACE_MEMBER_REMOVE', {'space_id': 's-1', 'user_id': _maya, 'member_id': 'mem-maya'}),
          );
          repository.handleEvent(_event('SPACE_MEMBER_ADD', joined(_maya, 'mem-maya-2')));
        }
        return [_member('mem-me', _me, 'gaby'), _member('mem-maya', _maya, 'maya')];
      };
      routes[('PUT', '/api/spaces/s-1/members/mem-maya-2/roles/role-mod')] = (_) => http.Response('', 204);
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      await repository.setRole('s-1', 'role-mod', _maya, has: true);
      expect(requests.last.url.path, '/api/spaces/s-1/members/mem-maya-2/roles/role-mod');
      expect(memberFetches(), 1);
    });

    test('leaving a Space forgets its member IDs: back in it, a role goes by the member ID of now', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      changingMembers();
      routes[('DELETE', '/api/spaces/s-1/members/@me')] = (_) => http.Response('', 204);
      routes[('PUT', '/api/spaces/s-1/members/mem-maya-2/roles/role-mod')] = (_) => http.Response('', 204);
      await repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      await repository.leaveSpace('s-1');
      // Maya left and came back while the user was away: no event said so.
      listed[1] = _member('mem-maya-2', _maya, 'maya');
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      await repository.setRole('s-1', 'role-mod', _maya, has: true);
      expect(requests.last.url.path, '/api/spaces/s-1/members/mem-maya-2/roles/role-mod');
      expect(memberFetches(), 2);
    });

    test('a members list on its way as the user leaves names no one, and doesn\'t hold up the next', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      final held = Completer<void>();
      routes[('GET', '/api/spaces/s-1/members')] = (_) async {
        // The first, from before the user left, lands once they're back.
        if (memberFetches() == 1) {
          await held.future;
          return [_member('mem-me-old', _me, 'gaby'), _member('mem-maya-old', _maya, 'maya')];
        }
        return [_member('mem-me', _me, 'gaby'), _member('mem-maya', _maya, 'maya'), _member('mem-leo', _leo, 'leo')];
      };
      routes[('DELETE', '/api/spaces/s-1/members/@me')] = (_) => http.Response('', 204);
      routes[('PUT', '/api/spaces/s-1/members/mem-maya/roles/role-mod')] = (_) => http.Response('', 204);
      // A role for someone not named yet asks for the list.
      repository.handleEvent(_event('MEMBER_ROLE_ADD', roleAdd('mem-leo')));
      await pumpEventQueue();
      await repository.leaveSpace('s-1');
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      // Back in the Space, another asks for it again.
      repository.handleEvent(_event('MEMBER_ROLE_ADD', roleAdd('mem-leo')));
      await pumpEventQueue();
      expect(memberFetches(), 2);
      expect(repository.rolesOf('s-1', _leo).map((r) => r.name), ['role-mod']);

      held.complete();
      await pumpEventQueue();
      await repository.setRole('s-1', 'role-mod', _maya, has: true);
      expect(requests.last.url.path, '/api/spaces/s-1/members/mem-maya/roles/role-mod');
      expect(memberFetches(), 2);
    });

    test('a members list on its way as the socket drops names no one once READY comes again', () async {
      await signIn();
      final ready = _event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'});
      repository.handleEvent(ready);
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      final held = Completer<void>();
      routes[('GET', '/api/spaces/s-1/members')] = (_) async {
        if (memberFetches() == 1) {
          await held.future;
          return [_member('mem-me', _me, 'gaby'), _member('mem-maya', _maya, 'maya')];
        }
        return [_member('mem-me', _me, 'gaby'), _member('mem-maya-2', _maya, 'maya')];
      };
      routes[('PUT', '/api/spaces/s-1/members/mem-maya-2/roles/role-mod')] = (_) => http.Response('', 204);
      final first = repository.members(const RoomTarget(spaceId: 's-1', roomId: 'r-general'));
      await pumpEventQueue();
      // Maya left and came back while the socket was down; the list on its
      // way lands after READY, with her old member ID.
      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      repository.handleEvent(ready);
      held.complete();
      await first;
      await repository.setRole('s-1', 'role-mod', _maya, has: true);
      expect(requests.last.url.path, '/api/spaces/s-1/members/mem-maya-2/roles/role-mod');
      expect(memberFetches(), 2);
    });

    test('a lookup on its way as the socket drops doesn\'t hold up the next one once READY comes again', () async {
      await signIn();
      final ready = _event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws'});
      repository.handleEvent(ready);
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      final held = Completer<void>();
      routes[('GET', '/api/spaces/s-1/members')] = (_) async {
        if (memberFetches() == 1) {
          await held.future;
          return [_member('mem-me', _me, 'gaby'), _member('mem-maya', _maya, 'maya')];
        }
        return [_member('mem-me', _me, 'gaby'), _member('mem-maya', _maya, 'maya'), _member('mem-leo', _leo, 'leo')];
      };
      // A role for someone not named yet asks for the members list.
      repository.handleEvent(
        _event('MEMBER_ROLE_ADD', {'member_id': 'mem-maya', 'role_id': 'role-mod', 'space_id': 's-1'}),
      );
      await pumpEventQueue();
      expect(memberFetches(), 1);
      // The socket drops and READY comes again with the Space; then a role for
      // someone else not named, before the old list lands.
      repository.handleConnectionState(duvet.GatewayConnectionState.reconnecting);
      repository.handleEvent(ready);
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      repository.handleEvent(
        _event('MEMBER_ROLE_ADD', {'member_id': 'mem-leo', 'role_id': 'role-mod', 'space_id': 's-1'}),
      );
      await pumpEventQueue();
      held.complete();
      await pumpEventQueue();
      expect(repository.rolesOf('s-1', _leo).map((r) => r.name), ['role-mod']);
    });

    test('a member\'s roles come highest first, with their IDs, places and whether they show apart', () async {
      await signIn();
      repository.handleEvent(
        _event('SPACE_CREATE', {
          ..._space(mine: ['role-low', 'role-high', 'role-mid']),
          'roles_permissions': {
            's-1': _role('s-1', 'everyone', Perm.viewChannels, position: 0),
            'role-low': _role('role-low', 'Low', 0),
            'role-high': _role('role-high', 'High', 0, position: 3, hoisted: true),
            'role-mid': _role('role-mid', 'Mid', 0, position: 2),
          },
        }),
      );
      expect(repository.rolesOf('s-1', _me).map((r) => (r.id, r.position, r.hoisted)), [
        ('role-high', 3, true),
        ('role-mid', 2, false),
        ('role-low', 1, false),
      ]);
      expect(
        {for (final r in repository.roles('s-1')) r.id: r.hoisted},
        {'s-1': false, 'role-low': false, 'role-high': true, 'role-mid': false},
      );
    });

    test('showing a role apart sends hoisted; a change that doesn\'t touch it leaves it out', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space(roles: {'role-mod': Perm.pinMessages})));
      routes[('PATCH', '/api/spaces/s-1/roles/role-mod')] = (request) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return _role('role-mod', 'role-mod', Perm.pinMessages, hoisted: body['hoisted'] as bool? ?? false);
      };
      Map<String, dynamic> sent() => jsonDecode(requests.last.body) as Map<String, dynamic>;

      await repository.updateRole('s-1', 'role-mod', hoisted: true);
      expect(sent()['hoisted'], isTrue);
      expect(repository.roles('s-1').singleWhere((r) => r.id == 'role-mod').hoisted, isTrue);

      await repository.updateRole('s-1', 'role-mod', name: 'Mods');
      expect(sent().containsKey('hoisted'), isFalse);
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

    test('a room that goes and comes back has only the overwrites it comes with', () async {
      // The gateway takes a room the user can no longer view away with
      // ROOM_DELETE, and brings it back with ROOM_CREATE and the overwrites it
      // has then: one deleted meanwhile never comes as an event.
      await signIn();
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            overwrites: {
              'r-general': [_overwrite('r-general', 's-1', deny: Perm.sendMessages)],
            },
          ),
        ),
      );
      expect(repository.canInRoom('s-1', 'r-general', Perm.sendMessages), isFalse);
      repository.handleEvent(_event('ROOM_DELETE', {'id': 'r-general', 'space_id': 's-1'}));
      repository.handleEvent(_event('ROOM_CREATE', _room('r-general')));
      expect(repository.overwrites('s-1', 'r-general'), isEmpty);
      expect(repository.canInRoom('s-1', 'r-general', Perm.sendMessages), isTrue);
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

    test('a room the user may see brings its category\'s header, though they can\'t see the category', () async {
      await signIn();
      // @everyone sees nothing: categories take no overwrites, so none is
      // seen, but the mods' room lets them in.
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            everyone: Perm.sendMessages,
            rooms: {
              'c-staff': _room('c-staff', type: 3),
              'r-mods': _room('r-mods', parent: 'c-staff'),
              'r-audit': _room('r-audit', position: 1, parent: 'c-staff'),
              'c-empty': _room('c-empty', type: 3, position: 1),
              'r-general': _room('r-general', position: 2),
            },
            roles: {'role-mod': Perm.pinMessages},
            mine: ['role-mod'],
            overwrites: {
              'r-mods': [_overwrite('r-mods', 'role-mod', allow: Perm.viewChannels)],
            },
          ),
        ),
      );
      // Only the rooms they see in it, and no category they can't see that
      // shows none.
      expect(sections(), ['c-staff']);
      expect(listed(), ['r-mods']);
      expect(repository.adminRooms('s-1').map((r) => r.id), ['c-staff', 'r-mods']);
    });

    test('give the user no other permission in them, as the API has it', () async {
      await signIn();
      // The helpers run rooms, pin and invite. @everyone can't see #mods, and
      // #logs lets the helpers in again.
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            rooms: {
              'r-general': _room('r-general'),
              'r-mods': _room('r-mods', position: 1),
              'r-logs': _room('r-logs', position: 2),
            },
            roles: {'role-helper': Perm.manageChannels | Perm.pinMessages | Perm.createInvites},
            mine: ['role-helper'],
            overwrites: {
              'r-mods': [_overwrite('r-mods', 's-1', deny: Perm.viewChannels)],
              'r-logs': [
                _overwrite('r-logs', 's-1', deny: Perm.viewChannels),
                _overwrite('r-logs', 'role-helper', allow: Perm.viewChannels),
              ],
            },
          ),
        ),
      );
      for (final bit in [Perm.sendMessages, Perm.manageChannels, Perm.pinMessages, Perm.createInvites]) {
        expect(repository.canInRoom('s-1', 'r-general', bit), isTrue, reason: 'bit $bit in #general');
        expect(repository.canInRoom('s-1', 'r-mods', bit), isFalse, reason: 'bit $bit in #mods');
        expect(repository.canInRoom('s-1', 'r-logs', bit), isTrue, reason: 'bit $bit in #logs');
      }
    });

    // Denied ViewChannels by @everyone's overwrite and their own.
    final hidden = {
      'r-mods': [
        _overwrite('r-mods', 's-1', deny: Perm.viewChannels),
        _overwrite('r-mods', _me, type: 1, deny: Perm.viewChannels),
      ],
    };

    test('an Administrator keeps every permission in them', () async {
      await signIn();
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            rooms: {'r-mods': _room('r-mods')},
            roles: {'role-admin': Perm.administrator},
            mine: ['role-admin'],
            overwrites: hidden,
          ),
        ),
      );
      expect(repository.canInRoom('s-1', 'r-mods', Perm.manageChannels), isTrue);
      expect(repository.canInRoom('s-1', 'r-mods', Perm.viewChannels), isTrue);
    });

    test('and so does the Space\'s owner', () async {
      await signIn();
      repository.handleEvent(
        _event('SPACE_CREATE', {
          ..._space(rooms: {'r-mods': _room('r-mods')}, overwrites: hidden),
          'space': {'id': 's-1', 'name': 'Duvet Official', 'owner_id': _me, 'created_at': _at, 'updated_at': _at},
          'owner_id': _me,
        }),
      );
      expect(repository.canInRoom('s-1', 'r-mods', Perm.manageChannels), isTrue);
      expect(repository.canInRoom('s-1', 'r-mods', Perm.viewChannels), isTrue);
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

    test('rooms that share a position go by ID, in the list and on the Rooms page alike (#59)', () async {
      await signIn();
      // Given in the order the gateway might send them: neither by ID.
      repository.handleEvent(
        _event(
          'SPACE_CREATE',
          _space(
            rooms: {
              'c-zeta': _room('c-zeta', type: 3),
              'c-alpha': _room('c-alpha', type: 3),
              'r-zeta': _room('r-zeta', parent: 'c-alpha'),
              'r-alpha': _room('r-alpha', parent: 'c-alpha'),
              'r-loose-b': _room('r-loose-b'),
              'r-loose-a': _room('r-loose-a'),
            },
          ),
        ),
      );
      expect(sections(), {
        null: ['r-loose-a', 'r-loose-b'],
        'c-alpha': ['r-alpha', 'r-zeta'],
        'c-zeta': <String>[],
      });
      expect(repository.adminRooms('s-1').map((r) => r.id), [
        'c-alpha',
        'c-zeta',
        'r-alpha',
        'r-loose-a',
        'r-loose-b',
        'r-zeta',
      ]);
    });

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

    // As the API deletes a category: ROOM_DELETE, then ROOM_REORDER with every
    // room of the Space, where the category's rooms follow the last place of
    // the top level (which the categories share), in the order they had. The
    // events may reach the phone before the user's own delete is answered, or
    // after it.
    for (final (before, answer) in [(2, 'after both events'), (1, 'between the events'), (0, 'before both events')]) {
      test('a deleted category\'s rooms go after the loose ones, in order, as ROOM_REORDER places them: '
          'the delete answered $answer', () async {
        await signIn();
        repository.handleEvent(
          _event(
            'SPACE_CREATE',
            _space(
              rooms: {
                'r-general': _room('r-general'),
                'r-rules': _room('r-rules', position: 1),
                'c-staff': _room('c-staff', type: 3, position: 2),
                'r-mods': _room('r-mods', parent: 'c-staff'),
                'c-talk': _room('c-talk', type: 3, position: 3),
                'r-crit': _room('r-crit', parent: 'c-talk'),
                'r-lounge': _room('r-lounge', type: 2, position: 1, parent: 'c-talk'),
              },
            ),
          ),
        );
        final events = [
          _event('ROOM_DELETE', {'id': 'c-talk', 'space_id': 's-1'}),
          _event('ROOM_REORDER', {
            'rooms': [
              _room('r-general'),
              _room('r-rules', position: 1),
              _room('c-staff', type: 3, position: 2),
              _room('r-mods', parent: 'c-staff'),
              _room('r-crit', position: 3),
              _room('r-lounge', type: 2, position: 4),
            ],
          }),
        ];
        Map<String, (String?, int)> places() => {
          for (final r in repository.adminRooms('s-1')) r.id: (r.parentId, r.position),
        };
        routes[('DELETE', '/api/spaces/s-1/rooms/c-talk')] = (_) {
          events.take(before).forEach(repository.handleEvent);
          return http.Response('', 204);
        };

        await repository.deleteRoom('s-1', 'c-talk');
        if (before == 0) {
          // Out of the category before ROOM_REORDER, after the top level's
          // last place, in their order: where it will put them.
          expect(places()['r-crit'], (null, 3));
          expect(places()['r-lounge'], (null, 4));
        }
        events.skip(before).forEach(repository.handleEvent);

        expect(sections(), {
          null: ['r-general', 'r-rules', 'r-crit', 'r-lounge'],
          'c-staff': ['r-mods'],
        });
        expect(places(), {
          'r-general': (null, 0),
          'r-rules': (null, 1),
          'c-staff': (null, 2),
          'r-mods': ('c-staff', 0),
          'r-crit': (null, 3),
          'r-lounge': (null, 4),
        });
      });
    }

    // As the API deletes a plain room: ROOM_DELETE, then, as the rooms after it
    // in its level moved up to close its place, ROOM_REORDER with every room of
    // the Space, the level numbered 0, 1, 2… again.
    for (final (before, answer) in [(2, 'after both events'), (1, 'between the events'), (0, 'before both events')]) {
      test('a deleted room\'s place closes up as ROOM_REORDER numbers its level again: '
          'the delete answered $answer', () async {
        await signIn();
        repository.handleEvent(
          _event(
            'SPACE_CREATE',
            _space(
              rooms: {
                'r-general': _room('r-general'),
                'c-talk': _room('c-talk', type: 3, position: 1),
                'r-crit': _room('r-crit', parent: 'c-talk'),
                'r-memes': _room('r-memes', position: 1, parent: 'c-talk'),
                'r-lounge': _room('r-lounge', type: 2, position: 2, parent: 'c-talk'),
              },
            ),
          ),
        );
        final events = [
          _event('ROOM_DELETE', {'id': 'r-memes', 'space_id': 's-1'}),
          _event('ROOM_REORDER', {
            'rooms': [
              _room('r-general'),
              _room('c-talk', type: 3, position: 1),
              _room('r-crit', parent: 'c-talk'),
              _room('r-lounge', type: 2, position: 1, parent: 'c-talk'),
            ],
          }),
        ];
        Map<String, (String?, int)> places() => {
          for (final r in repository.adminRooms('s-1')) r.id: (r.parentId, r.position),
        };
        routes[('DELETE', '/api/spaces/s-1/rooms/r-memes')] = (_) {
          events.take(before).forEach(repository.handleEvent);
          return http.Response('', 204);
        };

        await repository.deleteRoom('s-1', 'r-memes');
        events.skip(before).forEach(repository.handleEvent);

        expect(sections(), {
          null: ['r-general'],
          'c-talk': ['r-crit', 'r-lounge'],
        });
        expect(places(), {
          'r-general': (null, 0),
          'c-talk': (null, 1),
          'r-crit': ('c-talk', 0),
          'r-lounge': ('c-talk', 1),
        });
      });
    }

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

    test('a room moves into a category with its place there', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      patches();
      await repository.moveRoom('s-1', 'r-general', parentId: 'c-talk', position: 0);
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
      // As Move to… → No category places it: past the last room outside any.
      await repository.moveRoom('s-1', 'r-general', position: 5);
      expect(sent(), {'parent_id': null, 'position': 5});
    });

    test('moving a room sends the position as the API takes it', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      patches();
      await repository.moveRoom('s-1', 'r-general', position: 2);
      expect(sent(), {'parent_id': null, 'position': 2});
    });

    test('moves land where the user meant them, as the API places them', () async {
      await signIn();
      // The rooms as the API keeps them: three outside any category, which
      // share their positions with the two categories, and two in k.
      final server = <String, ({String? parent, int position, int type})>{
        'a': (parent: null, position: 0, type: 1),
        'b': (parent: null, position: 1, type: 1),
        'c': (parent: null, position: 2, type: 1),
        'k': (parent: null, position: 3, type: 3),
        'l': (parent: null, position: 4, type: 3),
        'x': (parent: 'k', position: 0, type: 1),
        'y': (parent: 'k', position: 1, type: 2),
      };
      Map<String, dynamic> json(String id) =>
          _room(id, type: server[id]!.type, position: server[id]!.position, parent: server[id]!.parent);
      // The API's UpdateRoom (rooms.go): the gap at the old place closes; the
      // position is one lower when the room moves later among the same rooms;
      // a gap opens at the new place.
      void place(String id, Map<String, dynamic> body) {
        final now = server[id]!;
        final parent = now.type != 3 && body.containsKey('parent_id') ? body['parent_id'] as String? : now.parent;
        var position = body['position'] as int? ?? now.position;
        for (final MapEntry(:key, :value) in [...server.entries]) {
          if (value.parent == now.parent && value.position > now.position) {
            server[key] = (parent: value.parent, position: value.position - 1, type: value.type);
          }
        }
        if (parent == now.parent && position > now.position) position--;
        for (final MapEntry(:key, :value) in [...server.entries]) {
          if (key != id && value.parent == parent && value.position >= position) {
            server[key] = (parent: value.parent, position: value.position + 1, type: value.type);
          }
        }
        server[id] = (parent: parent, position: position, type: now.type);
      }

      repository.handleEvent(_event('SPACE_CREATE', _space(rooms: {for (final id in server.keys) id: json(id)})));
      for (final id in server.keys) {
        routes[('PATCH', '/api/spaces/s-1/rooms/$id')] = (request) {
          place(id, jsonDecode(request.body) as Map<String, dynamic>);
          // As the API broadcasts after the move.
          repository.handleEvent(
            _event('ROOM_REORDER', {
              'rooms': [for (final r in server.keys) json(r)],
            }),
          );
          return json(id);
        };
      }

      // The rooms settings' lists: outside any category, the categories, and
      // each category's rooms.
      List<AdminRoom> siblingsOf(String id) {
        final all = repository.adminRooms('s-1');
        final room = all.singleWhere((r) => r.id == id);
        final categories = {for (final c in all.where((r) => r.kind == AdminRoomKind.category)) c.id};
        return [
          for (final r in all)
            if (room.kind == AdminRoomKind.category
                ? r.kind == AdminRoomKind.category
                : r.kind != AdminRoomKind.category &&
                      (categories.contains(room.parentId)
                          ? r.parentId == room.parentId
                          : !categories.contains(r.parentId)))
              r,
        ];
      }

      // As the rooms page sends a move one place up or down: before the
      // room now at the new index among the others there, or past the last.
      String? parentOf(String id) {
        final all = repository.adminRooms('s-1');
        final room = all.singleWhere((r) => r.id == id);
        final categories = {for (final c in all.where((r) => r.kind == AdminRoomKind.category)) c.id};
        return room.kind != AdminRoomKind.category && categories.contains(room.parentId) ? room.parentId : null;
      }

      int end(String id, String? parent) =>
          repository
              .adminRooms('s-1')
              .where((r) => r.id != id && r.parentId == parent)
              .fold(-1, (p, r) => r.position > p ? r.position : p) +
          1;

      Future<void> move(String id, {required bool up}) {
        final siblings = siblingsOf(id);
        final i = siblings.indexWhere((r) => r.id == id);
        final others = [...siblings]..removeAt(i);
        final to = up ? i - 1 : i + 1;
        final parent = parentOf(id);
        return repository.moveRoom(
          's-1',
          id,
          parentId: parent,
          position: to < others.length ? others[to].position : end(id, parent),
        );
      }

      // As Move to… sends it: first in a category, as the desktop drops one
      // in; or past the last room outside any.
      Future<void> moveTo(String id, String? category) {
        final loose = repository
            .adminRooms('s-1')
            .where((r) => r.id != id && r.kind != AdminRoomKind.category && r.parentId == null);
        return repository.moveRoom(
          's-1',
          id,
          parentId: category,
          position: category != null ? 0 : loose.fold(-1, (p, r) => r.position > p ? r.position : p) + 1,
        );
      }

      Map<String?, List<String>> shown() => {
        for (final s in repository.spaces.value.single.sections) s.name: [for (final r in s.rooms) r.id],
      };

      await move('a', up: false);
      expect(shown(), {
        null: ['b', 'a', 'c'],
        'k': ['x', 'y'],
        'l': <String>[],
      });
      await move('c', up: true);
      expect(shown()[null], ['b', 'c', 'a']);
      await move('b', up: false);
      await move('b', up: false);
      expect(shown()[null], ['c', 'a', 'b']);
      await move('x', up: false);
      expect(shown()['k'], ['y', 'x']);
      await moveTo('a', 'k');
      expect(shown(), {
        null: ['c', 'b'],
        'k': ['a', 'y', 'x'],
        'l': <String>[],
      });
      await moveTo('y', null);
      expect(shown(), {
        null: ['c', 'b', 'y'],
        'k': ['a', 'x'],
        'l': <String>[],
      });
      await move('l', up: true);
      expect(shown().keys, [null, 'l', 'k']);
      await move('b', up: true);
      await move('y', up: true);
      expect(shown()[null], ['b', 'y', 'c']);
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
      await refuses(
        'PATCH',
        '/api/spaces/s-1/rooms/r-general',
        () => repository.moveRoom('s-1', 'r-general', position: 1),
      );
      await refuses(
        'PATCH',
        '/api/spaces/s-1/rooms/r-general',
        () => repository.moveRoom('s-1', 'r-general', parentId: 'r-lounge', position: 0),
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

    test('a room\'s description', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _space()));
      await refuses(
        'PATCH',
        '/api/spaces/s-1/rooms/r-general',
        () => repository.setRoomDescription('s-1', 'r-general', 'Say hi'),
        status: 400,
        reason: 'description must be at most 1024 characters',
      );
      expect(repository.spaces.value.single.rooms.single.description, isNull);
    });

    test('without a connection, it says so', () async {
      await signIn();
      const offline = 'No connection. Check it and try again.';
      routes[('POST', '/api/invites/k7Qe2m/join')] = (_) => throw const SocketException('no network');
      await expectLater(
        repository.joinInvite('k7Qe2m'),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', offline)),
      );
      // As the HTTP client reports a dropped connection.
      routes[('POST', '/api/invites/k7Qe2m/join')] = (_) => throw http.ClientException('Connection closed');
      await expectLater(
        repository.joinInvite('k7Qe2m'),
        throwsA(isA<ActionFailed>().having((e) => e.message, 'message', offline)),
      );
    });

    test('a file the phone can\'t read isn\'t taken for a lost connection', () async {
      await signIn();
      await expectLater(
        repository.addAsset('s-1', AssetKind.emoji, 'party', '$upload.gone'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a 401 is the session\'s: refused again, it signs out', () async {
      await signIn();
      var signedOut = 0;
      final sub = repository.signedOut.listen((_) => signedOut++);
      addTearDown(sub.cancel);
      routes[('POST', '/api/spaces/s-1/roles')] = (_) => http.Response('{"error":"unauthorized"}', 401);
      routes[('POST', '/api/auth/refresh')] = (_) => http.Response('{"error":"session expired or invalid"}', 401);
      await expectLater(repository.createRole('s-1', 'Hosts'), throwsA(isA<duvet.DuvetAuthException>()));
      expect(signedOut, 1);
      expect(repository.profile.value, isNull);
    });

    test('webhooks', () async {
      await signIn();
      final hook = SpaceWebhook(
        id: 'w-1',
        roomId: 'r-general',
        roomName: 'general',
        name: 'CI',
        createdAt: DateTime(2026, 10, 24),
      );
      await refuses(
        'POST',
        '/api/spaces/s-1/rooms/r-general/webhooks',
        () => repository.createWebhook('s-1', 'r-general', 'CI'),
        reason: 'you don\'t have permission to manage webhooks in this space',
      );
      await refuses(
        'POST',
        '/api/spaces/s-1/rooms/r-general/webhooks/w-1/reset-token',
        () => repository.resetWebhook('s-1', hook),
        status: 404,
        reason: 'webhook not found',
      );
      await refuses(
        'DELETE',
        '/api/spaces/s-1/rooms/r-general/webhooks/w-1',
        () => repository.deleteWebhook('s-1', hook),
      );
    });

    test('making a Space says why it was refused, and that it may have been made when no answer came', () async {
      await signIn();
      await refuses(
        'POST',
        '/api/spaces',
        () => repository.createSpace('Testing lair'),
        status: 400,
        reason: 'you cannot be in more than 100 spaces',
      );
      // Unanswered, or its connection lost after the request left (as the
      // HTTP client reports a reset, or a connection closed before the
      // answer): it may have been made, so trying again could make another.
      for (final unanswered in [
        TimeoutException('no answer'),
        const SocketException('Connection reset by peer'),
        http.ClientException('Connection closed before full header was received'),
      ]) {
        routes[('POST', '/api/spaces')] = (_) => throw unanswered;
        await expectLater(
          repository.createSpace('Testing lair'),
          throwsA(
            isA<ActionFailed>().having(
              (e) => e.message,
              'message',
              'Duvet didn’t answer. Check Spaces before trying again: it may have been made.',
            ),
          ),
          reason: '$unanswered',
        );
      }
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

  group('the gateway\'s order', () {
    // READY asks for the mention counts: they land before the next event.
    Future<void> ready({List<String>? guilds}) async {
      repository.handleEvent(_event('READY', {'user': _user(_me, 'gaby'), 'sessionToken': 'ws', 'guild_ids': ?guilds}));
      await pumpEventQueue();
    }

    List<String> order() => [for (final s in repository.spaces.value) s.id];

    test('Spaces come as READY lists them, not by name', () async {
      await signIn();
      await ready(guilds: ['s-zeta', 's-alpha', 's-mid']);
      // The SPACE_CREATEs needn't come in that order either.
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-alpha', 'Alpha')));
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-mid', 'Mid')));
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-zeta', 'Zeta')));
      expect(order(), ['s-zeta', 's-alpha', 's-mid']);
    });

    test('a Space READY didn\'t list goes last, in the order they came', () async {
      await signIn();
      await ready(guilds: ['s-zeta', 's-alpha']);
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-alpha', 'Alpha')));
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-zeta', 'Zeta')));
      // Made or joined since: after the others, though their names come first.
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-new', 'Bees')));
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-newer', 'Aardvarks')));
      expect(order(), ['s-zeta', 's-alpha', 's-new', 's-newer']);
    });

    test('a Space renamed keeps its place', () async {
      await signIn();
      await ready(guilds: ['s-alpha', 's-zeta']);
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-alpha', 'Alpha')));
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-zeta', 'Zeta')));
      // A name that sorts first, which doesn't move it.
      repository.handleEvent(
        _event('SPACE_UPDATE', {
          'id': 's-zeta',
          'name': 'Aardvarks',
          'owner_id': _maya,
          'created_at': _at,
          'updated_at': _at,
        }),
      );
      expect(order(), ['s-alpha', 's-zeta']);
      expect(repository.spaces.value.last.name, 'Aardvarks');
    });

    test('a READY that lists none keeps the order they came in', () async {
      await signIn();
      await ready();
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-zeta', 'Zeta')));
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-alpha', 'Alpha')));
      expect(order(), ['s-zeta', 's-alpha']);
    });
  });

  group('banners', () {
    const banner = '00000000-0000-4000-8000-0000000000b1';
    const other = '00000000-0000-4000-8000-0000000000b2';
    Map<String, dynamic> updated(String? banner) => {
      'id': 's-1',
      'name': 'Duvet Official',
      'owner_id': _maya,
      'banner': banner,
      'created_at': _at,
      'updated_at': _at,
    };

    test(
      'a Space\'s banner is its attachment\'s URL, as its icon is; SPACE_UPDATE changes it or takes it away',
      () async {
        await signIn();
        repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-1', 'Duvet Official', banner: banner)));
        expect(repository.spaces.value.single.bannerUrl, 'https://api.duvet.chat/attachments/$banner');

        repository.handleEvent(_event('SPACE_UPDATE', updated(other)));
        expect(repository.spaces.value.single.bannerUrl, 'https://api.duvet.chat/attachments/$other');

        repository.handleEvent(_event('SPACE_UPDATE', updated(null)));
        expect(repository.spaces.value.single.bannerUrl, isNull);
      },
    );

    test('a description cleared as the banner goes is cleared first, alone: the form would drop it', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-1', 'Duvet Official', banner: banner)));
      routes[('PATCH', '/api/spaces/s-1')] = (_) => updated(null);
      final before = requests.length;
      await repository.updateSpace('s-1', description: '', removeBanner: true);
      final patches = requests.skip(before).where((r) => r.method == 'PATCH').toList();
      expect(patches, hasLength(2));
      expect(jsonDecode(patches.first.body), {'description': ''});
      expect(patches.last.body, contains('name="remove_banner"'));
      expect(patches.last.body, isNot(contains('name="description"')));
    });

    test('removing the banner asks the API to remove it; a new one, given too, wins', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-1', 'Duvet Official', banner: banner)));
      routes[('PATCH', '/api/spaces/s-1')] = (_) => updated(null);
      final dir = Directory.systemTemp.createTempSync('duvet_banners');
      addTearDown(() => dir.deleteSync(recursive: true));
      final upload = '${dir.path}/banner.png';
      File(upload).writeAsBytesSync(const [1, 2, 3]);

      await repository.updateSpace('s-1', removeBanner: true);
      expect(requests.last.body, contains('name="remove_banner"'));

      await repository.updateSpace('s-1', removeBanner: true, bannerPath: upload);
      expect(requests.last.body, isNot(contains('remove_banner')));
      expect(requests.last.body, contains('name="banner"'));
    });

    test('taking the banner away uploads nothing, so says no upload\'s progress; a new one does', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', _spaceOf('s-1', 'Duvet Official', banner: banner)));
      // Each change reaches the API whole, which holds its answer.
      late Completer<void> sent;
      late Completer<Object?> answer;
      routes[('PATCH', '/api/spaces/s-1')] = (_) {
        sent.complete();
        return answer.future;
      };
      final progress = <double>[];

      sent = Completer();
      answer = Completer();
      final removing = repository.updateSpace('s-1', removeBanner: true, onProgress: progress.add);
      await sent.future;
      expect(requests.last.body, contains('name="remove_banner"'));
      expect(progress, isEmpty);
      answer.complete(updated(null));
      await removing;
      expect(progress, isEmpty);

      final dir = Directory.systemTemp.createTempSync('duvet_banners');
      addTearDown(() => dir.deleteSync(recursive: true));
      final upload = '${dir.path}/banner.png';
      File(upload).writeAsBytesSync(const [1, 2, 3]);
      sent = Completer();
      answer = Completer();
      final uploading = repository.updateSpace('s-1', bannerPath: upload, onProgress: progress.add);
      await sent.future;
      expect(progress.last, 1);
      answer.complete(updated(other));
      await uploading;
    });
  });

  group('room descriptions', () {
    Map<String, dynamic> guild() => _space(
      rooms: {
        'r-general': _room('r-general', description: '  Say hi  '),
        'r-blank': _room('r-blank', position: 1, description: '   '),
        'r-quiet': _room('r-quiet', position: 2),
        'c-talk': _room('c-talk', type: 3, position: 3, description: 'Not shown'),
      },
    );
    Map<String, String?> shown() => {for (final r in repository.spaces.value.single.rooms) r.id: r.description};
    Map<String, String?> admin() => {for (final r in repository.adminRooms('s-1')) r.id: r.description};

    test('come from the rooms\', trimmed; a blank one is none, and a category has none', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      expect(shown(), {'r-general': 'Say hi', 'r-blank': null, 'r-quiet': null});
      expect(admin(), {'r-general': 'Say hi', 'r-blank': null, 'r-quiet': null, 'c-talk': null});
    });

    // The rooms' PATCH, answering the room as the API would.
    void patches() => routes[('PATCH', '/api/spaces/s-1/rooms/r-general')] = (request) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _room('r-general', description: body['description'] as String?);
    };
    Map<String, dynamic> sent() => jsonDecode(requests.last.body) as Map<String, dynamic>;

    test('setting one sends it trimmed, and shows it', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      patches();
      await repository.setRoomDescription('s-1', 'r-general', '  Where it starts  ');
      expect(sent(), {'description': 'Where it starts'});
      expect(shown()['r-general'], 'Where it starts');
      expect(admin()['r-general'], 'Where it starts');
    });

    test('a blank one or none clears it: null, as the API takes it', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      patches();
      for (final blank in ['', '   ', null]) {
        await repository.setRoomDescription('s-1', 'r-general', blank);
        expect(sent(), {'description': null}, reason: '"$blank"');
        expect(shown()['r-general'], isNull);
      }
    });

    test('ROOM_UPDATE brings someone else\'s', () async {
      await signIn();
      repository.handleEvent(_event('SPACE_CREATE', guild()));
      repository.handleEvent(_event('ROOM_UPDATE', _room('r-quiet', position: 2, description: 'Shh')));
      expect(shown()['r-quiet'], 'Shh');
      expect(admin()['r-quiet'], 'Shh');
    });
  });

  group('categories', () {
    Map<String, dynamic> guild() => _space(
      rooms: {
        'r-general': _room('r-general'),
        'c-talk': _room('c-talk', type: 3, position: 1),
        'r-crit': _room('r-crit', parent: 'c-talk'),
        'c-empty': _room('c-empty', type: 3, position: 2),
      },
    );

    test(
      'a section is its category\'s, by ID; the rooms outside any have none, and an empty one still shows',
      () async {
        await signIn();
        repository.handleEvent(_event('SPACE_CREATE', guild()));
        expect(repository.spaces.value.single.sections.map((s) => (s.id, s.rooms.length)), [
          (null, 1),
          ('c-talk', 1),
          ('c-empty', 0),
        ]);
      },
    );

    test('collapsing one folds it, and only it; expanding it opens it again', () async {
      await signIn();
      expect(repository.collapsedCategories.value, isEmpty);
      repository.setCategoryCollapsed('c-talk', true);
      expect(repository.collapsedCategories.value, {'c-talk'});
      // Twice is once.
      repository.setCategoryCollapsed('c-talk', true);
      expect(repository.collapsedCategories.value, {'c-talk'});
      repository.setCategoryCollapsed('c-empty', true);
      expect(repository.collapsedCategories.value, {'c-talk', 'c-empty'});
      repository.setCategoryCollapsed('c-talk', false);
      expect(repository.collapsedCategories.value, {'c-empty'});
      // Expanding one that's open changes nothing.
      repository.setCategoryCollapsed('c-talk', false);
      expect(repository.collapsedCategories.value, {'c-empty'});
    });

    test('collapsing, expanding, then collapsing another leaves just the other', () async {
      await signIn();
      repository.setCategoryCollapsed('c-talk', true);
      repository.setCategoryCollapsed('c-talk', false);
      repository.setCategoryCollapsed('c-empty', true);
      expect(repository.collapsedCategories.value, {'c-empty'});
    });

    DuvetRepository again() => DuvetRepository(
      store: MemorySessionStore(),
      recentsStore: MemoryRecentChatsStore(),
      httpClient: () => client,
      connectGateway: false,
      cacheStore: cache,
    );

    test('the folded ones are kept on the device, for the next session', () async {
      await signIn();
      repository.setCategoryCollapsed('c-talk', true);
      repository.setCategoryCollapsed('c-empty', true);
      repository.setCategoryCollapsed('c-empty', false);
      // The cache writes a moment after the changes.
      await eventually(() => expect(cache.data.keys, contains('collapsed')));

      final next = again();
      addTearDown(next.dispose);
      await next.logIn('gaby@duvet.chat', 'secret');
      await pumpEventQueue();
      expect(next.collapsedCategories.value, {'c-talk'});
    });

    test('opened offline, the folded ones come from the device too', () async {
      final sessions = MemorySessionStore();
      DuvetRepository over(MemorySessionStore store) => DuvetRepository(
        store: store,
        recentsStore: MemoryRecentChatsStore(),
        httpClient: () => client,
        connectGateway: false,
        cacheStore: cache,
      );
      final first = over(sessions);
      addTearDown(first.dispose);
      await first.logIn('gaby@duvet.chat', 'secret');
      first.handleEvent(_event('SPACE_CREATE', guild()));
      first.setCategoryCollapsed('c-talk', true);
      // The home and the folds write a moment after.
      await eventually(() => expect(cache.data.keys, containsAll(['home', 'collapsed'])));

      // The server out of reach: the session opens from what's saved.
      routes[('GET', '/api/users/@me')] = (_) => throw const SocketException('no network');
      final next = over(sessions);
      addTearDown(next.dispose);
      expect(await next.restore(), isTrue);
      await pumpEventQueue();
      expect(next.status.value, LiveStatus.offline);
      expect(next.collapsedCategories.value, {'c-talk'});
    });

    test('one folded before the saved ones are read stays folded', () async {
      final slow = _SlowCollapsed()..data['collapsed'] = jsonEncode({'ids': <String>[]});
      final next = DuvetRepository(
        store: MemorySessionStore(),
        recentsStore: MemoryRecentChatsStore(),
        httpClient: () => client,
        connectGateway: false,
        cacheStore: slow,
      );
      addTearDown(next.dispose);
      await next.logIn('gaby@duvet.chat', 'secret');
      next.setCategoryCollapsed('c-talk', true);
      // What's saved arrives after: it must not open it again.
      slow.release.complete();
      await pumpEventQueue();
      expect(next.collapsedCategories.value, {'c-talk'});
    });

    test('signing out forgets them', () async {
      await signIn();
      repository.setCategoryCollapsed('c-talk', true);
      await eventually(() => expect(cache.data.keys, contains('collapsed')));
      await repository.logOut();
      expect(repository.collapsedCategories.value, isEmpty);

      final next = again();
      addTearDown(next.dispose);
      await next.logIn('gaby@duvet.chat', 'secret');
      await pumpEventQueue();
      expect(next.collapsedCategories.value, isEmpty);
    });
  });

  group('the cache', () {
    test('keeps a Space\'s banner, its sections\' IDs and its rooms\' descriptions', () {
      const space = Space(
        id: 's-1',
        name: 'Duvet Official',
        bannerUrl: 'https://api.duvet.chat/attachments/b-1',
        sections: [
          RoomSection(
            name: null,
            rooms: [Room(id: 'r-general', spaceId: 's-1', name: 'general', kind: RoomKind.text, position: 0)],
          ),
          RoomSection(
            id: 'c-talk',
            name: 'Talk',
            rooms: [
              Room(
                id: 'r-crit',
                spaceId: 's-1',
                name: 'crit',
                kind: RoomKind.text,
                position: 0,
                description: 'Feedback, kindly',
              ),
            ],
          ),
        ],
      );
      final back = spaceFromJson(jsonDecode(jsonEncode(spaceToJson(space))) as Map<String, Object?>);
      expect(back.bannerUrl, space.bannerUrl);
      expect(back.sections.map((s) => s.id), [null, 'c-talk']);
      expect(back.rooms.map((r) => r.description), [null, 'Feedback, kindly']);
    });

    test('a Space cached before them reads as none', () {
      final back = spaceFromJson({
        'id': 's-1',
        'name': 'Duvet Official',
        'iconUrl': null,
        'sections': [
          {
            'name': 'Talk',
            'rooms': [
              {'id': 'r-crit', 'name': 'crit', 'voice': false, 'position': 0},
            ],
          },
        ],
      });
      expect(back.bannerUrl, isNull);
      expect(back.sections.single.id, isNull);
      expect(back.rooms.single.description, isNull);
    });
  });
}
