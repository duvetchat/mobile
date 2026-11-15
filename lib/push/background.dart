import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

import '../data/session_store.dart';
import 'notifications.dart';
import 'push_message.dart';

/// Shows a push that comes while the app isn't in front: FCM runs it in an isolate of its own, where the
/// notifications are set up without a tap's callback, which only the app's own isolate has. With the app in front,
/// FCM hands it to `onMessage` instead, which the app leaves alone: its own notices tell of what comes.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await showWhileSignedIn(message.data, const SecureSessionStore(), (push) async {
    await initNotifications();
    await showPush(push);
  });
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
