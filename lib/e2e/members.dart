/// Who is in a conversation (PLAN-E2E-CLIENTES.md, «Qué se manda», its members' rows; decisions 16 and 17): the owner
/// of a group adds and removes one user a request, each a commit of exactly that user, and a member leaves with a
/// statement their device signs, whose removal a member's commit makes once the API proposes it. A group has 20 members
/// at most, its owner among them: the cap holds before anything is asked. And who a blocked group's restart leaves out,
/// which its person confirms first; and whether the members of a newer generation are the ones this device holds. The
/// desktop's members.ts in Dart.
library;

import 'package:duvet_client/duvet.dart' as duvet;

import 'engine.dart';
import 'host.dart';
import 'identity.dart';

/// A group's members at most, its owner among them (decision 17).
const maxGroupMembers = 20;

/// The group as the core holds it (its `group`): its generation and epoch, whether it's blocked, who's in it by their
/// order, and its owner; and the users with a device in it ([joined], each once).
typedef HeldMembers = ({
  int generation,
  int epoch,
  bool blocked,
  String? owner,
  List<String> members,
  List<String> joined,
});

/// A group of [count] members, its owner among them, past the cap is refused here, before anything is asked of the API.
void checkRoom(int count) {
  if (count > maxGroupMembers) {
    throw CoreError(
      'too_many_members',
      message: 'a group can have $maxGroupMembers members at most',
      limit: maxGroupMembers,
    );
  }
}

/// Whether [owner] may add [user] to the conversation, as the API holds it: a group's owner adding someone else, while
/// it has room. A refusal is thrown, before anything is asked of the API.
void checkAddition(duvet.Conversation conv, String owner, String user) {
  if (conv.type != duvet.ConversationType.group) {
    throw CoreError('bad_command', message: "a DM's members don't change", field: 'conversation_id');
  }
  if (conv.ownerId != owner) throw CoreError('bad_command', message: "only the group's owner adds members");
  if (user == owner) throw CoreError('bad_command', message: 'the owner is in the group already', field: 'user_id');
  checkRoom(conv.members.length + 1);
}

/// The commit that adds [user], with a key package of each of their devices: none for a user without one, who joins
/// later, and then no welcome.
Future<duvet.Commit> addition(E2EEngine engine, duvet.Conversation conv, String user, HeldMembers at) async {
  final keyPackages = [for (final kp in await engine.api.claimKeyPackages(user)) kp.data];
  final made = await withIdentities(
    engine,
    () => engine.host.handle<Map<String, Object?>>({
      'cmd': 'add_members',
      'conversation_id': conv.id,
      'users': [
        {'user_id': user, 'key_packages': keyPackages},
      ],
    }),
  );
  return duvet.Commit(
    generation: at.generation,
    epoch: at.epoch,
    commit: made['commit']! as String,
    groupInfo: made['group_info']! as String,
    welcome: made['welcome'] as String?,
  );
}

/// The commit that takes [user] out, every device of theirs with them.
Future<duvet.Commit> removal(E2EEngine engine, duvet.Conversation conv, String user, HeldMembers at) async {
  final made = await withIdentities(
    engine,
    () => engine.host.handle<Map<String, Object?>>({
      'cmd': 'remove_members',
      'conversation_id': conv.id,
      'users': [user],
    }),
  );
  return duvet.Commit(
    generation: at.generation,
    epoch: at.epoch,
    commit: made['commit']! as String,
    groupInfo: made['group_info']! as String,
  );
}

/// The users the core's group holds that the API's conversation no longer lists: whom a restart leaves out.
List<String> leftOut(HeldMembers held, duvet.Conversation conv) => [
  for (final user in held.members)
    if (!conv.members.any((m) => m.userId == user)) user,
];

/// Two lists of users, the same whatever their order.
bool sameUsers(List<String> a, List<String> b) => a.length == b.length && a.every(b.contains);

/// The conversation's members as the API has them, and a group's owner: what the person said yes to (accept).
String membersKey(duvet.Conversation conv) => [
  conv.type == duvet.ConversationType.group ? conv.ownerId : '',
  ...[for (final m in conv.members) m.userId]..sort(),
].join(',');

/// Whether the API's conversation has the members, and a group the owner, that the core's group holds: only then does
/// this device join a newer generation it has no welcome for on its own (sync.dart's join).
bool sameMembers(HeldMembers held, duvet.Conversation conv) =>
    sameUsers(held.members, [for (final m in conv.members) m.userId]) &&
    (conv.type != duvet.ConversationType.group || held.owner == conv.ownerId);
