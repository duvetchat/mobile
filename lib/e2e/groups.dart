/// Making and joining a conversation's group (PLAN-E2E-CLIENTES.md, «Entrar a un grupo»), and restarting a blocked
/// one: who may make or restart it, and the first commit each way in gives, as its request goes up. The key packages of
/// every member's devices are claimed for it, this user's other devices' too; the core takes the members in the API's
/// order (by their membership's ID), and holds a conversation from before the cutover to this device's record of it.
/// The desktop's groups.ts in Dart.
library;

import 'package:duvet_client/duvet.dart' as duvet;

import 'engine.dart';
import 'identity.dart';
import 'legacy.dart';

/// Whether [user] may make the conversation's group: any member of one from before the cutover, either member of a
/// DM, a group's owner (the API's validator holds the same rule).
bool mayMake(duvet.Conversation conv, String user) =>
    conv.legacy || conv.type == duvet.ConversationType.dm || conv.ownerId == user;

/// Whether [user] may restart its blocked group: either member of a DM, a group's owner.
bool mayRestart(duvet.Conversation conv, String user) => conv.type == duvet.ConversationType.dm || conv.ownerId == user;

/// Every member's key packages, by user: one for each of their listed devices that has one to give.
Future<Map<String, List<String>>> _keyPackagesOf(E2EEngine engine, duvet.Conversation conv) async => {
  for (final member in conv.members)
    member.userId: [for (final kp in await engine.api.claimKeyPackages(member.userId)) kp.data],
};

/// What create_group and reset_group make: the generation's first commit, with epoch 0's group info and its welcome.
duvet.Commit _founding(Map<String, Object?> made) => duvet.Commit(
  generation: made['generation']! as int,
  epoch: 0,
  commit: made['commit']! as String,
  groupInfo: made['group_info']! as String,
  initialGroupInfo: made['initial_group_info']! as String,
  welcome: made['welcome'] as String?,
);

/// The conversation's group from nothing (create_group), under the API's external sender as pinned (Ruling 32).
Future<duvet.Commit> makeGroup(
  E2EEngine engine,
  duvet.Conversation conv,
  String externalSender,
  LegacyRecord? expected,
) async {
  final keyPackages = await _keyPackagesOf(engine, conv);
  final group = conv.type == duvet.ConversationType.group;
  return _founding(
    await withIdentities(
      engine,
      () => engine.host.handle<Map<String, Object?>>({
        'cmd': 'create_group',
        'conversation_id': conv.id,
        'kind': group ? 'group' : 'dm',
        if (group) 'owner': conv.ownerId,
        'members': [for (final member in conv.members) member.userId],
        'key_packages': keyPackages,
        'external_sender': externalSender,
        'legacy': conv.legacy,
        if (expected != null) 'expected': expectedOf(expected),
      }),
    ),
  );
}

/// The blocked group's next generation (reset_group), with the members and the owner the API has, in its order, as a
/// creation takes them, and every device's key packages: the core takes them only as a restart may found its group
/// (its #46), else a rule_violation.
Future<duvet.Commit> restartGroup(E2EEngine engine, duvet.Conversation conv) async {
  final keyPackages = await _keyPackagesOf(engine, conv);
  return _founding(
    await withIdentities(
      engine,
      () => engine.host.handle<Map<String, Object?>>({
        'cmd': 'reset_group',
        'conversation_id': conv.id,
        if (conv.type == duvet.ConversationType.group) 'owner': conv.ownerId,
        'members': [for (final member in conv.members) member.userId],
        'key_packages': keyPackages,
      }),
    ),
  );
}

/// The external commit that brings this device into the group as the API serves it (join_external), on the group info
/// of its latest epoch: held to the record of a conversation from before the cutover, and to the pinned external
/// sender.
Future<duvet.Commit?> joinGroup(
  E2EEngine engine,
  duvet.Conversation conv,
  String externalSender,
  LegacyRecord? expected, {
  Future<bool> Function(int generation)? mayJoin,
}) async {
  final info = await engine.api.groupInfo(conv.id);
  // Decided on the generation it would join ([mayJoin]): null when this device may not on its own.
  if (mayJoin != null && !await mayJoin(info.generation)) return null;
  // A device that never saw the group's members (a new device, joining a group its user was in) is asked for their
  // identities first.
  final made = await withIdentities(
    engine,
    () => engine.host.handle<Map<String, Object?>>({
      'cmd': 'join_external',
      'conversation_id': conv.id,
      'generation': info.generation,
      'group_info': info.groupInfo,
      'external_sender': externalSender,
      if (expected != null) 'expected': expectedOf(expected),
    }),
  );
  return duvet.Commit(
    generation: info.generation,
    epoch: info.epoch,
    commit: made['commit']! as String,
    groupInfo: made['group_info']! as String,
  );
}
