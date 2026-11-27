/// The record of a conversation from before the cutover (PLAN-E2E-CLIENTES.md, «Entrar a un grupo»; Ruling 14): its
/// owner and members as this device first listed them, which every welcome and external commit into its group is held
/// to (the core's `expected`), until the person says yes to the members of today. Then the record goes, and none is
/// made again for that conversation. The desktop's legacy.ts in Dart.
library;

import 'dart:convert';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'store.dart';

/// The records, by conversation: false for one whose record the person let go.
const legacyRecords = 'legacy_records';

/// A record as the core's `expected` takes it: a group's with its owner, a DM's without one. [exact] for the record the
/// core answered as it forgot the conversation's group (forget_group, mobile#369): what brings the group back has
/// exactly its users and owner, where one from before the cutover holds a join to its users alone.
typedef LegacyRecord = ({String? owner, List<String> members, bool exact});

/// The core's `expected` of [record], `exact` as the core gave it.
Map<String, Object?> expectedOf(LegacyRecord record) => {
  'owner': ?record.owner,
  'members': record.members,
  if (record.exact) 'exact': true,
};

/// A record as the record kept it, or the core answered it, or null for anything else.
LegacyRecord? recordIn(Object? kept) => switch (kept) {
  {'members': final List<Object?> members} when members.every((member) => member is String) => switch (kept['owner']) {
    final String owner => (owner: owner, members: members.cast<String>().toList(), exact: kept['exact'] == true),
    null => (owner: null, members: members.cast<String>().toList(), exact: kept['exact'] == true),
    _ => null,
  },
  _ => null,
};

/// The records of a user's conversations, in the engine's record: those from before the cutover, the person's picks as
/// they made a conversation on this device (C1 of step 4's closing reviews), and the record of a group this device
/// forgot (mobile#369), the last two until it holds its group. One the record didn't take is kept here for the
/// session, so a conversation stays held to what this device first saw while the storage refuses (M4 of the desktop's
/// review).
class LegacyRecords {
  LegacyRecords(this._store);
  final EngineStore _store;

  /// What the record didn't take, by conversation: a record's value, or false for one let go or gone.
  final _unsaved = <String, Object>{};

  Map<String, Object?> _kept() => switch (_store.read(legacyRecords)) {
    final Map<Object?, Object?> kept => kept.cast<String, Object?>(),
    _ => {},
  };

  Object? _valueOf(String id) => _unsaved.containsKey(id) ? _unsaved[id] : _kept()[id];

  /// The conversation's record: the one kept, whatever the API says of the conversation, none for one whose record the
  /// person let go; else, the first time this device sees a conversation from before the cutover, its owner (a
  /// group's) and members as listed now, held to what the person sees ([asDrawn]): a listing the chat doesn't draw as
  /// listed makes no record, as it's the API's word alone (N-M1 of step 4's closing re-review).
  Future<LegacyRecord?> of(duvet.Conversation conv, Future<bool> Function(LegacyRecord made) asDrawn) async {
    final kept = _valueOf(conv.id);
    if (kept == false) return null;
    if (recordIn(kept) case final record?) return record;
    if (!conv.legacy) return null;
    final members = [for (final member in conv.members) member.userId];
    final LegacyRecord made = (
      owner: conv.type == duvet.ConversationType.group ? conv.ownerId : null,
      members: members,
      exact: false,
    );
    if (!await asDrawn(made)) return null;
    await _keep(conv.id, expectedOf(made));
    return made;
  }

  /// The record kept for the conversation, as a push's engine reads it without the API's list: none for one this
  /// device never applied or made, or one let go.
  LegacyRecord? kept(String conversationId) => recordIn(_kept()[conversationId]);

  /// Whether the conversation's record is a forgotten group's ([forgot]: exact), as this session holds it.
  bool keepsForgotten(String conversationId) => switch (_valueOf(conversationId)) {
    {'exact': true} => true,
    _ => false,
  };

  /// The person's picks as they made the conversation here, this user among them: its group is founded with them alone.
  /// Kept only where nothing is (N-M2 of step 4's closing re-review): the API's answer can be a conversation with a
  /// record from before the cutover, or one let go, which stays as it is.
  Future<void> created(String conversationId, LegacyRecord picked) async {
    if (_valueOf(conversationId) != null) return;
    await _keep(conversationId, {...expectedOf(picked), 'created': true});
  }

  /// The group this device forgot ([record], the core's answer, exact) holds what brings it back, in the conversation's
  /// place, over what was kept there: a record from before the cutover, or the person's yes that let one go, which
  /// comes back once the device holds the group ([heldGroup]); an earlier forget's record, whose own it carries on; a
  /// creation's, which goes, as the forgotten group was founded with those picks.
  Future<void> forgot(String conversationId, LegacyRecord record) {
    final before = switch (_valueOf(conversationId)) {
      {'exact': true, 'before': final Object before} => before,
      {'exact': true} || {'created': true} => null,
      final kept => kept,
    };
    return _keep(conversationId, {...expectedOf(record), 'before': ?before});
  }

  /// This device holds the conversation's group: the record of its creation goes, and a forgotten group's gives way to
  /// what it was kept over. One from before the cutover stays.
  Future<void> heldGroup(String conversationId) async {
    if (_valueOf(conversationId) case final Map<Object?, Object?> kept
        when kept['created'] == true || kept['exact'] == true) {
      await _keep(conversationId, kept['before']);
    }
  }

  /// The person said yes to the members of today: the record goes, a forgotten group's with what it was kept over, and
  /// none is made again.
  Future<void> drop(String conversationId) => _keep(conversationId, false);

  /// Keeps [value] as the conversation's record, or takes it out for null.
  Future<void> _keep(String id, Object? value) async {
    try {
      await _store.write(legacyRecords, value == null ? ({..._kept()}..remove(id)) : {..._kept(), id: value});
    } catch (error) {
      debugPrint("e2e: a conversation's record wasn't kept: ${error.runtimeType}");
    }
    // Read back: what the record didn't take holds for the session.
    if (jsonEncode(_kept()[id]) == jsonEncode(value)) {
      _unsaved.remove(id);
    } else {
      _unsaved[id] = value ?? false;
    }
  }
}
