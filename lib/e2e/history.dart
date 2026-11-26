/// Shared histories (PLAN-E2E-CLIENTES.md, Tasks 30 and 31; decision 26), and the catch-ups this device receives
/// (decision 14, «Quien no tenía dispositivo»). The desktop's history.ts in Dart.
///
/// Sharing: the person shares how far back a conversation goes on this device (the last day, week or month, or all of
/// it) with another member. The core makes one package of it, its newest when not all of it fits (`truncated`); the
/// package goes up part by part outside the engine's turn and is completed, which posts its notice (type 4) in the
/// conversation, then its key goes to each of the member's devices' inboxes, and only then are its parts let go.
///
/// Receiving: a package for this device (HISTORY_SHARE_CREATE, or the API's list of those it hasn't acknowledged) opens
/// with the key its sender's device left in this one's inbox, which receive_direct took (inbox.dart) and the record
/// keeps the package of ([historyKeys]): one whose key hasn't come waits for it. A share is offered in its chat and
/// imported only on the person's yes (rule R2 of the core's review: a member could make a history up); a catch-up is
/// imported by itself once the engine's turn has been free a while ([quietBeforeImport]). The key's kind, sharer and
/// conversation are the core's, never the API's word. One import at a time: its parts download outside the engine's
/// turn, history_import runs in it, then the API is told (its ack). Imported messages say who shared them, and fill
/// the rows that waited; a row this device holds stays its own.
///
/// The app's engine alone does any of it, the one with a screen: a push's engine never shares or imports (core_gate.dart
/// refuses both there; Review Focus 2).
library;

import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart' as time;
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'host.dart';
import 'identity.dart';
import 'store.dart';

/// How far back a share goes, as the core names its ranges.
const shareRanges = ['day', 'week', 'month', 'all'];

/// How long the engine's turn stays free before a catch-up waiting for its import has it: one at a time, with the app
/// quiet.
const quietBeforeImport = Duration(seconds: 5);

/// An import that began this many times without ending (the app closed or was killed meanwhile) isn't tried again: a
/// package too big for the phone would end the app each time it starts.
const _mostStarts = 3;

/// How long the API keeps a package, and the record its key: past it, nothing opens it.
const _keyLife = Duration(days: 30);

/// A failed import waits 2 s, then twice as long each time, up to an hour, as a catch-up's upload does.
const _retryFirst = Duration(seconds: 2);
const _retryMost = Duration(hours: 1);

/// A share of a conversation's history whose key this device holds, waiting for the person's yes: who shared it and of
/// which conversation as the core read them from its key, and how far back the API says it goes.
@immutable
class HistoryOffer {
  const HistoryOffer({
    required this.shareId,
    required this.conversationId,
    required this.fromUserId,
    required this.range,
  });

  final String shareId;
  final String conversationId;

  /// Who shared it.
  final String fromUserId;

  /// How far back it goes: day, week, month or all.
  final String range;

  @override
  bool operator ==(Object other) =>
      other is HistoryOffer &&
      other.shareId == shareId &&
      other.conversationId == conversationId &&
      other.fromUserId == fromUserId &&
      other.range == range;

  @override
  int get hashCode => Object.hash(shareId, conversationId, fromUserId, range);

  @override
  String toString() => 'HistoryOffer($shareId, $range)';
}

/// What a share came to: cut to its newest messages ([truncated]), and the time from which it holds every one this
/// device has.
typedef SharedHistory = ({bool truncated, DateTime start});

/// The member to share with has no device that can receive it: no identity, or no device on their list.
class NoDeviceToShareWith implements Exception {
  const NoDeviceToShareWith();
}

/// The person's share made: what this device holds of the conversation from [range]'s start, sealed to [user]'s devices
/// as the API serves them, the member observed first so the core holds the list it seals to.
Future<Map<String, Object?>> makeShare(E2EEngine engine, String conversationId, String user, String range) async {
  final duvet.Identity identity;
  try {
    identity = await engine.api.identity(user);
  } on duvet.DuvetApiException catch (error) {
    if (error.statusCode == 403 || error.statusCode == 404) throw const NoDeviceToShareWith();
    rethrow;
  }
  if (identity.certificates.isEmpty) throw const NoDeviceToShareWith();
  await observeUsers(engine, [user]);
  try {
    return await withIdentities(
      engine,
      () => engine.host.share({
        'cmd': 'history_share',
        'conversation_id': conversationId,
        'to_user': user,
        'range': range,
        'devices': identity.certificates,
      }),
    );
  } on CoreError catch (error) {
    // None of the devices served is on their list as this device holds it.
    if (error.rule == 'device_not_listed' || error.field == 'devices') throw const NoDeviceToShareWith();
    rethrow;
  }
}

/// A package up, part by part, completed (a share's notice is posted then), then its key in each of its recipient's
/// devices' inboxes: a device the API no longer has, or no longer lets this user reach, takes none. The same package
/// and parts again are taken as they were, so one that failed midway goes again from the start. A share says how far
/// back it goes ([range]); a catch-up says nothing of it.
Future<void> uploadPackage(
  E2EEngine engine,
  String conversationId,
  String user,
  Map<String, Object?> made, {
  required String kind,
  String? range,
}) async {
  final E2EEngine(:api, :host) = engine;
  final shareId = made['share_id']! as String;
  final parts = made['parts']! as int;
  await api.putShare(
    conversationId,
    shareId,
    duvet.HistoryShareUpload(
      toUserId: user,
      kind: kind,
      range: range,
      startsAt: DateTime.fromMillisecondsSinceEpoch(made['start']! as int, isUtc: true),
      size: made['size']! as int,
      parts: parts,
    ),
  );
  for (var n = 0; n < parts; n++) {
    await api.putSharePart(conversationId, shareId, n, await host.sharePart(shareId, n));
  }
  await api.completeShare(conversationId, shareId);
  for (final key in (made['keys']! as List).cast<Map<String, Object?>>()) {
    try {
      await api.sendToDevice(key['device_id']! as String, key['message']! as String);
    } on duvet.DuvetApiException catch (error) {
      if (error.statusCode != 403 && error.statusCode != 404) rethrow;
    }
  }
}

/// A package's key as the record keeps it ([historyKeys]): its kind (share or catch_up), conversation and sharer, as
/// the core read them; when it came; how many imports of it began and never ended; and whether its import is done, its
/// acknowledgement still to go.
typedef _Key = ({String kind, String conversationId, String userId, int at, int starts, bool imported});

/// The person's shares and the packages this device receives, between the engine's turns.
class Histories {
  Histories(this._engine, this._act, this._soon, this._sync, this._changed);

  final E2EEngine _engine;

  /// Runs work in the engine's turn while this device is ready: it throws otherwise.
  final Future<void> Function(Future<void> Function() work) _act;

  /// Runs work in the engine's turn, while the device is ready, its failure logged.
  final void Function(Future<void> Function() work) _soon;

  /// The conversation's queue applied, in the turn: its welcome brings this device into its group.
  final Future<void> Function(String conversationId) _sync;

  /// A conversation's messages changed on this device: an import filled some.
  final void Function(String conversationId) _changed;

  /// The packages for this device as the API listed them or the gateway told of them since, by ID.
  final _packages = <String, duvet.HistoryShare>{};

  /// When each package or key came, in the order things came ([_mark]): what came since a list was asked for stays,
  /// whatever that list says.
  final _seen = <String, int>{};
  var _mark = 0;

  /// The keys the record keeps, read once: a record that can't be written still holds them for this run.
  Map<String, _Key>? _kept;

  final _offers = ValueNotifier<Map<String, List<HistoryOffer>>>(const {});

  /// The shares this device holds the keys of, waiting for the person's yes, by conversation, oldest first.
  ValueListenable<Map<String, List<HistoryOffer>>> get offers => _offers;

  /// The imports, one at a time, and whether one is on its way.
  Future<void> _importing = Future.value();
  var _inFlight = false;

  /// Whether the engine's turn is free now, and the wait for the quiet that lets a catch-up in (it calls it off).
  var _idle = true;
  void Function()? _quiet;

  /// Packages whose import failed, waiting before they go again (their timers), and how many failed in a row.
  final _waiting = <String, void Function()>{};
  final _failed = <String, int>{};

  /// The person's share made and not delivered yet, by conversation, member and range: one kept at a time.
  final _made = <String, Map<String, Object?>>{};

  var _stopped = false;

  // ---------------------------------------------------------------------------------------------------------------
  // Sharing.

  /// The person's share of the conversation's history from [range]'s start with [user]: made in the engine's turn, up
  /// outside it, its key in each of the member's devices' inboxes, then its parts let go. One whose upload failed once
  /// the API could have it is kept, and the person's next share of the same goes on with that package, which the API
  /// takes again as one share; one the API refused (its ten an hour, a member who left) goes, and the next is made anew.
  Future<SharedHistory> share(String conversationId, String user, String range) async {
    final key = '$conversationId:$user:$range';
    var made = _made[key];
    if (made == null) {
      Map<String, Object?>? fresh;
      await _act(() async => fresh = await makeShare(_engine, conversationId, user, range));
      made = fresh!;
      // Its parts stay in memory until it's delivered: an earlier share's go.
      for (final other in [..._made.keys]) {
        _dropMade(other);
      }
      _made[key] = made;
    }
    try {
      await uploadPackage(_engine, conversationId, user, made, kind: 'share', range: range);
    } on duvet.DuvetApiException catch (error) {
      // Refused, not cut: a 409 is a part or a key still to go (an inbox full), which the next share takes on.
      if (error.statusCode >= 400 && error.statusCode < 500 && error.statusCode != 409) _dropMade(key);
      rethrow;
    }
    _dropMade(key);
    return (
      truncated: made['truncated'] == true,
      start: DateTime.fromMillisecondsSinceEpoch(made['start']! as int, isUtc: true),
    );
  }

  void _dropMade(String key) {
    if (_made.remove(key)?['share_id'] case final String share) {
      unawaited(_engine.host.dropShare(share).catchError((Object _) {}));
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Receiving.

  Map<String, _Key> get _keys => _kept ??= _read();

  Map<String, _Key> _read() => {
    if (_engine.store.read(historyKeys) case final List<Object?> kept)
      for (final one in kept)
        if (one case {
          'share_id': final String id,
          'kind': final String kind,
          'conversation_id': final String conversation,
          'user_id': final String user,
          'at': final int at,
        })
          id: (
            kind: kind,
            conversationId: conversation,
            userId: user,
            at: at,
            starts: switch (one['starts']) {
              final int starts => starts,
              _ => 0,
            },
            imported: one['imported'] == true,
          ),
  };

  /// The record written as [_keys] has it now: no key, only what tells a package opens here.
  Future<void> _write() => _engine.store.write(historyKeys, [
    for (final MapEntry(key: id, value: key) in _keys.entries)
      {
        'share_id': id,
        'kind': key.kind,
        'conversation_id': key.conversationId,
        'user_id': key.userId,
        'at': key.at,
        if (key.starts > 0) 'starts': key.starts,
        if (key.imported) 'imported': true,
      },
  ]);

  /// receive_direct took a package's key (inbox.dart; its answer, `{type, share_id, conversation_id, user_id}`): kept in
  /// the record before its message leaves the inbox, so a write that fails leaves it there for the next round. Its
  /// package is offered or imported once it's known, which the API's list is asked for when it isn't.
  Future<void> keyTaken(Map<String, Object?> received) async {
    final kind = switch (received['type']) {
      'history.key' => 'share',
      'catch_up.key' => 'catch_up',
      _ => null,
    };
    if (kind == null) return;
    final id = received['share_id']! as String;
    final had = _keys[id];
    _keys[id] = (
      kind: kind,
      conversationId: received['conversation_id']! as String,
      userId: received['user_id']! as String,
      at: time.clock.now().millisecondsSinceEpoch,
      starts: had?.starts ?? 0,
      imported: had?.imported ?? false,
    );
    _seen[id] = ++_mark;
    await _write();
    if (!_packages.containsKey(id)) _soon(list);
    _shown();
  }

  /// HISTORY_SHARE_CREATE: a package completed for this user.
  void heard(duvet.HistoryShare share) {
    _packages[share.id] = share;
    _seen[share.id] = ++_mark;
    _shown();
  }

  /// The packages for this device as the API lists them now. What it no longer lists goes (acknowledged, or gone with
  /// its 30 days), with its key, but what came since the list was asked for: a key comes after its package is complete.
  Future<void> list() async {
    final mark = _mark;
    final listed = {for (final share in await _engine.api.shares()) share.id: share};
    bool gone(String id) => !listed.containsKey(id) && (_seen[id] ?? 0) <= mark;
    _packages
      ..removeWhere((id, _) => gone(id))
      ..addAll(listed);
    final old = time.clock.now().subtract(_keyLife).millisecondsSinceEpoch;
    final had = _keys.length;
    _keys.removeWhere((id, key) => gone(id) || key.at < old);
    if (_keys.length != had) {
      await _write().catchError((Object error) => debugPrint('e2e: the history keys: $error'));
    }
    _shown();
  }

  /// The person's yes to an offer: its package imported now, after an import on its way. A failure throws: one that
  /// can't ever be imported lets the offer go, and anything else leaves it for another yes.
  Future<void> take(String shareId) {
    final key = _keys[shareId];
    final share = key == null ? null : _agreed(shareId, key);
    if (share == null || key?.kind != 'share') throw StateError('no such offer');
    return _take(share, person: true);
  }

  /// The engine's turn took work: a catch-up waits for it to be quiet again.
  void busy() {
    _idle = false;
    _quiet?.call();
    _quiet = null;
  }

  /// The engine's turn is free: a catch-up due may go once it stays so a while.
  void idle() {
    _idle = true;
    _arrange();
  }

  /// Nothing more goes: what waits is called off.
  void stop() {
    _stopped = true;
    _quiet?.call();
    _quiet = null;
    for (final cancel in _waiting.values) {
      cancel();
    }
    _waiting.clear();
    for (final key in [..._made.keys]) {
      _dropMade(key);
    }
  }

  /// This installation starts over as a new device: what it knew of packages goes (the record's keys go with the rest
  /// of the device's record).
  void forget() {
    for (final cancel in _waiting.values) {
      cancel();
    }
    _waiting.clear();
    _failed.clear();
    _packages.clear();
    _seen.clear();
    _kept = {};
    _made.clear();
    _offers.value = const {};
  }

  /// The package [id] as the API lists it, when its key is here and says what the listing says (its conversation, sharer
  /// and kind, as the sender's device signed them): one that says otherwise is nothing this device takes in.
  duvet.HistoryShare? _agreed(String id, _Key key) => switch (_packages[id]) {
    final share?
        when share.conversationId == key.conversationId && share.fromUserId == key.userId && share.kind == key.kind =>
      share,
    _ => null,
  };

  /// The offers as the packages and keys known now make them, and what's due next arranged.
  void _shown() {
    final offers = <String, List<HistoryOffer>>{};
    for (final MapEntry(key: id, value: key) in _keys.entries) {
      final share = _agreed(id, key);
      if (share == null || key.kind != 'share' || key.imported) continue;
      (offers[key.conversationId] ??= []).add(
        HistoryOffer(shareId: id, conversationId: key.conversationId, fromUserId: key.userId, range: share.range ?? ''),
      );
    }
    for (final list in offers.values) {
      list.sort((a, b) => a.shareId.compareTo(b.shareId));
    }
    if (!mapEquals(_offersFlat(offers), _offersFlat(_offers.value))) _offers.value = offers;
    _arrange();
  }

  static Map<String, HistoryOffer> _offersFlat(Map<String, List<HistoryOffer>> offers) => {
    for (final list in offers.values)
      for (final offer in list) offer.shareId: offer,
  };

  /// Once the engine is quiet: the next catch-up to import, or an acknowledgement that didn't go. One at a time.
  void _arrange() {
    if (_stopped || _inFlight || _quiet != null || !_idle || _next() == null) return;
    _quiet = _engine.clock.later(quietBeforeImport, () {
      _quiet = null;
      if (_next() case final next? when !_stopped && !_inFlight) {
        unawaited(_take(next, person: false).catchError((Object _) {}));
      }
    });
  }

  /// The package due next by itself, oldest first: one imported whose acknowledgement didn't go, or a catch-up. None
  /// that waits after a failure, and no share, which waits for the person.
  duvet.HistoryShare? _next() {
    final due = [
      for (final MapEntry(key: id, value: key) in _keys.entries)
        if (_agreed(id, key) case final share?
            when !_waiting.containsKey(id) && (key.imported || key.kind == 'catch_up'))
          share,
    ]..sort((a, b) => a.id.compareTo(b.id));
    return due.firstOrNull;
  }

  Future<void> _take(duvet.HistoryShare share, {required bool person}) {
    final run = _importing.then((_) => _import(share, person: person));
    _importing = run.catchError((Object _) {});
    return run;
  }

  /// One package imported: its parts downloaded outside the engine's turn, history_import in it, then acknowledged and
  /// its key forgotten. A key the core no longer has was used by an import whose end wasn't recorded: done with. An
  /// import counts as begun in the record before it begins, and as ended once it ends.
  Future<void> _import(duvet.HistoryShare share, {required bool person}) async {
    final id = share.id;
    final kept = _keys[id];
    if (_stopped || kept == null || !_packages.containsKey(id)) return;
    _inFlight = true;
    try {
      if (!kept.imported) {
        if (kept.starts >= _mostStarts) throw CoreError('too_large', message: 'its imports never ended');
        // Nothing downloads for an import this device can't make now.
        if (_engine.state.value.stage != EngineStage.ready) throw StateError("encrypted conversations aren't ready");
        final parts = <Uint8List>[for (var n = 0; n < share.parts; n++) await _engine.api.sharePart(id, n)];
        _keys[id] = _with(kept, starts: kept.starts + 1);
        await _write();
        try {
          await _act(() async {
            await _sync(kept.conversationId).catchError(
              (Object error) => debugPrint("e2e: a conversation's queue waits while a history comes in: $error"),
            );
            await _engine.host.importShare(id, parts);
          });
        } on CoreError catch (error) {
          if (error.code != 'not_found' || error.what != 'share') rethrow;
        } finally {
          if (_keys[id] case final now?) _keys[id] = _with(now, starts: kept.starts);
        }
        _keys[id] = _with(kept, imported: true);
        await _write().catchError((Object error) => debugPrint('e2e: the history keys: $error'));
        _changed(kept.conversationId);
        _shown();
      }
      await _engine.api.ackShare(id);
      _failed.remove(id);
      await _forget(id);
    } catch (error) {
      if (_forGood(error)) {
        debugPrint("e2e: a shared history can't be imported here, and goes: ${_why(error)}");
        await _letGo(id);
      } else {
        debugPrint("e2e: a shared history wasn't imported, and goes again: ${_why(error)}");
        _later(id);
      }
      if (person) rethrow;
    } finally {
      _inFlight = false;
      _arrange();
    }
  }

  static _Key _with(_Key key, {int? starts, bool? imported}) => (
    kind: key.kind,
    conversationId: key.conversationId,
    userId: key.userId,
    at: key.at,
    starts: starts ?? key.starts,
    imported: imported ?? key.imported,
  );

  /// What can never import: a package that doesn't open, isn't what its key says, is past what a package holds, or
  /// whose imports kept ending the app; one the API no longer has. A gate that refuses the import itself (not the app's
  /// engine: core_gate.dart) isn't one of them, so nothing is acknowledged there.
  static bool _forGood(Object error) => switch (error) {
    CoreError(code: 'bad_command', field: 'cmd') => false,
    CoreError(:final code) => const {
      'too_large',
      'decrypt_failed',
      'invalid_signature',
      'rule_violation',
      'bad_command',
    }.contains(code),
    duvet.DuvetApiException(:final statusCode) => statusCode == 403 || statusCode == 404,
    _ => false,
  };

  /// An error as a log line says it: its code or status, never what a package holds.
  static String _why(Object error) => switch (error) {
    CoreError(:final code, :final rule) => '$code${rule == null ? '' : ' $rule'}',
    duvet.DuvetApiException(:final statusCode) => '$statusCode',
    _ => '${error.runtimeType}',
  };

  /// A package that can never import here: acknowledged all the same (its key opens nothing here), and forgotten.
  Future<void> _letGo(String id) async {
    try {
      await _engine.api.ackShare(id);
    } catch (error) {
      debugPrint("e2e: a shared history that can't be imported wasn't acknowledged: ${_why(error)}");
    }
    await _forget(id);
  }

  Future<void> _forget(String id) async {
    _keys.remove(id);
    _packages.remove(id);
    _failed.remove(id);
    _shown();
    await _write().catchError((Object error) => debugPrint('e2e: the history keys: $error'));
  }

  /// A failure that may pass: the package waits its backoff before it's due again.
  void _later(String id) {
    if (_stopped) return;
    final tries = _failed[id] = (_failed[id] ?? 0) + 1;
    final wait = _retryFirst * (1 << min(tries - 1, 11));
    _waiting[id]?.call();
    _waiting[id] = _engine.clock.later(wait < _retryMost ? wait : _retryMost, () {
      _waiting.remove(id);
      _arrange();
    });
  }
}
