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
import 'content.dart';
import 'content.dart' as content show heldBefore, sentUnder;
import 'host.dart';
import 'identity.dart';
import 'inbox.dart';
import 'failures.dart';
import 'files.dart' as files show fileNames;
import 'key_packages.dart';
import 'send.dart';
import 'store.dart';
import 'sync.dart';

export 'content.dart' show MessageStatus, ShownMessage;
export 'files.dart' show FilesGone;
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
/// for its upload. A [lostKey] is a database no key opens any more. [minimum] is the lowest version with encryption
/// of a client the API told to update, null where its platform has none.
@immutable
class EngineState {
  const EngineState(this.stage, {this.recoveryKey, this.finishing = false, this.lostKey = false, this.minimum});

  const EngineState.firstDevice({this.recoveryKey, this.finishing = false})
    : stage = EngineStage.firstDevice,
      lostKey = false,
      minimum = null;

  const EngineState.failed({this.lostKey = false})
    : stage = EngineStage.failed,
      recoveryKey = null,
      finishing = false,
      minimum = null;

  const EngineState.update(this.minimum)
    : stage = EngineStage.update,
      recoveryKey = null,
      finishing = false,
      lostKey = false;

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

  @override
  bool operator ==(Object other) =>
      other is EngineState &&
      other.stage == stage &&
      other.recoveryKey == recoveryKey &&
      other.finishing == finishing &&
      other.lostKey == lostKey &&
      other.minimum == minimum;

  @override
  int get hashCode => Object.hash(stage, recoveryKey, finishing, lostKey, minimum);

  // Never the recovery key itself: a state may end up in a log.
  @override
  String toString() =>
      'EngineState(${stage.name}${recoveryKey == null ? '' : ', a key shown'}${finishing ? ', finishing' : ''}'
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
       random = random ?? Random().nextDouble;

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

  /// What create_identity answered, until it's uploaded: kept nowhere else, as the core gives it again.
  IdentityMade? _made;

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
  );

  /// The cutover's instant, as GET /api/e2e gave it: a conversation from before it says when its messages went.
  DateTime? cutoverAt;

  final _messagesChanged = StreamController<String>.broadcast();
  final _deleted = StreamController<({String conversationId, List<String> ids})>.broadcast();

  /// The messages this device learned were deleted (a tombstone it applied, a message the queue serves as deleted, the
  /// person's own deletion): their files go from the app's folder of decrypted files (task 18's review, M4).
  Stream<({String conversationId, List<String> ids})> get messagesDeleted => _deleted.stream;

  void _messagesGone(String conversationId, List<String> ids) {
    if (!_deleted.isClosed && ids.isNotEmpty) _deleted.add((conversationId: conversationId, ids: ids));
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
  /// answer: shown done here, it never reached the others, which the person is told.
  Stream<({String conversationId, String messageId, String kind})> get changesRefused => _refused.stream;

  void _changeRefused(String conversationId, String messageId, String kind) {
    if (!_refused.isClosed) _refused.add((conversationId: conversationId, messageId: messageId, kind: kind));
  }

  void _messageChanged(String conversationId) {
    if (!_messagesChanged.isClosed) _messagesChanged.add(conversationId);
  }

  void _messageSent(String conversationId, String nonce, duvet.DirectMessage message) {
    if (!_sent.isClosed) _sent.add((conversationId: conversationId, nonce: nonce, message: message));
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
    String? went;
    await _queue(() async => went = await _sends.discard(conversationId, nonce));
    _messageChanged(conversationId);
    return went;
  }

  /// What this device's database shows of these messages of the conversation: a row for each it holds.
  Future<List<ShownMessage>> messages(String conversationId, List<String> ids) =>
      shownMessages(host, conversationId, ids);

  /// The person's messages of the conversation still being sent, in their order, with what goes with them.
  Future<List<Pending>> pendingMessages(String conversationId) => _sends.pending(conversationId);

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

  /// The person opened the conversation: its group goes on, or is made here when it has none and this user may. One
  /// opened before the engine can work goes once it's ready, while it stays open ([closeConversation]).
  Future<void> openConversation(String conversationId) {
    _shown.add(conversationId);
    return _queue(() => _whenReady(() => _groups.open(conversationId)));
  }

  /// The person left the conversation.
  void closeConversation(String conversationId) => _shown.remove(conversationId);

  /// The person's tap on Restart encryption, over a blocked group they may restart.
  Future<void> restartGroup(String conversationId) => _queue(() => _whenReady(() => _groups.restart(conversationId)));

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
    _stopped = true;
    await _heard?.cancel();
    _heard = null;
    _retry?.call();
    _retry = null;
    _daily?.call();
    _daily = null;
    _groups.stop();
    _sends.stop();
    _failures.stop();
    await _turn;
    await host.close();
    await _messagesChanged.close();
    await _deleted.close();
    await _sent.close();
    await _refused.close();
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
  /// identity there (409) has this one start over as a new device (Ruling 26). Too old a client goes to update.
  Future<void> keySaved() => _queue(() async {
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
    if (now.stage != EngineStage.firstDevice || now.recoveryKey == null) return;
    _made = null;
    _set(const EngineState.firstDevice(finishing: true));
  });

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
        _soon(() => _whenReady(() => _groups.open(id)));
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

  /// Runs [work] once the flow before it ended (nothing once stopped). What it throws fails this call alone.
  Future<void> _queue(Future<void> Function() work) {
    final run = _turn.then((_) async {
      if (!_stopped) await work();
    });
    _turn = run.catchError((Object error) => debugPrint("e2e: the engine's work failed: $error"));
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
        }
      case duvet.DeviceMessagePayloadEvent(:final data) when data.deviceId == _device:
        _soon(_inbox);
      case duvet.KeyPackagesLowPayloadEvent(:final data) when data.deviceId == _device:
        _soon(_keyPackages);
      case duvet.DeviceRemovedEvent(:final data) when data.deviceId == _device:
        _soon(() async => _set(EngineState.removed));
      // The person's message made again goes under a new nonce, which only the engine knows it by (I1 of task 17's
      // review).
      case duvet.DMMessageCreatedEvent(:final data) when data.authorId == user:
        _sends.heard(data);
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

  /// Step 5, with the inbox for a rotation's transfer this device may need first.
  Future<EngineState> _identity() => identityState(this, () => takeInbox(this, _tries, _failures));

  /// The inbox; once it brought a rotation's transfer, the own user observed, which may change what this device is.
  Future<void> _inbox() async {
    if (await takeInbox(this, _tries, _failures)) _set(await _identity());
  }

  /// «Arranque»: the API's configuration, the user's database, this installation's device and the session bound to it.
  Future<void> _boot() async {
    try {
      final config = await api.config();
      cutoverAt = config.cutoverAt;
      _groups.start(await _pin(config.externalSender));
      final opened = await host.open(user);
      if (opened.state != HostState.ready) return _closed(opened);
      final (:status, :keys) = await ownDevice(this);
      final device = status.deviceId;
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
    await _whenReady(_groups.all);
    // What waits to be sent goes once the queues are applied, before anything new («Enviar»).
    try {
      await _whenReady(_sends.resendAll);
    } catch (error) {
      debugPrint('e2e: what waits to be sent waits for the next READY: $error');
    }
    await _keyPackages();
    try {
      await _whenReady(_groups.renew);
    } catch (error) {
      debugPrint("e2e: the leaf renewals wait for tomorrow's: $error");
    }
    _daily ??= _everyDay();
  }

  /// Uploads the key packages: none while this device isn't on the list, which the API refuses.
  Future<void> _keyPackages() async {
    if (_state.value.stage == EngineStage.ready) await uploadKeyPackages(this);
  }

  void Function() _everyDay() => clock.later(_day, () {
    _daily = _everyDay();
    _soon(_keyPackages);
    _soon(() => _whenReady(_groups.renew));
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
    _made = null;
    _device = null;
    _tries.clear();
    _groups.forget();
    _sends.stop();
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
