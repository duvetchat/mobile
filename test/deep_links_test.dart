import 'dart:async';

import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

/// Message [n]'s link in a conversation: each test opens its own, as a link opens once.
Uri _link(int n) => Uri.parse(
  'https://duvet.chat/conversations/01920000-0000-7000-8000-000000000001/'
  '01920000-0000-7000-8000-${n.toString().padLeft(12, '0')}',
);

void main() {
  late List<Uri> opened;
  late StreamSubscription<Uri> sub;
  setUp(() {
    opened = [];
    sub = DeepLinkSource.tapped.stream.listen(opened.add);
  });
  tearDown(() => sub.cancel());

  test('a tap that launched the app opens the message once signed in, once', () async {
    final profile = ValueNotifier<Profile?>(null);
    // The launch's details and the tap's response both hand it.
    unawaited(openWhenSignedIn(profile, _link(1)));
    unawaited(openWhenSignedIn(profile, _link(1)));
    await pumpEventQueue();
    expect(opened, isEmpty);
    profile.value = FakeRepository.me;
    await pumpEventQueue();
    expect(opened, [_link(1)]);
  });

  test('signed in, a tap opens its message at once', () async {
    await openWhenSignedIn(ValueNotifier<Profile?>(FakeRepository.me), _link(2));
    await pumpEventQueue();
    expect(opened, [_link(2)]);
  });

  test('a tap that waited in vain opens when tapped again', () {
    fakeAsync((async) {
      final profile = ValueNotifier<Profile?>(null);
      unawaited(openWhenSignedIn(profile, _link(4)));
      async.elapse(tapWait + const Duration(seconds: 1));
      profile.value = FakeRepository.me;
      unawaited(openWhenSignedIn(profile, _link(4)));
      async.flushMicrotasks();
      expect(opened, [_link(4)]);
    });
  });

  test('a tap waits 30 s at most for a sign-in', () {
    fakeAsync((async) {
      final profile = ValueNotifier<Profile?>(null);
      unawaited(openWhenSignedIn(profile, _link(3)));
      async.elapse(const Duration(seconds: 31));
      profile.value = FakeRepository.me;
      async.flushMicrotasks();
      expect(opened, isEmpty);
    });
  });
}
