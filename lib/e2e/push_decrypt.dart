/// A push of a conversation's message, opened on this phone (decision 29; PLAN-E2E-CLIENTES.md, Task 21 and its
/// Android section on the engine that holds the core): the API pushes it without its text (`encrypted_message`), with
/// its queue entry while that fits FCM's 4096 bytes, and the push's engine shows what this device's core opens of it.
/// While the app's engine holds the core it's asked, on [pushPortName]: it takes the entry in its conversation's turn
/// and answers the texts, so one engine writes the database (Review Focus 2). With none answering, the push's engine
/// opens the core itself (a gate that still asks the app's engine, should one hold it by then), applies the entry or,
/// without one or past a gap, reads the queue with the stored session, reads the texts, and closes the core. Past
/// [pushTime], or failing (no session, no network, the core busy), it has no text, and its work stops: nothing opens
/// the core after its notification shows (Ruling 18).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet_client/duvet.dart' as duvet;
import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'contacts.dart';
import 'content.dart';
import 'engine.dart' show EngineStage, EngineState;
import 'failures.dart';
import 'host.dart';
import 'identity.dart';
import 'legacy.dart';
import 'store.dart';
import 'sync.dart' show entryOf, membersRefusedRules, recordRefusedGeneration;

/// The name the app's engine answers pushes under, while its device is ready.
const pushPortName = 'duvet-e2e-push';

/// How long a push has for its message's text (Ruling 18): Android gives a push's engine about 20 s.
const pushTime = Duration(seconds: 15);

/// How long the app's engine has to take a push's request: one that doesn't isn't running, though its name stayed.
const _takes = Duration(seconds: 2);

/// What a push's engine asks the app's: the texts of [lines] of the conversation (the push's message first, then its
/// chat's earlier ones), its [entry], as the core takes one, given first; the first waited for [wait] at most.
typedef PushAsk = ({String conversationId, Map<String, Object?>? entry, List<Authored> lines, Duration wait});

/// What a push's message comes to: the [texts] of its lines this device's core holds, by message ID, and whether its
/// chat is on screen in the app now, where it shows itself: a notification is decided again after its wait (rule 11 of
/// the desktop's task 20 review).
typedef PushAnswer = ({Map<String, String> texts, bool onScreen});

const PushAnswer _none = (texts: {}, onScreen: false);

String _askJson(PushAsk ask) => jsonEncode({
  'conversation_id': ask.conversationId,
  'entry': ask.entry,
  'lines': [
    for (final line in ask.lines) [line.id, line.author],
  ],
  'wait_ms': ask.wait.inMilliseconds,
});

PushAsk _askOf(String json) {
  final asked = (jsonDecode(json) as Map).cast<String, Object?>();
  return (
    conversationId: asked['conversation_id']! as String,
    entry: (asked['entry'] as Map?)?.cast<String, Object?>(),
    lines: [for (final line in asked['lines']! as List) (id: (line as List)[0] as String, author: line[1] as String)],
    wait: Duration(milliseconds: asked['wait_ms']! as int),
  );
}

/// In the app's engine: answers the pushes' engines with [answer] (null when it can't, which has the push read it
/// itself) until [stopAnsweringPushes]. A request is [reply, the ask's JSON]; its asker hears it's taken, with this
/// isolate's control port (its end ends the asker's wait), then the answer's JSON, or null.
ReceivePort answerPushes(Future<PushAnswer?> Function(PushAsk ask) answer) {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(pushPortName);
  IsolateNameServer.registerPortWithName(port.sendPort, pushPortName);
  port.listen((request) async {
    if (request case [final SendPort reply, final String asked]) {
      reply.send(['taken', Isolate.current.controlPort]);
      PushAnswer? answered;
      try {
        answered = await answer(_askOf(asked));
      } catch (error) {
        debugPrint("push: the app's engine couldn't answer: ${error.runtimeType}");
      }
      reply.send(answered == null ? null : jsonEncode({'texts': answered.texts, 'on_screen': answered.onScreen}));
    }
  });
  return port;
}

/// The app's engine answers pushes no more: only its own name goes, as another engine may answer under it since.
void stopAnsweringPushes(ReceivePort port) {
  if (IsolateNameServer.lookupPortByName(pushPortName) == port.sendPort) {
    IsolateNameServer.removePortNameMapping(pushPortName);
  }
  port.close();
}

/// The app's engine answers pushes with [answer] while its device is ready ([state]), and stops while it isn't.
void answerPushesWhileReady(ValueListenable<EngineState> state, Future<PushAnswer?> Function(PushAsk ask) answer) {
  ReceivePort? port;
  void follow() {
    final ready = state.value.stage == EngineStage.ready;
    if (ready && port == null) port = answerPushes(answer);
    if (!ready && port != null) {
      stopAnsweringPushes(port!);
      port = null;
    }
  }

  state.addListener(follow);
  follow();
}

/// Asks the app's engine, when one answers on [pushPortName], within the push's time [left]: null when none takes it
/// within [_takes] (none runs, or its isolate ended since it registered), when its isolate ends before it answers, or
/// when it can't (its device not ready). Its wait for the rest of the push's time ends as that time does, with a
/// [TimeoutException].
Future<PushAnswer?> _askApp(PushAsk ask, Duration Function() left) async {
  final app = IsolateNameServer.lookupPortByName(pushPortName);
  if (app == null) return null;
  final answers = ReceivePort();
  final replies = StreamIterator<Object?>(answers);
  Future<bool> next(Duration wait) =>
      replies.moveNext().timeout(wait.isNegative ? Duration.zero : wait, onTimeout: () => false);
  Isolate? engine;
  try {
    app.send([answers.sendPort, _askJson(ask)]);
    // A wait for the rest of the push's time ends it, never with null: the wait's timer counts whole milliseconds and
    // may end up to one before the push's clock does, which would leave the push a moment to make a core in (#341).
    final take = left();
    if (!await next(take < _takes ? take : _takes)) {
      if (take < _takes) throw TimeoutException('no app took the request');
      return null;
    }
    if (replies.current case ['taken', final SendPort control]) {
      // shortcut: an isolate that ends before this listens sends no exit message, and the push waits out its time then.
      engine = Isolate(control)..addOnExitListener(answers.sendPort, response: const ['gone']);
    }
    if (!await next(left())) throw TimeoutException("the app's engine didn't answer");
    return switch (replies.current) {
      final String answered => switch (jsonDecode(answered)) {
        {'texts': final Map<String, dynamic> texts, 'on_screen': final bool onScreen} => (
          texts: texts.cast<String, String>(),
          onScreen: onScreen,
        ),
        _ => null,
      },
      // Its end, or none.
      _ => null,
    };
  } finally {
    engine?.removeOnExitListener(answers.sendPort);
    await replies.cancel();
    answers.close();
  }
}

/// The stored session as it is: a refused one isn't renewed here, which could race the app's own renewal (as a call's
/// Decline from its notification does, call_decline.dart): its requests fail, and the push shows without its text.
class _AsStored with duvet.RestMethods {
  _AsStored(this.client, this.router, this._token, this._sessionToken, this.duvetClient);

  @override
  final http.Client client;

  @override
  final ApiRouter router;

  @override
  final String? duvetClient;

  final String _token;
  final String _sessionToken;

  @override
  Map<String, String> get authHeaders => {'Authorization': 'Bearer $_token', 'X-Session-Token': _sessionToken};
}

/// The push's [entry] (the API's queue entry, as its push carries it) as the core takes it: none for one that isn't its
/// own message's (another number, another message), or that doesn't read, which the queue has.
Map<String, Object?>? _coreEntry(Map<String, Object?>? entry, int? seq, String? messageId) {
  if (entry == null) return null;
  try {
    final read = duvet.MlsEntry.fromJson(entry);
    if (read.kind != 'message' || read.seq != seq || read.messageId != messageId) return null;
    return entryOf(read);
  } catch (_) {
    return null;
  }
}

/// The texts this device's core holds of a conversation's push's [lines] (its message first, then its chat's earlier
/// ones), by message ID, within [within]: what its notification shows. Its [entry] (as its push carries it, when it
/// fit) is applied first; without one, or past a gap, the queue is read up to its message's number [seq]. The app's
/// engine is asked first, which also says whether the chat is on screen there; else [core] is opened as [userId], a
/// gate that waits for a locked database no longer than the time left, with the stored session ([token],
/// [sessionToken]), never renewed here. None on a failure or past [within], which only the log says, never with a
/// text. Past [within] the work stops where it is: nothing more is asked, applied or read, and no core is made or kept
/// open.
Future<PushAnswer> openPushed({
  required String conversationId,
  required int? seq,
  required Map<String, Object?>? entry,
  required List<Authored> lines,
  required String? userId,
  required String token,
  required String sessionToken,
  required CoreHost Function(Duration lockedWait) core,
  required ApiRouter router,
  required String? duvetClient,
  http.Client? client,
  Future<EngineStore> Function(String userId) store = FileEngineStore.open,
  Duration within = pushTime,
}) async {
  final calls = client ?? http.Client();
  final given = _coreEntry(entry, seq, lines.firstOrNull?.id);
  final watch = Stopwatch()..start();
  Duration left() => within - watch.elapsed;
  var over = false;
  bool late() => over || left() <= Duration.zero;
  CoreHost? made;
  Future<void> reports = Future.value();
  Future<PushAnswer> texts() async {
    if (late()) return _none;
    final asked = await _askApp((
      conversationId: conversationId,
      entry: given,
      lines: lines,
      // The app answers with what it has before the push gives up.
      wait: within > const Duration(seconds: 2) ? within - const Duration(seconds: 1) : within ~/ 2,
    ), left);
    if (asked != null) return asked;
    if (userId == null) throw StateError('no session is kept on this phone');
    final api = duvet.E2eApi(_AsStored(calls, router, token, sessionToken, duvetClient));
    final records = await store(userId);
    if (late()) return _none;
    final sender = switch (records.read(externalSender)) {
      final String key when key.isNotEmpty => key,
      _ => null,
    };
    final record = LegacyRecords(records).kept(conversationId);
    final host = made = core(left());
    // What this phone's core answers here of other users goes to the record the app's engine reads: the core says
    // `changed` once (review 28's rule 2). One its gate asks of the app's engine is told there, and written there.
    final contacts = Contacts(records, userId);
    if (host case final ObservingHost observing) observing.onObserved = contacts.observed;
    final opened = await host.open(userId);
    try {
      if (opened.state != HostState.ready) throw StateError("the core didn't open: ${opened.state.name}");
      // What the app's engine noted in the record before it let the core go.
      await contacts.reload();
      final failed = <String>[];
      if (seq != null && !late()) {
        await _applyThrough(
          host,
          api,
          conversationId,
          seq,
          given,
          sender: sender,
          expected: record == null ? null : expectedOf(record),
          failed: failed,
          late: late,
          records: records,
        );
      }
      if (late()) return _none;
      if (failed.isNotEmpty) reports = _reported(api, failed, late, left);
      return (texts: await textsOf(host, conversationId, lines), onScreen: false);
    } finally {
      // The record's writes land before the core goes: this engine's isolate may end once its notification shows.
      await contacts.written;
      await host.close();
    }
  }

  try {
    return await texts().timeout(within);
  } on TimeoutException {
    over = true;
    debugPrint('push: no text within ${within.inMilliseconds} ms');
    // Closed now, after the open under way if one is: what the work does from here finds no core.
    if (made case final host?) unawaited(host.close().catchError((Object e) => debugPrint('push: ${e.runtimeType}')));
    return _none;
  } catch (error) {
    debugPrint("push: the message's text: ${error.runtimeType}");
    return _none;
  } finally {
    // The reports go on in what's left of the push's time; the client goes after them.
    if (client == null) unawaited(reports.whenComplete(calls.close));
  }
}

/// The conversation's queue applied through [seq]: [entry] when the push brought it, then, past a gap or without it,
/// the queue from where the core is, 50 entries an apply, the users each asks for observed first, until the push's
/// time is up ([late]). The welcomes of a conversation from before the cutover are held to its record ([expected]), as
/// the app's engine holds them (Ruling 14), and the kinds of what didn't open go in [failed], which the app's engine
/// would report had it applied them (decision 40). Out of the group (nothing applied there), nothing is read: joining
/// it waits for the app's engine, as do the commits the entries ask for. No commit is made here.
Future<void> _applyThrough(
  CoreHost host,
  duvet.E2eApi api,
  String conversationId,
  int seq,
  Map<String, Object?>? entry, {
  required String? sender,
  required Map<String, Object?>? expected,
  required List<String> failed,
  required bool Function() late,
  required EngineStore records,
}) async {
  // The generations of the welcomes the queue gives, by number: a welcome the core refuses for its members is marked
  // with its own.
  final welcomes = <int, int>{};
  Future<int?> apply(List<Map<String, Object?>> entries) async {
    final applied = await withIdentitiesOn(
      host,
      api,
      () => host.handle<Map<String, Object?>>({
        'cmd': 'apply',
        'conversation_id': conversationId,
        'entries': [
          for (final queued in entries)
            if (expected != null && queued['kind'] == 'welcome') {...queued, 'expected': expected} else queued,
        ],
        'external_sender': ?sender,
      }),
    );
    final deleted = {
      for (final queued in entries)
        if (queued['deleted'] == true) queued['seq']! as int,
    };
    final results = [for (final result in applied['results']! as List<Object?>) entryResult(result! as Map)];
    failed.addAll(failedKinds(results, deleted));
    // A welcome refused for its members leaves its mark for the app's engine, which asks the person (the core's #46).
    for (final result in results) {
      if (result.kind == 'welcome' && result.result == 'rejected' && membersRefusedRules.contains(result.rule)) {
        await recordRefusedGeneration(records, conversationId, welcomes[result.seq] ?? 0);
      }
    }
    return applied['applied_through'] as int?;
  }

  int? through;
  try {
    through = await apply([?entry]);
  } on CoreError catch (error) {
    if (error.code != 'gap' || error.from == null) rethrow;
    through = error.from! - 1;
  }
  while (through != null && through < seq && !late()) {
    final page = (await api.queue(conversationId, through)).entries;
    for (final queued in page) {
      if (queued.kind == 'welcome') welcomes[queued.seq] = queued.generation;
    }
    final entries = [for (final queued in page) entryOf(queued)];
    if (entries.isEmpty) return;
    final was = through;
    for (var at = 0; at < entries.length && !late(); at += 50) {
      through = await apply(entries.sublist(at, min(at + 50, entries.length)));
    }
    // A page that moved nothing on reads no further.
    if (through == null || through <= was) return;
  }
}

/// What the push's engine couldn't open ([failed], its kinds), reported as the app's engine reports it
/// (lib/e2e/failures.dart: one request per kind with its count), as the app's engine never applies those entries
/// again: best effort, in what's left of the push's time.
Future<void> _reported(duvet.E2eApi api, List<String> failed, bool Function() late, Duration Function() left) async {
  final counts = <String, int>{};
  for (final kind in failed) {
    counts[kind] = (counts[kind] ?? 0) + 1;
  }
  for (final MapEntry(key: kind, value: count) in counts.entries) {
    if (late()) return;
    try {
      await api.reportDecryptFailure(kind, count: count).timeout(left());
    } catch (error) {
      debugPrint("push: failures to decrypt weren't reported ($kind): ${error.runtimeType}");
    }
  }
}
