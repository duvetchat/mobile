/// A new device approved by another device of the user's (PLAN-E2E-CLIENTES.md, Tasks 26 and 27; decision 24), through
/// the approval frames their inboxes carry («Convenciones entre clientes»), one way per attempt:
/// - by QR: the new device shows approval_begin's QR, made again before its attempt's ten minutes end. A phone of the
///   user's scans it and, on its person's yes, approves from it (approval_from_qr, the text as it was scanned) and
///   sends its transfer to the device the reply names, which takes it with no code;
/// - by the code: the new device sends the commitment of an attempt of its own to each listed device of the user's. A
///   device that may approve asks its person «Is this device yours?», and offers only on their yes; the new device
///   reveals with the first offer, and shows an empty field for the code the approving device then shows, which the
///   person types; the approving device confirms on their Confirm and sends the transfer.
/// The new device takes the transfer (approval_receive): one sealed to its commitment's key only once the code typed
/// was accepted, so one that came before is kept, and taken after it. Then it goes on as with the recovery key
/// (recover.dart's putFirstList). The approving device changes no list and no key until that device's list is up (task
/// 24's review, M2), and approves no other new device meanwhile (review 27's M5). The desktop's approval.ts in Dart,
/// with the scan the desktop doesn't have (Ruling 21).
library;

import 'dart:async';
import 'dart:convert';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'bootstrap.dart';
import 'cbor.dart';
import 'conventions.dart';
import 'devices.dart' show unlist;
import 'engine.dart';
import 'host.dart';
import 'identity.dart';
import 'recover.dart';
import 'store.dart';

/// How a new device is being set up, as it shows it: its QR, or its code's progress, one way at a time; or, its core
/// holding the identity already, starting over's new identity (its key in the state) or its first list still to go up.
enum SetupWay { qr, code, reset, finishing }

/// What a new device shows as the person sets it up: the attempt's [qr] (the core's text, never logged: its key is the
/// one the transfer is sealed to), or its code's [fingerprint] (Ruling 35), [offered] once an approving device's offer
/// was taken and [accepted] once the code the person typed was; or the devices its first list leaves out
/// ([leavingOut], by the start of their IDs, as Settings names them), which only the person's Finish signs.
@immutable
class DeviceSetup {
  const DeviceSetup._(
    this.way, {
    this.qr,
    this.fingerprint,
    this.offered = false,
    this.accepted = false,
    this.leavingOut = const [],
  });

  const DeviceSetup.qr(String qr) : this._(SetupWay.qr, qr: qr);

  const DeviceSetup.code(String fingerprint, {bool offered = false, bool accepted = false})
    : this._(SetupWay.code, fingerprint: fingerprint, offered: offered, accepted: accepted);

  const DeviceSetup.finishing([List<String> leavingOut = const []])
    : this._(SetupWay.finishing, leavingOut: leavingOut);

  /// Starting over, its key shown or its upload waiting for Finish (the state says which).
  static const reset = DeviceSetup._(SetupWay.reset);

  final SetupWay way;
  final String? qr;
  final String? fingerprint;
  final bool offered;
  final bool accepted;
  final List<String> leavingOut;

  @override
  bool operator ==(Object other) =>
      other is DeviceSetup &&
      other.way == way &&
      other.qr == qr &&
      other.fingerprint == fingerprint &&
      other.offered == offered &&
      other.accepted == accepted &&
      listEquals(other.leavingOut, leavingOut);

  @override
  int get hashCode => Object.hash(way, qr, fingerprint, offered, accepted, Object.hashAll(leavingOut));

  // Never the QR itself: its key seals the transfer, and a state may end up in a log.
  @override
  String toString() =>
      'DeviceSetup(${way.name}${fingerprint == null ? '' : ', $fingerprint'}${offered ? ', offered' : ''}'
      '${accepted ? ', accepted' : ''}${leavingOut.isEmpty ? '' : ', leaving out ${leavingOut.join(', ')}'})';
}

/// Where an approval stands on the device approving: [asked] until the person's yes, [offered] until the new device's
/// reveal, then the [code] to type into it; [confirmed] once its transfer went, until its list is up; [ended] when it
/// can't go on.
enum ApprovalPhase { asked, offered, code, confirmed, ended }

/// Why an approval ended: its attempt is over, or can't be confirmed here any more ([over]); the device is set up
/// already ([listed]).
enum ApprovalEnd { over, listed }

/// What a device of the user's shows of a new one that asks to be approved: its [name] and the [fingerprint] its screen
/// shows (Ruling 35; none for one approved by its QR), where it stands ([phase]), the [code] to type into it, why it
/// [ended], and whether this device approved it before and it never took its transfer ([unfinished]): then it comes
/// off this device's list first (the core's way out).
@immutable
class DeviceApproval {
  const DeviceApproval({
    required this.device,
    required this.name,
    required this.fingerprint,
    required this.phase,
    this.code,
    this.ended,
    this.unfinished = false,
  });

  final String device;
  final String name;
  final String fingerprint;
  final ApprovalPhase phase;
  final String? code;
  final ApprovalEnd? ended;
  final bool unfinished;

  @override
  bool operator ==(Object other) =>
      other is DeviceApproval &&
      other.device == device &&
      other.name == name &&
      other.fingerprint == fingerprint &&
      other.phase == phase &&
      other.code == code &&
      other.ended == ended &&
      other.unfinished == unfinished;

  @override
  int get hashCode => Object.hash(device, name, fingerprint, phase, code, ended, unfinished);

  // Never the code: it's for the person's eyes, and a state may end up in a log.
  @override
  String toString() =>
      'DeviceApproval($device, ${phase.name}${ended == null ? '' : ', ${ended!.name}'}'
      '${unfinished ? ', unfinished' : ''}${code == null ? '' : ', a code shown'})';
}

/// A device a scanned QR names: its [id], its [name] among the user's devices (null for one the account doesn't have),
/// whether the user's list names it already ([listed]: it's set up), and whether this device approved it before and it
/// never took its transfer ([unfinished]: it comes off this device's list first, which its question says).
typedef ScannedDevice = ({String id, String? name, bool listed, bool unfinished});

/// Which approvals this device takes part in now: a new device's ([newDevice]), or an approving one's ([approver]:
/// ready, with no change of keys under way, whose new identity the API doesn't have yet).
enum ApprovalRole { newDevice, approver }

/// An attempt's ten minutes, by the engine's clock: the new device's from approval_begin, then from the offer it takes;
/// the approving device's from its offer.
const attemptLife = Duration(minutes: 10);

/// The QR is made again before its attempt ends.
const _qrLife = Duration(minutes: 9);

/// What a later round may get past: a cut call, the database, another engine (inbox.dart's rule).
const _again = {'internal', 'storage', 'locked'};

/// The six digits an approving device shows, and nothing else, which the person types into the new one.
final _sixDigits = RegExp(r'^\d{6}$');

void _nothing() {}

class _Attempt {
  _Attempt.qr(this.qr) : way = SetupWay.qr, fingerprint = '';
  _Attempt.code(this.fingerprint) : way = SetupWay.code, qr = '';

  final SetupWay way;
  final String qr;
  final String fingerprint;
  var offered = false;
  var accepted = false;

  /// Calls off its timer.
  void Function() stop = _nothing;
}

class _Asked {
  _Asked(this.device, this.name, this.fingerprint, this.message, {required this.unfinished});

  final String device;
  final String name;
  final String fingerprint;

  /// The inbox message of the commitment asked about.
  final String message;
  var phase = ApprovalPhase.asked;
  String? code;
  ApprovalEnd? ended;
  bool unfinished;

  /// A confirmed approval's transfer, and the device the core approved, whose inbox it goes to, while its send failed:
  /// the same bytes go on the next Confirm.
  ({String device, String transfer})? approved;
  void Function() stop = _nothing;
}

class _Confirmed {
  _Confirmed(this.device, this.name, this.fingerprint, {this.transfer});

  final String device;
  final String name;
  final String fingerprint;

  /// A scanned approval's transfer while its send failed: the same bytes go on the next try ([Approvals.sendScanned]).
  String? transfer;
  void Function() stop = _nothing;
}

/// What a kept frame comes to: dropped, kept for a later round, or a transfer that set this device up.
enum _Kept { drop, keep, received }

/// The approval frames the record keeps, as the inbox kept them (inbox.dart).
List<Map<String, Object?>> _keptIn(EngineStore store) => [
  for (final one in switch (store.read(keptApprovals)) {
    final List<Object?> list => list,
    _ => const <Object?>[],
  })
    if (one is Map) one.cast<String, Object?>(),
];

ApprovalFrame? _frameOf(Map<String, Object?> message) => switch (message['message']) {
  final String text => readApprovalFrame(text),
  _ => null,
};

/// When a commitment's attempt ends, by the API's word on when it came: nothing it asks for can be done after.
DateTime? _endsAt(Map<String, Object?> message) => switch (message['created_at']) {
  final String at => DateTime.tryParse(at)?.add(attemptLife),
  _ => null,
};

class Approvals {
  Approvals(this._engine, this._soon, this._changed, this._askKept);

  final E2EEngine _engine;

  /// Runs work in the engine's turn.
  final void Function(Future<void> Function() work) _soon;

  /// What the views show changed.
  final void Function() _changed;

  /// The kept frames taken by the engine's role, in its turn: a hold that ends asks the questions that waited for it.
  final Future<void> Function() _askKept;
  _Attempt? _attempt;
  _Asked? _asked;
  _Confirmed? _confirmed;

  /// What the new device shows of its attempt.
  DeviceSetup? setup() => switch (_attempt) {
    null => null,
    final attempt when attempt.way == SetupWay.qr => DeviceSetup.qr(attempt.qr),
    final attempt => DeviceSetup.code(attempt.fingerprint, offered: attempt.offered, accepted: attempt.accepted),
  };

  /// What the approving device shows: the question asked of its person first, then an approval whose list waits.
  DeviceApproval? shown() {
    if (_asked case final asked?) {
      return DeviceApproval(
        device: asked.device,
        name: asked.name,
        fingerprint: asked.fingerprint,
        phase: asked.phase,
        code: asked.code,
        ended: asked.ended,
        unfinished: asked.unfinished,
      );
    }
    if (_confirmed case final confirmed?) {
      return DeviceApproval(
        device: confirmed.device,
        name: confirmed.name,
        fingerprint: confirmed.fingerprint,
        phase: ApprovalPhase.confirmed,
      );
    }
    return null;
  }

  /// A device this one approved hasn't put up its list yet: no list or key change of this device's may leave it out.
  bool holds() => _confirmed != null;

  /// One new device at a time (review 27's M5): while this device holds for one, another isn't offered, confirmed or
  /// approved from its QR. Its transfer would carry the list naming the first without its certificate, which the API
  /// refuses until that one's list is up, and the hold would wait for it alone.
  void _oneAtATime(String device) {
    final held = _confirmed;
    if (held != null && held.device != device) {
      throw CoreError('approval_waits', message: "a device this one approved hasn't put up its list yet");
    }
  }

  /// Nothing goes on: timers called off, nothing shown.
  void stop() {
    _attempt?.stop();
    _asked?.stop();
    _confirmed?.stop();
    _attempt = null;
    _asked = null;
    _confirmed = null;
  }

  /// [run] in the engine's turn once [wait] passed.
  void Function() _after(Duration wait, FutureOr<void> Function() run) =>
      _engine.clock.later(wait, () => _soon(() async => run()));

  /// A new attempt, shown as its QR, made again before its ten minutes end: the attempt before is over.
  Future<void> begin() async {
    _attempt?.stop();
    final begun = await _engine.host.handle<Map<String, Object?>>({'cmd': 'approval_begin'});
    final attempt = _Attempt.qr(begun['qr']! as String);
    attempt.stop = _after(_qrLife, () async {
      if (identical(_attempt, attempt)) await begin();
    });
    _attempt = attempt;
    _changed();
  }

  /// An attempt is over: its QR or its code isn't shown any more, and no timer makes another.
  void end() {
    _attempt?.stop();
    _attempt = null;
    _changed();
  }

  /// An attempt not done in its ten minutes starts over, with a new QR.
  void Function() _overAfter(Duration wait, _Attempt attempt) => _after(wait, () async {
    if (identical(_attempt, attempt)) await begin();
  });

  /// The code's way, an attempt of its own: its commitment, with this device's name, to each listed device of the
  /// user's, and its fingerprint shown, which the approving device's screen shows too. None that can approve, or none
  /// that got it, is said (`not_found` `approver`): then a new QR, as the code's attempt replaced the QR's in the core.
  Future<void> useCode() async {
    final api = _engine.api;
    final others = [
      for (final device in await api.devices())
        if (device.listed && !device.current) device,
    ];
    if (others.isEmpty) {
      throw CoreError('not_found', message: "no other device of the user's can approve this one", what: 'approver');
    }
    final begun = await _engine.host.handle<Map<String, Object?>>({'cmd': 'approval_begin'});
    final commitment = begun['commitment']! as String;
    final frame = approvalFrameMessage((step: ApprovalStep.commitment, data: commitment, name: _engine.deviceName));
    var sent = 0;
    for (final other in others) {
      try {
        await api.sendToDevice(other.id, frame);
        sent++;
      } catch (error) {
        debugPrint("e2e: a device of the user's wasn't asked to approve this one: $error");
      }
    }
    if (sent == 0) {
      // Its approval_begin replaced the QR's attempt: a new QR, as the one on screen would open nothing (review M3).
      await begin();
      throw CoreError('not_found', message: "no other device of the user's got this one's request", what: 'approver');
    }
    _attempt?.stop();
    final attempt = _Attempt.code(approvalFingerprint(base64Decode(commitment)));
    attempt.stop = _overAfter(attemptLife, attempt);
    _attempt = attempt;
    _changed();
  }

  /// The code the person typed into the new device, from the approving device's screen: the core compares it with its
  /// own (`rule_violation` `code_mismatch` if it isn't), never shown. True once it's accepted: a transfer kept for it
  /// can be taken. Six digits only, which the field takes alone: anything else is no code of the approving device's.
  Future<bool> accept(String code) async {
    final attempt = _attempt;
    if (attempt == null || attempt.way != SetupWay.code || !attempt.offered) return false;
    if (!_sixDigits.hasMatch(code)) {
      throw CoreError('rule_violation', message: 'a code is six digits', rule: 'code_mismatch');
    }
    await _engine.host.handle<Object?>({'cmd': 'approval_accept', 'code': code});
    attempt.accepted = true;
    _changed();
    return true;
  }

  /// The person's yes on the approving device: its own user observed, then the offer to the new device. False, with
  /// nothing offered, while the identity it holds was replaced (`not_own_identity`: another device changed the keys,
  /// whose transfer this one hasn't taken): the engine takes its inbox first. A device this one approved before that
  /// never took its transfer is still on this device's list, where the core refuses to approve it again: it comes off
  /// first (the core's way out, a list without it), on this yes, which the question says.
  Future<bool> approve(String device) async {
    final asked = _asked;
    if (asked == null || asked.device != device || asked.phase != ApprovalPhase.asked) return true;
    _oneAtATime(device);
    final frame = _commitmentOf(asked);
    if (frame == null) {
      _end(asked, ApprovalEnd.over);
      return true;
    }
    final served = await servedIdentity(_engine);
    if (served != null && await observeOwn(_engine, served) == 'not_own_identity') return false;
    if (served != null && await _unfinished(device, served)) {
      await unlist(_engine, device);
      if (_confirmed?.device == device) _release();
    }
    final String offer;
    try {
      offer =
          (await _engine.host.handle<Map<String, Object?>>({
                'cmd': 'approval_offer',
                'commitment': frame.data,
              }))['offer']!
              as String;
    } on CoreError catch (error) {
      // No device this one may approve: one set up already, another user's, or this one off its own list.
      if (const {'exists', 'rule_violation', 'bad_command'}.contains(error.code)) {
        debugPrint("e2e: a new device's request can't be approved here (${error.code}).");
        _end(asked, error.code == 'exists' ? ApprovalEnd.listed : ApprovalEnd.over);
        return true;
      }
      rethrow;
    }
    await _engine.api.sendToDevice(device, approvalFrameMessage((step: ApprovalStep.offer, data: offer, name: null)));
    asked
      ..phase = ApprovalPhase.offered
      ..unfinished = false
      ..stop();
    asked.stop = _after(attemptLife, () {
      if (identical(_asked, asked)) _end(asked, ApprovalEnd.over);
    });
    _changed();
    return true;
  }

  /// The commitment the question is about, as the record keeps it.
  ApprovalFrame? _commitmentOf(_Asked asked) {
    final message = _keptIn(_engine.store).where((one) => one['id'] == asked.message).firstOrNull;
    return message == null ? null : _frameOf(message);
  }

  /// On the list this device holds and not on the API's: approved here before, its transfer never taken. A served list
  /// that doesn't read says nothing of it.
  Future<bool> _unfinished(String device, duvet.Identity served) async {
    final held = listDevices((await coreStatus(_engine.host)).deviceList ?? '') ?? const <String>[];
    return held.contains(device) && listDevices(served.deviceList)?.contains(device) == false;
  }

  /// The approval can't go on: it says why until the person closes it, and its timer is called off.
  void _end(_Asked asked, ApprovalEnd ended) {
    asked
      ..stop()
      ..stop = _nothing
      ..phase = ApprovalPhase.ended
      ..ended = ended
      ..code = null;
    _changed();
  }

  /// The person's no, or their Close of an approval that ended: the question goes, and what the new device sent.
  Future<void> decline(String device) async {
    if (_asked?.device == device) await _forget(device);
  }

  /// The person's Confirm, after they saw the new device accept the code: approval_confirm with the code this device
  /// showed, then the transfer to the device the core approved (its reply's `device_id`, e2e#52: review 27's M6), the
  /// same bytes again after a send that failed. Android has no box of the system's: this Confirm, beside the
  /// fingerprint, is the person's act (the web's way). An attempt the core no longer has (`not_found`: another offer
  /// since, or its ten minutes) is over, and says so.
  Future<void> confirm(String device) async {
    final asked = _asked;
    final code = asked?.code;
    if (asked == null || asked.device != device || asked.phase != ApprovalPhase.code || code == null) return;
    _oneAtATime(device);
    var approved = asked.approved;
    if (approved == null) {
      if (_commitmentOf(asked) == null) return _end(asked, ApprovalEnd.over);
      final Map<String, Object?> reply;
      try {
        reply = await _engine.host.handle<Map<String, Object?>>({'cmd': 'approval_confirm', 'code': code});
      } on CoreError catch (error) {
        if (error.code == 'not_found') return _end(asked, ApprovalEnd.over);
        rethrow;
      }
      approved = asked.approved = (device: reply['device_id']! as String, transfer: reply['transfer']! as String);
    }
    final message = approvalFrameMessage((step: ApprovalStep.transfer, data: approved.transfer, name: null));
    await _engine.api.sendToDevice(approved.device, message);
    await _forget(device);
    _hold(_Confirmed(approved.device, asked.name, asked.fingerprint));
  }

  /// The device a phone of the user's scanned the QR of, by the ID the QR names, so its person is asked about that
  /// device before anything is approved: read here, never checked, as the core checks it as it approves. Null for a
  /// text that isn't an approval's QR. Nothing of the QR is kept.
  String? scannedDevice(String qr) => qrDevice(qr);

  /// The person's yes to the device a QR they scanned names ([named], as [scannedDevice] read it, by its [name]): its
  /// own user observed first, as for an offer (null, with nothing approved, while the identity it holds was replaced);
  /// one this device approved before that never took its transfer off this device's list first; then approval_from_qr
  /// with the text as it was scanned, and its transfer, as an approval frame, to the inbox of the device its reply
  /// names (e2e#52), which takes it with no code. This device's lists and keys wait for that device's list from now
  /// on, as after a Confirm: the core put it on the list this device holds. True once the transfer went; false when
  /// its send failed, the transfer kept for [sendScanned] with the same bytes, as approving it again would be the
  /// core's `exists` (review 27's M2). Refused while another device this one approved sets up (M5).
  Future<bool?> approveScanned(String qr, String named, String name) async {
    _oneAtATime(named);
    final served = await servedIdentity(_engine);
    if (served != null && await observeOwn(_engine, served) == 'not_own_identity') return null;
    if (served != null && await _unfinished(named, served)) {
      await unlist(_engine, named);
      if (_confirmed?.device == named) _release();
    }
    final approved = await _engine.host.handle<Map<String, Object?>>({'cmd': 'approval_from_qr', 'qr': qr});
    final device = approved['device_id'];
    // The core read the same QR: another device would be one this app misread, while its person said yes to another.
    if (device is! String || device != named) throw StateError("the QR's device isn't the one its person was asked of");
    _hold(_Confirmed(device, name, '', transfer: approved['transfer']! as String));
    try {
      await sendScanned(device);
    } catch (error) {
      debugPrint("e2e: a scanned device's transfer waits for Try again: ${error.runtimeType}");
      return false;
    }
    return true;
  }

  /// The transfer of a scanned approval of [device] whose send failed, sent again as it was. None waits for it any
  /// more (its hold ended, another took its place, the engine started again): `not_found` `transfer`, and its QR is
  /// scanned again.
  Future<void> sendScanned(String device) async {
    final confirmed = _confirmed;
    final transfer = confirmed?.transfer;
    if (confirmed == null || confirmed.device != device || transfer == null) {
      throw CoreError('not_found', message: 'no transfer waits for that device', what: 'transfer');
    }
    final message = approvalFrameMessage((step: ApprovalStep.transfer, data: transfer, name: null));
    await _engine.api.sendToDevice(confirmed.device, message);
    confirmed.transfer = null;
    _changed();
  }

  /// This device's lists and keys, and its other approvals, wait for the approved device's list, ten minutes at most:
  /// the new device's attempt is over within ten minutes of the offer it took, or of its QR, which came first.
  void _hold(_Confirmed confirmed) {
    _confirmed?.stop();
    confirmed.stop = _after(attemptLife, () async {
      if (!identical(_confirmed, confirmed)) return;
      _release();
      await _askKept();
    });
    _confirmed = confirmed;
    _changed();
  }

  /// The user's list as served: once it names the device this one approved, its changes go on.
  void listed(duvet.Identity served) {
    final confirmed = _confirmed;
    if (confirmed != null && (listDevices(served.deviceList)?.contains(confirmed.device) ?? false)) _release();
  }

  void _release() {
    _confirmed?.stop();
    _confirmed = null;
    _changed();
  }

  /// A new device's request let go of: its question, and its frames in the record.
  Future<void> _forget(String device) async {
    if (_asked?.device == device) {
      _asked!.stop();
      _asked = null;
    }
    final kept = [
      for (final message in _keptIn(_engine.store))
        if (message['from_device_id'] != device) message,
    ];
    await _engine.store
        .write(keptApprovals, kept.isEmpty ? null : kept)
        .catchError((Object error) => debugPrint("e2e: the record's approvals: ${error.runtimeType}"));
    _changed();
  }

  /// The approval frames the inbox kept, each by this device's [role]: what one is for is done, and what waits stays
  /// kept (in order). One a cut call or an unanswered request couldn't do waits for the next round. True when a
  /// transfer set this device up, whose role then changes: the rest stays for its next round.
  Future<bool> take(ApprovalRole? role) async {
    final kept = _keptIn(_engine.store);
    if (role == null || kept.isEmpty) return false;
    // A device's newest commitment alone: one sent again replaces the one before.
    final newest = <Object?, Object?>{
      for (final message in kept)
        if (_frameOf(message)?.step == ApprovalStep.commitment) message['from_device_id']: message['id'],
    };
    final stays = <Map<String, Object?>>[];
    var received = false;
    for (final (at, message) in kept.indexed) {
      final frame = _frameOf(message);
      if (frame == null) continue;
      if (frame.step == ApprovalStep.commitment && newest[message['from_device_id']] != message['id']) continue;
      _Kept keep;
      try {
        keep = role == ApprovalRole.approver ? await _asApprover(message, frame) : await _asNew(message, frame);
      } catch (error) {
        if (error is CoreError && !_again.contains(error.code)) rethrow;
        debugPrint("e2e: an approval waits for the inbox's next round: $error");
        keep = _Kept.keep;
      }
      if (keep == _Kept.received) {
        received = true;
        stays.addAll(kept.skip(at + 1));
        break;
      }
      if (keep == _Kept.keep) stays.add(message);
    }
    await _engine.store
        .write(keptApprovals, stays.isEmpty ? null : stays)
        .catchError((Object error) => debugPrint("e2e: the record's approvals: ${error.runtimeType}"));
    _changed();
    return received;
  }

  /// On the approving device: a commitment asks its person; a reveal gives the code; the rest is a new device's.
  Future<_Kept> _asApprover(Map<String, Object?> message, ApprovalFrame frame) async {
    final device = message['from_device_id'];
    if (device is! String) return _Kept.drop;
    final asked = _asked;
    if (frame.step == ApprovalStep.commitment) {
      // The API names the sender: one that isn't the device the commitment names would have the person asked about one
      // device, and the yes offer to, and unlist, another (review 27's M6).
      if (commitmentDevice(frame.data) != device) {
        debugPrint("e2e: a new device's request came from another device than it names, and goes.");
        return _Kept.drop;
      }
      final left = _endsAt(message)?.difference(_engine.clock.now());
      if (left == null || left <= Duration.zero) {
        if (asked != null && asked.message == message['id'] && asked.phase == ApprovalPhase.asked) {
          await _forget(device);
        }
        return _Kept.drop;
      }
      if (asked != null && (asked.device != device || asked.message == message['id'])) return _Kept.keep;
      // Another device than the one this device approved and waits for: asked once that one's list is up (M5).
      if (_confirmed case final held? when held.device != device) return _Kept.keep;
      // A new attempt of the device's, or the first ask: the question starts over, and ends with that attempt.
      asked?.stop();
      final served = await servedIdentity(_engine);
      final question = _Asked(
        device,
        frame.name ?? '',
        approvalFingerprint(base64Decode(frame.data)),
        message['id']! as String,
        unfinished: served != null && await _unfinished(device, served),
      );
      question.stop = _after(left, () async {
        if (identical(_asked, question) && question.phase == ApprovalPhase.asked) await _forget(device);
      });
      _asked = question;
      return _Kept.keep;
    }
    if (frame.step != ApprovalStep.reveal || asked == null || asked.device != device) return _Kept.drop;
    // Kept until the approval ends: a restart asks again, and the yes's offer (the same) takes it again (review M1).
    if (asked.phase != ApprovalPhase.offered) return _Kept.keep;
    try {
      asked.code =
          (await _engine.host.handle<Map<String, Object?>>({'cmd': 'approval_check', 'reveal': frame.data}))['code']!
              as String;
    } on CoreError catch (error) {
      if (_again.contains(error.code)) rethrow;
      debugPrint("e2e: a new device's reveal doesn't hold (${error.code}), and goes.");
      return _Kept.drop;
    }
    asked.phase = ApprovalPhase.code;
    return _Kept.keep;
  }

  /// On the new device: the first offer by the code's way, and a transfer, kept until its code is accepted.
  Future<_Kept> _asNew(Map<String, Object?> message, ApprovalFrame frame) async {
    final E2EEngine(:api, :host) = _engine;
    if (frame.step == ApprovalStep.offer) {
      final attempt = _attempt;
      final from = message['from_device_id'];
      if (attempt == null || attempt.way != SetupWay.code || attempt.offered || from is! String) return _Kept.drop;
      final String reveal;
      try {
        reveal =
            (await host.handle<Map<String, Object?>>({'cmd': 'approval_reveal', 'offer': frame.data}))['reveal']!
                as String;
      } on CoreError catch (error) {
        if (_again.contains(error.code)) rethrow;
        debugPrint("e2e: an approving device's offer can't be taken (${error.code}), and goes.");
        return _Kept.drop;
      }
      // The same offer again gets the same reveal: a send that failed goes on the next round.
      await api.sendToDevice(from, approvalFrameMessage((step: ApprovalStep.reveal, data: reveal, name: null)));
      attempt
        ..offered = true
        ..stop();
      attempt.stop = _overAfter(attemptLife, attempt);
      return _Kept.drop;
    }
    if (frame.step != ApprovalStep.transfer) return _Kept.drop;
    try {
      final backup = await api.identityBackup();
      await withPreviousKeys(
        backup.wrappedPreviousBackupKeys,
        (previous) => host.handle<Object?>({
          'cmd': 'approval_receive',
          'transfer': frame.data,
          'wrapped_previous_backup_keys': ?previous,
        }),
      );
    } on CoreError catch (error) {
      if (_again.contains(error.code)) rethrow;
      // Sealed to the commitment's key, it counts once the code is accepted: kept, and taken after it.
      if (error.code == 'not_found' && error.what == 'code') return _Kept.keep;
      debugPrint("e2e: a transfer to this device can't be taken (${error.code}), and goes.");
      return _Kept.drop;
    }
    return _Kept.received;
  }
}
