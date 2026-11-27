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

/// The records of a user's conversations, in the engine's record: those from before the cutover, and the person's picks
/// as they made a conversation on this device, until it holds its group (C1 of step 4's closing reviews). One the
/// record didn't take is kept here for the session, so a conversation stays held to what this device first saw while
/// the storage refuses (M4 of the desktop's review).
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
  /// group's) and members as listed now.
  Future<LegacyRecord?> of(duvet.Conversation conv) async {
    final kept = _valueOf(conv.id);
    if (kept == false) return null;
    if (recordIn(kept) case final record?) return record;
    if (!conv.legacy) return null;
    final members = [for (final member in conv.members) member.userId];
    final LegacyRecord made = (
      owner: conv.type == duvet.ConversationType.group ? conv.ownerId : null,
      members: members,
    );
    await _keep(conv.id, expectedOf(made));
    return made;
  }

  /// The record kept for the conversation, as a push's engine reads it without the API's list: none for one this
  /// device never applied or made, or one let go.
  LegacyRecord? kept(String conversationId) => recordIn(_kept()[conversationId]);

  /// The person's picks as they made the conversation here, this user among them: its group is founded with them alone.
  Future<void> created(String conversationId, LegacyRecord picked) =>
      _keep(conversationId, {...expectedOf(picked), 'created': true});

  /// This device holds the conversation's group: the record of its creation goes. One from before the cutover stays.
  Future<void> heldGroup(String conversationId) async {
    if (_valueOf(conversationId) case {'created': true}) await _keep(conversationId, null);
  }

  /// The person said yes to the members of today: the record goes, and none is made again.
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
