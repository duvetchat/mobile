/// A conversation's queue and group (PLAN-E2E-CLIENTES.md, «La cola de una conversación», «Entrar a un grupo», «Un
/// commit sin respuesta», «Lo periódico»). What the API numbers in each conversation goes to the core by its number,
/// from the gateway's events and from the queue: a repeat is skipped, and a gap or an entry without its data reads the
/// queue from where the core is, 50 entries an apply. A device out of the group comes in by its welcome, read from the
/// queue, or an external commit, and makes the group where it may; its commits go through commits.dart, their bytes
/// kept until an answer comes. The engine runs this work in its turn, one conversation at a time: this class keeps
/// what's between turns, the entries heard, the commits whose requests go on, and what each conversation says to the
/// person. The desktop's sync.ts in Dart, with its review's rulings.
library;

import 'dart:async';
import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'commits.dart';
import 'engine.dart';
import 'failures.dart';
import 'groups.dart';
import 'host.dart';
import 'identity.dart';
import 'legacy.dart';

/// What a conversation says over its message box of its group (PLAN-E2E-CLIENTES.md, «Avisos»): blocked; waiting for
/// its owner to make it; waiting for another member to let this device back in; or members other than its record's.
enum ConversationNotice { blocked, waitOwner, waitRejoin, membersChanged }

/// Who may restart a blocked group: this user, its owner, or nobody (a group under an external sender other than the
/// pinned one, which no restart changes).
enum Restart { mine, owner, none }

/// What a conversation says of its group ([name]), with who may restart a blocked one, and its owner: a group's, whose
/// restart or making the others wait for.
@immutable
class ConversationState {
  const ConversationState.blocked({required Restart this.restart, this.owner}) : name = ConversationNotice.blocked;

  const ConversationState.waitOwner(String this.owner) : name = ConversationNotice.waitOwner, restart = null;

  const ConversationState._(this.name) : restart = null, owner = null;

  static const waitRejoin = ConversationState._(ConversationNotice.waitRejoin);
  static const membersChanged = ConversationState._(ConversationNotice.membersChanged);

  final ConversationNotice name;
  final Restart? restart;
  final String? owner;

  @override
  bool operator ==(Object other) =>
      other is ConversationState && other.name == name && other.restart == restart && other.owner == owner;

  @override
  int get hashCode => Object.hash(name, restart, owner);

  @override
  String toString() => 'ConversationState(${name.name}${restart == null ? '' : ', ${restart!.name}'}, $owner)';
}

/// An entry as the core's apply takes it (PLAN-E2E-API.md, «La entrada de la cola»): `data` null in an event's entry
/// past 16 KiB, which the queue gives whole. `deleted` and `generation` the core leaves aside.
Map<String, Object?> entryOf(duvet.MlsEntry entry) => {
  'seq': entry.seq,
  'kind': entry.kind,
  'data': entry.data,
  'sent_at': entry.sentAt,
  'message_id': ?entry.messageId,
  'sender_user': ?entry.senderUser,
  'sender_device': ?entry.senderDevice,
  'statement': ?entry.statement,
  if (entry.deleted) 'deleted': true,
  if (entry.mentions.isNotEmpty) 'mentions': entry.mentions,
  'reply_to': ?entry.replyTo,
};

/// An encrypted message (DM_MESSAGE_CREATE's) as its queue's entry: its ciphertext the data, its ID the message's, its
/// author and device the sender's. None of a message without a number, a notice's.
({String conversation, Map<String, Object?> entry})? messageEntry(duvet.DirectMessage message) {
  final (conversation, seq) = (message.conversationId, message.seq);
  if (conversation == null || seq == null || message.generation == null || message.epoch == null) return null;
  return (
    conversation: conversation,
    entry: {
      'seq': seq,
      'kind': 'message',
      'data': message.ciphertext,
      'sent_at': message.sentAt ?? 0,
      'message_id': message.id,
      'sender_user': message.authorId,
      'sender_device': ?message.senderDeviceId,
      if (message.mentions.isNotEmpty) 'mentions': message.mentions,
      'reply_to': ?message.referencedMessage?.messageId,
    },
  );
}

/// The entry an event carries, with its conversation and, of a group's own events, its generation: none from what has
/// none (a notice's message, its deletion).
({String conversation, Map<String, Object?> entry, int? generation})? _carried(duvet.GatewayEventPayload event) =>
    switch (event) {
      duvet.MlsCommitPayloadEvent(:final data) => (
        conversation: data.conversationId,
        entry: entryOf(data.entry),
        generation: data.generation,
      ),
      duvet.MlsWelcomePayloadEvent(:final data) => (
        conversation: data.conversationId,
        entry: entryOf(data.entry),
        generation: data.generation,
      ),
      duvet.MlsProposalPayloadEvent(:final data) => (
        conversation: data.conversationId,
        entry: entryOf(data.entry),
        generation: data.generation,
      ),
      duvet.DMMessageEditedEvent(:final data) => (
        conversation: data.conversationId,
        entry: entryOf(data.entry),
        generation: null,
      ),
      duvet.DMMessageDeletedEvent(data: duvet.DMMessageDeleteEvent(:final conversationId, :final entry?)) => (
        conversation: conversationId,
        entry: entryOf(entry),
        generation: null,
      ),
      duvet.DMMessageCreatedEvent(:final data) => switch (messageEntry(data)) {
        (:final conversation, :final entry) => (conversation: conversation, entry: entry, generation: null),
        null => null,
      },
      _ => null,
    };

/// A conversation as the API last listed it, and its group's numbers as the events and the queue told of them since.
class _Conv {
  _Conv(this.api)
    : group = switch (api.mls) {
        final mls? => _Group(mls.generation, mls.lastSeq, mls.joinedSeq),
        null => null,
      };

  final duvet.Conversation api;
  final _Group? group;

  String get id => api.id;

  bool hasMember(String user) => api.members.any((member) => member.userId == user);
}

class _Group {
  _Group(this.generation, this.lastSeq, this.joinedSeq);
  int generation;
  int lastSeq;

  /// The number from which this device has had a leaf in it (REST's alone), null without one.
  final int? joinedSeq;
}

/// Where the core is after applying: the entry it has through (null out of the group), the first one missing (a
/// gap's), whether a commit of its own is due, and whether the queue was just read to its end.
typedef _Where = ({int? through, int? gap, bool due, bool whole});

/// What a commit of this device's is for: it says what follows its answer.
enum _Purpose {
  make,
  restart,
  join,
  renew,
  renewAgain,
  due;

  /// A commit on the group the device holds, which a refusal leaves staged for the queue to settle.
  bool get member => this == renew || this == renewAgain || this == due;
}

/// A commit whose request goes on: its bytes, sent again as they are until an answer comes.
class _InFlight {
  _InFlight(this.purpose, this.commit);
  final _Purpose purpose;
  final duvet.Commit commit;
  var tries = 0;
  void Function()? cancel;
}

/// A turn that failed, and its retry.
class _Retry {
  var tries = 0;
  void Function() cancel = () {};
}

/// The group as the core holds it (its `group`).
typedef _Held = ({int generation, int epoch, bool blocked});

/// Entries an apply takes at most.
const _applyMost = 50;

/// A due commit waits a random while, up to this long, so the members it's due on don't all make it at once.
const _dueWait = Duration(seconds: 5);

/// A commit whose bytes went with the app is said to be refused only with the queue read whole this long after the
/// start (Ruling 25): before, the API may still be taking it.
const _settleAfter = Duration(minutes: 1);

/// What failed goes again after 2 s, then twice as long each time, up to a minute apart.
const _retryFirst = Duration(seconds: 2);
const _retryMost = Duration(minutes: 1);

Duration _backoff(int tries) {
  final wait = _retryFirst * (1 << min(tries, 5));
  return wait < _retryMost ? wait : _retryMost;
}

/// External commits that lost their epoch in a row before this device waits for the conversation's next event.
const _joinsLostMost = 3;

/// Rules a join refuses for whatever the device observes: the record, the external sender, a blocked group, a group
/// info behind what this device saw. Any other is observed for, then tried once more.
const _finalRules = {'member_list_mismatch', 'external_sender_mismatch', 'group_blocked', 'stale_group_info'};

int? _statusOf(Object error) => error is duvet.DuvetApiException ? error.statusCode : null;

class Conversations {
  Conversations(this._engine, this._soon, this._failures, this._changed) : _legacy = LegacyRecords(_engine.store);

  final E2EEngine _engine;

  /// Runs work in the engine's turn, while the device is ready.
  final void Function(Future<void> Function() work) _soon;
  final Failures _failures;
  final void Function(String conversationId, ConversationState? state) _changed;
  final LegacyRecords _legacy;

  CoreHost get _host => _engine.host;
  duvet.E2eApi get _api => _engine.api;
  String get _user => _engine.user;

  /// The API's external sender, as this device pinned it (Ruling 32).
  var _sender = '';

  /// The API's conversations as last listed, their groups as the events and the queue have told of them since.
  final _known = <String, _Conv>{};

  /// Entries heard by events, by conversation and number, until the conversation's turn.
  final _heard = <String, Map<int, Map<String, Object?>>>{};

  /// Conversations whose turn for what they heard is on its way, which what they hear meanwhile joins.
  final _turns = <String>{};
  final _states = <String, ConversationState>{};
  final _inFlight = <String, _InFlight>{};

  /// Commits whose bytes went with the app, or that the API refused but for the validator: the queue settles them, or
  /// they're said to be refused (Ruling 25).
  final _settling = <String>{};

  /// Due commits' waits, and failed turns' retries, by conversation.
  final _due = <String, void Function()>{};
  final _retries = <String, _Retry>{};

  /// External commits that lost their epoch in a row, by conversation; and those whose last one lost, after which a
  /// welcome from where the device's leaf began is stale.
  final _joinsLost = <String, int>{};
  final _lostJoin = <String>{};

  /// Groups under an external sender other than the pinned one: this device never goes in (Ruling 32).
  final _otherSender = <String>{};

  /// Groups whose members aren't their record's, until the person says yes ([accept]).
  final _recordRefused = <String>{};

  /// Groups a commit took this device out of: whether its user is still a member is the API's to say (I2 of the
  /// desktop's review).
  final _removed = <String>{};

  /// A minute has passed since the start ([_settleAfter]).
  var _settled = false;
  void Function()? _settleTimer;

  /// Begins with the pinned external sender: the minute a commit whose bytes were lost waits for starts now.
  void start(String externalSender) {
    _sender = externalSender;
    _settleTimer ??= _engine.clock.later(_settleAfter, () {
      _settled = true;
      for (final id in [..._settling]) {
        _soon(() => sync(id));
      }
    });
  }

  /// Stops waiting for anything: what's in memory goes, the bytes of a commit whose answer didn't come too.
  void stop() {
    _settleTimer?.call();
    for (final cancel in _due.values) {
      cancel();
    }
    for (final retry in _retries.values) {
      retry.cancel();
    }
    for (final flight in _inFlight.values) {
      flight.cancel?.call();
    }
    _due.clear();
    _retries.clear();
    _inFlight.clear();
    dropHeard();
  }

  /// Everything this device knew of its conversations goes, their states said to be none: it starts over.
  void forget() {
    stop();
    _settleTimer = null;
    _settled = false;
    for (final id in [..._states.keys]) {
      _set(id, null);
    }
    _known.clear();
    _joinsLost.clear();
    for (final kept in [_settling, _otherSender, _recordRefused, _removed, _lostJoin]) {
      kept.clear();
    }
  }

  /// What was heard goes: the engine isn't ready for it, and the queue keeps it all (M3 of the desktop's review).
  void dropHeard() {
    _heard.clear();
    _turns.clear();
  }

  ConversationState? state(String conversationId) => _states[conversationId];

  /// An event of a conversation's: its entry kept by its number, and the conversation's turn asked for, once what came
  /// with it is heard too, so a batch goes to the core in its order whatever order it came in (M8 of the desktop's
  /// review).
  void heard(duvet.GatewayEventPayload event) {
    final carried = _carried(event);
    if (carried == null) return;
    final (:conversation, :entry, :generation) = carried;
    final seq = entry['seq']! as int;
    (_heard[conversation] ??= {})[seq] = entry;
    if (_known[conversation]?.group case final group?) {
      group.lastSeq = max(group.lastSeq, seq);
      group.generation = max(group.generation, generation ?? 0);
    }
    if (!_turns.add(conversation)) return;
    _soon(() async {
      await Future<void>.delayed(Duration.zero);
      _turns.remove(conversation);
      await sync(conversation);
    });
  }

  /// At the start and at each READY: the API's conversations, each one's record made the first time it's seen, the
  /// queue of each with a group, and the commits whose requests had no answer sent again.
  Future<void> all() async {
    await _list();
    for (final conv in [..._known.values]) {
      try {
        await _legacy.of(conv.api);
        if (conv.group == null) {
          await _groupless(conv);
        } else {
          await sync(conv.id);
        }
      } catch (error) {
        debugPrint("e2e: a conversation's group waits for its next turn: $error");
      }
    }
    for (final id in [..._inFlight.keys]) {
      try {
        await _resend(id);
      } catch (error) {
        debugPrint('e2e: a commit waits for its answer again: $error');
      }
    }
  }

  /// The person opened the conversation (PLAN-E2E-CLIENTES.md, «Entrar a un grupo»): without a group, this user makes
  /// it where they may (any member before the cutover, either member of a DM, a group's owner); the others wait for
  /// its owner. With one, its turn.
  Future<void> open(String conversationId) async {
    var conv = _known[conversationId];
    if (conv?.group == null) conv = await _fresh(conversationId);
    if (conv == null) return;
    if (conv.group != null) return sync(conv.id);
    await _groupless(conv, make: true);
  }

  /// The person's restart of the conversation's blocked group, which only its owner (in a DM, either member) makes.
  Future<void> restart(String conversationId) async {
    final conv = _known[conversationId];
    final state = _states[conversationId];
    if (conv == null || state?.restart != Restart.mine || _inFlight.containsKey(conversationId)) return;
    await _commit(conv, _Purpose.restart, await restartGroup(_engine, conv.api));
  }

  /// The person's yes to the members of today: the record goes, and this device goes in with none to hold it to, by
  /// an external commit, or by making the group where there's none (M6 of the desktop's review).
  Future<void> accept(String conversationId) async {
    final conv = _known[conversationId];
    if (conv == null || !_recordRefused.contains(conversationId)) return;
    await _legacy.drop(conversationId);
    _recordRefused.remove(conversationId);
    _set(conversationId, null);
    if (conv.group == null) return open(conversationId);
    await _join(conv);
  }

  /// The leaf renewals due (refresh_due, «Lo periódico»): a commit in each conversation it names, one that fails
  /// leaving the others to go on (M7 of the desktop's review).
  Future<void> renew() async {
    final due = await _host.handle<Map<String, Object?>>({'cmd': 'refresh_due'});
    for (final id in (due['conversations']! as List<Object?>).cast<String>()) {
      try {
        final conv = _known[id] ?? await _fresh(id);
        if (conv != null && !_inFlight.containsKey(id)) await _own(conv, 'refresh', _Purpose.renew);
      } catch (error) {
        debugPrint("e2e: a leaf's renewal waits for tomorrow's: $error");
      }
    }
  }

  /// The conversation's turn ([read]: its queue read even when the core seems to have it all, as after another commit
  /// took an epoch). A turn that fails goes again later, as the conversation's next event would also ask; one refused
  /// for a conversation the user is no longer in (a 403 or a 404) lists the conversations again, and stops there when
  /// the user or the conversation is gone (I2 of the desktop's review).
  Future<void> sync(String conversationId, {bool read = false}) async {
    final conv = _known[conversationId] ?? await _fresh(conversationId);
    if (conv == null) return _gone(conversationId);
    try {
      await _sync(conv, read);
    } catch (error) {
      if (const [403, 404].contains(_statusOf(error)) && await _left(conversationId)) return _gone(conversationId);
      _retryLater(conversationId);
      rethrow;
    }
    _retries.remove(conversationId)?.cancel();
  }

  /// Whether the user is no longer in the conversation, as the API lists it now: false when that can't be read.
  Future<bool> _left(String id) async {
    try {
      final conv = await _fresh(id);
      return conv == null || !conv.hasMember(_user);
    } catch (error) {
      debugPrint("e2e: the conversations couldn't be listed: $error");
      return false;
    }
  }

  void _retryLater(String id) {
    final retry = _retries[id] ??= _Retry();
    retry.cancel();
    retry.cancel = _engine.clock.later(_backoff(retry.tries++), () => _soon(() => sync(id)));
  }

  /// The conversation is no longer the user's (left, removed, deleted): nothing more is asked of it.
  void _gone(String id) {
    _retries.remove(id)?.cancel();
    _inFlight.remove(id)?.cancel?.call();
    _due.remove(id)?.call();
    _heard.remove(id);
    _joinsLost.remove(id);
    for (final kept in [_settling, _otherSender, _recordRefused, _removed, _lostJoin]) {
      kept.remove(id);
    }
    _set(id, null);
  }

  /// A conversation without a group: nothing for whoever may make it, else waiting for its owner.
  ConversationState? _waiting(_Conv conv) =>
      mayMake(conv.api, _user) ? null : ConversationState.waitOwner(conv.api.ownerId);

  /// A conversation the API lists without a group. A creation of this device's the API never took, whose bytes went
  /// with the app, is dropped, as the core drops a creation whole on no answer, and the group made again (C1 of the
  /// desktop's review); else whoever may make it does so when the person opens it ([make]), and the others wait.
  Future<void> _groupless(_Conv conv, {bool make = false}) async {
    if (!mayMake(conv.api, _user)) return _set(conv.id, _waiting(conv));
    if (_inFlight.containsKey(conv.id)) return;
    if (await _dropStale(conv.id) || make) return _make(conv);
    _set(conv.id, null);
  }

  /// Whether the core held a creation of this device's for a conversation the API lists without a group, which it
  /// drops now: no answer came, and none will. No key package is claimed for it. A group it holds with no commit
  /// waiting, which create_group won't make again, throws the core's `not_found`, before anything is claimed (M4 of
  /// the review, as the desktop does).
  Future<bool> _dropStale(String id) async {
    if (await _group(id) == null) return false;
    await _host.handle<Object?>({'cmd': 'commit_result', 'conversation_id': id, 'accepted': false});
    return true;
  }

  /// The group made here, held to the record of a conversation from before the cutover.
  Future<void> _make(_Conv conv) async {
    final duvet.Commit commit;
    try {
      commit = await makeGroup(_engine, conv.api, _sender, await _legacy.of(conv.api));
    } on CoreError catch (error) {
      if (error.code == 'exists') return debugPrint("e2e: this device holds a group the API doesn't list.");
      if (error.rule == 'member_list_mismatch') return _refusedRecord(conv);
      rethrow;
    }
    await _commit(conv, _Purpose.make, commit);
  }

  /// The entries heard, in order; the queue when they don't follow on what the core has (a gap, an entry without its
  /// data, a number the API gave past them), when a commit of its own waits for the queue's word, or when asked; then
  /// what the group is now. A conversation known without a group is listed again: an event says it has one now.
  Future<void> _sync(_Conv given, bool read) async {
    final conv = given.group != null ? given : await _fresh(given.id);
    if (conv == null) return _gone(given.id);
    final id = conv.id;
    final group = conv.group;
    if (group == null) return _groupless(conv);
    // A commit of this device's waits for its answer: what's heard waits for it too.
    if (_inFlight.containsKey(id)) return;
    final heard = [...?_heard.remove(id)?.values]..sort((a, b) => (a['seq']! as int).compareTo(b['seq']! as int));
    var at = await _applyAll(conv, [
      for (final entry in heard)
        if (entry['data'] != null) entry,
    ]);
    final from = at.gap != null ? at.gap! - 1 : at.through;
    final behind =
        read ||
        at.gap != null ||
        heard.any((entry) => entry['data'] == null) ||
        _settling.contains(id) ||
        group.lastSeq > (at.through ?? 0);
    // Out of the group (no number to read from), _after reads its welcome or joins.
    if (behind && from != null) {
      final done = await _readQueue(conv, from);
      // The queue doesn't go back that far (410): this device joins again, its database as it is (13).
      if (done == null) return _join(conv);
      at = done;
      await _settle(id);
    }
    await _after(conv, at);
  }

  /// Applies entries in order, 50 an apply (once with none, which says where the core is).
  Future<_Where> _applyAll(_Conv conv, List<Map<String, Object?>> entries) async {
    _Where at = (through: null, gap: null, due: false, whole: false);
    var told = false;
    for (var start = 0; ;) {
      final chunk = entries.sublist(start, min(start + _applyMost, entries.length));
      final Map<String, Object?> applied;
      try {
        applied = await _apply(conv, chunk);
      } on CoreError catch (error) {
        if (error.code == 'gap') return (through: at.through, gap: error.from, due: at.due, whole: false);
        if (error.code != 'pending_commit' || told) rethrow;
        // A commit of this device's whose bytes went with the app (none is in flight here): the core is told no answer
        // came, and the queue settles it. Unless the core dropped it with its group (a creation, an external commit, a
        // reset), it stays staged until then, or until it's said to be refused.
        final answered = await _host.handle<Map<String, Object?>>({
          'cmd': 'commit_result',
          'conversation_id': conv.id,
          'accepted': false,
        });
        if (answered['epoch'] != null) _settling.add(conv.id);
        told = true;
        continue;
      }
      at = (through: applied['applied_through'] as int?, gap: null, due: applied['commit_due'] == true, whole: false);
      start += _applyMost;
      if (start >= entries.length) return at;
    }
  }

  /// One apply, the users it asks for observed first, the welcomes of a conversation from before the cutover held to
  /// its record (their `expected`, which the API never gives); what its results say is noted.
  Future<Map<String, Object?>> _apply(_Conv conv, List<Map<String, Object?>> entries) async {
    final record = await _legacy.of(conv.api);
    final given = record == null
        ? entries
        : [
            for (final entry in entries)
              entry['kind'] == 'welcome' ? {...entry, 'expected': expectedOf(record)} : entry,
          ];
    final applied = await withIdentities(
      _engine,
      () => _host.handle<Map<String, Object?>>({
        'cmd': 'apply',
        'conversation_id': conv.id,
        'entries': given,
        'external_sender': _sender,
      }),
    );
    final results = [for (final result in applied['results']! as List<Object?>) entryResult(result! as Map)];
    final deleted = {
      for (final entry in entries)
        if (entry['deleted'] == true) entry['seq']! as int,
    };
    failedKinds(results, deleted).forEach(_failures.note);
    for (final (:kind, :result, :rule, seq: _, epoch: _, reason: _) in results) {
      final refused = kind == 'welcome' && result == 'rejected';
      if (refused && rule == 'external_sender_mismatch') _otherSender.add(conv.id);
      if (refused && rule == 'member_list_mismatch' && record != null) _recordRefused.add(conv.id);
      // A commit of its epoch, its own or another's: a commit of this device's left to settle is settled.
      if (kind == 'commit' && result != 'ignored') _settling.remove(conv.id);
      if (result == 'removed') _removed.add(conv.id);
    }
    return applied;
  }

  /// The queue after [after], to its end, each page applied as it comes: where the core then is. Null when the queue
  /// doesn't go back that far (410).
  Future<_Where?> _readQueue(_Conv conv, int after) async {
    for (var from = after; ;) {
      final duvet.QueuePage page;
      try {
        page = await _api.queue(conv.id, from);
      } on duvet.DuvetApiException catch (error) {
        if (error.statusCode == 410) return null;
        rethrow;
      }
      if (conv.group case final group?) {
        group
          ..generation = page.generation
          ..lastSeq = page.lastSeq;
      }
      final at = await _applyAll(conv, [for (final entry in page.entries) entryOf(entry)]);
      if (at.gap case final gap?) {
        // The core needs what comes before this page: from there, as long as that's before where this read began.
        if (gap - 1 >= from) throw StateError('the queue of ${conv.id} skips entry $gap');
        from = gap - 1;
        continue;
      }
      final last = page.entries.lastOrNull?.seq;
      if (last == null || last >= page.lastSeq) return (through: at.through, gap: null, due: at.due, whole: true);
      from = last;
    }
  }

  /// A commit of this device's whose bytes went with the app, or that the API refused but for the validator (Ruling
  /// 25): with the queue read whole and a minute past the start, the API doesn't have it, and the core is told it was
  /// refused, so it's dropped. Never before, nor with the queue behind (Review Focus 11); forgotten once the core took
  /// that word (M5 of the desktop's review).
  Future<void> _settle(String id) async {
    if (!_settling.contains(id) || !_settled) return;
    try {
      await _host.handle<Object?>({'cmd': 'commit_result', 'conversation_id': id, 'accepted': false, 'invalid': true});
    } on CoreError catch (error) {
      // Nothing left to drop: the queue settled it after all.
      if (error.code != 'not_found') rethrow;
    }
    _settling.remove(id);
  }

  /// The group as the core holds it, or null without one.
  Future<_Held?> _group(String id) async {
    try {
      final held = await _host.handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': id});
      return (generation: held['generation']! as int, epoch: held['epoch']! as int, blocked: held['blocked'] == true);
    } on CoreError catch (error) {
      if (error.code == 'not_found') return null;
      rethrow;
    }
  }

  /// What the group is once the entries are in. In the API's group (its generation): blocked, or going on, with a due
  /// commit made after a random wait. Out of it, with the user still a member as the API lists it once a commit took
  /// this device out (I2): its welcome read from the queue, from where the core counts (a restart's welcome follows
  /// its commit, I1 of the desktop's review) or, for a core that never counted, from where its leaf began; else an
  /// external commit.
  Future<void> _after(_Conv conv, _Where at) async {
    final id = conv.id;
    final group = conv.group;
    final held = await _group(id);
    if (held != null && held.generation >= (group?.generation ?? 0)) {
      for (final kept in [_otherSender, _recordRefused, _removed, _lostJoin]) {
        kept.remove(id);
      }
      _set(id, held.blocked ? _blocked(conv) : null);
      if (at.due && !held.blocked) _dueLater(id);
      return;
    }
    if (group == null) return;
    var now = conv;
    if (_removed.remove(id) || !conv.hasMember(_user)) {
      final fresh = await _fresh(id);
      if (fresh == null || !fresh.hasMember(_user)) return _gone(id);
      now = fresh;
    }
    final joined = now.group?.joinedSeq;
    if (now.group == null) return;
    final refused = _otherSender.contains(id) || _recordRefused.contains(id);
    // After an external commit of its own lost its epoch, a welcome from where its leaf began is stale by then.
    final from = at.through ?? (_lostJoin.contains(id) || joined == null ? null : joined - 1);
    if (!refused && !at.whole && from != null) {
      final done = await _readQueue(now, from);
      if (done != null) return _after(now, done);
    }
    await _join(now);
  }

  ConversationState _blocked(_Conv conv) => ConversationState.blocked(
    restart: _otherSender.contains(conv.id)
        ? Restart.none
        : mayRestart(conv.api, _user)
        ? Restart.mine
        : Restart.owner,
    owner: conv.api.type == duvet.ConversationType.group ? conv.api.ownerId : null,
  );

  void _refusedRecord(_Conv conv) {
    _recordRefused.add(conv.id);
    _set(conv.id, ConversationState.membersChanged);
  }

  /// This device into the group by an external commit. The core asks no identities for it: refused for a rule, the
  /// members are observed and it's tried once more. Still refused, the conversation says why: members other than its
  /// record's, another external sender, a blocked group; or else this device waits for another member's commit (after
  /// it started over, the removal of its old devices) and tries again with each one ([ConversationState.waitRejoin]).
  Future<void> _join(_Conv conv) async {
    final id = conv.id;
    if (_otherSender.contains(id)) return _set(id, _blocked(conv));
    if (_recordRefused.contains(id)) return _set(id, ConversationState.membersChanged);
    if (_inFlight.containsKey(id)) return;
    if ((_joinsLost[id] ?? 0) >= _joinsLostMost) {
      _joinsLost.remove(id);
      return;
    }
    _settling.remove(id);
    Future<duvet.Commit> join() async => joinGroup(_engine, conv.api, _sender, await _legacy.of(conv.api));
    duvet.Commit commit;
    try {
      try {
        commit = await join();
      } on CoreError catch (error) {
        if (error.code != 'rule_violation' || _finalRules.contains(error.rule)) rethrow;
        await observeUsers(_engine, [for (final member in conv.api.members) member.userId]);
        commit = await join();
      }
    } on duvet.DuvetApiException catch (error) {
      // No group to join yet, or the conversation or its user gone (I2 of the desktop's review), on every way here, the
      // person's yes included: listed again, a conversation gone is let go.
      if (!const [403, 404].contains(error.statusCode)) rethrow;
      if (await _left(id)) _gone(id);
      return;
    } on CoreError catch (error) {
      // A commit of its own still waits for its word.
      if (error.code == 'pending_commit') return;
      if (error.code != 'rule_violation') rethrow;
      switch (error.rule) {
        case 'stale_group_info':
          return;
        case 'member_list_mismatch':
          return _refusedRecord(conv);
        case 'external_sender_mismatch':
          _otherSender.add(id);
          return _set(id, _blocked(conv));
        case 'group_blocked':
          return _set(id, _blocked(conv));
        default:
          return _set(id, ConversationState.waitRejoin);
      }
    }
    await _commit(conv, _Purpose.join, commit);
  }

  /// A commit of this device's own on the group it holds (commit_pending, refresh), sent: none when there's nothing.
  Future<void> _own(_Conv conv, String cmd, _Purpose purpose) async {
    final held = await _group(conv.id);
    if (held == null || held.blocked) return;
    final Map<String, Object?> made;
    try {
      made = await withIdentities(
        _engine,
        () => _host.handle<Map<String, Object?>>({'cmd': cmd, 'conversation_id': conv.id}),
      );
    } on CoreError catch (error) {
      // Nothing to commit (another member did it, or it was a false alarm), or a commit of its own still waits.
      if (error.code == 'not_found' || error.code == 'pending_commit') return;
      rethrow;
    }
    await _commit(
      conv,
      purpose,
      duvet.Commit(
        generation: held.generation,
        epoch: held.epoch,
        commit: made['commit']! as String,
        groupInfo: made['group_info']! as String,
      ),
    );
  }

  /// A due commit (apply's commit_due), after a random wait of up to 5 s: whoever loses the race finds it done.
  void _dueLater(String id) {
    if (_due.containsKey(id)) return;
    final wait = _dueWait * _engine.random();
    _due[id] = _engine.clock.later(wait, () {
      _due.remove(id);
      _soon(() async {
        final conv = _known[id];
        if (conv != null && !_inFlight.containsKey(id)) await _own(conv, 'commit_pending', _Purpose.due);
      });
    });
  }

  /// A commit of this device's to the API, its bytes kept until an answer comes: without one, the same bytes go again
  /// later and at each READY. Answered, the conversation's turn follows, reading the queue when another commit took
  /// the epoch, and a renewal that lost so is made again on top of it, once.
  Future<void> _commit(_Conv conv, _Purpose purpose, duvet.Commit commit) async {
    final id = conv.id;
    final flight = _inFlight[id] ??= _InFlight(purpose, commit);
    final Sent sent;
    try {
      sent = await sendCommit(_host, id, () => _api.commit(id, flight.commit));
    } catch (error) {
      _resendLater(id, flight);
      rethrow;
    }
    if (sent == Sent.unanswered) return _resendLater(id, flight);
    _inFlight.remove(id);
    if (sent == Sent.invalid) {
      // The validator refused it: it never entered, and nothing changed. An external commit so refused waits for the
      // conversation's next commit, as one the core refused would.
      debugPrint("e2e: the API refused a commit of this device's (${flight.purpose.name}).");
      if (flight.purpose == _Purpose.join) _set(id, ConversationState.waitRejoin);
      return;
    }
    if (flight.purpose == _Purpose.join) {
      if (sent == Sent.accepted) {
        _joinsLost.remove(id);
      } else {
        _joinsLost[id] = (_joinsLost[id] ?? 0) + 1;
        _lostJoin.add(id);
      }
    }
    // Refused otherwise, it may have entered by an earlier send of its bytes, which the queue says: a member's commit
    // stays staged until the queue settles it, or, read whole a minute past the start, it's said to be refused.
    if (sent == Sent.refused && flight.purpose.member) _settling.add(id);
    await sync(id, read: sent != Sent.accepted);
    if (sent == Sent.lost && flight.purpose == _Purpose.renew) {
      final now = _known[id];
      if (now != null && !_inFlight.containsKey(id)) await _own(now, 'refresh', _Purpose.renewAgain);
    }
  }

  void _resendLater(String id, _InFlight flight) {
    flight.cancel?.call();
    flight.cancel = _engine.clock.later(_backoff(flight.tries++), () {
      flight.cancel = null;
      _soon(() => _resend(id));
    });
  }

  /// A commit whose answer didn't come, sent again with its bytes; let go with a conversation the API no longer lists.
  Future<void> _resend(String id) async {
    final flight = _inFlight[id];
    final conv = _known[id];
    if (flight == null) return;
    if (conv == null) return _gone(id);
    flight.cancel?.call();
    flight.cancel = null;
    await _commit(conv, flight.purpose, flight.commit);
  }

  /// The API's conversations, which this device knows from now on; the states of those it's no longer in go.
  Future<void> _list() async {
    final listed = await _api.api.getConversations();
    _known
      ..clear()
      ..addAll({for (final conv in listed) conv.id: _Conv(conv)});
    for (final id in [..._states.keys]) {
      if (!_known.containsKey(id)) _set(id, null);
    }
  }

  /// The conversation as the API lists it now: null for one the user isn't in.
  Future<_Conv?> _fresh(String id) async {
    await _list();
    return _known[id];
  }

  void _set(String id, ConversationState? state) {
    if (_states[id] == state) return;
    if (state == null) {
      _states.remove(id);
    } else {
      _states[id] = state;
    }
    _changed(id, state);
  }
}
