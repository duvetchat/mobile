/// What a device fails to open, reported to the API by kind (PLAN-E2E-API.md, K; decision 40): counted, then sent with
/// the rest of its minute, one request per kind with its count. No ID and no content goes: only the kind, the client
/// and its version (its header). The desktop's failures.ts in Dart.
library;

import 'dart:async';
import 'dart:math';

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart';

import 'engine.dart';

/// How long a failure waits for the others of its minute.
const _window = Duration(minutes: 1);

/// How long reports wait after the API refused one for its rate (429; the route takes 60 an hour) without saying how
/// long: an hour, the most the route's window can ask (M2 of the desktop's review). One that says waits its
/// Retry-After (step 5's engines review, Minor 8).
const _refusedWait = Duration(hours: 1);

/// The most one report counts (the route's): the rest go in the next.
const _most = 1000;

/// What a message, an edit or a deletion that didn't open says of why: each is a kind of its own.
const _unreadable = ['message', 'envelope', 'too_large'];

/// What one entry of an apply did, as its results say.
typedef EntryResult = ({int seq, String kind, String result, int? epoch, String? reason, String? rule});

/// An entry's result as apply answers it.
EntryResult entryResult(Map<Object?, Object?> result) => (
  seq: result['seq']! as int,
  kind: result['kind']! as String,
  result: result['result']! as String,
  epoch: result['epoch'] as int?,
  reason: result['reason'] as String?,
  rule: result['rule'] as String?,
);

/// The kinds of what an apply's entries failed to open: a message, an edit or a deletion that didn't open, by its
/// reason; a commit or a welcome the core couldn't process. Not an entry the API marked deleted ([deleted], by number),
/// whose bytes are gone: that isn't a failure (PLAN-E2E-API.md, its queue's entry).
List<String> failedKinds(List<EntryResult> results, Set<int> deleted) => [
  for (final (:seq, kind: _, :result, epoch: _, :reason, :rule) in results)
    if (!deleted.contains(seq))
      if (result == 'undecryptable' && _unreadable.contains(reason))
        reason!
      else if (result == 'rejected' && rule == 'invalid_commit')
        'commit'
      else if (result == 'rejected' && rule == 'invalid_welcome')
        'welcome',
];

/// The failures waiting for their report, by kind.
class Failures {
  Failures(this._api, this._clock);
  final duvet.E2eApi _api;
  final EngineClock _clock;
  final _counts = <String, int>{};
  void Function()? _timer;

  /// Stopped with its engine: a report in flight then leaves no timer (M5 of the review).
  var _stopped = false;

  /// One more of a kind, reported with the others of its minute.
  void note(String kind) {
    _counts[kind] = (_counts[kind] ?? 0) + 1;
    _wait(_window);
  }

  /// Stops waiting: what wasn't reported goes uncounted.
  void stop() {
    _stopped = true;
    _timer?.call();
    _timer = null;
  }

  void _wait(Duration wait) {
    if (!_stopped) _timer ??= _clock.later(wait, _round);
  }

  void _round() {
    _timer = null;
    unawaited(_report());
  }

  /// Each kind's count in one request; what the API didn't take waits for the next minute. A refusal for the route's
  /// rate stops the round there, the other kinds waiting with it, its Retry-After, an hour without one.
  Future<void> _report() async {
    for (final kind in [..._counts.keys]) {
      if (_stopped) return;
      final count = _counts.remove(kind)!;
      final sent = min(count, _most);
      if (count > sent) _counts[kind] = count - sent;
      try {
        await _api.reportDecryptFailure(kind, count: sent);
      } catch (error) {
        _counts[kind] = (_counts[kind] ?? 0) + sent;
        if (error is duvet.DuvetApiException && error.statusCode == 429) {
          final wait = error.retryAfter ?? _refusedWait;
          debugPrint('e2e: failures to decrypt wait ${wait.inSeconds} s: the API takes no more now.');
          // In place of a minute's wait a failure noted meanwhile started.
          _timer?.call();
          _timer = null;
          return _wait(wait);
        }
        debugPrint("e2e: failures to decrypt weren't reported ($kind): $error");
      }
    }
    if (_counts.isNotEmpty) _wait(_window);
  }
}
