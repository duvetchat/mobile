import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../data/duvet_repository.dart' show duvetRouter;
import '../data/session_store.dart';
// The core's gate needs dart:io and isolates, which the web build lacks.
import '../e2e/app_host_web.dart' if (dart.library.io) '../e2e/app_host.dart';
import '../e2e/client.dart' as app show duvetClient;
import '../e2e/host.dart';
import '../e2e/push_decrypt.dart';
import '../e2e/store.dart';
import 'notifications.dart';
import 'push_message.dart';

/// Shows a push that comes while the app isn't in front: FCM runs it in an isolate of its own, where the
/// notifications are set up without a tap's callback, which only the app's own isolate has. With the app in front,
/// FCM hands it to `onMessage` instead, which the app leaves alone: its own notices tell of what comes. A
/// conversation's message shows the text this device's core opens of it ([openedPush]).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  final arrived = DateTime.now();
  await showWhileSignedIn(message.data, const SecureSessionStore(), (push) async {
    await notificationsReady();
    if (await _opened(push, arrived) case final shown?) await showPush(shown);
  });
}

// The conversations' pushes open one at a time in this isolate, as each may open the core: FCM runs those that waited
// for it together.
Future<void> _opening = Future.value();

// [push] as it shows: a conversation's opened, within what's left of its time since it [arrived]; none for a chat on
// screen by then.
Future<Push?> _opened(Push push, DateTime arrived) {
  if (push is! EncryptedMessagePush) return Future.value(push);
  final opened = _opening.then((_) async {
    final history = await pushHistory();
    await history.forgetConversationTexts();
    final left = pushTime - DateTime.now().difference(arrived);
    return openedPush(
      push,
      earlier: await history.read(push.conversationId),
      session: await const SecureSessionStore().read(),
      within: left.isNegative ? Duration.zero : left,
    );
  });
  _opening = opened.then((_) {}, onError: (Object _) {});
  return opened;
}

/// What a conversation's [push] shows (decision 29; lib/e2e/push_decrypt.dart): its text, and its chat's [earlier]
/// lines', as this device's core opens them, the app's engine asked first, else [core] opened with the stored
/// [session], [within] at most; without its text in time, «New message» with who wrote it. Nothing when the app's
/// engine says its chat is on screen there by then, which shows it.
Future<MessagePush?> openedPush(
  EncryptedMessagePush push, {
  required List<MessagePush> earlier,
  required StoredSession? session,
  CoreHost Function() core = pushCoreHost,
  ApiRouter router = duvetRouter,
  String? duvetClient,
  http.Client? client,
  Future<EngineStore> Function(String userId) store = FileEngineStore.open,
  Duration within = pushTime,
}) async {
  final answer = await openPushed(
    conversationId: push.conversationId,
    seq: push.seq,
    entry: push.entry,
    lines: [
      (id: push.messageId, author: push.authorId),
      for (final line in earlier)
        if (line.messageId != push.messageId) (id: line.messageId, author: line.authorId),
    ],
    userId: session?.userId,
    token: session?.token ?? '',
    sessionToken: session?.sessionToken ?? '',
    core: core,
    router: router,
    duvetClient: duvetClient ?? app.duvetClient(),
    client: client,
    store: store,
    within: within,
  );
  // Who the texts may name: those the chat's lines show. The app's engine names the others it knows.
  final names = {push.authorId: push.authorName, for (final line in earlier) line.authorId: line.authorName};
  return answer.onScreen ? null : push.shown(answer.texts, names: names);
}

// The notifications' setup in this isolate, which FCM keeps for the pushes that follow.
Future<void>? _ready;

/// Sets the notifications and their channels up in the background isolate, once for all its pushes: those FCM runs
/// together wait for the one setup. One that failed is forgotten, so the next push tries again.
@visibleForTesting
Future<void> notificationsReady() async {
  final ready = _ready ??= initNotifications().then((_) => ensureChannels());
  try {
    await ready;
  } catch (_) {
    if (identical(_ready, ready)) _ready = null;
    rethrow;
  }
}

/// Shows the push [data] holds with [show] while [store] keeps a session: signed out, nothing shows. The API may still
/// push to a phone signed out, as a session that lived on keeps its registration, and FCM renews its own as the app
/// starts.
Future<void> showWhileSignedIn(
  Map<String, dynamic> data,
  SessionStore store,
  Future<void> Function(Push push) show,
) async {
  final push = Push.fromData(data);
  if (push == null || await store.read() == null) return;
  await show(push);
}
