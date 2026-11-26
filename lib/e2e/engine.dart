/// The encryption engine (PLAN-E2E-CLIENTES.md, «El motor»): it carries what the core makes to the API and what the
/// API hands out to the core, never opening or making anything itself. A class with its parts given to it, so the app
/// runs one (lib/data/duvet_repository.dart) and a test as many as it needs, each with its own core, session and
/// gateway connection. The desktop's engine is its twin in TypeScript, and the two share their tests' names.
///
/// Its work goes one flow at a time, in the order it came: the start («Arranque», steps 1 to 7), the person's taps,
/// and what the gateway's events ask for. bootstrap.dart, identity.dart, key_packages.dart and inbox.dart hold the
/// steps, sync.dart each conversation's queue and group; this class keeps the state the app shows, and what's due
/// later.
library;

import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart' as time;
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'bootstrap.dart';
import 'contacts.dart';
import 'content.dart';
import 'content.dart' as content show heldBefore, sentUnder;
import 'devices.dart';
import 'devices.dart' as devices show removeDevice, unsentRemovals;
import 'host.dart';
import 'identity.dart';
import 'inbox.dart';
import 'failures.dart';
import 'files.dart' as files show fileNames;
import 'history.dart';
import 'key_packages.dart';
import 'members.dart';
import 'search.dart';
import 'send.dart';
import 'store.dart';
import 'sync.dart';

export 'contacts.dart' show ContactsShown, KeyChange, SafetyNumber, ShownChange, changedIn, waitingForYes;
export 'content.dart' show Authored, MessageStatus, ShownMessage;
export 'devices.dart' show DeviceNotice, DeviceNoticeKind, inactiveDevice, onlyDevice;
export 'files.dart' show FilesGone;
export 'history.dart' show HistoryOffer, NoDeviceToShareWith, ShareLimit, SharedHistory, quietBeforeImport, shareRanges;
export 'members.dart' show maxGroupMembers;
export 'send.dart' show Outgoing, Pending, TooManyWaiting;
export 'sync.dart' show ConversationNotice, ConversationState, Restart;

/// What the engine waits with: the system's timers in the app, a test's clock in its tests.
abstract interface class EngineClock {
  /// Runs [run] once [wait] has passed; what it gives calls it off.
  void Function() later(Duration wait, void Function() run);
}

class SystemClock implements EngineClock {
  const SystemClock();

  @override
  void Function() later(Duration wait, void Function() run) => Timer(wait, run).cancel;
}

/// Where the engine is (PLAN-E2E-CLIENTES.md, «El motor», its states), which the app shows.
enum EngineStage { starting, firstDevice, newDevice, ready, removed, locked, unsupported, failed, update }

/// The engine's [stage], and what goes with it. A first device waits for the person's tap to make its identity, then
/// shows its [recoveryKey] until it's saved; [finishing] when an identity it made before the app closed still waits
/// for its upload. A ready device [rotating] its keys (Task 25) shows the new [recoveryKey] until it's saved, and none
/// once the rotation waits for the person to finish it (Later, or the app closed before its upload), or [stuck] once it
/// can never go up, another device having changed the user's devices or keys meanwhile (review 24's I1). A [lostKey] is
/// a database no key opens any more. [minimum] is the lowest version with encryption of a client the API told to
/// update, null where its platform has none.
@immutable
class EngineState {
  const EngineState(
    this.stage, {
    this.recoveryKey,
    this.finishing = false,
    this.lostKey = false,
    this.minimum,
    this.rotating = false,
    this.stuck = false,
  });

  const EngineState.rotation({this.recoveryKey, this.stuck = false})
    : stage = EngineStage.ready,
      finishing = false,
      lostKey = false,
      minimum = null,
      rotating = true;

  const EngineState.firstDevice({this.recoveryKey, this.finishing = false})
    : stage = EngineStage.firstDevice,
      lostKey = false,
      minimum = null,
      rotating = false,
      stuck = false;

  const EngineState.failed({this.lostKey = false})
    : stage = EngineStage.failed,
      recoveryKey = null,
      finishing = false,
      minimum = null,
      rotating = false,
      stuck = false;

  const EngineState.update(this.minimum)
    : stage = EngineStage.update,
      recoveryKey = null,
      finishing = false,
      lostKey = false,
      rotating = false,
      stuck = false;

  static const starting = EngineState(EngineStage.starting);
  static const newDevice = EngineState(EngineStage.newDevice);
  static const ready = EngineState(EngineStage.ready);
  static const removed = EngineState(EngineStage.removed);
  static const locked = EngineState(EngineStage.locked);
  static const unsupported = EngineState(EngineStage.unsupported);

  final EngineStage stage;
  final String? recoveryKey;
  final bool finishing;
  final bool lostKey;
  final String? minimum;
  final bool rotating;
  final bool stuck;

  @override
  bool operator ==(Object other) =>
      other is EngineState &&
      other.stage == stage &&
      other.recoveryKey == recoveryKey &&
      other.finishing == finishing &&
      other.lostKey == lostKey &&
      other.minimum == minimum &&
      other.rotating == rotating &&
      other.stuck == stuck;

  @override
  int get hashCode => Object.hash(stage, recoveryKey, finishing, lostKey, minimum, rotating, stuck);

  // Never the recovery key itself: a state may end up in a log.
  @override
  String toString() =>
      'EngineState(${stage.name}${rotating ? ', rotating' : ''}${stuck ? ', stuck' : ''}'
      '${recoveryKey == null ? '' : ', a key shown'}'
      '${finishing ? ', finishing' : ''}'
      '${lostKey ? ', its key lost' : ''}${stage == EngineStage.update ? ', minimum $minimum' : ''})';
}

const _day = Duration(days: 1);

/// A start that failed goes again after 2 s, then twice as long each time, up to a minute apart.
const _retryFirst = Duration(seconds: 2);
const _retryMost = Duration(minutes: 1);

/// The binding's refusals no try changes (a proof that doesn't verify, a body the API refuses), which end the tries
/// with the failed state. A rate limit, a renewal's 401 and an update's 426 pass.
bool _refusedForGood(Object error) =>
    error is duvet.DuvetApiException &&
    error.statusCode >= 400 &&
    error.statusCode < 500 &&
    !const [401, 426, 429].contains(error.statusCode);

class E2EEngine {
  E2EEngine({
    required this.host,
    required this.api,
    required this.events,
    required this.store,
    required this.clock,
    required this.user,
    required this.deviceName,
    required this.registered,
    ({String challenge, DateTime at})? loginChallenge,
    double Function()? random,
  }) : _challenge = loginChallenge,
       random = random ?? Random().nextDouble {
    // Every observation this device's core answers, whoever asked (a push's engine through the port too), reaches the
    // contacts (review 28's rule 2): the core says `changed` once.
    if (host case final ObservingHost observing) observing.onObserved = _contacts.observed;
  }

  final CoreHost host;

  /// The routes, for the session the engine works for.
  final duvet.E2eApi api;

  /// The gateway's events of that session.
  final Stream<duvet.GatewayEventPayload> events;
  final EngineStore store;
  final EngineClock clock;

  /// The session's user.
  final String user;

  /// This installation's name among the user's devices: the phone's model (bootstrap.dart's phoneName).
  final String deviceName;

  /// The session is bound to this device, which every identify names from now on (Ruling 30).
  final void Function(String deviceId) registered;

  /// A number from 0 to 1, at random: how much of its 5 s a due commit waits.
  final double Function() random;

  /// How long a login's challenge is taken for: the API's 10 minutes (its challengeLife), less one for the way there.
  static const challengeLife = Duration(minutes: 9);

  // The login's device_challenge and when it came, used for the first binding alone: a refused or cut one spends it,
  // so the next binding asks for one (bootstrap.dart).
  ({String challenge, DateTime at})? _challenge;

  /// The login's challenge, once and while it's fresh: null after, once it's too old for the API, and without one.
  String? takeChallenge() {
    final login = _challenge;
    _challenge = null;
    if (login == null || time.clock.now().difference(login.at) >= challengeLife) return null;
    return login.challenge;
  }

  final _state = ValueNotifier(EngineState.starting);

  /// What the app shows, as it changes.
  ValueListenable<EngineState> get state => _state;

  // The flow under way: each one waits for the one before.
  Future<void> _turn = Future.value();
  var _stopped = false;
  StreamSubscription<duvet.GatewayEventPayload>? _heard;

  // A start that failed and goes again (calls it off), and the uploads every day.
  void Function()? _retry;
  var _retries = 0;
  void Function()? _daily;

  /// The device this session is bound to, once it is.
  String? _device;

  /// This installation's device, as its database names it, whether or not the session is bound to it yet (the
  /// desktop's #self): its DEVICE_ADD is never told (review 25's M3).
  String? _self;

  /// What create_identity answered, until it's uploaded: kept nowhere else, as the core gives it again.
  IdentityMade? _made;

  /// What rotate_keys answered while its key shows, until it's uploaded or put off (Task 25).
  Rotation? _rotation;

  /// How many rounds each inbox message's call was cut (inbox.dart).
  final _tries = <String, int>{};

  /// What failed to open, waiting for its report.
  late final _failures = Failures(api, clock);

  /// The conversations' queues and groups.
  late final _groups = Conversations(
    this,
    (work) => _soon(() => _whenReady(work)),
    _failures,
    _conversationChanged,
    _messageChanged,
    _messagesGone,
  );

  /// The person's shares of a conversation's history, and the packages this device receives (history.dart).
  late final _histories = Histories(
    this,
    _act,
    (work) => _soon(() => _whenReady(work)),
    (conversationId) => _groups.sync(conversationId),
    (conversationId) => _groups.left(conversationId),
    _historyImported,
    (conversationId, shareId) => _changeRefused(conversationId, shareId, 'share'),
  );

  /// The messages this device sends, edits and deletes.
  late final _sends = Sends(
    this,
    _groups,
    (work) => _soon(() => _whenReady(work)),
    _act,
    _messageChanged,
    _messageSent,
    _changeRefused,
    _messagesGone,
    _held,
  );

  /// The cutover's instant, as GET /api/e2e gave it: a conversation from before it says when its messages went.
  DateTime? cutoverAt;

  final _messagesChanged = StreamController<String>.broadcast();
  // Told as it's told, as the desktop calls its listeners: a start that warns has told its listeners as it ends.
  final _deviceNotices = StreamController<DeviceNotice>.broadcast(sync: true);
  final _deleted = StreamController<({String conversationId, List<String> ids})>.broadcast();

  /// The messages this device learned were deleted (a tombstone it applied, a message the queue serves as deleted, the
  /// person's own deletion): their files go from the app's folder of decrypted files (task 18's review, M4).
  Stream<({String conversationId, List<String> ids})> get messagesDeleted => _deleted.stream;

  void _messagesGone(String conversationId, List<String> ids) {
    if (!_deleted.isClosed && ids.isNotEmpty) _deleted.add((conversationId: conversationId, ids: ids));
  }

  final _imports = StreamController<String>.broadcast();

  /// Each conversation a shared history or a catch-up was imported into (history.dart): rows its chat's pages left out
  /// may show now, as well as the ones [messagesChanged] has read again.
  Stream<String> get historiesImported => _imports.stream;

  void _historyImported(String conversationId) {
    _messageChanged(conversationId);
    if (!_imports.isClosed) _imports.add(conversationId);
  }

  final _sent = StreamController<({String conversationId, String nonce, duvet.DirectMessage message})>.broadcast();
  final _refused = StreamController<({String conversationId, String messageId, String kind})>.broadcast();

  /// Each conversation whose messages changed on this device (an apply, a send, an edit, a deletion): what shows of
  /// them is read again.
  Stream<String> get messagesChanged => _messagesChanged.stream;

  /// Each message of the person's that the API took, by the nonce they sent it with ([nonce]): their copy of it is the
  /// API's [message], whose nonce is another when no member could open the first bytes any more.
  Stream<({String conversationId, String nonce, duvet.DirectMessage message})> get sent => _sent.stream;

  /// Each edit (`edit`) or deletion (`delete`) of the person's the API refused for good with nobody waiting for its
  /// answer: shown done here, it never reached the others, which the person is told. A share of a conversation's
  /// history (`share`, by the package's ID) the person was told went and that ended for good is one too.
  Stream<({String conversationId, String messageId, String kind})> get changesRefused => _refused.stream;

  /// What the engine tells of the user's other devices (Task 25): one added, and once each, one not seen in 45 days.
  Stream<DeviceNotice> get deviceNotices => _deviceNotices.stream;

  void _tell(DeviceNoticeKind kind, duvet.UserDevice device) {
    if (!_deviceNotices.isClosed) _deviceNotices.add((kind: kind, device: device));
  }

  void _changeRefused(String conversationId, String messageId, String kind) {
    if (!_refused.isClosed) _refused.add((conversationId: conversationId, messageId: messageId, kind: kind));
  }

  void _messageChanged(String conversationId) {
    if (!_messagesChanged.isClosed) _messagesChanged.add(conversationId);
  }

  void _messageSent(String conversationId, String nonce, duvet.DirectMessage message) {
    if (!_sent.isClosed) _sent.add((conversationId: conversationId, nonce: nonce, message: message));
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Contacts (Task 29; decision 25)

  /// The person's contacts (contacts.dart): whom they verified, and their changed keys.
  late final _contacts = Contacts(store, user);

  /// What the views show of the person's contacts: their changed keys, and whom they verified.
  ValueListenable<ContactsShown> get contacts => _contacts.shown;

  /// Whether the person verified the user, as this device's core holds them once it observed them as the API serves
  /// them now: a changed key leaves its notice, and one the core refuses changes nothing. False for one the API serves
  /// no identity of, and before this device is ready.
  Future<bool> contact(String userId) async {
    // One that fails (logged by the turn) leaves what the core held before.
    await _queue(() => _whenReady(() => observeUsers(this, [userId]))).catchError((Object _) {});
    return _contacts.shown.value.verified[userId] ?? false;
  }

  /// The security number with a contact (decision 25): its 60 digits in 12 groups of 5, and its QR's text, the core's
  /// `qr` as it gives it, which the other's phone scans (e2e-conventions.json's safety_qr). The contact is observed as
  /// the API serves them first, so the number is of the identity they have now; one the core refuses leaves the number
  /// of the identity this device holds of them.
  Future<SafetyNumber> safetyNumber(String userId) => _act(() async {
    await _observed([userId]);
    return _safetyNumber(userId);
  });

  /// The person marks the contact verified, having compared these [digits] with theirs: only while they're still the
  /// number the core holds, read again in the same turn, and by that number's QR, so the core marks only while it pins
  /// the identities the person compared, whatever another engine asks of it meanwhile (review 28's rule 4). Whether
  /// they're verified now.
  Future<bool> verifyContact(String userId, String digits) => _act(() async {
    final number = await _safetyNumber(userId);
    if (number.digits != digits) return false;
    return _verify(userId, number.qr);
  });

  /// The person scanned the contact's code from their phone (Ruling 21): its text, as read, goes to the core for this
  /// contact, never one the code names. The core verifies them only if the code holds the identities it pins; for the
  /// same two users with other keys it unmarks them, and another pair's code changes nothing. Whether they're verified
  /// now. A text that isn't a security number's code throws the core's `bad_command`.
  Future<bool> verifyScanned(String userId, String qr) => _act(() => _verify(userId, qr));

  /// verify_user by [qr]: a yes once verified, as verifying the new number is (review 28's Minor 7). A code that
  /// didn't match leaves the mark as the core holds it, which the contact's observation says at once: unmarked, a
  /// contact the person had verified waits for their yes again.
  Future<bool> _verify(String userId, String qr) async {
    final answered = await withIdentities(
      this,
      () => host.handle<Map<String, Object?>>({'cmd': 'verify_user', 'user_id': userId, 'qr': qr}),
    );
    final verified = answered['verified'] == true;
    if (!verified) {
      await _observed([userId]);
      return false;
    }
    _contacts.verifiedNow(userId, true);
    _released();
    return true;
  }

  /// The core's security number with the contact, as it holds them now: observed first when it asks.
  Future<SafetyNumber> _safetyNumber(String userId) async {
    final number = await withIdentities(
      this,
      () => host.handle<Map<String, Object?>>({'cmd': 'safety_number', 'user_id': userId}),
    );
    final (digits, qr) = (number['digits'], number['qr']);
    // Without its QR, verify_user would mark whatever the core pins as it runs (review 28's rule 4).
    if (digits is! String || qr is! String || qr.isEmpty) {
      throw CoreError('internal', message: 'the core gave the security number no QR');
    }
    return (digits: digits, qr: qr);
  }

  /// The changed keys of the conversation's people (review 28's I1): the users its group holds on this device, members
  /// and leaves, with those the API lists, as a server could list it without someone its group still holds. None
  /// while this device isn't ready, where nothing is sent.
  Future<Map<String, KeyChange>> keyChangesIn(String conversationId) async {
    var found = const <String, KeyChange>{};
    await _queue(
      () => _whenReady(() async {
        final changes = _contacts.shown.value.changes;
        found = {for (final user in await _groups.people(conversationId)) user: ?changes[user]};
      }),
    );
    return found;
  }

  /// The person closes the notice of the contact's change they were shown: it shows no more, wherever it showed.
  Future<void> closeKeyChange(String userId, String change) async => _contacts.close(userId, change);

  /// The person's yes to sending, the changes they were shown known (decision 25): what waited for it goes, as at a
  /// READY.
  Future<void> confirmKeyChanges(List<ShownChange> changes) async {
    _contacts.confirm(changes);
    _released();
  }

  /// Of these users, those whose changed key makes what goes to them wait for the person's yes (deviceless.dart's
  /// catch-ups).
  List<String> holding(List<String> users) => _contacts.holding(users);

  /// Whom what goes to the conversation reaches, of those whose changed key waits for the person's yes: its group's
  /// people, read in the turn (send.dart's hold).
  Future<List<String>> _held(String conversationId) async => _contacts.holding(await _groups.people(conversationId));

  /// What waited for the person's yes goes: messages and edits, as at a READY, and the catch-ups and shares held for it.
  void _released() {
    _soon(() => _whenReady(_sends.resendAll));
    _groups.catchUpsAgain();
    _histories.again();
  }

  /// Other users observed as the API serves them now, a failure logged: what the core held of them stays.
  Future<void> _observed(List<String> users) async {
    if (users.isEmpty) return;
    try {
      await observeUsers(this, users);
    } catch (error) {
      debugPrint("e2e: contacts weren't observed: ${error.runtimeType}");
    }
  }

  /// The person's message, sent after what waits in its conversation (PLAN-E2E-CLIENTES.md, «Enviar»): the API's
  /// message, or null when it was sent already. A refusal or a lost answer throws, the message kept for Retry and
  /// Dismiss; while this device isn't ready nothing is sent or kept.
  /// Its files go sealed («Adjuntos»), [onProgress] following their upload and [cancel] stopping it: a Cancel is then
  /// its Dismiss. Only the core's calls take the engine's turn: its request waits in its conversation's lane.
  Future<duvet.DirectMessage?> sendMessage(
    Outgoing message, {
    void Function(int sent, int total)? onProgress,
    Future<void>? cancel,
  }) => _updating(() => _sends.send(message, onProgress: onProgress, cancel: cancel));

  /// The person's Retry of their message [nonce] that waits on this device: what the record keeps of it goes with it.
  Future<duvet.DirectMessage?> resendMessage(String conversationId, String nonce) =>
      _updating(() => _sends.resend(conversationId, nonce));

  /// A request of the person's that came outside the turn: its 426 has this device wait for its update.
  Future<T> _updating<T>(Future<T> Function() work) async {
    try {
      return await work();
    } on duvet.DuvetUpdateRequiredException catch (error) {
      if (_state.value.stage != EngineStage.update) _set(EngineState.update(error.minimum));
      rethrow;
    }
  }

  /// A file of a message opened by this device's core, part by part: the app's engine's alone (Review Focus 2).
  Future<Uint8List> openFile(String key, String id, Uint8List sealed, {void Function(int done)? progress}) =>
      host.openFile(key, id, sealed, progress: progress);

  /// A file of a message that didn't open, or opened to other bytes than its message says: counted (decision 40).
  void fileFailed() => _failures.note('attachment');

  /// The names of the files whose messages this device holds, by their IDs (Ruling 31): the person's attachments'.
  Future<Map<String, String>> fileNames() => files.fileNames(host);

  /// Whether this run holds the sealed bytes of the files of the person's message [nonce], which a Retry sends.
  bool holdsFiles(String nonce) => _sends.holdsFiles(nonce);

  /// An edit of the user's message: shown here at once, sent, and its answer's entry applied.
  Future<void> editMessage(String conversationId, String messageId, String text) =>
      _act(() => _sends.change(conversationId, messageId, text));

  /// A deletion of the user's message, for everyone: done here at once, sent, and its answer's entry applied.
  Future<void> deleteMessage(String conversationId, String messageId) =>
      _act(() => _sends.change(conversationId, messageId, null));

  /// The person's Dismiss of a message the API never took: whatever the device's state, as it only drops it here. The
  /// API's ID of a message that went after all (its answer and its event lost), whose copy the views show in its place;
  /// else null.
  Future<String?> discardMessage(String conversationId, String nonce) async {
    // Its request, when one is out, stopped and settled first, outside the turn (task 19's review, M4).
    await _sends.settle(nonce);
    String? went;
    await _queue(() async => went = await _sends.discard(conversationId, nonce));
    _messageChanged(conversationId);
    return went;
  }

  /// What this device's database shows of these messages of the conversation: a row for each it holds.
  Future<List<ShownMessage>> messages(String conversationId, List<String> ids) =>
      shownMessages(host, conversationId, ids);

  /// The core's search of this device's conversations (lib/e2e/search.dart): a read, as [messages] is.
  Future<DeviceFound> search(DeviceSearch request) => searchDevice(host, request);

  /// The text this device's database holds of [messageId] of the conversation, from [authorId], the author the API
  /// names: its row read now, and again each time the conversation's messages change here (its entry applied), [wait]
  /// at most, each read raced against it; a read that fails is none yet. Once the row is opened (`ok`) it's decided:
  /// its text, or null for one without text (a sticker, files) or another author's. Null too without it by then, or
  /// once [settled] says what would bring it came and one more read found none. A notice then says who wrote it and
  /// that a message came, as the desktop's deviceText does. It's kept nowhere.
  Future<String?> textOf(
    String conversationId,
    String messageId,
    String authorId,
    Duration wait, {
    Future<void>? settled,
  }) async {
    final timeUp = Completer<void>();
    var changed = Completer<void>();
    var done = false;
    final heard = messagesChanged.listen((id) {
      if (id == conversationId && !changed.isCompleted) changed.complete();
    });
    unawaited(
      settled?.then((_) {
        done = true;
        if (!changed.isCompleted) changed.complete();
      }),
    );
    final cancel = clock.later(wait, timeUp.complete);
    try {
      while (!timeUp.isCompleted) {
        // A change that comes while it reads has it read again.
        final next = changed = Completer<void>();
        final last = done;
        final row = await Future.any([
          shownMessages(host, conversationId, [messageId]).then(
            (rows) => rows.where((row) => row.messageId == messageId && row.status == MessageStatus.ok).firstOrNull,
            onError: (Object _) => null,
          ),
          timeUp.future.then((_) => null),
        ]);
        if (row != null) return row.userId == authorId ? row.text : null;
        if (last) return null;
        await Future.any([next.future, timeUp.future]);
      }
      return null;
    } finally {
      cancel();
      await heard.cancel();
    }
  }

  /// A push's message, as the push's engine asks this one for it while this one holds the core (lib/e2e/
  /// push_decrypt.dart; decision 29): its [entry] taken in its conversation's turn, or, without one, the conversation's
  /// queue read; then the texts this device's database holds of [lines] (the push's message first, then its chat's
  /// earlier ones), the first waited for until its entry is taken, all of it [wait] at most: past it, the first line's
  /// text alone, if it came.
  Future<Map<String, String>> pushTexts(
    String conversationId,
    Map<String, Object?>? entry,
    List<Authored> lines,
    Duration wait,
  ) async {
    final timeUp = Completer<void>();
    final cancel = clock.later(wait, timeUp.complete);
    try {
      final taken = _queue(
        () => _whenReady(
          () => entry == null ? _groups.sync(conversationId, read: true) : _groups.take(conversationId, [entry]),
        ),
      ).catchError((Object _) {});
      final first = lines.firstOrNull;
      final text = first == null ? null : await textOf(conversationId, first.id, first.author, wait, settled: taken);
      final alone = {if (first != null && text != null) first.id: text};
      if (timeUp.isCompleted) return alone;
      return await Future.any([textsOf(host, conversationId, lines), timeUp.future.then((_) => alone)]);
    } finally {
      cancel();
    }
  }

  /// The person's messages of the conversation still being sent, in their order, with what goes with them.
  Future<List<Pending>> pendingMessages(String conversationId) => _sends.pending(conversationId);

  /// The shares of a conversation's history whose keys this device holds, waiting for the person's yes, by
  /// conversation (history.dart).
  ValueListenable<Map<String, List<HistoryOffer>>> get historyOffers => _histories.offers;

  /// The person's share of a conversation's history from [range]'s start (day, week, month or all) with one of its
  /// other members (PLAN-E2E-CLIENTES.md, Task 31): what came of it, once the API took it; the rest goes by itself, and
  /// a share that then ends for good is told on [changesRefused]. A refusal throws: [ShareLimit] for the API's ten an
  /// hour, [NoDeviceToShareWith], or the API's; a client too old for it waits for its update.
  Future<SharedHistory> shareHistory(String conversationId, String userId, String range) =>
      _updating(() => _histories.share(conversationId, userId, range));

  /// The person's yes to a share of a conversation's history ([historyOffers]): its messages imported here.
  Future<void> takeHistoryOffer(String shareId) => _updating(() => _histories.take(shareId));

  /// The person's Dismiss of a share of a conversation's history ([historyOffers]): it shows no more, and the API is
  /// told this device is done with it.
  Future<void> dismissHistoryOffer(String shareId) => _histories.dismiss(shareId);

  /// Whether this device's database holds any message of the conversation numbered before [seq].
  Future<bool> heldBefore(String conversationId, int seq) => content.heldBefore(host, conversationId, seq);

  /// How far this device applied the conversation's queue this run: none before its first apply, `through` null while
  /// it's out of the conversation's group. A message numbered past it isn't applied yet, and loads.
  ({int? through})? appliedThrough(String conversationId) => _groups.applied(conversationId);

  /// The person's message this device sent under [nonce] (the nonce they sent it with: made again, it went under
  /// another), as its database holds it once the API has it.
  Future<ShownMessage?> sentUnder(String conversationId, String nonce) =>
      content.sentUnder(host, conversationId, _sends.current(nonce));

  /// The nonce the person sent their message under, whose nonce is [nonce] now: another once it was made again.
  String firstNonceOf(String nonce) => _sends.firstOf(nonce);

  /// The person's act on a conversation's messages, in the engine's turn: refused while this device isn't ready, or
  /// once the engine stopped; a client too old for it waits for its update.
  Future<T> _act<T>(Future<T> Function() work) async {
    late T value;
    var done = false;
    await _queue(() async {
      if (_state.value.stage != EngineStage.ready) throw StateError("encrypted conversations aren't ready here");
      try {
        value = await work();
        done = true;
      } on duvet.DuvetUpdateRequiredException catch (error) {
        _set(EngineState.update(error.minimum));
        rethrow;
      }
    });
    if (!done) throw StateError('the encryption engine stopped');
    return value;
  }

  /// The API's external sender as this device pinned it, for the session too.
  String? _sender;

  /// The conversations the person has open: they get their groups once the engine can (M6 of the desktop's review).
  final _shown = <String>{};

  final _conversations = ValueNotifier<Map<String, ConversationState>>(const {});

  /// What each conversation says over its message box of its group, by its ID: none while its group goes on.
  ValueListenable<Map<String, ConversationState>> get conversations => _conversations;

  /// What the conversation says of its group: null while it goes on.
  ConversationState? conversationState(String conversationId) => _conversations.value[conversationId];

  /// The person opened the conversation: its group goes on, or is made here when it has none and this user may, and
  /// its members without a device are asked for («Quien no tenía dispositivo»). One opened before the engine can work
  /// goes once it's ready, while it stays open ([closeConversation]).
  Future<void> openConversation(String conversationId) {
    _shown.add(conversationId);
    return _queue(() => _whenReady(() => _open(conversationId)));
  }

  /// A conversation the person opened, its members without a device asked for once its group goes on.
  Future<void> _open(String conversationId) async {
    await _groups.open(conversationId);
    // Its people observed as the API serves them now: a changed key leaves its notice there, an event missed or not.
    await _observed([
      for (final person in await _groups.people(conversationId))
        if (person != user) person,
    ]);
    await _groups.checkDevices(conversationId);
  }

  /// The person's new DM (PLAN-E2E-CLIENTES.md, Task 23): the API makes the conversation (or answers the one they
  /// have), then this device its group at once, as either member of a DM may. Before this device is ready, its group is
  /// made once it is. The API's conversation.
  Future<duvet.Conversation> createDM(String userId) => _created(() => api.api.createDM(userId));

  /// The person's new group, which they own: as [createDM], its group made at once. One past 20 members, its owner
  /// among them, is refused before anything is asked.
  Future<duvet.Conversation> createGroup(String name, List<String> userIds) async {
    checkRoom({user, ...userIds}.length);
    return _created(() => api.api.createGroup(name, userIds));
  }

  Future<duvet.Conversation> _created(Future<duvet.Conversation> Function() create) async {
    final conv = await _updating(create);
    // A DM they had, with its group, goes on as its chat opens it.
    if (conv.mls != null) return conv;
    await openConversation(conv.id).catchError((Object error) {
      debugPrint("e2e: the new conversation's group waits for its next open: $error");
    });
    return conv;
  }

  /// The owner's addition of a user to a group, one commit of exactly that user (sync.dart's add): the member added.
  Future<duvet.ConversationMember> addMember(String conversationId, String userId) =>
      _act(() => _groups.add(conversationId, userId));

  /// The owner's removal of a member of a group, one commit that takes them and their devices out.
  Future<void> removeMember(String conversationId, String userId) => _act(() => _groups.remove(conversationId, userId));

  /// The person leaves a group, with the statement this device signs: a member's commit takes them out later.
  Future<void> leaveConversation(String conversationId) => _act(() => _groups.leave(conversationId));

  /// The person left the conversation.
  void closeConversation(String conversationId) => _shown.remove(conversationId);

  /// The person's tap on Restart encryption, over a blocked group they may restart: whom it would leave out that the
  /// person hasn't confirmed yet ([leaving]), and nothing restarted while there are some; else it restarts, and
  /// answers none.
  Future<List<String>> restartGroup(String conversationId, {List<String> leaving = const []}) async {
    var out = const <String>[];
    await _queue(() => _whenReady(() async => out = await _groups.restart(conversationId, leaving)));
    return out;
  }

  /// The person's yes to a conversation's members of today, which its record from before the cutover didn't have.
  Future<void> acceptMembers(String conversationId) => _queue(() => _whenReady(() => _groups.accept(conversationId)));

  void _conversationChanged(String conversationId, ConversationState? state) {
    final next = {..._conversations.value};
    if (state == null) {
      next.remove(conversationId);
    } else {
      next[conversationId] = state;
    }
    _conversations.value = next;
  }

  /// Starts: hears the gateway's events, then runs «Arranque». It settles when the start's flow ended, whatever state.
  Future<void> start() {
    _heard ??= events.listen(_hear);
    return _queue(_boot);
  }

  /// Stops hearing and waiting, lets the flow under way end, and closes the core: its database stays (decision 13).
  Future<void> stop() async {
    await _halt();
    await _turn;
    await host.close();
    await _messagesChanged.close();
    await _imports.close();
    await _deleted.close();
    await _sent.close();
    await _refused.close();
    await _deviceNotices.close();
  }

  /// Hears and waits for nothing more: the flow under way ends, and none starts after it.
  Future<void> _halt() async {
    _stopped = true;
    final heard = _heard;
    _heard = null;
    _retry?.call();
    _retry = null;
    _daily?.call();
    _daily = null;
    _groups.stop();
    _sends.stop();
    _failures.stop();
    _histories.stop();
    await heard?.cancel();
  }

  /// The person's tap on a first device: create_identity, whose recovery key the app shows next. A device whose user
  /// was set up elsewhere meanwhile makes none (I1 of the desktop's review).
  Future<void> makeIdentity() => _queue(() async {
    final now = _state.value;
    if (now.stage != EngineStage.firstDevice || !await _stillFirst()) return;
    _made = IdentityMade.of(await host.handle<Map<String, Object?>>({'cmd': 'create_identity'}));
    _set(EngineState.firstDevice(recoveryKey: _made!.recoveryKey, finishing: now.finishing));
  });

  /// The person saved the recovery key: the identity goes up, and only once the API took it is it confirmed. A
  /// refusal or a lost answer throws, the key still shown, and the same bytes go next time; another first device's
  /// identity there (409) has this one start over as a new device (Ruling 26). Too old a client goes to update. A
  /// rotation's new key the same: its identity goes up with its transfers ([_rotationSaved]).
  Future<void> keySaved() => _queue(() async {
    if (_state.value.rotating) return _rotationSaved();
    final made = _made;
    if (made == null || _state.value.stage != EngineStage.firstDevice) return;
    final bool published;
    try {
      published = await publishIdentity(this, made);
    } on duvet.DuvetUpdateRequiredException catch (error) {
      // The core keeps the identity for its upload, which an update finishes.
      _made = null;
      return _set(EngineState.update(error.minimum));
    }
    if (!published) return _startOver();
    // Published and confirmed: the key is done with, and the start's last steps follow.
    _made = null;
    _set(EngineState.starting);
    try {
      await _settle();
    } catch (error) {
      _failed(error);
    }
  });

  /// The person closes the key's screen after its upload failed, the key saved: the upload waits for Finish, which
  /// brings the same key and bytes back, as the core keeps them until identity_uploaded (I2 of the desktop's review).
  Future<void> uploadLater() => _queue(() async {
    final now = _state.value;
    if (now.recoveryKey == null) return;
    if (now.rotating) {
      _rotation = null;
      return _set(const EngineState.rotation());
    }
    if (now.stage != EngineStage.firstDevice) return;
    _made = null;
    _set(const EngineState.firstDevice(finishing: true));
  });

  /// The person's removal of another of their devices (Task 25): one never set up by its registration, a listed one by
  /// a list without it, or, lost ([changeKeys]), with new keys, whose recovery key the state then shows until it's
  /// saved. Only while this device is ready, with no rotation of its own waiting: that one goes first.
  Future<void> removeDevice(String deviceId, {bool changeKeys = false}) => _deviceAct(() async {
    if (deviceId == _device) throw ArgumentError.value(deviceId, 'deviceId', "this device's data goes another way");
    if (_state.value.rotating) throw StateError('finish changing the security keys first');
    if (!changeKeys) return devices.removeDevice(this, deviceId);
    await _rotate([deviceId]);
  });

  /// The person's Change security keys (Task 25), with no device taken off: or, with a rotation waiting, its Finish,
  /// the same rotation again, its key shown once more.
  Future<void> changeKeys() => _deviceAct(() => _rotate(const []));

  /// The devices a list of this device's took off that the API didn't take, which the next list or key change takes
  /// along (review 24's M3): its confirmation names them.
  Future<List<String>> unsentRemovals() => devices.unsentRemovals(this);

  Future<void> _rotate(List<String> remove) async {
    final Rotation rotation;
    try {
      rotation = _rotation = await rotateKeys(this, remove);
    } on CoreError catch (error) {
      // Finish of a change that waits, which the core runs again only with a certificate the API serves, of an identity
      // it knows, for every device it keeps: another device took one off, or changed the keys (review 24's I1).
      final gone =
          (error.code == 'bad_command' && error.field == 'certificates') ||
          (error.code == 'invalid_signature' && error.what == 'certificate');
      if (!_state.value.rotating || !gone) rethrow;
      return _set(const EngineState.rotation(stuck: true));
    }
    _set(EngineState.rotation(recoveryKey: rotation.recoveryKey));
  }

  /// A rotation's key saved: its identity goes up with its transfers, confirmed only after the API's 200. A refusal or
  /// a lost answer throws, the key still shown, and the same rotation goes again.
  Future<void> _rotationSaved() async {
    final rotation = _rotation;
    if (rotation == null || _state.value.recoveryKey == null) return;
    try {
      await publishRotation(this, rotation);
    } on duvet.DuvetUpdateRequiredException catch (error) {
      // The core keeps the rotation for its upload, which an update finishes.
      _rotation = null;
      return _set(EngineState.update(error.minimum));
    } on duvet.DuvetIdentityChangedException {
      // Another device changed the keys first. The inbox is read, but while this change waits the core checks that
      // device's transfer against the identity this change made and refuses it (invalid_signature), which the inbox
      // lets go: the change can never go up, and only this device's data deleted gets out, until duvetchat/e2e#49 has
      // the core take such a transfer (review 25's I1).
      _rotation = null;
      await takeInbox(this, _tries, _failures, _histories.keyTaken);
      final next = await _identity();
      return _set(next.rotating ? const EngineState.rotation(stuck: true) : next);
    } on duvet.DuvetApiException catch (error) {
      // A device it keeps was taken off on another device meanwhile: its transfer can't go (review 24's I1).
      if (error.statusCode != 400 || !(error.body ?? '').contains("isn't a registered device of yours")) rethrow;
      _rotation = null;
      return _set(const EngineState.rotation(stuck: true));
    }
    _rotation = null;
    _set(EngineState.ready);
  }

  /// «Remove this device and delete its data» (decision 13; Task 25): its database destroyed with its key, then the
  /// record's device and what it told of the user's devices forgotten, the engine stopped for good, and last its
  /// registration given up where the API lets it go, as that ends the session (review 24's M5 and M4). The app signs
  /// out after. The pinned external sender (Ruling 32) and the records of conversations from before the cutover (Ruling
  /// 14's anchor) stay: they're the account's on this phone, which a next device here takes up. Not where this device
  /// has no database of its own open ([EngineStage.starting], locked, unsupported).
  Future<void> removeThisDevice() => _queue(() async {
    const none = {EngineStage.starting, EngineStage.locked, EngineStage.unsupported};
    if (none.contains(_state.value.stage)) throw StateError("this device's encrypted data isn't open here");
    await host.destroy(user);
    for (final key in [...deviceRecord, toldAdded, toldInactive]) {
      await store.write(key, null).catchError((Object error) => debugPrint("e2e: the record's $key: $error"));
    }
    _contacts.forget();
    await _halt();
    if (_device case final device?) await giveUpRegistration(this, device);
    _made = null;
    _rotation = null;
    _device = null;
    _set(EngineState.starting);
  });

  /// The person's act on the user's devices, in the engine's turn: only while this device is ready; a client too old
  /// for it waits for its update.
  Future<void> _deviceAct(Future<void> Function() work) async {
    var done = false;
    await _queue(() async {
      if (_state.value.stage != EngineStage.ready) throw StateError("this device isn't set up");
      try {
        await work();
        done = true;
      } on duvet.DuvetUpdateRequiredException catch (error) {
        _set(EngineState.update(error.minimum));
        rethrow;
      }
    });
    if (!done) throw StateError('the encryption engine stopped');
  }

  /// This installation starts again as a new device: what a removed device, or one whose key is lost, does on the
  /// person's word. Only from those states, whatever a stale tap asks: elsewhere its database is in use.
  Future<void> startOver() => _queue(() async {
    final now = _state.value;
    if (now.stage == EngineStage.removed || (now.stage == EngineStage.failed && now.lostKey)) await _startOver();
  });

  void _set(EngineState state) {
    final was = _state.value.stage;
    _state.value = state;
    if (state.stage != EngineStage.ready) {
      // Nothing heard is kept while the device can't work: the queue keeps it all (M3 of the desktop's review).
      _groups.dropHeard();
    } else if (was != EngineStage.ready) {
      for (final id in [..._shown]) {
        _soon(() => _whenReady(() => _open(id)));
      }
    }
  }

  /// Conversations' work, only while this device is ready: a client too old for it waits for its update.
  Future<void> _whenReady(Future<void> Function() work) async {
    if (_state.value.stage != EngineStage.ready) return;
    try {
      await work();
    } on duvet.DuvetUpdateRequiredException catch (error) {
      _set(EngineState.update(error.minimum));
    }
  }

  /// The flows queued and not done yet: with none, the engine is quiet, which a catch-up's import waits for.
  var _queued = 0;

  /// Runs [work] once the flow before it ended (nothing once stopped). What it throws fails this call alone.
  Future<void> _queue(Future<void> Function() work) {
    if (_queued++ == 0) _histories.busy();
    final run = _turn.then((_) async {
      if (!_stopped) await work();
    });
    final turn = _turn = run.catchError((Object error) => debugPrint("e2e: the engine's work failed: $error"));
    unawaited(
      turn.then((_) {
        if (--_queued == 0 && !_stopped) _histories.idle();
      }),
    );
    return run;
  }

  /// Work an event asks for: what fails is logged, and goes again with the next event that asks for it.
  void _soon(Future<void> Function() work) => unawaited(_queue(work).catchError((Object _) {}));

  void _hear(duvet.GatewayEventPayload event) {
    if (_state.value.stage == EngineStage.ready) _groups.heard(event);
    switch (event) {
      case duvet.ReadyEvent():
        // A new gateway session: a start that failed goes again now, and the inbox and the conversations' queues may
        // have filled meanwhile.
        if (_retry case final retry?) {
          retry();
          _retry = null;
          _soon(_boot);
        } else if (_device != null) {
          _soon(_inbox);
          _soon(() => _whenReady(_groups.all));
          // What waits to be sent goes once the queues are applied («Enviar»).
          _soon(() => _whenReady(_sends.resendAll));
          // The packages for this device that came meanwhile, once its groups are as the queues have them.
          _soon(() => _whenReady(_histories.list));
        }
      case duvet.DeviceMessagePayloadEvent(:final data) when data.deviceId == _device:
        _soon(_inbox);
      case duvet.KeyPackagesLowPayloadEvent(:final data) when data.deviceId == _device:
        _soon(_keyPackages);
      // A shared history or a catch-up completed for this user: offered or imported once its key is here too.
      case duvet.HistoryShareCreatedEvent(:final data) when _state.value.stage == EngineStage.ready:
        _histories.heard(data);
      case duvet.DeviceRemovedEvent(:final data) when data.deviceId == _device:
        _soon(() async => _set(EngineState.removed));
      // Another device of the user's: its registration, then its listing, told once (Task 25), and never this one,
      // which its database names from the start's first steps, bound or not (review 25's M3).
      case duvet.DeviceAddedEvent(:final data):
        _soon(() async {
          if (data.id != _self && await addedToTell(store, data)) {
            _tell(DeviceNoticeKind.added, data);
          }
        });
      // The person's message made again goes under a new nonce, which only the engine knows it by (I1 of task 17's
      // review).
      case duvet.DMMessageCreatedEvent(:final data) when data.authorId == user:
        _sends.heard(data);
      // Another user's identity: whether they have a device may have changed, which their conversations tell the core.
      case duvet.IdentityUpdatedEvent(:final data) when data.userId != user:
        _soon(
          () => _whenReady(() async {
            // Observed as the API serves them now: a changed key leaves its notice (contacts.dart).
            await _observed([data.userId]);
            await _groups.identityChanged(data.userId);
          }),
        );
      // A conversation's owner handed on (they left): what it says goes by its new owner.
      case duvet.ConversationUpdatedEvent(:final data):
        _soon(() => _whenReady(() => _groups.changed(data.id)));
      case duvet.IdentityUpdatedEvent(:final data) when data.userId == user:
        // The user's own: another device changed the list or the keys, which may leave this one off it, or published
        // the identity this first device was to make, if it hasn't shown a key yet.
        _soon(() async {
          final now = _state.value;
          if (now.stage == EngineStage.ready) {
            // Its own list may now leave out a device that still has leaves: the groups say whether a commit is due to
            // take them out.
            _set(await _identity());
            await _whenReady(_groups.all);
          } else if (now.stage == EngineStage.firstDevice && now.recoveryKey == null) {
            await _stillFirst();
          }
        });
      default:
    }
  }

  /// Whether this device is still its user's first: the API serves no identity, or its own (an upload cut before its
  /// answer). Another's served, the user was set up elsewhere, and a key made here would open nothing: the device
  /// becomes a new one, by starting over when it made an identity the core can't undo (Ruling 26).
  Future<bool> _stillFirst() async {
    final served = await servedIdentity(this);
    if (served == null) return true;
    final status = await coreStatus(host);
    if (served.identityKey == status.identityKey) return true;
    if (status.hasIdentity) {
      await _startOver();
    } else {
      _set(EngineState.newDevice);
    }
    return false;
  }

  /// Step 5, with the inbox for a rotation's transfer this device may need first. A rotation of this device's whose key
  /// shows stays shown, as its saving or Later alone puts it away; one gone (another device's transfer replaced the
  /// identity) is forgotten.
  Future<EngineState> _identity() async {
    final state = await identityState(this, () => takeInbox(this, _tries, _failures, _histories.keyTaken));
    if (!state.rotating) _rotation = null;
    final shown = _rotation?.recoveryKey;
    if (shown != null) return EngineState.rotation(recoveryKey: shown);
    // A change found stuck this run stays said while the core keeps it: only another device's keys end it.
    return state.rotating && _state.value.stuck ? _state.value : state;
  }

  /// The inbox; once it brought a rotation's transfer, the own user observed, which may change what this device is.
  Future<void> _inbox() async {
    if (await takeInbox(this, _tries, _failures, _histories.keyTaken)) _set(await _identity());
  }

  /// «Arranque»: the API's configuration, the user's database, this installation's device and the session bound to it.
  Future<void> _boot() async {
    try {
      final config = await api.config();
      cutoverAt = config.cutoverAt;
      _groups.start(await _pin(config.externalSender));
      final opened = await host.open(user);
      if (opened.state != HostState.ready) return _closed(opened);
      // What a push's engine noted in the record while it held the core (contacts.dart), before anything here writes.
      await _contacts.reload();
      final (:status, :keys) = await ownDevice(this);
      final device = status.deviceId;
      _self = device;
      if (device == null) return _set(EngineState.removed);
      final bool bound;
      try {
        bound = await bindSession(this, device, keys);
      } catch (error) {
        if (!_refusedForGood(error)) rethrow;
        debugPrint('e2e: the API refused this device: $error');
        return _set(const EngineState.failed());
      }
      if (!bound) return _set(EngineState.removed);
      _device = device;
      // Kept so the next start identifies with it before the core opens: one the record can't keep still registers.
      await store.write(keptDevice, device).catchError((Object error) => debugPrint('e2e: the device: $error'));
      registered(device);
      _retries = 0;
      // An identity made before the app closed, still waiting for its upload: the same command gives it again, its
      // recovery key with it, from the person's tap as the first time (step 4).
      if (status.waitingUpload == 'create_identity') return _set(const EngineState.firstDevice(finishing: true));
      await _settle();
    } catch (error) {
      _failed(error);
    }
  }

  /// A start that failed: a client too old waits for its update; anything else goes again later.
  void _failed(Object error) {
    if (error is duvet.DuvetUpdateRequiredException) return _set(EngineState.update(error.minimum));
    debugPrint("e2e: the engine didn't start: $error");
    _later();
  }

  /// Steps 5 to 7: what the user's identity makes of this device, the inbox, then a listed device's conversations'
  /// queues, before its key packages, so a welcome waiting there takes its keys before key_packages lets them go; then
  /// the leaf renewals due («Lo periódico»), as every day after: a phone seldom runs a whole day.
  Future<void> _settle() async {
    _set(await _identity());
    await _inbox();
    if (_state.value.stage != EngineStage.ready) return;
    // Whom the person verified, looked at again: a change of theirs the record never took holds from the start (review
    // 28's Minor 5).
    await _observed(_contacts.verifiedUsers());
    await _whenReady(_groups.all);
    // What waits to be sent goes once the queues are applied, before anything new («Enviar»).
    try {
      await _whenReady(_sends.resendAll);
    } catch (error) {
      debugPrint('e2e: what waits to be sent waits for the next READY: $error');
    }
    // The packages for this device, once its groups are as the queues have them.
    try {
      await _whenReady(_histories.list);
    } catch (error) {
      debugPrint('e2e: the shared histories wait for the next READY: $error');
    }
    await _keyPackages();
    try {
      await _whenReady(_groups.renew);
    } catch (error) {
      debugPrint("e2e: the leaf renewals wait for tomorrow's: $error");
    }
    await _warnInactive();
    _daily ??= _everyDay();
  }

  /// The user's devices not seen in 45 days, each warned of once (decision 13): at start and every day after.
  Future<void> _warnInactive() async {
    if (_state.value.stage != EngineStage.ready) return;
    try {
      for (final device in await inactiveToTell(this)) {
        _tell(DeviceNoticeKind.inactive, device);
      }
    } catch (error) {
      debugPrint("e2e: the devices not seen lately wait for tomorrow's look: $error");
    }
  }

  /// Uploads the key packages: none while this device isn't on the list, which the API refuses.
  Future<void> _keyPackages() async {
    if (_state.value.stage == EngineStage.ready) await uploadKeyPackages(this);
  }

  void Function() _everyDay() => clock.later(_day, () {
    _daily = _everyDay();
    _soon(_keyPackages);
    _soon(() => _whenReady(_groups.renew));
    _soon(_warnInactive);
  });

  /// The API's external sender as this device pinned it (Ruling 32): the first one it saw, which the record keeps, and
  /// this session where the record can't (its storage full or refused), so a later start in it keeps it too; the
  /// record is asked again each time (M4 of the desktop's review). Another one served later is refused, said in the
  /// log, and the pinned one stays: groups under it are the only ones this device goes into.
  Future<String> _pin(String served) async {
    final recorded = switch (store.read(externalSender)) {
      final String key when key.isNotEmpty => key,
      _ => null,
    };
    final pinned = recorded ?? _sender ?? served;
    if (recorded == null) {
      await store.write(externalSender, pinned).catchError((Object error) => debugPrint('e2e: the pin: $error'));
    }
    if (pinned != served) {
      debugPrint(
        'e2e: the API serves another external sender than the one this device pinned: it stays the pinned one.',
      );
    }
    return _sender = pinned;
  }

  /// The core didn't open: unsupported for good, a lost key until the person starts over, anything else again later.
  void _closed(Opened opened) {
    if (opened.state == HostState.unsupported) return _set(EngineState.unsupported);
    final lostKey = opened.state == HostState.failed && opened.reason == 'bad_key';
    _set(opened.state == HostState.locked ? EngineState.locked : EngineState.failed(lostKey: lostKey));
    if (!lostKey) _later();
  }

  /// The start goes again after a while, or at the next READY.
  void _later() {
    _retry?.call();
    final wait = _retryFirst * (1 << min(_retries++, 5));
    _retry = clock.later(wait < _retryMost ? wait : _retryMost, () {
      _retry = null;
      _soon(_boot);
    });
  }

  /// This installation as a new device (Ruling 26): its database destroyed with its key, then a new device registered,
  /// which this session binds to, and only then the old one's registration deleted, as deleting it ends its sessions.
  /// A device still on the list can't be deleted (409): another device of the user's takes it off.
  Future<void> _startOver() async {
    final old = (await api.devices()).where((device) => device.current).firstOrNull?.id;
    await host.destroy(user);
    for (final key in deviceRecord) {
      await store.write(key, null).catchError((Object error) => debugPrint("e2e: the record's $key: $error"));
    }
    _contacts.forget();
    _made = null;
    _device = null;
    _tries.clear();
    _groups.forget();
    _sends.stop();
    _histories.forget();
    _daily?.call();
    _daily = null;
    _set(EngineState.starting);
    await _boot();
    // Not before the session is bound to the new device: it would end with the old one.
    if (old == null || _device == null || old == _device) return;
    try {
      await api.deleteDevice(old);
    } on duvet.DuvetApiException catch (error) {
      if (error.statusCode != 404 && error.statusCode != 409) rethrow;
    }
  }
}
