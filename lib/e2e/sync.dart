/// A conversation's queue and group (PLAN-E2E-CLIENTES.md, «La cola de una conversación», «Entrar a un grupo», «Un
/// commit sin respuesta», «Lo periódico»). What the API numbers in each conversation goes to the core by its number,
/// from the gateway's events and from the queue: a repeat is skipped, and a gap or an entry without its data reads the
/// queue from where the core is, 50 entries an apply. A device out of the group comes in by its welcome, read from the
/// queue, or an external commit, and makes the group where it may; its commits go through commits.dart, their bytes
/// kept until an answer comes, the members routes' too (members.dart: an addition, a removal) and a member's leave.
/// The engine runs this work in its turn, one conversation at a time: this class keeps what's between turns, the
/// entries heard, the commits whose requests go on, and what each conversation says to the person. The desktop's
/// sync.ts in Dart, with its review's rulings.
library;

import 'dart:async';
import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'commits.dart';
import 'deviceless.dart';
import 'engine.dart';
import 'failures.dart';
import 'groups.dart';
import 'host.dart';
import 'identity.dart';
import 'legacy.dart';
import 'members.dart';
import 'store.dart';

/// What a conversation says over its message box of its group (PLAN-E2E-CLIENTES.md, «Avisos»): blocked; waiting for
/// its owner to make it; waiting for another member to let this device back in; members other than its record's, or
/// than those its group holds; a group that holds a user, a kind or an owner the person doesn't see in the conversation
/// (C1 of step 4's closing reviews); or, while it goes on, the members who can't receive what's sent yet (`no_device`).
enum ConversationNotice { blocked, waitOwner, waitRejoin, membersChanged, groupDiffers, noDevice }

/// A conversation as its chat draws it: whether it's a group, a group's owner, and its members' users.
typedef ShownConversation = ({bool group, String? owner, List<String> users});

/// Whether a chat draws [member] at all: listed with their own profile, so by one ID, the membership's, which the
/// group is held to. One whose profile names another ID isn't drawn anywhere (R-I1 of step 4's closing re-review).
bool drawnMember(duvet.ConversationMember member) => member.user?.id == member.userId;

/// [conv] as a chat of [me]'s draws it from the API's listing (N-C1 of step 4's closing re-review): the person, and the
/// members the chat names ([drawnMember]). A DM is the person and the one other its view shows, the first listed,
/// whatever else its listing holds: no addition to a DM is drawn (N-I1).
ShownConversation drawnOf(duvet.Conversation conv, String me) {
  final group = conv.type == duvet.ConversationType.group;
  final others = [
    for (final member in conv.members)
      if (drawnMember(member) && member.userId != me) member.userId,
  ];
  return (group: group, owner: group ? conv.ownerId : null, users: [me, ...group ? others : others.take(1)]);
}

/// Who may restart a blocked group: this user, its owner, or nobody (a group under an external sender other than the
/// pinned one, which no restart changes).
enum Restart { mine, owner, none }

/// What a conversation says of its group ([name]), with who may restart a blocked one, and its owner: a group's, whose
/// restart or making the others wait for; and its members without a device, or whom a group that differs from the
/// conversation holds ([users]).
@immutable
class ConversationState {
  const ConversationState.blocked({required Restart this.restart, this.owner})
    : name = ConversationNotice.blocked,
      users = const [];

  const ConversationState.waitOwner(String this.owner)
    : name = ConversationNotice.waitOwner,
      restart = null,
      users = const [];

  const ConversationState.noDevice(this.users) : name = ConversationNotice.noDevice, restart = null, owner = null;

  /// The group holds whom the conversation doesn't show ([users]: everyone it holds, whom what's sent would reach).
  const ConversationState.groupDiffers(this.users)
    : name = ConversationNotice.groupDiffers,
      restart = null,
      owner = null;

  /// Its members aren't those this device would go in with ([users]: whom a yes has it go in with, the conversation's
  /// members as the API lists them; N-M10 of step 4's closing re-review).
  const ConversationState.membersChanged(this.users)
    : name = ConversationNotice.membersChanged,
      restart = null,
      owner = null;

  const ConversationState._(this.name) : restart = null, owner = null, users = const [];

  static const waitRejoin = ConversationState._(ConversationNotice.waitRejoin);

  final ConversationNotice name;
  final Restart? restart;
  final String? owner;
  final List<String> users;

  @override
  bool operator ==(Object other) =>
      other is ConversationState &&
      other.name == name &&
      other.restart == restart &&
      other.owner == owner &&
      listEquals(other.users, users);

  @override
  int get hashCode => Object.hash(name, restart, owner, Object.hashAll(users));

  @override
  String toString() =>
      'ConversationState(${name.name}${restart == null ? '' : ', ${restart!.name}'}, $owner'
      '${users.isEmpty ? '' : ', $users'})';
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

/// The most JavaScript's numbers hold exactly, which the desktop counts with: the API sends no number past it.
const _mostExact = (1 << 53) - 1;

/// A number the engine counts with (an entry's, a group's generation): a whole one of 0 or more that the desktop holds
/// exactly too, which refuses any other.
bool _counts(int? value) => value != null && value >= 0 && value <= _mostExact;

/// An encrypted message (DM_MESSAGE_CREATE's) as its queue's entry: its ciphertext the data, its ID the message's, its
/// author and device the sender's, each as the server gave it. None of a notice's, which has no number, nor of a
/// message the API never sends so: without its conversation, or whose number, generation, epoch or time isn't one. Its
/// time is the message's, never one made up, which the core would show as its own.
({String conversation, Map<String, Object?> entry})? messageEntry(duvet.DirectMessage message) {
  final (conversation, seq, sentAt) = (message.conversationId, message.seq, message.sentAt);
  if (conversation == null || conversation.isEmpty || ![seq, message.generation, message.epoch].every(_counts)) {
    return null;
  }
  if (sentAt == null || sentAt < -_mostExact || sentAt > _mostExact) return null;
  return (
    conversation: conversation,
    entry: {
      'seq': seq,
      'kind': 'message',
      'data': message.ciphertext,
      'sent_at': sentAt,
      'message_id': message.id,
      'sender_user': message.authorId,
      'sender_device': ?message.senderDeviceId,
      if (message.mentions.isNotEmpty) 'mentions': message.mentions,
      'reply_to': ?message.referencedMessage?.messageId,
    },
  );
}

/// The entry an event carries, with its conversation and, of a group's own events, its generation: none from what has
/// none (a notice's message, its deletion), nor from what isn't one (no conversation, a number that doesn't count).
@visibleForTesting
({String conversation, Map<String, Object?> entry, int? generation})? carriedEntry(duvet.GatewayEventPayload event) =>
    switch (event) {
      duvet.MlsCommitPayloadEvent(:final data) => _eventEntry(data.conversationId, data.entry, data.generation),
      duvet.MlsWelcomePayloadEvent(:final data) => _eventEntry(data.conversationId, data.entry, data.generation),
      duvet.MlsProposalPayloadEvent(:final data) => _eventEntry(data.conversationId, data.entry, data.generation),
      duvet.DMMessageEditedEvent(:final data) => _eventEntry(data.conversationId, data.entry, null),
      duvet.DMMessageDeletedEvent(data: duvet.DMMessageDeleteEvent(:final conversationId, :final entry?)) =>
        _eventEntry(conversationId, entry, null),
      duvet.DMMessageCreatedEvent(:final data) => switch (messageEntry(data)) {
        (:final conversation, :final entry) => (conversation: conversation, entry: entry, generation: null),
        null => null,
      },
      _ => null,
    };

({String conversation, Map<String, Object?> entry, int? generation})? _eventEntry(
  String conversation,
  duvet.MlsEntry entry,
  int? generation,
) => conversation.isEmpty || !_counts(entry.seq) || (generation != null && !_counts(generation))
    ? null
    : (conversation: conversation, entry: entryOf(entry), generation: generation);

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
  due,
  add,
  remove;

  /// A commit on the group the device holds, which a refusal leaves staged for the queue to settle.
  bool get member => this == renew || this == renewAgain || this == due || this == add || this == remove;
}

/// A commit whose request goes on: its bytes, sent again as they are until an answer comes, by its route ([send]: a
/// member's addition or removal; …/mls/commits without one).
class _InFlight {
  _InFlight(this.purpose, this.commit, this.send, this.user);
  final _Purpose purpose;
  final duvet.Commit commit;
  final Future<duvet.CommitTaken> Function(duvet.Commit commit)? send;

  /// The user an addition or a removal is of: made again when its resend loses its epoch.
  final String? user;
  var tries = 0;
  void Function()? cancel;
}

/// A turn that failed, and its retry.
class _Retry {
  var tries = 0;
  void Function() cancel = () {};
}

/// The group as the core holds it (its `group`).
typedef _Held = HeldMembers;

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

/// What a welcome is refused for when its members aren't the ones this device holds: its record's (a conversation from
/// before the cutover), or, for a group it holds, a restart's that leaves out whom no statement it holds lets go, or
/// that isn't the owner's. Either way the device joins that generation only on its person's yes (the core's #46).
const membersRefusedRules = {'member_list_mismatch', 'members_changed_by_non_owner'};

/// The generations of conversations whose members a welcome or a join was refused for, as [store] keeps them (M4 of the
/// review): by conversation, kept across restarts, as a push's engine can see the refusal first.
Map<String, int> refusedGenerationsIn(EngineStore store) => _refusedOf(store.read(refusedGenerations));

Map<String, int> _refusedOf(Object? record) => {
  for (final MapEntry(:key, :value) in switch (record) {
    final Map<String, Object?> kept => kept.entries,
    _ => const <MapEntry<String, Object?>>[],
  })
    if (value is int) key: value,
};

/// Keeps [generation] of the conversation as refused in [store] (null: none any more), over the refusals the record
/// holds as it's kept: the other engine's stay (mobile#345).
Future<void> recordRefusedGeneration(EngineStore store, String conversationId, int? generation) {
  if (generation == null && !refusedGenerationsIn(store).containsKey(conversationId)) return Future.value();
  return store
      .update(refusedGenerations, (record) {
        final kept = _refusedOf(record);
        if (generation == null) {
          kept.remove(conversationId);
        } else {
          kept[conversationId] = generation;
        }
        return kept;
      })
      .catchError((Object error) => debugPrint("e2e: a refused generation wasn't kept: $error"));
}

/// How many times an addition or a removal is made again after another commit took its epoch.
const _changeTries = 3;

/// A change of the members whose request got no answer yet: its bytes go again on their own (_commit).
CoreError _unanswered() => CoreError('unanswered', message: 'no answer came yet: the change goes again on its own');

/// The entries that are a conversation's messages, and what an apply did to one that changes what it shows.
const _messageKinds = {'message', 'edit', 'delete'};
const _shownChanges = {'applied', 'own', 'undecryptable'};

class Conversations {
  Conversations(this._engine, this._soon, this._failures, this._changed, this._messages, this._deleted)
    : _legacy = LegacyRecords(_engine.store),
      _catchUps = CatchUps(_engine, _soon);

  final E2EEngine _engine;

  /// Runs work in the engine's turn, while the device is ready.
  final void Function(Future<void> Function() work) _soon;
  final Failures _failures;
  final void Function(String conversationId, ConversationState? state) _changed;

  /// A conversation's messages changed on this device: an apply opened, kept or took some.
  final void Function(String conversationId) _messages;

  /// Messages an apply learned were deleted (a tombstone it took, one the queue serves as deleted): their files go
  /// (task 18's review, M4).
  final void Function(String conversationId, List<String> messageIds) _deleted;
  final LegacyRecords _legacy;
  final CatchUps _catchUps;

  CoreHost get _host => _engine.host;
  duvet.E2eApi get _api => _engine.api;
  String get _user => _engine.user;

  /// The API's external sender, as this device pinned it (Ruling 32).
  var _sender = '';

  /// The API's conversations as last listed, their groups as the events and the queue have told of them since.
  final _known = <String, _Conv>{};

  /// Entries heard by events, by conversation and number, until the conversation's turn.
  final _heard = <String, Map<int, Map<String, Object?>>>{};

  /// The generations of the welcomes heard or read, by conversation and number, until they're applied: a welcome the
  /// core refuses for its members is marked with its own (M4).
  final _welcomeGenerations = <String, Map<int, int>>{};

  /// Conversations whose turn for what they heard is on its way, which what they hear meanwhile joins.
  final _turns = <String>{};
  final _states = <String, ConversationState>{};
  final _inFlight = <String, _InFlight>{};

  /// Commits whose bytes went with the app, or that the API refused but for the validator: the queue settles them, or
  /// they're said to be refused (Ruling 25).
  final _settling = <String>{};

  /// How far the core applied each conversation's queue, as its last apply this run said: null out of its group, and
  /// no entry before its first apply. A row past it isn't applied yet, and draws as loading (M2 of the desktop's task
  /// 16 review; M1 of task 17's).
  final _through = <String, int?>{};

  /// How far this device applied the conversation's queue this run: none before its first apply, `through` null while
  /// this device is out of its group.
  ({int? through})? applied(String conversationId) =>
      _through.containsKey(conversationId) ? (through: _through[conversationId]) : null;

  /// Due commits' waits, and failed turns' retries, by conversation.
  final _due = <String, void Function()>{};
  final _retries = <String, _Retry>{};

  /// External commits that lost their epoch in a row, by conversation; and those whose last one lost, after which a
  /// welcome from where the device's leaf began is stale.
  final _joinsLost = <String, int>{};
  final _lostJoin = <String>{};

  /// Groups under an external sender other than the pinned one: this device never goes in (Ruling 32).
  final _otherSender = <String>{};

  /// Groups whose members aren't their record's, or than its group holds (a restart's welcome its core refused, a newer
  /// generation with other members), until the person says yes ([accept]): the generation refused, by conversation,
  /// kept in the engine's store across restarts (M4 of the review).
  late final _refused = refusedGenerationsIn(_engine.store);

  /// The person's yes, by conversation: the generation it was given for and the members the question named ([_asked]),
  /// which a founding after it is held to, and a join goes only while the API lists them; it goes with the refusal it
  /// answered (M5 of the desktop's review; N-M10 of step 4's closing re-review).
  final _accepted = <String, ({int generation, LegacyRecord record})>{};

  /// Whom each conversation's question of changed members names: the members, and a group's owner, a yes has this
  /// device go in with, as the API listed the conversation when it asked.
  final _asked = <String, LegacyRecord>{};

  /// The group [_deviceless] was worked out from, by conversation: once the core's members differ, or those of them
  /// with a device in it, it's asked again (I3; #350).
  final _devicelessFrom = <String, _Held>{};

  /// Restarts the core or the API refused, by conversation: the queue's last number then. Restart stays off until a
  /// new entry comes (M1 of the review).
  final _restartRefused = <String, int>{};

  /// Each conversation's members without a device, as this device last told its core (deviceless.dart).
  final _deviceless = <String, List<String>>{};

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
    _catchUps.stop();
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
    _accepted.clear();
    _asked.clear();
    _deviceless.clear();
    _devicelessFrom.clear();
    _restartRefused.clear();
    _refused.clear();
    for (final kept in [_settling, _otherSender, _removed, _lostJoin]) {
      kept.clear();
    }
  }

  /// What was heard goes: the engine isn't ready for it, and the queue keeps it all (M3 of the desktop's review).
  void dropHeard() {
    _heard.clear();
    _welcomeGenerations.clear();
    _turns.clear();
    // A catch-up whose turn was skipped, as the engine wasn't ready, is asked for again by the next apply (M3).
    _catchUps.dropQueued();
  }

  ConversationState? state(String conversationId) => _states[conversationId];

  /// An event of a conversation's: its entry kept by its number, and the conversation's turn asked for, once what came
  /// with it is heard too, so a batch goes to the core in its order whatever order it came in (M8 of the desktop's
  /// review).
  void heard(duvet.GatewayEventPayload event) {
    final carried = carriedEntry(event);
    if (carried == null) return;
    final (:conversation, :entry, :generation) = carried;
    _hear(conversation, entry, generation);
    if (!_turns.add(conversation)) return;
    _soon(() async {
      await Future<void>.delayed(Duration.zero);
      _turns.remove(conversation);
      await sync(conversation);
    });
  }

  /// Entries an answer gave (an edit's, a deletion's): applied now, in this turn, as heard ones are.
  Future<void> take(String conversationId, List<Map<String, Object?>> entries) async {
    for (final entry in entries) {
      _hear(conversationId, entry, null);
    }
    await sync(conversationId);
  }

  /// An entry kept by its number until the conversation's turn, and the queue's end it says.
  void _hear(String conversation, Map<String, Object?> entry, int? generation) {
    final seq = entry['seq']! as int;
    (_heard[conversation] ??= {})[seq] = entry;
    if (generation != null && entry['kind'] == 'welcome') (_welcomeGenerations[conversation] ??= {})[seq] = generation;
    if (_known[conversation]?.group case final group?) {
      group.lastSeq = max(group.lastSeq, seq);
      group.generation = max(group.generation, generation ?? 0);
    }
  }

  /// Before this device sends there (PLAN-E2E-CLIENTES.md, «Enviar»): the conversation's group as it is now, its queue
  /// applied, joined or made where it has none. Without it, blocked, or holding someone the person doesn't see there
  /// ([asShown]), nothing can be sent: the conversation says why.
  Future<void> current(String conversationId) async {
    await open(conversationId);
    final held = await _group(conversationId);
    if (held == null || held.blocked) throw StateError("this device can't send in this conversation now");
    await asShown(conversationId);
  }

  /// Before anything more goes to the conversation (C1 of step 4's closing reviews): the person sees it, and its group
  /// holds no user, and no kind or owner, that the person doesn't see in it (N-C1 of the re-review). The queue is read
  /// whole and a due commit made first, so a member who left, whose removal the API proposed, goes as in any honest
  /// group; else the conversation says so, and this throws, as it does while what's drawn can't be read yet.
  Future<void> asShown(String conversationId) async {
    final held = await _group(conversationId);
    if (held == null || !await _strays(conversationId, held)) return;
    await sync(conversationId, read: true);
    await commitDue(conversationId);
    final now = await _group(conversationId);
    if (now != null && !await _strays(conversationId, now)) return;
    if (now != null && !now.blocked) _set(conversationId, ConversationState.groupDiffers(now.members));
    throw StateError("this device can't send in this conversation now");
  }

  /// What [asShown] compares, with no queue read and no move (T-C1 of step 4's closing re-reviews): the last thing
  /// before what was made for the group goes, so what goes is of the group compared. A difference says so and throws.
  Future<void> stillAsShown(String conversationId) async {
    final held = await _group(conversationId);
    if (held != null && !await _strays(conversationId, held)) return;
    if (held != null && !held.blocked) _set(conversationId, ConversationState.groupDiffers(held.members));
    throw StateError("this device can't send in this conversation now");
  }

  /// Whether the core's group is at [generation] and [epoch] now: what was made for it is of it.
  Future<bool> isAt(String conversationId, int generation, int epoch) async {
    final held = await _group(conversationId);
    return held != null && held.generation == generation && held.epoch == epoch;
  }

  /// The person made the conversation here with [picked]: its group is founded with them alone.
  Future<void> created(String conversationId, LegacyRecord picked) => _legacy.created(conversationId, picked);

  /// A commit of this device's waits for its word (encrypt's `pending_commit`): the request of one in flight goes
  /// again, which the API answers as it did; one whose bytes went with the app is told no answer came, and the queue
  /// settles it, or, read whole a minute past the start, it's said to be refused («Un commit sin respuesta»).
  Future<void> settleCommit(String conversationId) async {
    if (_inFlight.containsKey(conversationId)) return _resend(conversationId);
    final answered = await _host.handle<Map<String, Object?>>({
      'cmd': 'commit_result',
      'conversation_id': conversationId,
      'accepted': false,
    });
    if (answered['epoch'] != null) _settling.add(conversationId);
    await sync(conversationId, read: true);
  }

  /// The proposals and leaves off their lists that keep this device from sending (encrypt's pending_proposals),
  /// committed.
  Future<void> commitDue(String conversationId) async {
    final conv = _known[conversationId] ?? await _fresh(conversationId);
    if (conv != null && !_inFlight.containsKey(conversationId)) await _own(conv, 'commit_pending', _Purpose.due);
  }

  /// At the start and at each READY: the API's conversations, each one's record made the first time it's seen, the
  /// queue of each with a group, and the commits whose requests had no answer sent again.
  Future<void> all() async {
    await _list();
    for (final conv in [..._known.values]) {
      try {
        await _record(conv.api);
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

  /// The person's restart of the conversation's blocked group, which only its owner (in a DM, either member) makes,
  /// with the members and owner the API has (reset_group). Whom it leaves out, those the core's group holds that the
  /// API no longer lists, the person confirms first (the core's #46): while [leaving] isn't them, nothing is made, and
  /// they're what this answers. A reset the core refuses (a successor's, without a statement it needs) leaves the group
  /// blocked, and throws.
  Future<List<String>> restart(String conversationId, List<String> leaving) async {
    if (_inFlight.containsKey(conversationId)) return const [];
    // Who may restart, from the list as it is now and the group the core holds blocked (the desktop's check).
    final conv = await _fresh(conversationId);
    final held = await _group(conversationId);
    if (conv == null || held == null || !held.blocked || _blocked(conv).restart != Restart.mine) return const [];
    final out = leftOut(held, conv.api);
    if (!sameUsers(out, leaving)) return out;
    final duvet.Commit commit;
    try {
      commit = await restartGroup(_engine, conv.api);
    } on CoreError catch (error) {
      if (error.code == 'rule_violation') _refuseRestart(conv);
      rethrow;
    }
    if (await _commit(conv, _Purpose.restart, commit) == Sent.invalid) {
      _refuseRestart(conv);
      throw CoreError('rule_violation', message: 'the API refused the restart', rule: 'restart_refused');
    }
    return const [];
  }

  /// A restart refused: Restart stays off until a new entry comes, so no tap claims key packages for nothing (M1).
  void _refuseRestart(_Conv conv) {
    _restartRefused[conv.id] = conv.group?.lastSeq ?? 0;
    _set(conv.id, _blocked(conv));
  }

  /// The person's yes to the members the question named ([_asked]): the record goes, and this device goes in with them,
  /// by an external commit while the API lists them, or by making the group with them alone where there's none (M6 of
  /// the desktop's review; N-M10 of step 4's closing re-review): a listing with others by then asks again. The yes is
  /// to [users], those the question named as the person was shown it: once it names others, asked again since, the
  /// yes is none (R-M2 of the re-review).
  Future<void> accept(String conversationId, List<String> users) async {
    final asked = _asked[conversationId];
    if (!_refused.containsKey(conversationId) || asked == null || !sameUsers(users, asked.members)) return;
    final conv = await _fresh(conversationId);
    if (conv == null) return _gone(conversationId);
    await _legacy.drop(conversationId);
    final generation = _refused[conversationId] ?? 0;
    await _unrefuse(conversationId);
    _accepted[conversationId] = (generation: max(generation, conv.group?.generation ?? 0), record: asked);
    _set(conversationId, null);
    if (conv.group == null) return open(conversationId);
    await _join(conv);
  }

  Future<void> _refuse(String id, int generation) async {
    _refused[id] = generation;
    await recordRefusedGeneration(_engine.store, id, generation);
  }

  Future<void> _unrefuse(String id) async {
    if (_refused.remove(id) != null) await recordRefusedGeneration(_engine.store, id, null);
  }

  /// The owner's addition of a user (PLAN-E2E-CLIENTES.md, «Qué se manda», its members' row): one commit of exactly
  /// that user, with a key package of each of their devices, to POST …/members, on the group as it is now. The cap
  /// holds before anything is asked. One whose epoch another commit took is made again on top of it; one that went
  /// before (its user a member now) is done. The member, as the API answered or lists them.
  Future<duvet.ConversationMember> add(String conversationId, String user) async {
    for (var tries = 1; ; tries++) {
      final conv = await _memberChange(conversationId);
      if (conv.api.members.where((m) => m.userId == user).firstOrNull case final member?) return member;
      checkAddition(conv.api, _user, user);
      final held = await _changeable(conv);
      // A change that waited went first: the list as it is now says whether it was this one (M2).
      if (held.members.contains(user)) {
        final listed = (await _fresh(conv.id))?.api.members.where((m) => m.userId == user).firstOrNull;
        if (listed != null) return listed;
      }
      duvet.ConversationMember? added;
      final made = await addition(_engine, conv.api, user, held);
      final (:sent, :refusal) = await _change(conv, _Purpose.add, made, user, (commit) async {
        final answer = await _api.addMember(conv.id, user, commit);
        added = answer;
        return answer.commit;
      });
      if (sent == Sent.accepted && added != null) return added!;
      if (sent != Sent.lost || tries >= _changeTries) throw refusal!;
    }
  }

  /// The owner's removal of a member: one commit that takes them out, every device of theirs with them.
  Future<void> remove(String conversationId, String user) async {
    for (var tries = 1; ; tries++) {
      final conv = await _memberChange(conversationId);
      if (!conv.hasMember(user)) return;
      final held = await _changeable(conv);
      if (!held.members.contains(user)) return;
      final made = await removal(_engine, conv.api, user, held);
      final (:sent, :refusal) = await _change(
        conv,
        _Purpose.remove,
        made,
        user,
        (commit) => _api.removeMember(conv.id, user, commit),
      );
      if (sent == Sent.accepted) return;
      if (sent != Sent.lost || tries >= _changeTries) throw refusal!;
    }
  }

  /// The user leaves the conversation (PLAN-E2E-CLIENTES.md, «Qué se manda», its leave's row): with their statement,
  /// which this device signs on its group as it is now, where it has one; without one where it hasn't. Nobody commits
  /// their own removal: the API proposes it, and a member's commit makes it. A leave sent again after its answer was
  /// lost is a 403, as its user isn't a member any more: the list says so, and it's the leave (step 3's closing
  /// review).
  Future<void> leave(String conversationId) async {
    final conv = await _fresh(conversationId);
    if (conv == null) return _gone(conversationId);
    String? statement;
    if (conv.group != null) {
      // The statement is of the group's generation and an epoch it reached: the queue first.
      await sync(conv.id);
      // Only a device in the API's generation signs a statement it takes (M6): another leaves, or this one goes in.
      final held = await _group(conv.id);
      if (held == null || held.generation < (conv.group?.generation ?? 0)) {
        throw CoreError('not_in_group', message: "this device isn't in the conversation's group", what: 'group');
      }
      final left = await _host.handle<Map<String, Object?>>({'cmd': 'leave', 'conversation_id': conv.id});
      statement = left['statement']! as String;
    }
    try {
      await _api.leave(conv.id, statement: statement);
    } on duvet.DuvetApiException catch (error) {
      // Gone already, by another of the user's devices or an earlier try: the list says so (a 403 or a 404).
      if (!const [403, 404].contains(error.statusCode) || await _fresh(conv.id) != null) rethrow;
    }
    _gone(conv.id);
  }

  /// As the person opens the conversation (PLAN-E2E-CLIENTES.md, «Quien no tenía dispositivo»): its members without a
  /// device, told to the core, which notes what this device sends them; while the group goes on, the conversation
  /// says who they are. Nothing without a group here, which the core needs.
  Future<void> checkDevices(String conversationId) async {
    var conv = _known[conversationId];
    final held = conv?.group == null ? null : await _group(conversationId);
    if (conv == null || held == null) return;
    if (!held.members.every(conv.hasMember)) conv = await _fresh(conversationId) ?? conv;
    _devicelessFrom[conv.id] = held;
    _deviceless[conv.id] = await withoutDevices(_engine, conv.api, held);
    final now = _states[conv.id];
    if (now == null || now.name == ConversationNotice.noDevice) _set(conv.id, _goingOn(conv.id));
  }

  /// Whom what goes to the conversation reaches (review 28's I1, contacts.dart): the users its group holds on this
  /// device, its members and its devices' users, with those the API lists, as a server could list it without someone
  /// its group still holds.
  Future<List<String>> people(String conversationId) async {
    final users = {...members(conversationId)};
    try {
      final held = await _host.handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': conversationId});
      for (final part in [held['members'], held['devices']]) {
        for (final entry in part as List? ?? const []) {
          if (entry case {'user_id': final String user}) users.add(user);
        }
      }
    } on CoreError catch (error) {
      if (error.code != 'not_found') rethrow;
    }
    return [...users];
  }

  /// The conversation's members as the API listed them last: none for one it doesn't know.
  List<String> members(String conversationId) => [
    for (final member in _known[conversationId]?.api.members ?? const <duvet.ConversationMember>[]) member.userId,
  ];

  /// The catch-ups held for the person's yes are asked for again (contacts.dart): it may have come.
  void catchUpsAgain() => _catchUps.again();

  /// A user's identity changed (IDENTITY_UPDATE): their conversations' members without a device are asked again.
  Future<void> identityChanged(String user) async {
    for (final conv in [..._known.values]) {
      if (!conv.hasMember(user)) continue;
      try {
        await checkDevices(conv.id);
      } catch (error) {
        debugPrint("e2e: who has no device waits for the conversation's next open: $error");
      }
    }
  }

  /// The API changed a conversation (CONVERSATION_UPDATE: its owner, when they left): listed again, its state goes by
  /// the conversation as it is now, a blocked group's restart offered to its new owner.
  Future<void> changed(String conversationId) async {
    if (!_known.containsKey(conversationId)) return;
    if (await _fresh(conversationId) == null) return _gone(conversationId);
    await sync(conversationId);
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
      if (const [403, 404].contains(_statusOf(error)) && await left(conversationId)) return _gone(conversationId);
      _retryLater(conversationId);
      rethrow;
    }
    _retries.remove(conversationId)?.cancel();
  }

  /// Whether the user is no longer in the conversation, as the API lists it now: false when that can't be read.
  Future<bool> left(String id) async {
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

  /// The conversation is no longer the user's (left, removed, deleted): nothing more is asked of it, its catch-ups and
  /// a generation its person was asked about let go too, as the desktop's drop does (step 5's engines review, Minor 7).
  void _gone(String id) {
    _retries.remove(id)?.cancel();
    _inFlight.remove(id)?.cancel?.call();
    _due.remove(id)?.call();
    _heard.remove(id);
    _welcomeGenerations.remove(id);
    _joinsLost.remove(id);
    _accepted.remove(id);
    _asked.remove(id);
    _catchUps.forget(id);
    // The record's write logs its own failure: the refusal goes from memory at once.
    unawaited(_unrefuse(id));
    _deviceless.remove(id);
    _devicelessFrom.remove(id);
    _restartRefused.remove(id);
    for (final kept in [_settling, _otherSender, _removed, _lostJoin]) {
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

  /// The group made here with the members this device can account for (C1 of step 4's closing reviews): those the
  /// person said yes to, as a question named them (N-M10 of the re-review); its record (the person's picks as they made
  /// the conversation here, or one from before the cutover as first seen); else the conversation as the person sees
  /// it, asked again of a fresh listing. The API gives their order, never the set or the kind: a listing that differs
  /// founds nothing, and the conversation says so; one the person doesn't see waits.
  Future<void> _make(_Conv conv) async {
    final record = _accepted[conv.id]?.record ?? await _record(conv.api);
    var accounted = record ?? _recordOf(await _shown(conv.id));
    if (record == null && accounted != null && !_isRecord(conv.api, accounted)) {
      accounted = _recordOf(await _shown(conv.id, fresh: true));
    }
    if (accounted == null) return;
    if (!_isRecord(conv.api, accounted)) return _membersChanged(conv);
    final duvet.Commit commit;
    try {
      commit = await makeGroup(_engine, conv.api, _sender, accounted);
    } on CoreError catch (error) {
      if (error.code == 'exists') return debugPrint("e2e: this device holds a group the API doesn't list.");
      if (error.rule == 'member_list_mismatch') return _membersChanged(conv);
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
    final record = await _record(conv.api);
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
    final resultOf = {for (final r in results) r.seq: r.result};
    _deleted(conv.id, [
      for (final entry in entries)
        if (entry['message_id'] case final String message)
          if (entry['deleted'] == true || (entry['kind'] == 'delete' && _shownChanges.contains(resultOf[entry['seq']])))
            message,
    ]);
    final through = applied['applied_through'] as int?;
    final moved = !_through.containsKey(conv.id) || _through[conv.id] != through;
    _through[conv.id] = through;
    // What a chat shows of the conversation is read again: a message changed, or its rows past the queue applied.
    if (moved || results.any((r) => _messageKinds.contains(r.kind) && _shownChanges.contains(r.result))) {
      _messages(conv.id);
    }
    final generations = _welcomeGenerations[conv.id];
    for (final (:kind, :result, :rule, :seq, epoch: _, reason: _) in results) {
      final refused = kind == 'welcome' && result == 'rejected';
      if (refused && rule == 'external_sender_mismatch') _otherSender.add(conv.id);
      if (refused && membersRefusedRules.contains(rule)) {
        await _refuse(conv.id, generations?[seq] ?? conv.group?.generation ?? 0);
      }
      // A commit of its epoch, its own or another's: a commit of this device's left to settle is settled.
      if (kind == 'commit' && result != 'ignored') _settling.remove(conv.id);
      if (result == 'removed') _removed.add(conv.id);
    }
    // The welcomes applied go with their generations.
    generations?.removeWhere((seq, _) => seq <= (through ?? 0));
    // Members who had no device have one now: what this device noted for them goes (deviceless.dart).
    if (applied['catch_up_due'] case final List<Object?> due when due.isNotEmpty) _catchUps.due(conv.id, due.cast());
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
      for (final entry in page.entries) {
        if (entry.kind == 'welcome') (_welcomeGenerations[conv.id] ??= {})[entry.seq] = entry.generation;
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
      // A page that doesn't go past where this read was would come again as it is, for good: the turn ends, as for a
      // gap that doesn't move, and the queue is read again with the next.
      if (last <= from) throw StateError("the queue of ${conv.id} doesn't go past entry $from");
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

  /// The conversation as the person sees it ([E2EEngine.shown]), [fresh] from a listing made now: null for one not
  /// drawn. Never as this engine lists it (N-C1 of step 4's closing re-review); one that can't be read yet throws.
  Future<ShownConversation?> _shown(String id, {bool fresh = false}) => _engine.shown(id, fresh: fresh);

  /// Whether the group holds a user, a kind or an owner that the conversation as the person sees it doesn't: asked
  /// again of a fresh listing, as a member just added may not show yet. A conversation not drawn differs.
  Future<bool> _strays(String id, _Held held) async =>
      _differs(held, await _shown(id)) && _differs(held, await _shown(id, fresh: true));

  /// [_strays] for what the conversation says of its group: false while what's drawn can't be read yet (the session's
  /// first listing not in), when nothing goes there anyway, as [asShown] throws too.
  Future<bool> _saysStrays(String id, _Held held) async {
    try {
      return await _strays(id, held);
    } catch (error) {
      debugPrint("e2e: what the conversation draws couldn't be read yet: $error");
      return false;
    }
  }

  /// A DM as drawn is the person and one other, any other count differs (N-I1 of step 4's closing re-review); a group
  /// as drawn has the group's owner.
  bool _differs(_Held held, ShownConversation? shown) =>
      shown == null ||
      (held.owner != null) != shown.group ||
      (shown.group ? held.owner != shown.owner : shown.users.length != 2 || !shown.users.contains(_user)) ||
      held.members.any((user) => !shown.users.contains(user));

  /// The conversation's record ([LegacyRecords.of]), one made the first time it's seen held to what's drawn.
  Future<LegacyRecord?> _record(duvet.Conversation conv) => _legacy.of(conv, (made) => _drawnAs(conv.id, made));

  /// [conv] as the API lists it, as a record: its users, and a group's owner.
  static LegacyRecord _listedAs(duvet.Conversation conv) => (
    owner: conv.type == duvet.ConversationType.group ? conv.ownerId : null,
    members: [for (final member in conv.members) member.userId],
  );

  /// Whether [record] is the conversation as the person sees it: its kind, a group's owner and its users, whatever
  /// their order (N-M1 of step 4's closing re-review). False while that can't be read.
  Future<bool> _drawnAs(String id, LegacyRecord record) async {
    try {
      final shown = await _shown(id);
      return shown != null &&
          shown.group == (record.owner != null) &&
          (!shown.group || shown.owner == record.owner) &&
          sameUsers(shown.users, record.members);
    } catch (error) {
      debugPrint("e2e: what the conversation draws couldn't be read yet: $error");
      return false;
    }
  }

  static LegacyRecord? _recordOf(ShownConversation? shown) =>
      shown == null ? null : (owner: shown.group ? shown.owner : null, members: shown.users);

  /// Whether the API's conversation is [record], as the core's create_group holds a founding to it: its kind, a group's
  /// owner, and its users, whatever their order.
  static bool _isRecord(duvet.Conversation conv, LegacyRecord record) =>
      (conv.type == duvet.ConversationType.group ? conv.ownerId : null) == record.owner &&
      sameUsers([for (final m in conv.members) m.userId], record.members);

  /// The group as the core holds it, or null without one.
  Future<_Held?> _group(String id) async {
    try {
      final held = await _host.handle<Map<String, Object?>>({'cmd': 'group', 'conversation_id': id});
      return (
        generation: held['generation']! as int,
        epoch: held['epoch']! as int,
        blocked: held['blocked'] == true,
        owner: held['owner'] as String?,
        members: [for (final m in (held['members']! as List).cast<Map<String, Object?>>()) m['user_id']! as String],
        joined: {
          for (final device in held['devices'] as List? ?? const [])
            if (device case {'user_id': final String user}) user,
        }.toList(),
      );
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
      for (final kept in [_otherSender, _removed, _lostJoin]) {
        kept.remove(id);
      }
      // This device holds the group: the record of the conversation's creation here is done with.
      await _legacy.heldGroup(id);
      // In the API's generation, at or past any it refused: the refusal and its yes are done with.
      if (held.generation >= (_refused[id] ?? held.generation)) await _unrefuse(id);
      if (_accepted[id] case final yes? when held.generation >= yes.generation) _accepted.remove(id);
      // Its members changed since who has no device was worked out, or which of them have a device in it (a member's
      // first device in, or last one out): asked again (I3 of the review; #350).
      if (_devicelessFrom[id] case final from?
          when !held.blocked && (!sameUsers(from.members, held.members) || !sameUsers(from.joined, held.joined))) {
        try {
          await checkDevices(id);
        } catch (error) {
          debugPrint('e2e: who has no device waits for the next change: $error');
        }
      }
      // A group that holds whom the person doesn't see there is said, with the queue read whole, unless a due commit is
      // on its way (a member who left, whose removal the API proposed, goes with it).
      final strays = !held.blocked && !at.due && await _saysStrays(id, held);
      if (strays && !at.whole && at.through != null) {
        final done = await _readQueue(conv, at.through!);
        if (done != null) return _after(conv, done);
      }
      _set(id, held.blocked ? _blocked(conv) : (strays ? ConversationState.groupDiffers(held.members) : _goingOn(id)));
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
    final refused = _otherSender.contains(id) || (_refused[id] ?? -1) >= (now.group?.generation ?? 0);
    // After an external commit of its own lost its epoch, a welcome from where its leaf began is stale by then.
    final from = at.through ?? (_lostJoin.contains(id) || joined == null ? null : joined - 1);
    if (!refused && !at.whole && from != null) {
      final done = await _readQueue(now, from);
      if (done != null) return _after(now, done);
    }
    await _join(now);
  }

  ConversationState _blocked(_Conv conv) => ConversationState.blocked(
    restart: _otherSender.contains(conv.id) || (_restartRefused[conv.id] ?? -1) >= (conv.group?.lastSeq ?? 0)
        ? Restart.none
        : mayRestart(conv.api, _user)
        ? Restart.mine
        : Restart.owner,
    owner: conv.api.type == duvet.ConversationType.group ? conv.api.ownerId : null,
  );

  /// What a conversation whose group goes on says: who in it has no device yet, or nothing.
  ConversationState? _goingOn(String id) => switch (_deviceless[id]) {
    final users? when users.isNotEmpty => ConversationState.noDevice(users),
    _ => null,
  };

  /// Its members aren't those this device would go in with: the person says whether to go on ([accept]).
  Future<void> _membersChanged(_Conv conv, [int? generation]) async {
    await _refuse(conv.id, generation ?? conv.group?.generation ?? 0);
    _ask(conv);
  }

  /// The question of changed members, naming whom a yes has this device go in with: the conversation as the API last
  /// listed it, which the yes records (N-M10 of step 4's closing re-review).
  void _ask(_Conv conv) {
    final asked = _asked[conv.id] = _listedAs(_known[conv.id]?.api ?? conv.api);
    _set(conv.id, ConversationState.membersChanged(asked.members));
  }

  /// Whether this device may join [generation] (the group info's it fetched) by an external commit on its own: not
  /// one it refused, nor one newer than the core's with members (or a group's owner) other than those it holds, a
  /// restart it never saw, its welcome kept from it or past the queue's floor, which its core never judged (the core's
  /// #46), unless the person's yes was to that generation with these members.
  Future<bool> _mayJoin(_Conv conv, int generation) async {
    // The members as the API lists them now: those a join would bring this device in with.
    final now = (await _fresh(conv.id))?.api ?? conv.api;
    if (_accepted[conv.id] case final yes? when yes.generation == generation && _isRecord(now, yes.record)) {
      return true;
    }
    if ((_refused[conv.id] ?? -1) >= generation) return false;
    final held = await _group(conv.id);
    return held == null || held.generation >= generation || sameMembers(held, now);
  }

  /// A conversation whose members the user may change, as the API lists it now: one they aren't in is refused.
  Future<_Conv> _memberChange(String id) async =>
      await _fresh(id) ??
      (throw CoreError('not_found', message: "the user isn't in this conversation", what: 'conversation'));

  /// The group a change of its members goes on, as it is now: made here where it has none, its queue applied, and a
  /// commit of this device's still waiting there sent again first, which one left unanswered refuses.
  Future<_Held> _changeable(_Conv conv) async {
    if (_inFlight.containsKey(conv.id)) await _resend(conv.id);
    if (_inFlight.containsKey(conv.id)) throw _unanswered();
    await current(conv.id);
    return await _group(conv.id) ??
        (throw CoreError('not_found', message: 'this device holds no group here', what: 'group'));
  }

  /// A members route's commit, sent as every commit is (_commit): what came of it, and what the API refused it with.
  Future<({Sent sent, Object? refusal})> _change(
    _Conv conv,
    _Purpose purpose,
    duvet.Commit commit,
    String user,
    Future<duvet.CommitTaken> Function(duvet.Commit commit) send,
  ) async {
    Object? refusal;
    final sent = await _commit(conv, purpose, commit, (bytes) async {
      try {
        return await send(bytes);
      } catch (error) {
        refusal = error;
        rethrow;
      }
    }, user);
    return (sent: sent, refusal: sent == Sent.unanswered ? _unanswered() : refusal);
  }

  /// This device into the group by an external commit. The core asks no identities for it: refused for a rule, the
  /// members are observed and it's tried once more. Still refused, the conversation says why: members other than its
  /// record's, another external sender, a blocked group; or else this device waits for another member's commit (after
  /// it started over, the removal of its old devices) and tries again with each one ([ConversationState.waitRejoin]).
  Future<void> _join(_Conv conv) async {
    final id = conv.id;
    if (_otherSender.contains(id)) return _set(id, _blocked(conv));
    if ((_refused[id] ?? -1) >= (conv.group?.generation ?? 0)) return _ask(conv);
    if (_inFlight.containsKey(id)) return;
    if ((_joinsLost[id] ?? 0) >= _joinsLostMost) {
      _joinsLost.remove(id);
      return;
    }
    _settling.remove(id);
    // Decided on the generation of the group info it fetched (M4): one it refused, or never judged, waits for the yes.
    int? refusedAt;
    Future<bool> mayJoin(int generation) async {
      final may = await _mayJoin(conv, generation);
      if (!may) refusedAt = generation;
      return may;
    }

    Future<duvet.Commit?> join() async =>
        joinGroup(_engine, conv.api, _sender, await _record(conv.api), mayJoin: mayJoin);
    duvet.Commit? commit;
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
      if (await left(id)) _gone(id);
      return;
    } on CoreError catch (error) {
      // A commit of its own still waits for its word.
      if (error.code == 'pending_commit') return;
      if (error.code != 'rule_violation') rethrow;
      switch (error.rule) {
        case 'stale_group_info':
          return;
        case 'member_list_mismatch':
          return _membersChanged(conv, conv.group?.generation);
        case 'external_sender_mismatch':
          _otherSender.add(id);
          return _set(id, _blocked(conv));
        case 'group_blocked':
          return _set(id, _blocked(conv));
        default:
          return _set(id, ConversationState.waitRejoin);
      }
    }
    if (commit == null) return _membersChanged(conv, refusedAt);
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
  /// the epoch, and a renewal that lost so is made again on top of it, once. [send] is a members route's request, the
  /// commits route's without one. What came of it.
  Future<Sent> _commit(
    _Conv conv,
    _Purpose purpose,
    duvet.Commit commit, [
    Future<duvet.CommitTaken> Function(duvet.Commit commit)? send,
    String? user,
  ]) async {
    final id = conv.id;
    final flight = _inFlight[id] ??= _InFlight(purpose, commit, send, user);
    final Sent sent;
    try {
      sent = await sendCommit(_host, id, () => flight.send?.call(flight.commit) ?? _api.commit(id, flight.commit));
    } catch (error) {
      _resendLater(id, flight);
      rethrow;
    }
    if (sent == Sent.unanswered) {
      _resendLater(id, flight);
      return sent;
    }
    _inFlight.remove(id);
    if (sent == Sent.invalid) {
      // The validator refused it: it never entered, and nothing changed. An external commit so refused waits for the
      // conversation's next commit, as one the core refused would.
      debugPrint("e2e: the API refused a commit of this device's (${flight.purpose.name}).");
      if (flight.purpose == _Purpose.join) _set(id, ConversationState.waitRejoin);
      return sent;
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
    // An addition or a removal sent again on its own that another commit beat to its epoch: made again, as its notice
    // promised (I1 of the desktop's review). Its first send's caller does this itself.
    if (flight.user case final user? when sent == Sent.lost && flight.tries > 0) {
      try {
        await (flight.purpose == _Purpose.add ? add(id, user) : remove(id, user));
      } catch (error) {
        debugPrint("e2e: a change of the members sent again didn't go: $error");
      }
    }
    return sent;
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
    await _commit(conv, flight.purpose, flight.commit, flight.send, flight.user);
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
