import 'package:duvet_client/http/router.dart' show ApiRouter;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../data/cache.dart';
import '../data/duvet_repository.dart' show duvetRouter;
import '../data/models.dart' show ConversationSummary;
import '../data/session_store.dart';
// The core's gate needs dart:io and isolates, which the web build lacks.
import '../e2e/app_host_web.dart' if (dart.library.io) '../e2e/app_host.dart';
import '../e2e/client.dart' as app show duvetClient;
import '../e2e/host.dart';
import '../e2e/push_decrypt.dart';
import '../e2e/store.dart';
import 'notifications.dart';
import 'push_history.dart';
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
    if (await openedInBackground(push, arrived) case final shown?) await showPush(shown);
  });
}

// The conversations' pushes open one at a time in this isolate, as each may open the core: FCM runs those that waited
// for it together.
Future<void> _opening = Future.value();

/// What opens a conversation's push in the background: [openedPush], with its defaults.
typedef PushOpener =
    Future<MessagePush?> Function(
      EncryptedMessagePush push, {
      required List<MessagePush> earlier,
      required StoredSession? session,
      Duration within,
    });

/// [push] as the background handler shows it: a conversation's opened ([open]) one at a time, within what's left of its
/// time ([pushTime]) since it [arrived], after the histories a version before this one kept with their text are gone,
/// with its chat's lines from the [history] and the session [sessions] keeps; none for a chat on screen by then.
/// Anything else as it came.
@visibleForTesting
Future<Push?> openedInBackground(
  Push push,
  DateTime arrived, {
  SessionStore sessions = const SecureSessionStore(),
  Future<PushHistory> Function() history = pushHistory,
  PushOpener open = openedPush,
}) {
  if (push is! EncryptedMessagePush) return Future.value(push);
  final opened = _opening.then((_) async {
    final kept = await history();
    await kept.forgetConversationTexts();
    final earlier = await kept.read(push.conversationId);
    final session = await sessions.read();
    final left = pushTime - DateTime.now().difference(arrived);
    return open(push, earlier: earlier, session: session, within: left.isNegative ? Duration.zero : left);
  });
  _opening = opened.then((_) {}, onError: (Object _) {});
  return opened;
}

/// What a conversation's [push] shows (decision 29; lib/e2e/push_decrypt.dart): its text, and its chat's [earlier]
/// lines', as this device's core opens them, the app's engine asked first, else [core] opened with the stored
/// [session], [within] at most; without its text in time, «New message» with who wrote it. Nothing when the app's
/// engine says its chat is on screen there by then, which shows it. A text it read itself names people as the app
/// does those this phone keeps: the person, the people of their DMs ([cache]'s home), and the chat's authors.
Future<MessagePush?> openedPush(
  EncryptedMessagePush push, {
  required List<MessagePush> earlier,
  required StoredSession? session,
  CoreHost Function(Duration lockedWait) core = pushCoreHost,
  ApiRouter router = duvetRouter,
  String? duvetClient,
  http.Client? client,
  Future<EngineStore> Function(String userId) store = pushRecord,
  ChatCacheStore? cache,
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
  if (answer.onScreen) return null;
  // Who the texts may name; the app's engine names the people it knows itself.
  final names = {
    ...await _known(cache ?? FileChatCacheStore(), session?.userId),
    for (final line in earlier) line.authorId: line.authorName,
    push.authorId: push.authorName,
  };
  return push.shown(answer.texts, names: names);
}

// The names of the people this phone keeps for [userId]'s account, by ID: the person's, and those of their DMs (the
// home the app last saw, which it keeps to open offline). None for another account's.
Future<Map<String, String>> _known(ChatCacheStore cache, String? userId) async {
  final home = await ChatCache(cache).loadHome();
  if (home == null || home.profile.id != userId) return const {};
  return {
    for (final conversation in home.conversations)
      if (conversation case ConversationSummary(isGroup: false, :final otherUserId?, :final title)) otherUserId: title,
    home.profile.id: home.profile.displayName,
  };
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
