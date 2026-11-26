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

/// A record as the core's `expected` takes it: a group's with its owner, a DM's without one.
typedef LegacyRecord = ({String? owner, List<String> members});

/// The core's `expected` of [record].
Map<String, Object?> expectedOf(LegacyRecord record) => {'owner': ?record.owner, 'members': record.members};

/// A record as the record kept it, or null for anything else.
LegacyRecord? recordIn(Object? kept) => switch (kept) {
  {'members': final List<Object?> members} when members.every((member) => member is String) => switch (kept['owner']) {
    final String owner => (owner: owner, members: members.cast<String>().toList()),
    null => (owner: null, members: members.cast<String>().toList()),
    _ => null,
  },
  _ => null,
};

/// The records of a user's conversations, in the engine's record. One the record didn't take is kept here for the
/// session, so a conversation stays held to what this device first saw while the storage refuses (M4 of the desktop's
/// review).
class LegacyRecords {
  LegacyRecords(this._store);
  final EngineStore _store;

  /// What the record didn't take, by conversation: a record, or null for one let go.
  final _unsaved = <String, LegacyRecord?>{};

  Map<String, Object?> _kept() => switch (_store.read(legacyRecords)) {
    final Map<Object?, Object?> kept => kept.cast<String, Object?>(),
    _ => {},
  };

  /// The conversation's record: none for one from after the cutover, or one whose record the person let go; else the
  /// one kept, or, the first time this device sees the conversation, its owner (a group's) and members as listed now.
  Future<LegacyRecord?> of(duvet.Conversation conv) async {
    if (!conv.legacy) return null;
    if (_unsaved.containsKey(conv.id)) return _unsaved[conv.id];
    final kept = _kept()[conv.id];
    if (kept == false) return null;
    if (recordIn(kept) case final record?) return record;
    final members = [for (final member in conv.members) member.userId];
    final LegacyRecord made = (
      owner: conv.type == duvet.ConversationType.group ? conv.ownerId : null,
      members: members,
    );
    await _keep(conv.id, made);
    return made;
  }

  /// The record kept for the conversation, as a push's engine reads it without the API's list: none for one from after
  /// the cutover, one this device never applied, or one let go.
  LegacyRecord? kept(String conversationId) => recordIn(_kept()[conversationId]);

  /// The person said yes to the members of today: the record goes, and none is made again.
  Future<void> drop(String conversationId) => _keep(conversationId, null);

  Future<void> _keep(String id, LegacyRecord? record) async {
    final value = record == null ? false : expectedOf(record);
    try {
      await _store.write(legacyRecords, {..._kept(), id: value});
    } catch (error) {
      debugPrint("e2e: a conversation's record wasn't kept: ${error.runtimeType}");
    }
    // Read back: what the record didn't take holds for the session.
    if (jsonEncode(_kept()[id]) == jsonEncode(value)) {
      _unsaved.remove(id);
    } else {
      _unsaved[id] = record;
    }
  }
}
