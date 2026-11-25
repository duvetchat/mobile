/// The encryption engine (PLAN-E2E-CLIENTES.md, «El motor»): it carries what the core makes to the API and what the
/// API hands out to the core, never opening or making anything itself. A class with its parts given to it, so the app
/// runs one (lib/data/duvet_repository.dart) and a test as many as it needs, each with its own core, session and
/// gateway connection. The desktop's engine is its twin in TypeScript, and the two share their tests' names.
///
/// Its work goes one flow at a time, in the order it came: the start («Arranque», steps 1 to 7, here without the
/// conversations), the person's taps, and what the gateway's events ask for. bootstrap.dart, identity.dart,
/// key_packages.dart and inbox.dart hold the steps; this class keeps the state the app shows, and what's due later.
library;

import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart' as time;
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'bootstrap.dart';
import 'host.dart';
import 'identity.dart';
import 'inbox.dart';
import 'key_packages.dart';
import 'store.dart';

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
  }) : _challenge = loginChallenge;

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
    await _turn;
    await host.close();
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

  void _set(EngineState state) => _state.value = state;

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
    switch (event) {
      case duvet.ReadyEvent():
        // A new gateway session: a start that failed goes again now, and the inbox may have filled meanwhile.
        if (_retry case final retry?) {
          retry();
          _retry = null;
          _soon(_boot);
        } else if (_device != null) {
          _soon(_inbox);
        }
      case duvet.DeviceMessagePayloadEvent(:final data) when data.deviceId == _device:
        _soon(_inbox);
      case duvet.KeyPackagesLowPayloadEvent(:final data) when data.deviceId == _device:
        _soon(_keyPackages);
      case duvet.DeviceRemovedEvent(:final data) when data.deviceId == _device:
        _soon(() async => _set(EngineState.removed));
      case duvet.IdentityUpdatedEvent(:final data) when data.userId == user:
        // The user's own: another device changed the list or the keys, which may leave this one off it, or published
        // the identity this first device was to make, if it hasn't shown a key yet.
        _soon(() async {
          final now = _state.value;
          if (now.stage == EngineStage.ready) {
            _set(await _identity());
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
  Future<EngineState> _identity() => identityState(this, () => takeInbox(this, _tries));

  /// The inbox; once it brought a rotation's transfer, the own user observed, which may change what this device is.
  Future<void> _inbox() async {
    if (await takeInbox(this, _tries)) _set(await _identity());
  }

  /// «Arranque»: the API's configuration, the user's database, this installation's device and the session bound to it.
  Future<void> _boot() async {
    try {
      await api.config();
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

  /// Steps 5 to 7: what the user's identity makes of this device, the inbox, and a listed device's key packages.
  Future<void> _settle() async {
    _set(await _identity());
    await _inbox();
    if (_state.value.stage != EngineStage.ready) return;
    await _keyPackages();
    _daily ??= _everyDay();
  }

  /// Uploads the key packages: none while this device isn't on the list, which the API refuses.
  Future<void> _keyPackages() async {
    if (_state.value.stage == EngineStage.ready) await uploadKeyPackages(this);
  }

  void Function() _everyDay() => clock.later(_day, () {
    _daily = _everyDay();
    _soon(_keyPackages);
  });

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
