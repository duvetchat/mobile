import 'dart:async';
import 'dart:io';

import 'package:duvet/data/session_store.dart';
import 'package:duvet/push/background.dart';
import 'package:duvet/push/notifications.dart';
import 'package:duvet/push/push_message.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider/path_provider.dart';

String _id(int n) => '01920000-0000-7000-8000-${n.toString().padLeft(12, '0')}';

/// Message [n] of Maya's in room [room] of Space 1, with [avatar] as hers.
MessagePush _push(int n, {int room = 100, String avatar = ''}) =>
    Push.fromData({
          'type': 'message',
          'message_id': _id(n),
          'author_id': _id(900),
          'author_name': 'Maya',
          'author_avatar': avatar,
          'place': '#general · Design Guild',
          'text': 'number $n',
          'sent_at': '${1794702917695 + n}',
          'space_id': _id(1),
          'room_id': _id(room),
        })
        as MessagePush;

const _plugin = MethodChannel('dexterous.com/flutter/local_notifications');

/// Waits for [done], on the real clock: files take their time.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  // What the app asked of Android's notifications, and when.
  late List<(DateTime, MethodCall)> calls;
  // The photos fetched, and a wait each fetch takes while it's set.
  late List<Uri> fetched;
  Completer<void>? photoHeld;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('push-notifications');
    pushDirectory = () async => dir;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance = AndroidFlutterLocalNotificationsPlugin();
    calls = [];
    fetched = [];
    photoHeld = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_plugin, (call) async {
      calls.add((DateTime.now(), call));
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_plugin, null);
    debugDefaultTargetPlatformOverride = null;
    pushDirectory = getApplicationSupportDirectory;
    await dir.delete(recursive: true);
  });

  // Photos come from a fake API.
  Future<T> withPhotos<T>(Future<T> Function() body) => http.runWithClient(
    body,
    () => MockClient((request) async {
      fetched.add(request.url);
      await photoHeld?.future;
      return http.Response.bytes([1, 2, 3], 200);
    }),
  );

  // Each notification posted, with when.
  List<(DateTime, Map<Object?, Object?>)> posts() => [
    for (final (at, call) in calls)
      if (call.method == 'show') (at, (call.arguments as Map)['platformSpecifics'] as Map<Object?, Object?>),
  ];
  List<Map<Object?, Object?>> messages(Map<Object?, Object?> post) => [
    for (final message in (post['styleInformation'] as Map)['messages'] as List) message as Map<Object?, Object?>,
  ];
  List<String> texts(Map<Object?, Object?> post) => [for (final m in messages(post)) m['text'] as String];

  // FCM runs the messages that waited for its isolate together: a closed app gets them as a burst, and Android drops
  // a notification's updates that come faster than about five a second.
  test('ten messages at once show one at a time: the first, then the rest in one quiet post a moment later', () async {
    await Future.wait([for (var n = 1; n <= 10; n++) showPush(_push(n))]);
    final shown = posts();
    expect(shown, hasLength(2));
    expect(texts(shown.first.$2), ['number 1']);
    expect(texts(shown.last.$2), ['number 5', 'number 6', 'number 7', 'number 8', 'number 9', 'number 10']);
    expect([for (final (_, post) in shown) post['silent']], [false, true]);
    expect(shown.last.$1.difference(shown.first.$1), greaterThanOrEqualTo(postSpacing));
  });

  test("a message waits for its author's photo, then shows once, with it", () async {
    await withPhotos(() => showPush(_push(1, avatar: _id(900))));
    expect(fetched, hasLength(1));
    final shown = posts();
    expect(shown, hasLength(1));
    expect((messages(shown.single.$2).single['person'] as Map)['icon'], isNotNull);
  });

  test('a chat that comes on screen while its photo is fetched gets no notification back', () async {
    photoHeld = Completer();
    final showing = withPhotos(() => showPush(_push(1, avatar: _id(900))));
    await _until(() => fetched.isNotEmpty);
    await forgetChat(_push(1).chatId);
    photoHeld!.complete();
    await showing;
    expect(posts(), isEmpty);
  });

  test('the end of the session takes the notifications away with what they kept, and asks to sign in', () async {
    await showPush(_push(1));
    await showPush(_push(2, room: 101));
    calls.clear();
    await showPush(const SignedOutPush());
    expect([for (final (_, call) in calls) call.method], ['cancelAll', 'show']);
    expect((calls.last.$2.arguments as Map)['id'], signedOutNotice.id);
    expect(Directory('${dir.path}/push').listSync().whereType<File>(), isEmpty);
  });

  // The API signs a webhook's photo by URL anew each day.
  test('a photo whose URL is signed anew is kept once', () async {
    const day1 = 'https://api.duvet.chat/media/01920000-0000-7000-8000-000000000777.png?exp=1&sig=a';
    const day2 = 'https://api.duvet.chat/media/01920000-0000-7000-8000-000000000777.png?exp=2&sig=b';
    await withPhotos(() => showPush(_push(1, avatar: day1)));
    await withPhotos(() => showPush(_push(2, avatar: day2)));
    expect(fetched, hasLength(1));
    expect(Directory('${dir.path}/push/avatars').listSync(), hasLength(1));
  });

  // The API may still push to a phone signed out: a session that lived on keeps its registration, and FCM renews its
  // own as the app starts.
  test('signed out, a push shows nothing', () async {
    final shown = <Push>[];
    final data = _push(1).toData();
    await showWhileSignedIn(data, MemorySessionStore(), (push) async => shown.add(push));
    expect(shown, isEmpty);
    final session = (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: null);
    await showWhileSignedIn(data, MemorySessionStore(session), (push) async => shown.add(push));
    expect(shown, hasLength(1));
  });
}
