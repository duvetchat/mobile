import 'dart:async';
import 'dart:io';

import 'package:duvet/data/models.dart';
import 'package:duvet/data/session_store.dart';
import 'package:duvet/push/background.dart';
import 'package:duvet/push/call_decline.dart';
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

/// A call in conversation [n] that Maya started just now, ringing for half a minute.
CallPush _callPush(int n) {
  final started = DateTime.now();
  return CallPush(
    conversationId: _id(n),
    initiatorId: _id(900),
    initiatorName: 'Maya',
    initiatorAvatar: '',
    place: '',
    startedAt: started,
    ringUntil: started.add(const Duration(seconds: 30)),
  );
}

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
  // The notifications Android shows, as getActiveNotifications gives them, and whether Duvet's are allowed.
  late List<Map<String, Object?>> active;
  late bool allowed;
  // The photos fetched, and a wait each fetch takes while it's set.
  late List<Uri> fetched;
  Completer<void>? photoHeld;
  // A wait each channel's creation takes while it's set, and the methods Android refuses, each the times it's set to.
  Completer<void>? channelsHeld;
  late Map<String, int> refused;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('push-notifications');
    pushDirectory = () async => dir;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance = AndroidFlutterLocalNotificationsPlugin();
    calls = [];
    active = [];
    allowed = true;
    fetched = [];
    photoHeld = null;
    channelsHeld = null;
    refused = {};
    forgetChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_plugin, (call) async {
      calls.add((DateTime.now(), call));
      if (call.method == 'createNotificationChannel') await channelsHeld?.future;
      if ((refused[call.method] ?? 0) > 0) {
        refused[call.method] = refused[call.method]! - 1;
        throw PlatformException(code: 'refused', message: call.method);
      }
      return switch (call.method) {
        'getActiveNotifications' => active,
        'areNotificationsEnabled' => allowed,
        'initialize' => true,
        _ => null,
      };
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

  List<String> methods() => [for (final (_, call) in calls) call.method];
  List<Object?> channelsMade() => [
    for (final (_, call) in calls)
      if (call.method == 'createNotificationChannel') (call.arguments as Map)['id'],
  ];

  // The app's start doesn't wait for the channels (main): a notification does, so none comes before its channel.
  test('a message waits for the channels, which are created once', () async {
    channelsHeld = Completer();
    final showing = showPush(_push(1));
    await _until(() => calls.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(methods(), ['createNotificationChannel'], reason: 'nothing shows while the channels are made');

    channelsHeld!.complete();
    await showing;
    expect(channelsMade(), ['messages', 'calls']);
    expect(methods().indexOf('show'), greaterThan(methods().lastIndexOf('createNotificationChannel')));

    // Asked again, by the app after its first frame or by the next notification: they're there.
    await ensureChannels();
    await showPush(_push(2));
    expect(channelsMade(), hasLength(2));
    expect(posts(), hasLength(2));
  });

  test('a call waits for the channels too, from a push or from the app', () async {
    channelsHeld = Completer();
    final ringing = showPush(_callPush(7));
    final away = ringCallAway(_callPush(8));
    await _until(() => methods().contains('areNotificationsEnabled'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(methods(), isNot(contains('show')));
    expect(methods().where((m) => m == 'createNotificationChannel'), hasLength(1), reason: 'one creation for both');

    channelsHeld!.complete();
    await ringing;
    expect(await away, isTrue);
    expect(channelsMade(), ['messages', 'calls']);
    expect(methods().where((m) => m == 'show'), hasLength(2));
    expect(methods().indexOf('show'), greaterThan(methods().lastIndexOf('createNotificationChannel')));
  });

  // Android makes a notification's channel as it shows, when it has none.
  test("channels that can't be created hold no notification back, and the next asks again", () async {
    refused['createNotificationChannel'] = 1;
    await showPush(_push(1));
    expect(posts(), hasLength(1));
    expect(channelsMade(), ['messages']);

    await showPush(_push(2));
    expect(posts(), hasLength(2));
    expect(channelsMade(), ['messages', 'messages', 'calls']);
  });

  // FCM keeps its isolate for the pushes that follow, and runs those that waited for it together.
  test('the background isolate sets the notifications up once for all its pushes, and again after a failure', () async {
    refused['initialize'] = 1;
    await expectLater(notificationsReady(), throwsA(isA<PlatformException>()));
    expect(methods(), ['initialize']);

    await Future.wait([notificationsReady(), notificationsReady()]);
    await notificationsReady();
    expect(methods(), ['initialize', 'initialize', 'createNotificationChannel', 'createNotificationChannel']);
  });

  // Only Android's notifications are set up: on an iPhone the plugin is never asked what started the app.
  test('no notification started the app where none is set up', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await launchedWith(), isNull);
    expect(calls, isEmpty);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await launchedWith(), isNull);
    expect(methods(), ['getNotificationAppLaunchDetails']);
  });

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

  // PLAN-E2E-CLIENTES.md, Task 21: a conversation's lines are what this device's database holds of them, as the push
  // that brings a new one read them: the history keeps none of their text, and a line the device no longer holds (a
  // message deleted since) isn't shown.
  test(
    "a conversation's notification shows its lines as the device holds them, and keeps none of their text",
    () async {
      MessagePush said(int n, String text, {Map<String, String> earlier = const {}}) => MessagePush(
        messageId: _id(n),
        authorId: _id(901),
        authorName: 'Bo',
        authorAvatar: '',
        place: '',
        text: text,
        target: ConversationTarget(_id(300)),
        sentAt: DateTime.fromMillisecondsSinceEpoch(1794702917695 + n, isUtc: true),
        earlier: earlier,
      );
      await showPush(said(1, 'umbrella'));
      await showPush(said(2, 'violin', earlier: {_id(1): 'umbrella'}));
      // The first is gone from the device by the third's push, which read the second's line.
      await showPush(said(3, 'walrus', earlier: {_id(2): 'violin, as the device holds it'}));
      expect(
        [for (final (_, post) in posts()) texts(post)],
        [
          ['umbrella'],
          ['umbrella', 'violin'],
          ['violin, as the device holds it', 'walrus'],
        ],
      );
      final kept = [for (final f in Directory('${dir.path}/push').listSync().whereType<File>()) f.readAsStringSync()];
      expect(
        kept.join(),
        allOf(contains(_id(3)), isNot(contains('umbrella')), isNot(contains('violin')), isNot(contains('walrus'))),
      );
    },
  );

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
    final session = (token: 'access-1', sessionToken: 'refresh-1', refreshedAt: null, userId: null);
    await showWhileSignedIn(data, MemorySessionStore(session), (push) async => shown.add(push));
    expect(shown, hasLength(1));
  });

  // A call that started [ago] and rings [window] in all, by the server's clock.
  CallPush call(
    int conversation, {
    Duration ago = const Duration(seconds: 5),
    Duration window = const Duration(seconds: 30),
    String place = 'Friday raid',
  }) {
    final started = DateTime.now().subtract(ago);
    return CallPush(
      conversationId: _id(conversation),
      initiatorId: _id(900),
      initiatorName: 'Maya',
      initiatorAvatar: '',
      place: place,
      startedAt: started,
      ringUntil: started.add(window),
    );
  }

  List<Map<Object?, Object?>> shows() => [
    for (final (_, c) in calls)
      if (c.method == 'show') c.arguments as Map<Object?, Object?>,
  ];
  List<(Object?, Object?)> cancels() => [
    for (final (_, c) in calls)
      if (c.method == 'cancel') ((c.arguments as Map)['id'], (c.arguments as Map)['tag']),
  ];
  int timeoutOf(Map<Object?, Object?> show) => (show['platformSpecifics'] as Map)['timeoutAfter'] as int;

  // A call rings at once, not behind the messages' spacing: Android's call category, shown whole on the lock screen,
  // the calls channel's ringtone over and over (FLAG_INSISTENT) until its ring window ends, Decline and Answer.
  test('a call shows at once as a ringing call, until its ring window ends', () async {
    final ringing = call(7);
    final started = ringing.startedAt.millisecondsSinceEpoch;
    await withPhotos(() => showPush(ringing));
    final show = shows().single;
    final android = show['platformSpecifics'] as Map<Object?, Object?>;
    expect(show['id'], callNotificationIdOf(_id(7)));
    // Tagged with the call's start, which its payload names too: the end of another call of the conversation leaves it.
    expect(android['tag'], '$started');
    expect(
      (show['title'], show['body'], show['payload']),
      ('Maya', 'Incoming call · Friday raid', 'call:${_id(7)}:$started'),
    );
    // Not full screen: without showing over the lock screen, which the app doesn't, Android would launch the app behind
    // it, which then took the notification away as if it showed.
    expect((android['channelId'], android['category'], android['fullScreenIntent']), ('calls', 'call', false));
    expect(android['ongoing'], isTrue);
    expect(android['additionalFlags'], [4]);
    expect(timeoutOf(show), inInclusiveRange(23000, 25000));
    final actions = [for (final a in android['actions'] as List) a as Map<Object?, Object?>];
    expect([for (final a in actions) (a['id'], a['showsUserInterface'])], [('decline', false), ('answer', true)]);
  });

  test('a call in a direct message says only who calls', () async {
    await withPhotos(() => showPush(call(7, place: '')));
    expect(shows().single['body'], 'Incoming call');
  });

  // A ring comes only within its window, as its time to live ends with it: one the phone's clock puts past its window,
  // or beyond it, is the phone's clock being off, and it rings the window's length.
  test("a phone whose clock is off rings a call its window's length", () async {
    await withPhotos(() => showPush(call(7, ago: const Duration(seconds: 80))));
    await withPhotos(() => showPush(call(8, ago: const Duration(seconds: -60))));
    expect([for (final show in shows()) timeoutOf(show)], everyElement(inInclusiveRange(28000, 30000)));
    expect(shows(), hasLength(2));
  });

  test("a call's end takes away its call's notification, not another call's of the conversation", () async {
    await showPush(CallEndPush(conversationId: _id(7), startedAt: 1794702917695));
    // Also the one the app put up itself, which doesn't know the call's start.
    expect(cancels(), [(callNotificationIdOf(_id(7)), '1794702917695'), (callNotificationIdOf(_id(7)), '0')]);
  });

  test('a ring that comes after its call ended shows nothing', () async {
    final late = call(7);
    await showPush(CallEndPush(conversationId: _id(7), startedAt: late.startedAt.millisecondsSinceEpoch));
    await withPhotos(() => showPush(late));
    expect(shows(), isEmpty);
    // Another call of the conversation rings.
    await withPhotos(() => showPush(call(7, ago: const Duration(seconds: 1))));
    expect(shows(), hasLength(1));
  });

  test("a call whose notification shows already isn't put up again, which would start its ringtone over", () async {
    active = [
      {'id': callNotificationIdOf(_id(7)), 'tag': '0', 'channelId': 'calls'},
    ];
    await withPhotos(() => showPush(call(7)));
    expect(shows(), isEmpty);
  });

  test(
    "the app puts a call's notification up itself, not knowing its start, while notifications are allowed",
    () async {
      final ringing = CallPush(
        conversationId: _id(7),
        initiatorId: _id(900),
        initiatorName: 'Maya',
        initiatorAvatar: '',
        place: '',
        startedAt: DateTime.now(),
        ringUntil: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(await withPhotos(() => ringCallAway(ringing)), isTrue);
      final show = shows().single;
      expect(((show['platformSpecifics'] as Map)['tag'], show['payload']), ('0', 'call:${_id(7)}:0'));

      allowed = false;
      expect(await withPhotos(() => ringCallAway(ringing)), isFalse);
      expect(shows(), hasLength(1));
    },
  );

  test("the app takes a call's notification away, whichever call it was put up for", () async {
    active = [
      {'id': callNotificationIdOf(_id(7)), 'tag': '1794702917695'},
      {'id': callNotificationIdOf(_id(7)), 'tag': '0'},
      {'id': notificationIdOf(_id(7)), 'tag': null},
    ];
    await hideCallNotification(_id(7));
    expect(cancels(), [(callNotificationIdOf(_id(7)), '1794702917695'), (callNotificationIdOf(_id(7)), '0')]);
  });

  test("Decline on a call's notification declines it through the API, with the session the phone keeps", () async {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      return http.Response('', 204);
    });
    final store = MemorySessionStore((token: 'access', sessionToken: 'session', refreshedAt: null, userId: null));
    await declineFromNotification(_id(7), startedAt: 1794702917695, store: store, client: client);
    expect(sent.single.method, 'POST');
    expect(sent.single.url.path, '/api/users/@me/conversations/${_id(7)}/call/decline');
    expect(sent.single.headers['X-Session-Token'], 'session');
    // The call it rang for: a later call of the conversation isn't declined.
    expect(sent.single.body, '{"started_at":1794702917695}');
    // Without its start (the app put the notification up), whatever call goes on there.
    await declineFromNotification(_id(7), startedAt: 0, store: store, client: client);
    expect(sent.last.body, '');

    // Signed out, or with a conversation that isn't one, it sends nothing.
    await declineFromNotification(_id(7), startedAt: 0, store: MemorySessionStore(), client: client);
    await declineFromNotification('../x', startedAt: 0, store: store, client: client);
    expect(sent, hasLength(2));
  });

  // The plugin's own manifest declares none of its receivers: without the app's, a call's Decline goes nowhere.
  test("the app declares the receiver of its notifications' buttons", () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"'));
  });

  test("a call's notification goes to the app: a tap or Answer opens it, Answer answers, Decline declines", () {
    final opened = <(String, bool)>[];
    final declined = <(String, int)>[];
    final links = <String?>[];
    void route(String? action, String? payload) => routeNotificationResponse(
      NotificationResponse(
        notificationResponseType: action == null
            ? NotificationResponseType.selectedNotification
            : NotificationResponseType.selectedNotificationAction,
        actionId: action,
        payload: payload,
      ),
      onTap: links.add,
      onCall: (conversation, {required answer}) => opened.add((conversation, answer)),
      decline: (conversation, startedAt) async => declined.add((conversation, startedAt)),
    );
    route(null, 'call:${_id(7)}:1794702917695');
    route('answer', 'call:${_id(7)}:1794702917695');
    route('decline', 'call:${_id(7)}:1794702917695');
    route('decline', 'call:${_id(7)}:0');
    route('decline', 'call:${_id(7)}:soon');
    route(null, 'https://duvet.chat/conversations/${_id(7)}/${_id(8)}');
    expect(opened, [(_id(7), false), (_id(7), true)]);
    expect(declined, [(_id(7), 1794702917695), (_id(7), 0)]);
    expect(links, ['https://duvet.chat/conversations/${_id(7)}/${_id(8)}']);
  });
}
