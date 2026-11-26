/// The encrypted backup (PLAN-E2E-CLIENTES.md, Task 33, its Task 32 in Dart; decisions 20, 21 and 44 to 46): each
/// conversation's days as the core seals them, a segment a day, kept in the user's own storage. Only the app's engine
/// backs up, the one with a screen, with the app open (Ruling 23): a push's engine and WorkManager's never do, and
/// their gates refuse the backup's commands (core_gate.dart). Its core's calls go in the engine's turn, its requests
/// outside it. A pass runs once the engine has had no work for a minute, and at the latest 30 minutes after the last
/// one ended, or as a UTC day ends. It takes the inbox first, whose change of keys brings the key the work seals with,
/// then goes in this order:
/// - a restore, on a device set up as a new one (recovered or approved): every segment, the newest conversation first
///   and each day of it newest first, taken in with what the API saw deleted; one that doesn't open is skipped, and
///   what a passing outage stops is tried again a day later, while the rest comes in;
/// - each day backup_due lists: built without what the API saw deleted, put in the place of the copy this device knows
///   of it, and confirmed with the version its build answered. Another copy there (409) is another device's: taken in
///   first, then the day built again over it, never overwritten unseen;
/// - what isn't under the current key (a change of keys', or any a new installation finds): each such segment sealed
///   anew under the current key, in the place of the copy it was, the record keeping how far the move went.
/// A full storage (413) pauses it for a day. A day too large to keep is set aside, and so is a day, or a restore's day
/// or conversation, that failed three passes in a row: each is tried again a day later, while the rest goes on. A
/// move's segment that failed three passes in a row is passed over. Any other failure waits a minute, then twice as
/// long each time, up to an hour. What waits is never confirmed, so it stays due. The desktop's backup.ts in Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'engine.dart' show EngineClock;
import 'failures.dart';
import 'host.dart';
import 'store.dart';

const _minute = Duration(minutes: 1);
const _hour = Duration(hours: 1);
const _day = Duration(days: 1);

/// The longest the backup waits for the app to be quiet: a pass at the latest this long after the last one ended.
const _ceiling = Duration(minutes: 30);

/// The most a page of the segments or of the deleted messages has (the API's most).
const _page = 1000;

/// The most pages a listing takes: a million segments, or deleted messages, is no real backup's.
const _maxPages = 1000;

/// How many times one pass builds a day again over another device's copy: past it, the day waits for the next pass.
const _rounds = 3;

/// How many passes in a row may fail on one day or segment before it's set aside.
const _maxFails = 3;

/// A day of no conversation: its build answers the key the core seals with, and writes nothing ([Backups._sealsWith]).
const _noConversation = '00000000-0000-0000-0000-000000000000';
const _firstDay = '2026-01-01';

/// The most bytes a segment has: the API's request body (32 MiB), past which it takes none, and so keeps none. A day
/// past it never goes up, and a download past it is cut off.
const maxSegmentBytes = 32 << 20;

/// Where the backup is, as the views show it.
enum BackupStage { uploading, upToDate, restoring, paused }

/// Why the backup is paused: the user's storage is full, or a day's segment is too large to keep.
enum BackupPause { full, tooLarge }

/// What the views show of the backup (Settings → Devices, and a new device's restore): a restore's progress; a pause
/// and why, a day too large to keep among them while it's set aside; up to date once a pass found nothing due, and
/// nothing failed since; else days going up.
@immutable
class BackupShown {
  const BackupShown._(this.stage, {this.done = 0, this.total = 0, this.pause});

  /// A restore, [done] of its [total] segments.
  const BackupShown.restoring(int done, int total) : this._(BackupStage.restoring, done: done, total: total);

  const BackupShown.paused(BackupPause pause) : this._(BackupStage.paused, pause: pause);

  /// Days going up, or waiting to: before a first pass, after a failure, while a day waits for its key or a change of
  /// keys for its upload.
  static const uploading = BackupShown._(BackupStage.uploading);
  static const upToDate = BackupShown._(BackupStage.upToDate);

  final BackupStage stage;
  final int done;
  final int total;
  final BackupPause? pause;

  @override
  bool operator ==(Object other) =>
      other is BackupShown &&
      other.stage == stage &&
      other.done == done &&
      other.total == total &&
      other.pause == pause;

  @override
  int get hashCode => Object.hash(stage, done, total, pause);

  @override
  String toString() => switch (stage) {
    BackupStage.restoring => 'BackupShown(restoring, $done of $total)',
    BackupStage.paused => 'BackupShown(paused, ${pause?.name})',
    _ => 'BackupShown(${stage.name})',
  };
}

/// A pass: all of it, or a restore alone, as a new device's starts as soon as it's ready.
enum _Run { all, restore }

/// What the backup counts failures of, by item: a day it backs up (`day:<conversation>/<day>`), a restore's day or
/// conversation (`restore:<conversation>/<day>`, `restore:<conversation>` for its deleted messages), or a move's
/// segment (`move:<segment ID>`). How many passes in a row failed on it, since when it's set aside, and whether it's a
/// day too large.
typedef _Aside = ({int fails, int? at, bool tooLarge});

/// A segment that came down past [maxSegmentBytes]: no copy the API keeps is that large, so nothing of it is read.
class _PastTheCap implements Exception {
  const _PastTheCap();

  @override
  String toString() => 'a segment past $maxSegmentBytes bytes';
}

/// A day whose segment is past [maxSegmentBytes]: the API takes no such body, so it never goes.
class _DayTooLarge implements Exception {
  const _DayTooLarge();

  @override
  String toString() => 'a day past $maxSegmentBytes bytes';
}

/// What the API's answer [error] says of [field] (its `error`, by default): null for anything else.
Object? _said(Object error, [String field = 'error']) {
  if (error is! duvet.DuvetApiException) return null;
  try {
    final body = jsonDecode(error.body ?? '');
    return body is Map ? body[field] : null;
  } on FormatException {
    return null;
  }
}

int? _statusOf(Object error) => error is duvet.DuvetApiException ? error.statusCode : null;

/// The segment that holds a day the API kept another one out of (409, `current`): null for any other answer, one whose
/// bucket moved or went under the upload among them, which passes.
String? _holding(Object error) => switch (_statusOf(error) == 409 ? _said(error, 'current') : null) {
  final String current => current,
  _ => null,
};

/// The user's storage is full (the API's 413 «not enough storage space»): what pauses the backup for a day.
bool _storageFull(Object error) =>
    _statusOf(error) == 413 && RegExp('not enough storage space', caseSensitive: false).hasMatch('${_said(error)}');

/// A day too large to keep: a segment past the request's 32 MiB (which never goes, or the API's «over 32 MiB»), past
/// the user's or their bucket's limit for one file («file is too large»), or past the core's own (`too_large`). Any 413
/// but a full storage's is taken for one, so no answer the API rewords stops the other days.
bool _tooLarge(Object error) =>
    error is _DayTooLarge ||
    (error is CoreError && error.code == 'too_large') ||
    (_statusOf(error) == 413 && !_storageFull(error));

/// The API refused a segment's key: one a change of keys this device hasn't taken retired, or none of the user's.
bool _refusedKey(Object error) =>
    _statusOf(error) == 400 && RegExp(r'^(retired|unknown) backup key$').hasMatch('${_said(error)}');

/// A request that got no answer at all: the network's, which counts against no day or segment.
bool _noAnswer(Object error) => error is http.ClientException || error is TimeoutException;

/// An error as a log line says it: its code or status, never what a segment holds.
String _why(Object error) => switch (error) {
  CoreError(:final code) => code,
  duvet.DuvetApiException(:final statusCode) => '$statusCode',
  _PastTheCap() || _DayTooLarge() => '$error',
  _ => '${error.runtimeType}',
};

/// Newest first, by day and then by ID.
int _newestFirst(duvet.BackupSegment a, duvet.BackupSegment b) =>
    a.day == b.day ? b.id.compareTo(a.id) : b.day.compareTo(a.day);

/// A restore's progress as the views show it: the whole percent reached, so its 1000 segments are told 100 times.
int _step(({int done, int total})? progress) => progress == null ? -1 : (100 * progress.done) ~/ max(progress.total, 1);

class Backups {
  Backups({
    required CoreHost host,
    required duvet.E2eApi api,
    required EngineStore store,
    required EngineClock clock,
    required Failures failures,
    required Future<void> Function(Future<void> Function() work) turn,
    required Future<void> Function() inbox,
    required void Function(String conversationId) changed,
    required void Function(duvet.DuvetUpdateRequiredException error) update,
  }) : _host = host,
       _api = api,
       _store = store,
       _clock = clock,
       _failures = failures,
       _turn = turn,
       _inbox = inbox,
       _changed = changed,
       _update = update;

  final CoreHost _host;
  final duvet.E2eApi _api;
  final EngineStore _store;
  final EngineClock _clock;
  final Failures _failures;

  /// Work with the core in the engine's turn while this device backs up (ready, with no change of keys waiting for its
  /// upload, which the API takes no segment under): refused (`not_ready`) when it doesn't, or once the engine stopped.
  final Future<void> Function(Future<void> Function() work) _turn;

  /// The inbox, in the engine's turn: a change of keys' transfer brings the key a newer segment is under.
  final Future<void> Function() _inbox;

  /// An import brought rows of the conversation: the views read them again.
  final void Function(String conversationId) _changed;

  /// A request outside the turn was answered 426: the device waits for its update.
  final void Function(duvet.DuvetUpdateRequiredException error) _update;

  final _shown = ValueNotifier(BackupShown.uploading);

  /// What the views show: a restore's progress, a pause and why, that it's up to date, or else days going up.
  ValueListenable<BackupShown> get shown => _shown;

  /// The pass under way, and the one asked for while it runs (all of it, or its restore only).
  Future<void>? _pass;
  _Run? _again;

  /// Moved on by forget and stop: a pass from before them does nothing more.
  var _generation = 0;
  var _stopped = false;

  /// The copy this device knows of each day (conversation/day → its segment's ID): what its next upload replaces.
  final _known = <String, String>{};
  ({int done, int total})? _restoring;

  /// The last pass found nothing due, and nothing failed since.
  var _upToDate = false;

  /// The day or segment the pass works on, which a failure counts against (as the record's set-aside keys it).
  String? _item;

  /// The API answered the pass: a request that got no answer after that is the item's failure, not the network's.
  var _answered = false;

  /// Passing failures in a row, the earliest the next pass may run (in ms), and the timer that runs it.
  var _failsInARow = 0;
  var _notBefore = 0;
  void Function()? _retry;

  /// The pass at the latest ([_ceiling]), however busy the app.
  void Function()? _latest;

  int get _now => _clock.now().millisecondsSinceEpoch;

  /// This device took the user's identity as a new one (recovered or approved), its first list still to go up: it
  /// restores the backup once it's ready, from the start, as nothing of before it is here. One the record can't keep is
  /// kept for this run.
  Future<void> restoreDue() => _store
      .write(backupRestore, {'done': <String>[]})
      .catchError((Object error) => debugPrint("e2e: the backup's restore isn't in the record: ${error.runtimeType}"));

  /// The device is ready: it shows what the record holds (a pause or a day set aside outlives the app), and a restore
  /// that's due starts now, as the person waits for their messages.
  void wake() {
    _atTheLatest();
    _show();
    if (_restoreRecord() != null) _start(_Run.restore);
  }

  /// The app has been quiet a minute: a pass, unless one waits out a failure or a pause.
  void quiet() => _start(_Run.all);

  /// What the backup does now, settled: a test's wait.
  Future<void> settled() => _pass ?? Future.value();

  /// What this device knew of the backup goes, as it starts over as a new device: a pass under way does nothing more.
  void forget() {
    _generation++;
    _pass = null;
    _again = null;
    _retry?.call();
    _retry = null;
    _latest?.call();
    _latest = null;
    _known.clear();
    _restoring = null;
    _upToDate = false;
    _item = null;
    _failsInARow = 0;
    _notBefore = 0;
    _shown.value = BackupShown.uploading;
  }

  /// Nothing more, for good: the engine stopped.
  void stop() {
    forget();
    _stopped = true;
  }

  /// A pass, after the one under way when there's one: one at a time.
  void _start(_Run what) {
    if (_stopped) return;
    if (_pass != null) {
      _again = _again == _Run.all || what == _Run.all ? _Run.all : _Run.restore;
      return;
    }
    final generation = _generation;
    final run = _passes(generation, what);
    _pass = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_pass, run)) _pass = null;
        if (_live(generation)) _atTheLatest();
      }),
    );
  }

  Future<void> _passes(int generation, _Run first) async {
    try {
      for (_Run? next = first; next != null && _live(generation);) {
        await _once(generation, restoreOnly: next == _Run.restore);
        next = _again;
        _again = null;
      }
    } catch (error) {
      debugPrint("e2e: the encrypted backup's pass failed: ${_why(error)}");
    }
  }

  /// The next pass at the latest [_ceiling] from now, however busy the app is, or as the UTC day ends, when that comes
  /// first: the day that ended is due then, and what a pass found up to date before it no longer is.
  void _atTheLatest() {
    if (_stopped) return;
    final dayLeft = _day.inMilliseconds - _now % _day.inMilliseconds;
    _latest?.call();
    _latest = _clock.later(Duration(milliseconds: min(_ceiling.inMilliseconds, dayLeft + 1000)), () {
      _latest = null;
      quiet();
    });
  }

  bool _live(int generation) => !_stopped && generation == _generation;

  /// Goes on only while the pass is this device's still: one from before a start over, or a stop, ends here.
  void _check(int generation) {
    if (!_live(generation)) throw CoreError('not_ready', message: 'the backup stopped');
  }

  /// The record written only while the pass is this device's still. One the disk refuses is kept for this run, as the
  /// record reads what was written.
  Future<void> _write(int generation, String key, Object? value) async {
    if (!_live(generation)) return;
    await _store
        .write(key, value)
        .catchError((Object error) => debugPrint("e2e: the backup's record ($key): ${error.runtimeType}"));
  }

  Future<void> _once(int generation, {required bool restoreOnly}) async {
    if (_now < _notBefore) return;
    _answered = false;
    try {
      // Nothing before this device backs up: its first call is the turn's, refused until it's ready.
      await _turn(() async {});
      // The core's rule: a change of keys' transfer first, which brings the key the work seals with; one that fails
      // leaves the keys as they are, which a refused key and a missing one deal with.
      await _inbox().catchError((Object error) => debugPrint('e2e: the inbox waits: ${_why(error)}'));
      await _restore(generation);
      if (restoreOnly || _waitsForDay()) return;
      final upToDate = await _upload(generation);
      await _reencrypt(generation);
      _failsInARow = 0;
      if (_pausedAt() != null) await _write(generation, backupPaused, null);
      _upToDate = upToDate;
      _show();
    } catch (error) {
      if (!_live(generation)) return;
      _restoring = null;
      _upToDate = false;
      _show();
      if (error is CoreError && error.code == 'not_ready') return;
      if (_storageFull(error)) return _pauseFor(generation);
      if (error is duvet.DuvetUpdateRequiredException) return _update(error);
      debugPrint('e2e: the encrypted backup tries again later: ${_why(error)}');
      if (_refusedKey(error)) {
        // A key this device's core still seals with that the API retired: the change of keys' transfer may wait in the
        // inbox, after which the core builds those days again under the new key.
        await _inbox().catchError((Object error) => debugPrint('e2e: the inbox waits: ${_why(error)}'));
      } else if (_item case final item? when _answered || !_noAnswer(error)) {
        // The item's own failure: the API's answer, its bytes, or a request cut after the API answered the pass. One
        // with no answer at all is the network's, and counts against nothing.
        await _failedOn(generation, item);
      }
      _later(Duration(milliseconds: min(_hour.inMilliseconds, _minute.inMilliseconds << min(_failsInARow++, 6))));
    } finally {
      _item = null;
    }
  }

  /// The pass runs again after [wait], and none before.
  void _later(Duration wait) {
    _notBefore = _now + wait.inMilliseconds;
    _retry?.call();
    _retry = _clock.later(wait, () {
      _retry = null;
      quiet();
    });
  }

  /// What the views show, as the backup is now.
  void _show() {
    final restoring = _restoring;
    _shown.value = restoring != null
        ? BackupShown.restoring(restoring.done, restoring.total)
        : _pausedAt() != null
        ? const BackupShown.paused(BackupPause.full)
        : _tooLargeAside()
        ? const BackupShown.paused(BackupPause.tooLarge)
        : _upToDate
        ? BackupShown.upToDate
        : BackupShown.uploading;
  }

  /// Since when the storage is full, as the record holds it: null when it isn't.
  int? _pausedAt() => switch (_store.read(backupPaused)) {
    {'at': final int at} => at,
    _ => null,
  };

  /// The backup pauses for a day (decision 45's full quota), and says so: what waits stays due.
  Future<void> _pauseFor(int generation) async {
    await _write(generation, backupPaused, {'at': _now});
    _show();
    _later(_day);
  }

  /// Paused less than a day ago: nothing goes up before the day is over, when the pass tries again by itself.
  bool _waitsForDay() {
    final at = _pausedAt();
    final left = at == null ? 0 : at + _day.inMilliseconds - _now;
    if (left <= 0) return false;
    // After a restart, the timer the pause set went with the app.
    if (_retry == null) _later(Duration(milliseconds: left));
    return true;
  }

  /// The days and segments set aside or failing, as the record holds them.
  Map<String, _Aside> _asideRecord() => switch (_store.read(backupSetAside)) {
    final Map<Object?, Object?> kept => {
      for (final MapEntry(:key, :value) in kept.entries)
        if ((key, value) case (final String item, final Map<Object?, Object?> entry))
          item: (
            fails: switch (entry['fails']) {
              final int fails => fails,
              _ => 0,
            },
            at: switch (entry['at']) {
              final int at => at,
              _ => null,
            },
            tooLarge: entry['too_large'] == true,
          ),
    },
    _ => {},
  };

  bool _tooLargeAside() => _asideRecord().values.any((entry) => entry.tooLarge);

  /// The record of what's set aside written, and the views told of a day too large that came or went with it.
  Future<void> _writeAside(int generation, Map<String, _Aside> entries) async {
    final kept = {
      for (final MapEntry(:key, :value) in entries.entries)
        key: {'fails': value.fails, 'at': ?value.at, if (value.tooLarge) 'too_large': true},
    };
    await _write(generation, backupSetAside, kept.isEmpty ? null : kept);
    _show();
  }

  /// Whether the pass leaves the item alone: a move's segment for the whole move, anything else for a day after it was
  /// set aside.
  bool _isAside(String item) {
    final at = _asideRecord()[item]?.at;
    if (at == null) return false;
    return item.startsWith('move:') || _now < at + _day.inMilliseconds;
  }

  /// A pass failed on the item: one more in a row, and set aside once they're [_maxFails].
  Future<void> _failedOn(int generation, String item) async {
    final entries = _asideRecord();
    final fails = (entries[item]?.fails ?? 0) + 1;
    entries[item] = (fails: fails, at: fails >= _maxFails ? _now : null, tooLarge: false);
    await _writeAside(generation, entries);
  }

  /// The item set aside now, for a day: a day too large to keep, or a restore's day under a key this device lacks.
  Future<void> _setAside(int generation, String item, {bool tooLarge = false}) async {
    final entries = _asideRecord();
    entries[item] = (fails: entries[item]?.fails ?? 0, at: _now, tooLarge: tooLarge);
    await _writeAside(generation, entries);
  }

  /// The item went through: nothing of it is kept.
  Future<void> _cleared(int generation, String item) async {
    final entries = _asideRecord();
    if (entries.remove(item) != null) await _writeAside(generation, entries);
  }

  /// What's kept under [prefix] goes, but for the items in [still] (the days still due).
  Future<void> _forgetAside(int generation, String prefix, [Set<String> still = const {}]) async {
    final entries = _asideRecord();
    final before = entries.length;
    entries.removeWhere((item, _) => item.startsWith(prefix) && !still.contains(item));
    if (entries.length != before) await _writeAside(generation, entries);
  }

  void _progress(({int done, int total})? next) {
    final changed = _step(next) != _step(_restoring);
    _restoring = next;
    if (changed) _show();
  }

  /// The record of a restore that's due: the conversations it went through, and whether only what it set aside is left
  /// (`waiting`). Null when none is due.
  ({Set<String> done, bool waiting})? _restoreRecord() => switch (_store.read(backupRestore)) {
    final Map<Object?, Object?> kept => (
      done: {
        if (kept['done'] case final List<Object?> done)
          for (final id in done)
            if (id is String) id,
      },
      waiting: kept['waiting'] == true,
    ),
    _ => null,
  };

  /// The restore that's due: the segments of the conversations it didn't go through yet, and the days it set aside
  /// whose day came, the newest conversation first (by its newest day), each of its days newest first. The record keeps
  /// the conversations gone through, so an app closed midway takes up from the next one. What a passing outage stops
  /// waits a day, while the rest comes in: a day whose segment failed [_maxFails] passes in a row, or is under a key
  /// this device doesn't hold even after its inbox, and a conversation whose deleted messages didn't come [_maxFails]
  /// passes in a row, none of whose days comes in without them. It's over once all that's left is what no core reads,
  /// or what the API no longer has.
  Future<void> _restore(int generation) async {
    final record = _restoreRecord();
    if (record == null) return;
    final done = record.done;
    Set<String> setAside() => {
      for (final item in _asideRecord().keys)
        if (item.startsWith('restore:')) item,
    };
    final waits = setAside();
    // All of it was gone through, and none of what waits is due yet: nothing to list.
    if (record.waiting && waits.isNotEmpty && waits.every(_isAside)) return;
    final listed = await _listed(generation);
    final byConversation = <String, List<duvet.BackupSegment>>{};
    for (final segment in listed) {
      (byConversation[segment.conversationId] ??= []).add(segment);
    }
    final order = [for (final days in byConversation.values) days..sort(_newestFirst)]
      ..sort((a, b) => _newestFirst(a.first, b.first));
    final plan = [
      for (final days in order)
        (
          conversation: days.first.conversationId,
          // Its deleted messages wait for their day: none of its days comes in meanwhile.
          due: _isAside('restore:${days.first.conversationId}')
              ? null
              : [
                  for (final segment in days)
                    if ((!done.contains(segment.conversationId) ||
                            waits.contains('restore:${segment.conversationId}/${segment.day}')) &&
                        !_isAside('restore:${segment.conversationId}/${segment.day}'))
                      segment,
                ],
        ),
    ];
    final total = plan.fold(0, (sum, step) => sum + (step.due?.length ?? 0));
    var restored = 0;
    _progress(total > 0 ? (done: 0, total: total) : null);
    for (final (:conversation, :due) in plan) {
      if (due == null) continue;
      if (due.isNotEmpty) {
        final whole = 'restore:$conversation';
        _item = whole;
        final deleted = await _deleted(generation, conversation);
        _item = null;
        await _cleared(generation, whole);
        for (final segment in due) {
          final item = 'restore:$conversation/${segment.day}';
          _item = item;
          final imported = await _import(generation, segment, deleted);
          _item = null;
          if (imported == null) {
            await _setAside(generation, item);
          } else {
            await _cleared(generation, item);
            if (imported > 0) _changed(conversation);
          }
          _progress((done: ++restored, total: total));
        }
      }
      if (done.add(conversation)) await _write(generation, backupRestore, {'done': done.toList()});
    }
    // What waits of a day or a conversation the API no longer lists has nothing left to restore.
    await _forgetAside(generation, 'restore:', {
      for (final segment in listed) ...[
        'restore:${segment.conversationId}',
        'restore:${segment.conversationId}/${segment.day}',
      ],
    });
    await _write(generation, backupRestore, setAside().isEmpty ? null : {'done': done.toList(), 'waiting': true});
    _progress(null);
  }

  /// A segment taken in: how many of its records changed something here; null for one under a key this device doesn't
  /// hold even after its inbox. None for one the API no longer shows, or that doesn't open here, which nobody reads
  /// (the core's rule).
  Future<int?> _import(int generation, duvet.BackupSegment segment, List<String> deleted) async {
    final data = await _download(segment.id);
    if (data == null) return 0;
    final opened = await _opened(generation, {'cmd': 'backup_import', 'data': data, 'deleted': deleted});
    if (opened.noKey) return null;
    final answer = opened.answer;
    if (answer == null) return 0;
    _known['${segment.conversationId}/${segment.day}'] = segment.id;
    return answer['imported'] as int? ?? 0;
  }

  /// A segment's bytes, in base64 as the core takes them: none for one the API no longer shows (404). One past
  /// [maxSegmentBytes] is cut off as it comes, and nothing of it is read.
  Future<String?> _download(String segmentId) async {
    final cut = Completer<void>();
    void heard(int received, int total) {
      if ((received > maxSegmentBytes || total > maxSegmentBytes) && !cut.isCompleted) cut.complete();
    }

    final Uint8List bytes;
    try {
      bytes = await _api.segment(segmentId, onProgress: heard, abortTrigger: cut.future);
    } on duvet.DuvetApiException catch (error) {
      _answered = true;
      if (error.statusCode == 404) return null;
      rethrow;
    } catch (_) {
      if (cut.isCompleted) throw const _PastTheCap();
      rethrow;
    }
    _answered = true;
    if (bytes.length > maxSegmentBytes) throw const _PastTheCap();
    return base64Encode(bytes);
  }

  /// A command that opens a segment (backup_import, backup_reencrypt), by the core's rules: its answer; none for one
  /// that doesn't open (`decrypt_failed`, counted for the API by its kind) or that no core reads (`too_large`,
  /// `bad_command` `data`); [noKey] for one under a key this device doesn't hold, after its inbox, whose change of keys
  /// may bring it, and once more.
  Future<({Map<String, Object?>? answer, bool noKey})> _opened(int generation, Map<String, Object?> command) async {
    for (var round = 1; ; round++) {
      _check(generation);
      Map<String, Object?>? answer;
      Object? refused;
      // The core's refusal comes back as the turn's answer: one the backup expects isn't the engine's failure.
      await _turn(() async {
        try {
          answer = await _host.handle<Map<String, Object?>>(command);
        } catch (error) {
          refused = error;
        }
      });
      final error = refused;
      if (error == null) return (answer: answer, noKey: false);
      if (error is! CoreError) throw error;
      if (error.code == 'not_found' && error.what == 'backup_key') {
        if (round > 1) return (answer: null, noKey: true);
        await _inbox();
        continue;
      }
      if (error.code == 'decrypt_failed') _failures.note('segment');
      final unread =
          error.code == 'decrypt_failed' ||
          error.code == 'too_large' ||
          (error.code == 'bad_command' && error.field == 'data');
      if (unread) return (answer: null, noKey: false);
      throw error;
    }
  }

  /// A page more of a listing, refused past [_maxPages]: an API whose pages never end lists no real backup.
  void _nextPage(int pages) {
    if (pages > _maxPages) throw StateError("the API's listing went past $_maxPages pages");
  }

  /// The conversation's deleted encrypted messages, by ID, as the API lists them: none of one the user left.
  Future<List<String>> _deleted(int generation, String conversationId) async {
    final ids = <String>[];
    String? after;
    for (var pages = 1; ; pages++) {
      _check(generation);
      _nextPage(pages);
      final List<String> page;
      try {
        // Asked for whole pages: a shorter one is the last by the size asked, whatever the API's default.
        page = await _api.deletedMessages(conversationId, after: after, limit: _page);
      } on duvet.DuvetApiException catch (error) {
        _answered = true;
        if (error.statusCode != 403 && error.statusCode != 404) rethrow;
        return ids;
      }
      _answered = true;
      ids.addAll(page);
      if (page.length < _page) return ids;
      after = page.last;
    }
  }

  /// Every segment of the user's backup the API shows, in its order (by ID).
  Future<List<duvet.BackupSegment>> _listed(int generation) async {
    final all = <duvet.BackupSegment>[];
    String? after;
    for (var pages = 1; ; pages++) {
      _check(generation);
      _nextPage(pages);
      final page = await _api.segments(after: after);
      _answered = true;
      all.addAll(page);
      if (page.length < _page) return all;
      after = page.last.id;
    }
  }

  /// What the core holds due to go up, in its order: by conversation, then by day.
  Future<List<({String conversationId, String day})>> _due() async {
    late Map<String, Object?> due;
    await _turn(() async => due = await _host.handle<Map<String, Object?>>({'cmd': 'backup_due'}));
    return [
      for (final day in (due['segments']! as List).cast<Map<String, Object?>>())
        (conversationId: day['conversation_id']! as String, day: day['day']! as String),
    ];
  }

  /// Each day backup_due lists goes up, in its order, with its conversation's deleted messages read once a pass; a day
  /// too large to keep is set aside, and the rest goes on. Whether nothing was due once it's done: up to date.
  Future<bool> _upload(int generation) async {
    final due = await _due();
    final items = [for (final day in due) 'day:${day.conversationId}/${day.day}'];
    // A day no longer due is done with, wherever it went.
    await _forgetAside(generation, 'day:', items.toSet());
    if (due.isEmpty) return true;
    if (_upToDate) {
      _upToDate = false;
      _show();
    }
    final deleted = <String, List<String>>{};
    for (final (i, day) in due.indexed) {
      final item = items[i];
      if (_isAside(item)) continue;
      _item = item;
      final ids = deleted[day.conversationId] ??= await _deleted(generation, day.conversationId);
      try {
        await _uploadDay(generation, day.conversationId, day.day, ids);
      } catch (error) {
        // Any other failure ends the pass, counted against this day (_once).
        if (!_tooLarge(error)) rethrow;
        debugPrint(
          "e2e: a day of the encrypted backup is too large to keep, and is tried again tomorrow: ${_why(error)}",
        );
        _item = null;
        await _setAside(generation, item, tooLarge: true);
        continue;
      }
      _item = null;
      await _cleared(generation, item);
    }
    return (await _due()).isEmpty;
  }

  /// One day up: built without what the API saw deleted, in the place of the copy this device knows of it, then
  /// confirmed with the version its build answered, after the API took it. Another copy there (409) is another
  /// device's: taken in first, and the day built again over it while it's still due; one under a key this device
  /// doesn't hold stays there, and the day waits.
  Future<void> _uploadDay(int generation, String conversation, String day, List<String> deleted) async {
    final key = '$conversation/$day';
    for (var round = 1; round <= _rounds; round++) {
      _check(generation);
      late Map<String, Object?> built;
      await _turn(
        () async => built = await _host.handle<Map<String, Object?>>({
          'cmd': 'backup_segment',
          'conversation_id': conversation,
          'day': day,
          'deleted': deleted,
        }),
      );
      final bytes = base64Decode(built['data']! as String);
      if (bytes.length > maxSegmentBytes) throw const _DayTooLarge();
      final String stored;
      try {
        stored = await _api.putSegment(conversation, day, bytes, replaces: _known[key]);
      } catch (error) {
        final current = _holding(error);
        if (current == null) rethrow;
        _answered = true;
        if (!await _takeIn(generation, conversation, current, deleted)) return;
        _known[key] = current;
        if (!await _stillDue(conversation, day)) return;
        continue;
      }
      _answered = true;
      _known[key] = stored;
      await _turn(
        () => _host.handle<Object?>({
          'cmd': 'backup_uploaded',
          'conversation_id': conversation,
          'day': day,
          'complete': built['complete'],
          'version': built['version'],
        }),
      );
      return;
    }
  }

  /// Another device's copy of a day, taken in before the day is built over it, the views told of what it brought. One
  /// that doesn't open is no one's to read, and the day's build replaces it. False for one under a key this device
  /// doesn't hold, which stays where it is.
  Future<bool> _takeIn(int generation, String conversation, String segmentId, List<String> deleted) async {
    final data = await _download(segmentId);
    // Gone meanwhile: nothing holds the day any more.
    if (data == null) return true;
    final opened = await _opened(generation, {'cmd': 'backup_import', 'data': data, 'deleted': deleted});
    if (opened.noKey) return false;
    if ((opened.answer?['imported'] as int? ?? 0) > 0) _changed(conversation);
    return true;
  }

  /// Whether the day is still due once another copy was taken in: the same as what this device holds isn't.
  Future<bool> _stillDue(String conversation, String day) async =>
      (await _due()).any((due) => due.conversationId == conversation && due.day == day);

  /// What isn't under the key this device seals with now, moved to it: due once it seals with another key than the one
  /// it last saw itself seal with, or with its first (a new installation, which may finish a move a lost device left),
  /// and until every segment the API shows was gone past. The record keeps the key and the last segment moved in one
  /// write, as two writes of the file aren't atomic, so the move picks up there; a segment that failed [_maxFails]
  /// passes in a row is passed over.
  Future<void> _reencrypt(int generation) async {
    final current = await _sealsWith();
    final record = _store.read(backupMove);
    final (seen, kept) = record is Map ? (record['key'], record['after']) : (null, null);
    // Another key recorded, or none, starts the move from the first segment: until a segment moves, the record names
    // the key before, so an app closed meanwhile starts it again.
    String after;
    if (seen != current) {
      after = '';
    } else if (kept is String) {
      after = kept;
    } else {
      return;
    }
    final deleted = <String, List<String>>{};
    for (var pages = 1; ; pages++) {
      _check(generation);
      _nextPage(pages);
      final page = await _api.segments(after: after.isEmpty ? null : after);
      _answered = true;
      for (final segment in page) {
        after = segment.id;
        final item = 'move:${segment.id}';
        if (segment.keyId == current || _isAside(item)) continue;
        _item = item;
        await _move(generation, segment, current, deleted);
        _item = null;
        await _cleared(generation, item);
        await _write(generation, backupMove, {'key': current, 'after': segment.id});
      }
      if (page.length < _page) break;
    }
    await _write(generation, backupMove, {'key': current});
    await _forgetAside(generation, 'move:');
  }

  /// The ID of the key the core seals with now: what a build of a day nothing's in answers, which writes nothing.
  Future<String> _sealsWith() async {
    late Map<String, Object?> built;
    await _turn(
      () async => built = await _host.handle<Map<String, Object?>>({
        'cmd': 'backup_segment',
        'conversation_id': _noConversation,
        'day': _firstDay,
      }),
    );
    return built['key_id']! as String;
  }

  /// A segment under an older key, sealed anew under the current one, without what the API saw deleted, in the place
  /// of the copy it was. One gone meanwhile, that doesn't open here, or whose day another copy took meanwhile (409) is
  /// left to what holds its day now; nothing is deleted but by the API's replacing it.
  Future<void> _move(
    int generation,
    duvet.BackupSegment segment,
    String current,
    Map<String, List<String>> deleted,
  ) async {
    final duvet.BackupSegment(conversationId: conversation, :day, :id) = segment;
    final ids = deleted[conversation] ??= await _deleted(generation, conversation);
    final data = await _download(id);
    if (data == null) return;
    final answer = (await _opened(generation, {'cmd': 'backup_reencrypt', 'data': data, 'deleted': ids})).answer;
    // Sealed with another key than the current one, the device's key changed under the pass: the next pass sees it.
    if (answer == null || answer['key_id'] != current) return;
    final String stored;
    try {
      stored = await _api.putSegment(conversation, day, base64Decode(answer['data']! as String), replaces: id);
    } catch (error) {
      if (_holding(error) == null) rethrow;
      return;
    }
    // The copy this device knew of the day moved: what its next upload replaces is the one it moved to.
    final key = '$conversation/$day';
    if (_known[key] == id) _known[key] = stored;
  }
}
