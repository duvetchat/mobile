/// The phone's notifications for the pushes the API sends: one per chat, its last messages in Android's messaging
/// style, each author with their photo.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/duvet_repository.dart' show avatarUrlOn, duvetRouter;
import 'push_history.dart';
import 'push_message.dart';

/// The channel every message's notification goes through. Android fixes its sound and importance as it creates it.
const messagesChannel = AndroidNotificationChannel(
  'messages',
  'Messages',
  importance: Importance.high,
  sound: RawResourceAndroidNotificationSound('message_notification'),
);

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

/// Sets the notifications up in this isolate: the channel, and in the app's own isolate what a tap does ([onTap], with
/// the notification's payload, a message's link). The background isolate passes none, so the app's own stays.
Future<void> initNotifications({void Function(String? payload)? onTap}) async {
  await _plugin.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('mipmap/ic_launcher_monochrome')),
    onDidReceiveNotificationResponse: onTap == null ? null : (response) => onTap(response.payload),
  );
  await _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(messagesChannel);
}

/// The link of the notification whose tap started the app, if one did.
Future<String?> launchedWith() async {
  final details = await _plugin.getNotificationAppLaunchDetails();
  return details?.didNotificationLaunchApp == true ? details?.notificationResponse?.payload : null;
}

// The pushes waiting to show, in the order they came, each with what its caller waits on.
final _waiting = <(Push, Completer<void>)>[];
var _showing = false;

/// Shows [push] once those before it have: a message in its chat's notification, with the chat's last messages; the
/// session's end as the notice to sign in again. FCM runs the messages that waited for its isolate together, and each
/// writes its chat's history, so they go one at a time: a chat's messages that wait together show in one post, posts
/// keep [postSpacing] apart, and only a burst's first post alerts. Completes once [push] shows, or fails to.
Future<void> showPush(Push push) {
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
      switch (next) {
        case MessagePush():
          await _showMessages([for (final (push, _) in batch) push as MessagePush], alert: alert);
        case SignedOutPush():
          await _showSignedOut(alert: alert);
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
  var hash = 0xcbf29ce484222325;
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
