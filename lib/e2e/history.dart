/// Shared histories (PLAN-E2E-CLIENTES.md, Tasks 30 and 31; decision 26), and the catch-ups this device receives
/// (decision 14, «Quien no tenía dispositivo»). The desktop's history.ts in Dart.
///
/// Sharing: the person shares how far back a conversation goes on this device (the last day, week or month, or all of
/// it) with another member. The core makes one package of it in the engine's turn, its newest when not all of it fits
/// (`truncated`). Outside the turn the package goes to the API, and the person is answered once the API took it. Then
/// its parts go up, its key goes to each of the member's devices' inboxes, and last it's completed. That posts its
/// notice (type 4) in the conversation and lists it for the member, so nobody sees a share whose keys didn't go. A try
/// that fails goes on from where it stopped after a wait ([packageWait]); one that can never go is told to the person.
///
/// Receiving: a package for this device (HISTORY_SHARE_CREATE, or the API's list of those it hasn't acknowledged) opens
/// with the key its sender's device left in this one's inbox, in either order. receive_direct took the key (inbox.dart)
/// and the record keeps its package of it ([historyKeys]): one whose key hasn't come waits for it. A share is offered
/// in its chat, imported only on the person's yes (rule R2 of the core's review: a member could make a history up) or
/// let go on their Dismiss; a catch-up is imported by itself once the engine's turn has been free a while
/// ([quietBeforeImport]). The key's kind, sharer and conversation are the core's, never the API's word. One import at a
/// time: its parts download outside the engine's turn, history_import runs in it, then the API is told (its ack).
/// Imported messages say who shared them, and fill the rows that waited; a row this device holds stays its own.
///
/// The app's engine alone does any of it, the one with a screen: a push's engine never shares or imports
/// (core_gate.dart refuses both there; Review Focus 2).
library;

import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart' as time;
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'core_gate.dart' show maxShareParts;
import 'engine.dart';
import 'host.dart';
import 'identity.dart';
import 'store.dart';

/// How far back a share goes, as the core names its ranges.
const shareRanges = ['day', 'week', 'month', 'all'];

/// How long the engine's turn stays free before a catch-up waiting for its import has it: one at a time, with the app
/// quiet.
const quietBeforeImport = Duration(seconds: 5);

/// A catch-up whose imports began this many times without bringing it in isn't imported by itself again: it waits as
/// an offer for the person. Those that never ended count (the app closed or was killed meanwhile, as a package too big
/// for the phone would end it each time it starts), and so do those that failed, so a package that keeps failing isn't
/// downloaded every hour for its 30 days.
const _mostStarts = 3;

/// How long the API keeps a package, and the record its key and the ID of one done with: past it, nothing opens it.
const _keyLife = Duration(days: 30);

/// A package's parts together, and each part, at most: the API's caps (MaxHistoryShare, MaxHistorySharePart).
const _packageMost = 64 << 20;
const _partMost = (1 << 20) + 16;

/// The API's page of the packages a device hasn't acknowledged: the oldest 100, the next once those are acknowledged.
const _listMost = 100;

/// The keys, and the IDs of packages done with, that the record keeps at most: past it, the oldest go first.
const _keptMost = 1000;

/// The offers each chat shows at once, the newest first: the next shows as one is added or dismissed.
const _offersShown = 3;

/// A try that failed waits a minute, then twice as long each time, up to an hour.
const _retryFirst = Duration(minutes: 1);
const _retryMost = Duration(hours: 1);

/// How long a package's try that failed waits before its next, sent or received ([tries]: those that failed before):
/// a minute, then twice as long each time, up to an hour. A 429 waits what its Retry-After says ([unsaid] when it says
/// nothing, the backoff unless given), never less than the backoff's first minute, so a `Retry-After: 0` isn't tried
/// again at once.
Duration packageWait(Object error, int tries, {Duration? unsaid}) {
  final backoff = _retryFirst * (1 << min(tries, 6));
  final waited = backoff < _retryMost ? backoff : _retryMost;
  if (error is! duvet.DuvetApiException || error.statusCode != 429) return waited;
  final asked = error.retryAfter ?? unsaid ?? waited;
  return asked > _retryFirst ? asked : _retryFirst;
}

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

  /// How far back it goes: day, week, month or all, or none for a catch-up.
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

/// The member to share with has no device that can receive it: no identity, or no device of theirs the API serves.
class NoDeviceToShareWith implements Exception {
  const NoDeviceToShareWith();
}

/// The API refused the person's share for its ten an hour: they may share again after [wait].
class ShareLimit implements Exception {
  const ShareLimit(this.wait);
  final Duration wait;

  @override
  String toString() => 'ShareLimit($wait)';
}

/// A part longer than a part can be: a server that sends one gets nothing more of its package.
class _PartTooLong implements Exception {
  const _PartTooLong();

  @override
  String toString() => 'a part past $_partMost bytes';
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
  // A served device that isn't on their list (the core's device_not_listed) is the server's doing, as a member with
  // devices is served only theirs: the core's refusal, not a member with no device.
  return withIdentities(
    engine,
    () => engine.host.share({
      'cmd': 'history_share',
      'conversation_id': conversationId,
      'to_user': user,
      'range': range,
      'devices': identity.certificates,
    }),
  );
}

/// A package going up, a share or a catch-up: how far it went, so a try that failed goes on from there.
class PackageUpload {
  PackageUpload(this.conversationId, this.user, this.made, {required this.kind, this.range});

  final String conversationId;

  /// Whom it's for.
  final String user;

  /// What the core made: its ID, parts, size and start, whether it was cut, and its keys for the member's devices.
  final Map<String, Object?> made;
  final String kind;
  final String? range;

  /// The API took it (its PUT), which counts it toward the sender's limits.
  var taken = false;
  var partsUp = 0;

  /// The devices whose key went, or that take none: the API no longer has them, or no longer lets this user reach them.
  final keysSent = <String>{};
  var completed = false;

  /// What it was doing when it last stopped (`key` for a key's inbox), and how many tries failed in a row.
  var step = '';
  var tries = 0;

  String get shareId => made['share_id']! as String;

  /// Whether [error] ends it for good: the core no longer has its parts, or the API refused what no try changes. A full
  /// inbox (409) waits for its device to read it.
  bool endsWith(Object error) => switch (error) {
    CoreError() => true,
    duvet.DuvetApiException(:final statusCode) =>
      const {400, 403, 404, 413}.contains(statusCode) || (statusCode == 409 && step != 'key'),
    _ => false,
  };
}

/// A package up, from where it stopped: taken by the API (then [onTaken]), its parts, its key in each of its
/// recipient's devices' inboxes, then completed, which lists it for them and posts a share's notice. A device the API
/// no longer has, or no longer lets this user reach, takes no key. What went before is taken again as it was.
Future<void> uploadPackage(E2EEngine engine, PackageUpload upload, {void Function()? onTaken}) async {
  final E2EEngine(:api, :host) = engine;
  final PackageUpload(:conversationId, :shareId, :made) = upload;
  final parts = made['parts']! as int;
  if (!upload.taken) {
    upload.step = 'put';
    await api.putShare(
      conversationId,
      shareId,
      duvet.HistoryShareUpload(
        toUserId: upload.user,
        kind: upload.kind,
        range: upload.range,
        startsAt: DateTime.fromMillisecondsSinceEpoch(made['start']! as int, isUtc: true),
        size: made['size']! as int,
        parts: parts,
      ),
    );
    upload.taken = true;
    onTaken?.call();
  }
  upload.step = 'part';
  for (; upload.partsUp < parts; upload.partsUp++) {
    await api.putSharePart(conversationId, shareId, upload.partsUp, await host.sharePart(shareId, upload.partsUp));
  }
  upload.step = 'key';
  for (final key in (made['keys']! as List).cast<Map<String, Object?>>()) {
    final device = key['device_id']! as String;
    if (upload.keysSent.contains(device)) continue;
    try {
      await api.sendToDevice(device, key['message']! as String);
    } on duvet.DuvetApiException catch (error) {
      if (error.statusCode != 403 && error.statusCode != 404) rethrow;
    }
    upload.keysSent.add(device);
  }
  if (!upload.completed) {
    upload.step = 'complete';
    await api.completeShare(conversationId, shareId);
    upload.completed = true;
  }
}

/// A package's key as the record keeps it ([historyKeys]): its kind (share or catch_up), conversation and sharer, as
/// the core read them; when it came; how many imports of it began and never ended, and how many failed; and what only
/// its acknowledgement is owed for, once it came in (`imported`), the person dismissed it, or it can't come in here
/// (`refused`).
typedef _Key = ({String kind, String conversationId, String userId, int at, int starts, int failures, String? owed});

/// What a package may be owed for: its acknowledgement alone is left.
const _owed = ['imported', 'dismissed', 'refused'];

/// What the record holds: the keys by package, and the packages done with, by ID, with when.
typedef _Kept = ({Map<String, _Key> keys, Map<String, int> done});

/// The person's share on its way: its upload, the answer they wait for (once the API took it), and its next try's wait.
class _Sharing {
  _Sharing(this.upload);
  final PackageUpload upload;
  final answer = Completer<SharedHistory>();
  void Function()? cancel;
}

/// The person's shares and the packages this device receives, between the engine's turns.
class Histories {
  Histories(this._engine, this._act, this._soon, this._sync, this._left, this._imported, this._ended);

  final E2EEngine _engine;

  /// Runs work in the engine's turn while this device is ready: it throws otherwise.
  final Future<void> Function(Future<void> Function() work) _act;

  /// Runs work in the engine's turn, while the device is ready, its failure logged.
  final void Function(Future<void> Function() work) _soon;

  /// The conversation's queue applied, in the turn: its welcome brings this device into its group.
  final Future<void> Function(String conversationId) _sync;

  /// Whether the user is no longer in the conversation, as the API lists it now (false when that can't be read), in
  /// the turn.
  final Future<bool> Function(String conversationId) _left;

  /// An import filled a conversation's messages on this device.
  final void Function(String conversationId) _imported;

  /// The person's share, which they were told went, ended for good: they're told.
  final void Function(String conversationId, String shareId) _ended;

  // ---------------------------------------------------------------------------------------------------------------
  // Sharing.

  final _sharing = <_Sharing>{};

  /// The person's share of the conversation's history from [range]'s start with [user]: made in the engine's turn, then
  /// up outside it. What it gives comes once the API took the package, or says why it didn't ([ShareLimit] for the
  /// hour's ten); the rest goes by itself after it.
  Future<SharedHistory> share(String conversationId, String user, String range) async {
    Map<String, Object?>? made;
    await _act(() async => made = await makeShare(_engine, conversationId, user, range));
    final sharing = _Sharing(PackageUpload(conversationId, user, made!, kind: 'share', range: range));
    _sharing.add(sharing);
    unawaited(_send(sharing));
    return sharing.answer.future;
  }

  Future<void> _send(_Sharing sharing) async {
    final upload = sharing.upload;
    try {
      await uploadPackage(
        _engine,
        upload,
        onTaken: () => sharing.answer.complete((
          truncated: upload.made['truncated'] == true,
          start: DateTime.fromMillisecondsSinceEpoch(upload.made['start']! as int, isUtc: true),
        )),
      );
    } catch (error) {
      return _shareFailed(sharing, error);
    }
    _shareDone(sharing);
  }

  /// A try that failed. Before the API took the package, the person hears why, and it goes: Share again makes another.
  /// Once taken, one a later try may get past waits and goes on; one that can never go ends, and the person, told it
  /// went, is told it didn't.
  void _shareFailed(_Sharing sharing, Object error) {
    if (!_sharing.contains(sharing)) return;
    final upload = sharing.upload;
    if (!upload.taken) {
      _shareDone(sharing);
      final limited = error is duvet.DuvetApiException && error.statusCode == 429;
      return sharing.answer.completeError(limited ? ShareLimit(packageWait(error, 0)) : error);
    }
    if (upload.endsWith(error)) {
      debugPrint("e2e: a share of a conversation's history stopped: ${_why(error)}");
      _shareDone(sharing);
      return _ended(upload.conversationId, upload.shareId);
    }
    debugPrint("e2e: a share of a conversation's history waits for its next try: ${_why(error)}");
    sharing.cancel = _engine.clock.later(packageWait(error, upload.tries++), () {
      sharing.cancel = null;
      if (_sharing.contains(sharing)) unawaited(_send(sharing));
    });
  }

  /// It's over: its parts go from the core's engine.
  void _shareDone(_Sharing sharing) {
    sharing.cancel?.call();
    _sharing.remove(sharing);
    unawaited(_engine.host.dropShare(sharing.upload.shareId).catchError((Object _) {}));
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Receiving.

  /// The packages for this device as the API listed them or the gateway told of them since, by ID.
  final _packages = <String, duvet.HistoryShare>{};

  /// When each package came, in the order things came ([_mark]): one that came since a list was asked for stays,
  /// whatever that list says.
  final _seen = <String, int>{};
  var _mark = 0;

  /// The API's last list was a whole page: what's past it isn't listed until acknowledgements make room for it.
  var _full = false;

  /// A list asked for that hasn't run yet: an inbox round's keys ask for one.
  var _listing = false;

  /// What the record keeps, read once: a record that can't be written still holds it for this run.
  _Kept? _kept;

  final _offers = ValueNotifier<Map<String, List<HistoryOffer>>>(const {});

  /// The shares this device holds the keys of, waiting for the person's yes, by conversation, the newest three first.
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

  var _stopped = false;

  Map<String, _Key> get _keys => (_kept ??= _read()).keys;

  /// The packages done with (imported and acknowledged, dismissed, or let go), by ID, with when: a key of one that
  /// comes again is a replay, which goes as it comes.
  Map<String, int> get _done => (_kept ??= _read()).done;

  _Kept _read() {
    final keys = <String, _Key>{};
    final done = <String, int>{};
    if (_engine.store.read(historyKeys) case final List<Object?> kept) {
      for (final one in kept) {
        switch (one) {
          case {'share_id': final String id, 'done': final int at}:
            done[id] = at;
          case {
            'share_id': final String id,
            'kind': final String kind,
            'conversation_id': final String conversation,
            'user_id': final String user,
            'at': final int at,
          }:
            keys[id] = (
              kind: kind,
              conversationId: conversation,
              userId: user,
              at: at,
              starts: switch (one['starts']) {
                final int starts => starts,
                _ => 0,
              },
              failures: switch (one['failures']) {
                final int failures => failures,
                _ => 0,
              },
              owed: _owed.contains(one['owed']) ? one['owed']! as String : null,
            );
        }
      }
    }
    return (keys: keys, done: done);
  }

  /// The record written as it is now: no key, only what tells a package opens here, and the IDs of those done with.
  Future<void> _write() => _engine.store.write(historyKeys, [
    for (final MapEntry(key: id, value: key) in _keys.entries)
      {
        'share_id': id,
        'kind': key.kind,
        'conversation_id': key.conversationId,
        'user_id': key.userId,
        'at': key.at,
        if (key.starts > 0) 'starts': key.starts,
        if (key.failures > 0) 'failures': key.failures,
        'owed': ?key.owed,
      },
    for (final MapEntry(key: id, value: at) in _done.entries) {'share_id': id, 'done': at},
  ]);

  /// What the record keeps past its 30 days goes, and past [_keptMost] of each, the oldest: never because a list left a
  /// package out. Whether any went.
  bool _pruned() {
    final old = time.clock.now().subtract(_keyLife).millisecondsSinceEpoch;
    final had = _keys.length + _done.length;
    _keys.removeWhere((_, key) => key.at < old);
    _done.removeWhere((_, at) => at < old);
    _keepNewest(_keys, (key) => key.at);
    _keepNewest(_done, (at) => at);
    return _keys.length + _done.length != had;
  }

  static void _keepNewest<T>(Map<String, T> kept, int Function(T value) at) {
    if (kept.length <= _keptMost) return;
    final oldest = [...kept.entries]..sort((a, b) => at(a.value).compareTo(at(b.value)));
    for (final entry in oldest.take(kept.length - _keptMost)) {
      kept.remove(entry.key);
    }
  }

  /// receive_direct took a package's key (inbox.dart; its answer, `{type, share_id, conversation_id, user_id}`): kept
  /// in the record, stamped as it came, before its message leaves the inbox, so a write that fails leaves it there for
  /// the next round. One of a package done with goes. Its package is offered or imported once it's known, which one
  /// list after the round asks the API for.
  Future<void> keyTaken(Map<String, Object?> received) async {
    final kind = switch (received['type']) {
      'history.key' => 'share',
      'catch_up.key' => 'catch_up',
      _ => null,
    };
    if (kind == null) return;
    final id = received['share_id']! as String;
    if (_done.containsKey(id)) return;
    final had = _keys[id];
    _keys[id] = (
      kind: kind,
      conversationId: received['conversation_id']! as String,
      userId: received['user_id']! as String,
      at: had?.at ?? time.clock.now().millisecondsSinceEpoch,
      starts: had?.starts ?? 0,
      failures: had?.failures ?? 0,
      owed: had?.owed,
    );
    _pruned();
    await _write();
    if (!_packages.containsKey(id)) _askList();
    _shown();
  }

  /// One list, once the engine's turn is free: what asks for one meanwhile is taken in by it.
  void _askList() {
    if (_listing || _stopped) return;
    _listing = true;
    _soon(list);
  }

  /// HISTORY_SHARE_CREATE: a package completed for this user.
  void heard(duvet.HistoryShare share) {
    if (_done.containsKey(share.id)) return;
    _packages[share.id] = share;
    _seen[share.id] = ++_mark;
    _shown();
  }

  /// The packages for this device as the API lists them now. A package known before the list was asked for and missing
  /// from it goes (acknowledged elsewhere, or gone with its 30 days), but only from a list shorter than the API's page,
  /// which leaves out what's past it. Keys stay until their 30 days, as a key may come before its package.
  Future<void> list() async {
    _listing = false;
    final mark = _mark;
    final shares = await _engine.api.shares();
    _full = shares.length >= _listMost;
    final listed = {
      for (final share in shares)
        if (!_done.containsKey(share.id)) share.id: share,
    };
    _packages
      ..removeWhere((id, _) => !_full && !listed.containsKey(id) && (_seen[id] ?? 0) <= mark)
      ..addAll(listed);
    _seen.removeWhere((id, _) => !_packages.containsKey(id));
    if (_pruned()) await _write().catchError((Object error) => debugPrint('e2e: the history keys: $error'));
    _shown();
  }

  /// The person's yes to an offer: its package imported now, after an import on its way. A failure throws: one that
  /// can't ever be imported lets the offer go, and anything else leaves it for another yes.
  Future<void> take(String shareId) {
    final key = _keys[shareId];
    final share = key == null ? null : _agreed(shareId, key);
    if (share == null || key == null || !_offered(key)) throw StateError('no such offer');
    return _take(share, person: true);
  }

  /// The person's Dismiss of an offer: it shows no more, and the API is told this device is done with it, which an
  /// offer left would hold a place of the API's page for its 30 days.
  Future<void> dismiss(String shareId) async {
    final key = _keys[shareId];
    if (key == null || !_offered(key)) return;
    _keys[shareId] = _with(key, owed: 'dismissed');
    _shown();
    await _write().catchError((Object error) => debugPrint('e2e: the history keys: $error'));
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

  /// Nothing more goes: what waits is called off, and the person still waiting for a share hears it didn't go.
  void stop() {
    _stopped = true;
    _quiet?.call();
    _quiet = null;
    for (final cancel in _waiting.values) {
      cancel();
    }
    _waiting.clear();
    for (final sharing in [..._sharing]) {
      _shareDone(sharing);
      if (!sharing.answer.isCompleted) sharing.answer.completeError(StateError("encrypted conversations stopped"));
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
    _full = false;
    _listing = false;
    _kept = (keys: {}, done: {});
    for (final sharing in [..._sharing]) {
      _shareDone(sharing);
      if (!sharing.answer.isCompleted) sharing.answer.completeError(StateError('this device started over'));
    }
    _offers.value = const {};
  }

  /// The package [id] as the API lists it, when its key is here and says what the listing says (its conversation,
  /// sharer and kind, as the sender's device signed them), and it's within the API's caps (1 to [maxShareParts] parts,
  /// [_packageMost] bytes): any other is nothing this device takes in, downloads or acknowledges.
  duvet.HistoryShare? _agreed(String id, _Key key) => switch (_packages[id]) {
    final share?
        when share.conversationId == key.conversationId &&
            share.fromUserId == key.userId &&
            share.kind == key.kind &&
            share.parts >= 1 &&
            share.parts <= maxShareParts &&
            share.size <= _packageMost =>
      share,
    _ => null,
  };

  /// Whether a key's package is offered to the person: a share, or a catch-up whose imports kept not bringing it in,
  /// until it's added or dismissed.
  static bool _offered(_Key key) =>
      key.owed == null && (key.kind == 'share' || key.starts + key.failures >= _mostStarts);

  /// The offers as the packages and keys known now make them, and what's due next arranged.
  void _shown() {
    final offers = <String, List<HistoryOffer>>{};
    for (final MapEntry(key: id, value: key) in _keys.entries) {
      final share = _agreed(id, key);
      if (share == null || !_offered(key)) continue;
      (offers[key.conversationId] ??= []).add(
        HistoryOffer(shareId: id, conversationId: key.conversationId, fromUserId: key.userId, range: share.range ?? ''),
      );
    }
    for (final conversation in [...offers.keys]) {
      final list = offers[conversation]!..sort((a, b) => b.shareId.compareTo(a.shareId));
      if (list.length > _offersShown) offers[conversation] = list.sublist(0, _offersShown);
    }
    if (!mapEquals(_offersFlat(offers), _offersFlat(_offers.value))) _offers.value = offers;
    _arrange();
  }

  static Map<String, HistoryOffer> _offersFlat(Map<String, List<HistoryOffer>> offers) => {
    for (final list in offers.values)
      for (final offer in list) offer.shareId: offer,
  };

  /// Once the engine is quiet: the next catch-up to import, or an acknowledgement still to go. One at a time.
  void _arrange() {
    if (_stopped || _inFlight || _quiet != null || !_idle || _next() == null) return;
    _quiet = _engine.clock.later(quietBeforeImport, () {
      _quiet = null;
      if (_next() case final next? when !_stopped && !_inFlight) {
        unawaited(_take(next, person: false).catchError((Object _) {}));
      }
    });
  }

  /// The package due next by itself, oldest first: one whose acknowledgement alone is owed and didn't go, or a catch-up
  /// whose imports haven't kept not bringing it in. None that waits after a failure, and no offer, which waits for the
  /// person.
  duvet.HistoryShare? _next() {
    final due = [
      for (final MapEntry(key: id, value: key) in _keys.entries)
        if (_agreed(id, key) case final share?
            when !_waiting.containsKey(id) &&
                (key.owed != null || (key.kind == 'catch_up' && key.starts + key.failures < _mostStarts)))
          share,
    ]..sort((a, b) => a.id.compareTo(b.id));
    return due.firstOrNull;
  }

  Future<void> _take(duvet.HistoryShare share, {required bool person}) {
    final run = _importing.then((_) => _import(share, person: person));
    _importing = run.catchError((Object _) {});
    return run;
  }

  /// One package taken in: imported, or refused for good here, after which what's owed of it is the API's
  /// acknowledgement alone, tried until it lands ([_acknowledge]). A failure that may pass waits ([_later]), and the
  /// person who asked for the import hears of it; a package of a conversation the user left goes, unacknowledged.
  Future<void> _import(duvet.HistoryShare share, {required bool person}) async {
    final id = share.id;
    final kept = _keys[id];
    if (_stopped || kept == null || !_packages.containsKey(id)) return;
    _inFlight = true;
    try {
      Object? refused;
      if (kept.owed == null) {
        try {
          await _bringIn(share, kept);
        } catch (error) {
          if (!_forGood(error)) {
            if (await _userLeft(kept.conversationId)) {
              // Its conversation is no longer the user's: it goes unacknowledged, as their other devices may still
              // want it.
              debugPrint('e2e: a shared history of a conversation the user left goes');
              await _forget(id);
            } else {
              debugPrint("e2e: a shared history wasn't imported, and goes again: ${_why(error)}");
              _later(id, error);
              // A catch-up whose tries ran out is offered from now on.
              _shown();
            }
            if (person) rethrow;
            return;
          }
          debugPrint("e2e: a shared history can't be imported here, and goes: ${_why(error)}");
          refused = error;
        }
        final now = _keys[id];
        if (_stopped || now == null) return;
        _keys[id] = _with(now, starts: kept.starts, owed: refused == null ? 'imported' : 'refused');
        await _write().catchError((Object error) => debugPrint('e2e: the history keys: $error'));
        if (refused == null) _imported(kept.conversationId);
        _shown();
      }
      await _acknowledge(id);
      if (person && refused != null) throw refused;
    } finally {
      _inFlight = false;
      _arrange();
    }
  }

  /// Its parts down, outside the engine's turn, then history_import in it, counted as begun in the record right
  /// before: an import that never ends (the app killed meanwhile) stays counted. One that ended is no longer, and one
  /// that failed counts as a failure beside them (M1 of the review; the twins' cap on tries). A key the core no longer
  /// has was used by an import whose end wasn't recorded: it came in.
  Future<void> _bringIn(duvet.HistoryShare share, _Key kept) async {
    final id = share.id;
    var begun = false;
    try {
      // Nothing downloads for an import this device can't make now.
      if (_engine.state.value.stage != EngineStage.ready) throw StateError("encrypted conversations aren't ready");
      final parts = [for (var n = 0; n < share.parts; n++) await _part(id, n)];
      await _act(() async {
        await _sync(kept.conversationId).catchError(
          (Object error) => debugPrint("e2e: a conversation's queue waits while a history comes in: $error"),
        );
        final now = _keys[id];
        if (now == null) return;
        _keys[id] = _with(now, starts: now.starts + 1);
        await _write();
        begun = true;
        await _engine.host.importShare(id, parts);
      });
    } catch (error) {
      if (error is CoreError && error.code == 'not_found' && error.what == 'share') return;
      if (_keys[id] case final now? when now.starts != kept.starts) {
        _keys[id] = _with(now, starts: kept.starts, failures: now.failures + (begun ? 1 : 0));
        await _write().catchError((Object error) => debugPrint('e2e: the history keys: $error'));
      }
      rethrow;
    }
  }

  /// The API told this device is done with the package, then done with here. One a later try may get past goes again
  /// after its wait; one the API refuses otherwise (a 404 for a package it no longer has among them) is done with all
  /// the same.
  Future<void> _acknowledge(String id) async {
    try {
      await _engine.api.ackShare(id);
    } catch (error) {
      if (_passes(error)) {
        debugPrint("e2e: a shared history's acknowledgement goes again: ${_why(error)}");
        _later(id, error);
        return;
      }
      debugPrint("e2e: a shared history's acknowledgement was refused: ${_why(error)}");
    }
    await _forget(id);
    // The API's page was whole: the next ones come in as this one's place frees.
    if (_full) _askList();
  }

  /// Whether a later try may get past [error]: no answer, a session's renewal, a slow answer, a limit or the server.
  static bool _passes(Object error) => switch (error) {
    duvet.DuvetApiException(:final statusCode) => const {401, 408, 429}.contains(statusCode) || statusCode >= 500,
    _ => true,
  };

  /// Part [n] of package [id], cut off once it passes what a part holds.
  Future<Uint8List> _part(String id, int n) async {
    final cut = Completer<void>();
    void heard(int received, int total) {
      if ((received > _partMost || total > _partMost) && !cut.isCompleted) cut.complete();
    }

    try {
      final part = await _engine.api.sharePart(id, n, onProgress: heard, abortTrigger: cut.future);
      if (part.length > _partMost) throw const _PartTooLong();
      return part;
    } catch (_) {
      if (cut.isCompleted) throw const _PartTooLong();
      rethrow;
    }
  }

  Future<bool> _userLeft(String conversationId) async {
    var left = false;
    try {
      await _act(() async => left = await _left(conversationId));
    } catch (error) {
      debugPrint("e2e: whether a shared history's conversation is still the user's wasn't read: ${_why(error)}");
    }
    return left;
  }

  static _Key _with(_Key key, {int? starts, int? failures, String? owed}) => (
    kind: key.kind,
    conversationId: key.conversationId,
    userId: key.userId,
    at: key.at,
    starts: starts ?? key.starts,
    failures: failures ?? key.failures,
    owed: owed ?? key.owed,
  );

  /// What can never import: a package that doesn't open, isn't what its key says, is past what a package or a part
  /// holds; one the API no longer has. A gate that refuses the import itself (not the app's engine: core_gate.dart)
  /// isn't one of them, so nothing is acknowledged there.
  static bool _forGood(Object error) => switch (error) {
    CoreError(code: 'bad_command', field: 'cmd') => false,
    CoreError(:final code) => const {
      'too_large',
      'decrypt_failed',
      'invalid_signature',
      'rule_violation',
      'bad_command',
    }.contains(code),
    _PartTooLong() => true,
    duvet.DuvetApiException(:final statusCode) => statusCode == 403 || statusCode == 404,
    _ => false,
  };

  /// An error as a log line says it: its code or status, never what a package holds.
  static String _why(Object error) => switch (error) {
    CoreError(:final code, :final rule) => '$code${rule == null ? '' : ' $rule'}',
    duvet.DuvetApiException(:final statusCode) => '$statusCode',
    _ => '${error.runtimeType}',
  };

  /// Done with: its key and package go, and its ID is kept for 30 days, so a key of it that comes again goes.
  Future<void> _forget(String id) async {
    _keys.remove(id);
    _packages.remove(id);
    _seen.remove(id);
    _failed.remove(id);
    _waiting.remove(id)?.call();
    _done[id] = time.clock.now().millisecondsSinceEpoch;
    _pruned();
    _shown();
    await _write().catchError((Object error) => debugPrint('e2e: the history keys: $error'));
  }

  /// A failure that may pass: the package waits before it's due again ([packageWait]).
  void _later(String id, Object error) {
    if (_stopped) return;
    final tries = _failed[id] ?? 0;
    _failed[id] = tries + 1;
    _waiting[id]?.call();
    _waiting[id] = _engine.clock.later(packageWait(error, tries), () {
      _waiting.remove(id);
      _arrange();
    });
  }
}
