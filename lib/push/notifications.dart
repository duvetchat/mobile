/// The phone's notifications for the pushes the API sends: one per chat, its last messages in Android's messaging
/// style, each author with their photo.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/duvet_repository.dart' show avatarUrlOn, duvetRouter;
import '../data/links.dart' show isDuvetId;
import 'call_decline.dart';
import 'push_history.dart';
import 'push_message.dart';

/// The channel every message's notification goes through. Android fixes its sound and importance as it creates it.
const messagesChannel = AndroidNotificationChannel(
  'messages',
  'Messages',
  importance: Importance.high,
  sound: RawResourceAndroidNotificationSound('message_notification'),
);

/// The channel of the calls that ring the user: the app's own ring (res/raw/voice_calling), as a ringtone, which
/// Android's ringer volume sets.
const callsChannel = AndroidNotificationChannel(
  'calls',
  'Calls',
  importance: Importance.max,
  sound: RawResourceAndroidNotificationSound('voice_calling'),
  audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
);

/// A call's notification's buttons.
const declineAction = 'decline';
const answerAction = 'answer';

/// Android's FLAG_INSISTENT: the sound goes on until the notification goes, as a phone call's ringtone does.
const _flagInsistent = 4;

/// The payload of a call's notification, which taps and buttons go by: its conversation, and its call's start (Unix ms,
/// as its ring gave it; 0 when the app put it up, not knowing it), which is its tag too, so the end of another call of
/// the conversation leaves it.
String callPayload(String conversationId, int startedAt) => 'call:$conversationId:$startedAt';
({String conversationId, int startedAt})? callOfPayload(String? payload) => switch (payload?.split(':')) {
  ['call', final conversation, final started] when isDuvetId(conversation) && int.tryParse(started) != null => (
    conversationId: conversation,
    startedAt: int.parse(started),
  ),
  _ => null,
};

// The calls whose end came, by conversation and start, for [_endsKept]: a ring that comes after its end, as FCM may
// deliver them, rings nothing. Kept in this isolate, which a call's pushes reach together.
final _ended = <String, DateTime>{};
const _endsKept = Duration(minutes: 1);

/// The conversation whose call a notification's Answer opened the app for: the app answers it as it rings
/// (DuvetApp, VoiceController.answerWhenRinging), and sets this back to null.
final callAnswered = ValueNotifier<String?>(null);

/// How long a notification waits for its authors' photos before it shows without them.
const avatarWait = Duration(seconds: 2);

/// The most a photo takes: a bigger one shows no photo.
const avatarMaxBytes = 2 << 20;

final _plugin = FlutterLocalNotificationsPlugin();

/// Where the notifications keep their messages and photos (`push/` under it): the app's support directory, which
/// tests replace.
@visibleForTesting
Future<Directory> Function() pushDirectory = getApplicationSupportDirectory;

/// How far apart the notifications' posts keep: Android drops the updates of an app that posts faster than about five
/// a second.
const postSpacing = Duration(milliseconds: 250);

/// Sets the notifications up in this isolate: in the app's own isolate what a tap does ([onTap], with a message
/// notification's payload, its link; [onCall] for a call's: see [routeNotificationResponse]). The background isolate
/// passes none, so the app's own stay. A call's Decline while the app isn't running goes to
/// [callActionInBackground]. The channels come apart from it ([ensureChannels]): the app's start waits for this, not
/// for them.
Future<void> initNotifications({
  void Function(String? payload)? onTap,
  void Function(String conversationId, {required bool answer})? onCall,
}) async {
  await _plugin.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('mipmap/ic_launcher_monochrome')),
    onDidReceiveNotificationResponse: onTap == null && onCall == null
        ? null
        : (response) => routeNotificationResponse(response, onTap: onTap, onCall: onCall),
    onDidReceiveBackgroundNotificationResponse: callActionInBackground,
  );
}

// The channels' creation in this isolate, once it's asked for.
Future<void>? _channels;

/// Creates the two channels, once in this isolate however often it's asked: the app asks after its first frame, and
/// every notification waits for it before it shows, so none comes before its channel. A failure is only logged, and
/// the next one asks again: Android then makes the channel of the notification that shows.
Future<void> ensureChannels() => _channels ??= _createChannels().catchError((Object e) {
  _channels = null;
  debugPrint('push: the channels: $e');
});

Future<void> _createChannels() async {
  final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(messagesChannel);
  await android?.createNotificationChannel(callsChannel);
}

/// Forgets that the channels were created: each test starts as a new isolate does.
@visibleForTesting
void forgetChannels() => _channels = null;

/// Where a notification's tap or button goes: a message's to [onTap], with its link; a call's Decline declines it
/// ([decline]); its Answer or its body to [onCall], which opens the app on it, answering it for Answer.
void routeNotificationResponse(
  NotificationResponse response, {
  void Function(String? payload)? onTap,
  void Function(String conversationId, {required bool answer})? onCall,
  Future<void> Function(String conversationId, int startedAt) decline = _decline,
}) {
  final payload = response.payload;
  if (payload == null || !payload.startsWith('call:')) {
    onTap?.call(payload);
    return;
  }
  final call = callOfPayload(payload);
  if (call == null) return;
  if (response.actionId == declineAction) {
    unawaited(decline(call.conversationId, call.startedAt));
  } else {
    onCall?.call(call.conversationId, answer: response.actionId == answerAction);
  }
}

Future<void> _decline(String conversationId, int startedAt) =>
    declineFromNotification(conversationId, startedAt: startedAt);

/// A call's Decline while the app isn't running, in an isolate the plugin starts for it, which it waits for.
@pragma('vm:entry-point')
Future<void> callActionInBackground(NotificationResponse response) async {
  final call = callOfPayload(response.payload);
  if (call == null || response.actionId != declineAction) return;
  WidgetsFlutterBinding.ensureInitialized();
  await declineFromNotification(call.conversationId, startedAt: call.startedAt);
}

/// The response of the notification whose tap or button started the app, if one did.
Future<NotificationResponse?> launchedWith() async {
  // Only Android's notifications are set up ([initNotifications]): elsewhere none of them started the app.
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  final details = await _plugin.getNotificationAppLaunchDetails();
  return details?.didNotificationLaunchApp == true ? details?.notificationResponse : null;
}

// The pushes waiting to show, in the order they came, each with what its caller waits on.
final _waiting = <(Push, Completer<void>)>[];
var _showing = false;

/// Shows [push] once those before it have: a message in its chat's notification, with the chat's last messages; the
/// session's end as the notice to sign in again. FCM runs the messages that waited for its isolate together, and each
/// writes its chat's history, so they go one at a time: a chat's messages that wait together show in one post, posts
/// keep [postSpacing] apart, and only a burst's first post alerts. Completes once [push] shows, or fails to. A call
/// rings at once, outside that line, and its end takes it away.
Future<void> showPush(Push push) {
  switch (push) {
    case CallPush():
      return _showCall(push).then((_) {}, onError: (Object e) => debugPrint('push: a call: $e'));
    case CallEndPush():
      return endCallNotification(push).catchError((Object e) => debugPrint('push: a call\'s end: $e'));
    case MessagePush() || SignedOutPush():
  }
  final shown = Completer<void>();
  _waiting.add((push, shown));
  if (!_showing) unawaited(_showWaiting());
  return shown.future;
}

Future<void> _showWaiting() async {
  _showing = true;
  var alert = true;
  while (_waiting.isNotEmpty) {
    final next = _waiting.first.$1;
    final batch = [
      for (final waiting in _waiting)
        if (_together(waiting.$1, next)) waiting,
    ];
    _waiting.removeWhere(batch.contains);
    try {
      // After the batch is taken: the first of a burst still shows alone, at once.
      await ensureChannels();
      switch (next) {
        case MessagePush():
          await _showMessages([for (final (push, _) in batch) push as MessagePush], alert: alert);
        case SignedOutPush():
          await _showSignedOut(alert: alert);
        case CallPush() || CallEndPush():
        // Never waiting: showPush shows them at once.
      }
    } catch (e) {
      debugPrint('push: showing: $e');
    }
    alert = false;
    for (final (_, shown) in batch) {
      shown.complete();
    }
    if (_waiting.isNotEmpty) await Future<void>.delayed(postSpacing);
  }
  _showing = false;
}

// Whether [push] shows in one post with [next]: a message of the same chat.
bool _together(Push push, Push next) => switch ((push, next)) {
  (MessagePush(:final chatId), MessagePush(chatId: final nextChat)) => chatId == nextChat,
  _ => identical(push, next),
};

/// Takes every notification away, and the messages and photos they showed: the session ended.
Future<void> forgetAllNotifications() async {
  await _plugin.cancelAll();
  await PushHistory(await pushDirectory()).forgetAll();
}

/// Takes away the notification of the call [end] names, and the one the app put up for the conversation's call, which
/// doesn't know its start; and keeps the end a while, as its ring may come after it.
Future<void> endCallNotification(CallEndPush end) async {
  if (end.startedAt == 0) return hideCallNotification(end.conversationId);
  final now = DateTime.now();
  _ended.removeWhere((_, at) => now.difference(at) > _endsKept);
  _ended['${end.conversationId}:${end.startedAt}'] = now;
  final id = callNotificationIdOf(end.conversationId);
  await _plugin.cancel(id: id, tag: '${end.startedAt}');
  await _plugin.cancel(id: id, tag: '0');
}

/// Takes away a conversation's call's notification, whichever call it was put up for: the app rings the call itself,
/// on screen, or it rings here no more.
Future<void> hideCallNotification(String conversationId) async {
  final id = callNotificationIdOf(conversationId);
  for (final shown in await _plugin.getActiveNotifications()) {
    if (shown.id == id) await _plugin.cancel(id: id, tag: shown.tag);
  }
}

/// Puts the call's notification up from the app, as Duvet leaves the screen while [push]'s call rings it, unless a push
/// put it up already: it rings the call there. False when it doesn't show, as the phone shows none of Duvet's
/// notifications: the app rings on itself then.
Future<bool> ringCallAway(CallPush push) async {
  final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  if (await android?.areNotificationsEnabled() != true) return false;
  return _showCall(push, fromApp: true);
}

// Rings a call until its ring window ends, unless it's over or shows already: Android's call category, shown whole on
// the lock screen, the calls channel's ringtone over and over, Decline and Answer. Not full screen: the app doesn't show
// over the lock screen, so Android would start it behind it, where it would take its notification away as if it showed. Its caller's photo goes with it when
// it's kept, or comes within a second: the ring doesn't wait longer for it. A push comes only within its ring window,
// as its time to live ends with it: one the phone's clock puts out of it is that clock being off, and it rings the
// window's length. The app's own ([fromApp]) doesn't know the call's start. Answers whether the call's notification
// shows.
Future<bool> _showCall(CallPush push, {bool fromApp = false}) async {
  final started = fromApp ? 0 : push.startedAt.millisecondsSinceEpoch;
  if (_ended.containsKey('${push.conversationId}:$started')) return false;
  await ensureChannels();
  final window = push.ringUntil.difference(push.startedAt);
  var left = push.ringUntil.difference(DateTime.now());
  if (left <= Duration.zero || left > window) left = window;
  final until = DateTime.now().add(left);
  final dir = await pushDirectory();
  await _keepPhoto(dir, push.initiatorAvatar).timeout(const Duration(seconds: 1), onTimeout: () {});
  final id = callNotificationIdOf(push.conversationId);
  // Put up again, it would ring from the start: the app put it up, or a push before.
  if ((await _plugin.getActiveNotifications()).any((shown) => shown.id == id)) return true;
  final timeout = until.difference(DateTime.now());
  if (timeout <= Duration.zero) return false;
  final photo = _photoFile(dir, push.initiatorAvatar);
  final withPhoto = photo != null && await photo.exists();
  await _plugin.show(
    id: id,
    title: push.initiatorName.isEmpty ? 'Someone' : push.initiatorName,
    body: push.place.isEmpty ? 'Incoming call' : 'Incoming call · ${push.place}',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        callsChannel.id,
        callsChannel.name,
        importance: callsChannel.importance,
        priority: Priority.max,
        sound: callsChannel.sound,
        audioAttributesUsage: callsChannel.audioAttributesUsage,
        category: AndroidNotificationCategory.call,
        ongoing: true,
        autoCancel: false,
        visibility: NotificationVisibility.public,
        timeoutAfter: timeout.inMilliseconds,
        tag: '$started',
        additionalFlags: Int32List.fromList(const [_flagInsistent]),
        largeIcon: withPhoto ? FilePathAndroidBitmap(photo.path) : null,
        when: push.startedAt.millisecondsSinceEpoch,
        actions: const [
          AndroidNotificationAction(declineAction, 'Decline'),
          AndroidNotificationAction(answerAction, 'Answer', showsUserInterface: true),
        ],
      ),
    ),
    payload: callPayload(push.conversationId, started),
  );
  return true;
}

/// Takes a chat's notification away, and the messages it showed: the chat is on screen.
Future<void> forgetChat(String chatId) async {
  await _plugin.cancel(id: notificationIdOf(chatId));
  await PushHistory(await pushDirectory()).forget(chatId);
}

// Shows a chat's [pushes] in its notification, with the chat's last messages, once each author's photo is here
// ([avatarWait] at most), so it shows once.
Future<void> _showMessages(List<MessagePush> pushes, {required bool alert}) async {
  final dir = await pushDirectory();
  final history = PushHistory(dir);
  final kept = await history.addAll(pushes);
  await Future.wait({for (final push in kept) push.authorAvatar}.map((avatar) => _keepPhoto(dir, avatar)));
  // The chat came on screen meanwhile, which took its messages away (forgetChat): they stay away.
  final now = await history.read(pushes.first.chatId);
  final ids = {for (final push in pushes) push.messageId};
  if (!now.any((push) => ids.contains(push.messageId))) return;
  await _show(dir, now.last, now, alert: alert);
}

// The session ended: its notifications go, with what they kept, and one asks to sign in again.
Future<void> _showSignedOut({required bool alert}) async {
  await forgetAllNotifications();
  await _plugin.show(
    id: signedOutNotice.id,
    title: signedOutNotice.title,
    body: signedOutNotice.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        messagesChannel.id,
        messagesChannel.name,
        importance: messagesChannel.importance,
        priority: Priority.high,
        sound: messagesChannel.sound,
        silent: !alert,
      ),
    ),
  );
}

Future<void> _show(Directory dir, MessagePush push, List<MessagePush> history, {required bool alert}) async {
  final messages = [for (final p in history) Message(p.text, p.sentAt.toLocal(), await _person(dir, p))];
  final style = MessagingStyleInformation(
    const Person(name: 'You'),
    conversationTitle: push.place.isEmpty ? null : push.place,
    groupConversation: push.place.isNotEmpty,
    messages: messages,
  );
  await _plugin.show(
    id: notificationIdOf(push.chatId),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        messagesChannel.id,
        messagesChannel.name,
        importance: messagesChannel.importance,
        priority: Priority.high,
        sound: messagesChannel.sound,
        category: AndroidNotificationCategory.message,
        styleInformation: style,
        silent: !alert,
        when: push.sentAt.millisecondsSinceEpoch,
      ),
    ),
    payload: push.link.toString(),
  );
}

Future<Person> _person(Directory dir, MessagePush push) async {
  final photo = _photoFile(dir, push.authorAvatar);
  return Person(
    key: push.authorId,
    name: push.authorName,
    icon: photo != null && await photo.exists() ? BitmapFilePathAndroidIcon(photo.path) : null,
  );
}

/// Where an avatar's photo is kept: under a hash of the avatar as the API gives it, an attachment's ID or a URL, without
/// the URL's query, as the API signs a URL anew each day.
File? _photoFile(Directory dir, String avatar) {
  if (avatar.isEmpty) return null;
  // FNV-1a's 64-bit offset basis, in two halves: whole, the web's compiler refuses the file for a number it
  // can't hold, though nothing there asks for a photo's file.
  var hash = (0xcbf29ce4 << 32) | 0x84222325;
  for (final byte in utf8.encode(avatar.split('?').first)) {
    hash = (hash ^ byte) * 0x100000001b3;
  }
  return File('${dir.path}/push/avatars/${hash.toUnsigned(64).toRadixString(16)}');
}

// Keeps [avatar]'s photo, unless it's kept already.
Future<void> _keepPhoto(Directory dir, String avatar) async {
  final photo = _photoFile(dir, avatar);
  if (photo == null || await photo.exists()) return;
  await _fetchPhoto(avatar, photo);
}

// Fetches an avatar's photo into [file], within [avatarWait]: false when it can't.
Future<bool> _fetchPhoto(String avatar, File file) async {
  final url = avatarUrlOn(duvetRouter, avatar);
  if (url == null) return false;
  try {
    final response = await http.get(Uri.parse(url)).timeout(avatarWait);
    if (response.statusCode != 200 || response.bodyBytes.isEmpty || response.bodyBytes.length > avatarMaxBytes) {
      return false;
    }
    await file.parent.create(recursive: true);
    await file.writeAsBytes(response.bodyBytes);
    return true;
  } catch (e) {
    debugPrint('push: an author\'s photo: $e');
    return false;
  }
}
