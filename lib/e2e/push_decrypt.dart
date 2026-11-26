/// A push of a conversation's message, opened on this phone (decision 29; PLAN-E2E-CLIENTES.md, Task 21 and «Android:
/// el engine que tiene el núcleo»): the API pushes it without its text (`encrypted_message`), with its queue entry while
/// that fits FCM's 4096 bytes, and the push's engine shows what this device's core opens of it. While the app's engine
/// holds the core it's asked, on [pushPortName]: it takes the entry in its conversation's turn and answers the texts, so
/// one engine writes the database (Review Focus 2). With none answering, the push's engine opens the core itself (a gate
/// that still asks the app's engine, should one hold it by then), applies the entry or, without one or past a gap, reads
/// the queue with the stored session, reads the texts, and closes the core. Past [pushTime], or failing (no session, no
/// network, the core busy), it has no text, and the core is left closed (Ruling 18).
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

import 'content.dart';
import 'engine.dart' show EngineStage, EngineState;
import 'host.dart';
import 'identity.dart';
import 'store.dart';
import 'sync.dart' show entryOf;

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
/// itself) until [stopAnsweringPushes]. A request is [reply, the ask's JSON]; its asker hears it's taken, then the
/// answer's JSON, or null.
ReceivePort answerPushes(Future<PushAnswer?> Function(PushAsk ask) answer) {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(pushPortName);
  IsolateNameServer.registerPortWithName(port.sendPort, pushPortName);
  port.listen((request) async {
    if (request case [final SendPort reply, final String asked]) {
      reply.send('taken');
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

/// Asks the app's engine, when one answers on [pushPortName]: null when none takes it within [_takes] (none runs, or
/// its isolate ended since it registered), when it doesn't answer in its time, or when it can't (its device not ready).
Future<PushAnswer?> _askApp(PushAsk ask) async {
  final app = IsolateNameServer.lookupPortByName(pushPortName);
  if (app == null) return null;
  final answers = ReceivePort();
  final replies = StreamIterator<Object?>(answers);
  try {
    app.send([answers.sendPort, _askJson(ask)]);
    if (!await replies.moveNext().timeout(_takes, onTimeout: () => false)) return null;
    if (!await replies.moveNext().timeout(ask.wait + _takes, onTimeout: () => false)) return null;
    return switch (replies.current) {
      final String answered => switch (jsonDecode(answered)) {
        {'texts': final Map<String, dynamic> texts, 'on_screen': final bool onScreen} => (
          texts: texts.cast<String, String>(),
          onScreen: onScreen,
        ),
        _ => null,
      },
      _ => null,
    };
  } finally {
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
/// engine is asked first, which also says whether the chat is on screen there; else [core] is opened as [userId], with
/// the stored session ([token], [sessionToken]), never renewed here. None on a failure or past [within], which only the
/// log says, never with a text.
Future<PushAnswer> openPushed({
  required String conversationId,
  required int? seq,
  required Map<String, Object?>? entry,
  required List<Authored> lines,
  required String? userId,
  required String token,
  required String sessionToken,
  required CoreHost Function() core,
  required ApiRouter router,
  required String? duvetClient,
  http.Client? client,
  Future<EngineStore> Function(String userId) store = FileEngineStore.open,
  Duration within = pushTime,
}) async {
  final calls = client ?? http.Client();
  final given = _coreEntry(entry, seq, lines.firstOrNull?.id);
  CoreHost? made;
  Future<PushAnswer> texts() async {
    final asked = await _askApp((
      conversationId: conversationId,
      entry: given,
      lines: lines,
      // The app answers with what it has before the push gives up.
      wait: within > const Duration(seconds: 2) ? within - const Duration(seconds: 1) : within ~/ 2,
    ));
    if (asked != null) return asked;
    if (userId == null) throw StateError('no session is kept on this phone');
    final api = duvet.E2eApi(_AsStored(calls, router, token, sessionToken, duvetClient));
    final sender = switch ((await store(userId)).read(externalSender)) {
      final String key when key.isNotEmpty => key,
      _ => null,
    };
    final host = made = core();
    return (texts: await _readHere(host, api, userId, sender, conversationId, seq, given, lines), onScreen: false);
  }

  try {
    return await texts().timeout(within);
  } on TimeoutException {
    debugPrint('push: no text within ${within.inMilliseconds} ms');
    // Closed now: what the work does from here finds no core.
    if (made case final host?) unawaited(host.close().catchError((Object e) => debugPrint('push: ${e.runtimeType}')));
    return (texts: const <String, String>{}, onScreen: false);
  } catch (error) {
    debugPrint("push: the message's text: ${error.runtimeType}");
    return (texts: const <String, String>{}, onScreen: false);
  } finally {
    if (client == null) calls.close();
  }
}

/// The texts [host] holds once opened here: the push's entries applied through [seq], then the texts of [lines]; the
/// core closed after, whatever happens.
Future<Map<String, String>> _readHere(
  CoreHost host,
  duvet.E2eApi api,
  String userId,
  String? sender,
  String conversationId,
  int? seq,
  Map<String, Object?>? entry,
  List<Authored> lines,
) async {
  final opened = await host.open(userId);
  if (opened.state != HostState.ready) throw StateError("the core didn't open: ${opened.state.name}");
  try {
    if (seq != null) await _applyThrough(host, api, conversationId, seq, entry, sender);
    return await textsOf(host, conversationId, lines);
  } finally {
    await host.close();
  }
}

/// The conversation's queue applied through [seq]: [entry] when the push brought it, then, past a gap or without it,
/// the queue from where the core is, 50 entries an apply, the users each asks for observed first. Out of the group
/// (nothing applied there), nothing is read: joining it waits for the app's engine, as do the commits the entries ask
/// for and the reports of what didn't open. No commit is made here, and nothing is sent.
Future<void> _applyThrough(
  CoreHost host,
  duvet.E2eApi api,
  String conversationId,
  int seq,
  Map<String, Object?>? entry,
  String? sender,
) async {
  Future<int?> apply(List<Map<String, Object?>> entries) async {
    final applied = await withIdentitiesOn(
      host,
      api,
      () => host.handle<Map<String, Object?>>({
        'cmd': 'apply',
        'conversation_id': conversationId,
        'entries': entries,
        'external_sender': ?sender,
      }),
    );
    return applied['applied_through'] as int?;
  }

  int? through;
  try {
    through = await apply([?entry]);
  } on CoreError catch (error) {
    if (error.code != 'gap' || error.from == null) rethrow;
    through = error.from! - 1;
  }
  while (through != null && through < seq) {
    final entries = [for (final queued in (await api.queue(conversationId, through)).entries) entryOf(queued)];
    if (entries.isEmpty) return;
    final was = through;
    for (var at = 0; at < entries.length; at += 50) {
      through = await apply(entries.sublist(at, min(at + 50, entries.length)));
    }
    // A page that moved nothing on reads no further.
    if (through == null || through <= was) return;
  }
}
