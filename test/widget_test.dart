import 'dart:async';
import 'dart:io';

import 'package:duvet/account.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:duvet/members_sheet.dart';
import 'package:duvet/push/registration.dart';
import 'package:duvet/tabs.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/facehash.dart';
import 'package:duvet/widgets/ghost_art.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'support/fake_repository.dart';

/// A repository whose restores the test answers, each in turn. With [keptHome] its profile and lists show before the
/// answer, as a session whose home was kept has them.
class _HeldRestore extends FakeRepository {
  final bool keptHome;
  _HeldRestore({this.keptHome = false});

  final restores = <Completer<bool>>[];

  @override
  Future<bool> restore() {
    if (keptHome) super.restore();
    restores.add(Completer());
    return restores.last.future;
  }

  /// The API answered: the session is up.
  void signIn() => super.restore();
}

/// A push registrar that counts the times the phone is unregistered.
class _CountedRegistrar implements PushRegistrar {
  int unregisters = 0;

  @override
  Future<bool> allowed() async => true;

  @override
  Future<void> register() async {}

  @override
  Stream<String> get registered => const Stream.empty();

  @override
  Future<void> unregister() async => unregisters++;
}

/// A repository that counts the times its storage is asked for.
class _CountedStorage extends FakeRepository {
  int asked = 0;

  @override
  Future<StorageInfo> storage() {
    asked++;
    return super.storage();
  }
}

/// The app's assets, and each one asked of it.
class _CountedAssets extends CachingAssetBundle {
  final asked = <String>[];

  @override
  Future<ByteData> load(String key) {
    asked.add(key);
    return rootBundle.load(key);
  }
}

void main() {
  Future<FakeRepository> pumpApp(WidgetTester tester, {bool signedIn = true}) async {
    final repository = FakeRepository(signedIn: signedIn);
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> openMaya(WidgetTester tester) async {
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
  }

  // Signed out, Welcome comes first; its Sign in opens the form.
  Future<void> openSignIn(WidgetTester tester) async {
    expect(find.text('Talk with your people.'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to Duvet'), findsOneWidget);
  }

  group('the session gate', () {
    testWidgets('shows the app as soon as there is a profile, the restore still on its way', (tester) async {
      final repository = _HeldRestore(keptHome: true);
      await tester.pumpWidget(DuvetApp(repository: repository));
      await tester.pumpAndSettle();
      expect(find.byType(HomeTabs), findsOneWidget);
      expect(find.text('Maya'), findsOneWidget);
      final shown = tester.state(find.byType(HomeTabs));

      // The restore's answer changes nothing of it.
      repository.restores.single.complete(true);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(HomeTabs)), same(shown));

      // The session found ended: the welcome screen, with no spinner on the way.
      await repository.endSession();
      await tester.pump();
      expect(find.byType(HomeTabs), findsNothing);
      expect(find.text('Talk with your people.'), findsOneWidget);
    });

    testWidgets('waits with no profile, and an unreachable server offers to try again', (tester) async {
      final repository = _HeldRestore();
      await tester.pumpWidget(DuvetApp(repository: repository));
      await tester.pump();
      expect(find.byType(FCircularProgress), findsOneWidget);
      expect(find.byType(HomeTabs), findsNothing);

      repository.restores.single.completeError(const SocketException('no network'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t reach Duvet'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(repository.restores, hasLength(2));
      expect(find.byType(FCircularProgress), findsOneWidget);
      repository.signIn();
      repository.restores.last.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(HomeTabs), findsOneWidget);
    });

    testWidgets('signed out, or the session gone, it shows the welcome screen', (tester) async {
      final repository = _HeldRestore();
      await tester.pumpWidget(DuvetApp(repository: repository));
      await tester.pump();
      repository.restores.single.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Talk with your people.'), findsOneWidget);

      // Unreachable, then signing in instead.
      final other = _HeldRestore();
      await tester.pumpWidget(DuvetApp(key: UniqueKey(), repository: other));
      await tester.pump();
      other.restores.single.completeError(const SocketException('no network'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in instead'));
      await tester.pumpAndSettle();
      expect(find.text('Talk with your people.'), findsOneWidget);
    });

    // main() starts the restore before the app's widgets: the gate follows that one, and starts none of its own.
    testWidgets('follows a restore started before it, and starts another only to try again', (tester) async {
      final repository = _HeldRestore();
      final started = StartedRestore(repository.restore());
      await tester.pumpWidget(DuvetApp(repository: repository, restoring: started));
      await tester.pump();
      expect(repository.restores, hasLength(1));
      expect(find.byType(FCircularProgress), findsOneWidget);

      repository.restores.single.completeError(const SocketException('no network'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t reach Duvet'), findsOneWidget);

      // Trying again restores afresh, and the failure before it shows no more.
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(repository.restores, hasLength(2));
      expect(find.byType(FCircularProgress), findsOneWidget);
      repository.signIn();
      repository.restores.last.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(HomeTabs), findsOneWidget);
    });

    // A future tells of its answer a turn after the first build: the gate reads the outcome kept beside it.
    testWidgets('a restore that ended before the first frame shows its outcome in it, with no spinner', (tester) async {
      final repository = _HeldRestore();
      final started = StartedRestore(repository.restore());
      expect(started.outcome, isNull);
      repository.restores.single.complete(false);
      await tester.pump();
      expect(started.outcome?.data, isFalse);
      // One frame, and no more.
      await tester.pumpWidget(DuvetApp(repository: repository, restoring: started));
      expect(find.byType(FCircularProgress), findsNothing);
      expect(find.text('Talk with your people.'), findsOneWidget);
      expect(repository.restores, hasLength(1));
      await tester.pumpAndSettle();
      expect(find.text('Talk with your people.'), findsOneWidget);
    });

    // Nobody follows the restore until the gate builds: its failure waits there, and fails nothing.
    testWidgets('a restore that failed before the first frame offers to try again in it', (tester) async {
      final repository = _HeldRestore();
      final started = StartedRestore(repository.restore());
      repository.restores.single.completeError(const SocketException('no network'));
      await tester.pump();
      expect(started.outcome?.hasError, isTrue);
      await tester.pumpWidget(DuvetApp(repository: repository, restoring: started));
      expect(find.byType(FCircularProgress), findsNothing);
      expect(find.text('Couldn’t reach Duvet'), findsOneWidget);

      await tester.tap(find.text('Sign in instead'));
      await tester.pumpAndSettle();
      expect(find.text('Talk with your people.'), findsOneWidget);
      expect(repository.restores, hasLength(1));
    });

    // The API may refuse the session main() restores before the app's widgets are there to hear of the sign-out.
    testWidgets('a session that ended before the app was built still unregisters the phone', (tester) async {
      final repository = FakeRepository();
      final started = StartedRestore(Future.value(false), signedOut: repository.signedOut);
      expect(started.signedOut, isFalse);
      await repository.endSession();
      expect(started.signedOut, isTrue);
      final registrar = _CountedRegistrar();
      await tester.pumpWidget(DuvetApp(repository: repository, push: registrar, restoring: started));
      expect(registrar.unregisters, 1);
      await tester.pumpAndSettle();
      expect(find.text('Talk with your people.'), findsOneWidget);

      // One that didn't end unregisters nothing.
      final signedIn = FakeRepository();
      final other = _CountedRegistrar();
      await tester.pumpWidget(
        DuvetApp(
          key: UniqueKey(),
          repository: signedIn,
          push: other,
          restoring: StartedRestore(signedIn.restore(), signedOut: signedIn.signedOut),
        ),
      );
      await tester.pumpAndSettle();
      expect(other.unregisters, 0);
    });
  });

  group('the tabs', () {
    const names = ['Chats', 'Spaces', 'Calls', 'You'];
    // Each tab that's built, showing or behind the one that is.
    List<String> built() => [
      for (final (i, tab) in const [ChatsTab, SpacesTab, CallsTab, YouTab].indexed)
        if (find.byType(tab, skipOffstage: false).evaluate().isNotEmpty) names[i],
    ];
    Future<void> select(WidgetTester tester, String tab) =>
        tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text(tab)));
    // The home's first frame: the restore answers in the one before it.
    Future<T> pumpHome<T extends FakeRepository>(WidgetTester tester, T repository) async {
      await tester.pumpWidget(DuvetApp(repository: repository));
      await tester.pump();
      expect(find.byType(HomeTabs), findsOneWidget);
      return repository;
    }

    testWidgets('only the open one is built at first, and the others once the home is still', (tester) async {
      await pumpHome(tester, FakeRepository());
      expect(built(), ['Chats']);
      expect(find.text('Maya'), findsOneWidget);

      // Not in the frames after it, while the home is still coming up (its icon hops).
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(built(), ['Chats'], reason: 'frame $frame');
      }
      expect(tester.hasRunningAnimations, isTrue);

      // Still, the others come one a frame.
      for (var frame = 0; tester.hasRunningAnimations && frame < 100; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.hasRunningAnimations, isFalse);
      expect(built(), ['Chats']);
      await tester.pump();
      expect(built(), ['Chats', 'Spaces']);
      await tester.pump();
      expect(built(), ['Chats', 'Spaces', 'Calls']);
      await tester.pump();
      expect(built(), names);
      await tester.pumpAndSettle();
      // Behind the open one: Chats is all there is to see.
      expect(find.byType(SpacesTab), findsNothing);
      expect(find.byType(ChatsTab), findsOneWidget);
    });

    testWidgets('a tab is built when it is picked, and keeps its state from then on', (tester) async {
      await pumpHome(tester, FakeRepository());
      await select(tester, 'You');
      await tester.pump();
      expect(built(), ['Chats', 'You']);
      expect(find.byType(YouTab), findsOneWidget);
      final you = tester.state(find.byType(YouTab));
      final chats = tester.element(find.byType(ChatsTab, skipOffstage: false));

      // Scrolled down, to find it there again.
      await tester.pumpAndSettle();
      await tester.drag(find.byType(YouTab), const Offset(0, -300));
      await tester.pumpAndSettle();
      final scrolled = tester.state<ScrollableState>(
        find.descendant(of: find.byType(YouTab), matching: find.byType(Scrollable)).first,
      );
      final offset = scrolled.position.pixels;
      expect(offset, greaterThan(0));

      // The others built meanwhile, another tab picked and this one again: the same tabs, as they were left.
      expect(built(), names);
      await select(tester, 'Calls');
      await tester.pumpAndSettle();
      expect(find.byType(CallsTab), findsOneWidget);
      expect(find.byType(YouTab), findsNothing);
      await select(tester, 'You');
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(YouTab)), same(you));
      expect(tester.element(find.byType(ChatsTab, skipOffstage: false)), same(chats));
      expect(scrolled.position.pixels, offset);

      // And across the layouts, a wide window and back.
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1194, 834) * 2;
      await tester.pumpAndSettle();
      expect(find.byType(DuvetNavRail), findsOneWidget);
      expect(tester.state(find.byType(YouTab)), same(you));
      tester.view.physicalSize = const Size(390, 844) * 2;
      await tester.pumpAndSettle();
      expect(find.byType(DuvetTabBar), findsOneWidget);
      expect(tester.state(find.byType(YouTab)), same(you));
      expect(tester.element(find.byType(ChatsTab, skipOffstage: false)), same(chats));
    });

    testWidgets('a wide window has Spaces built with the first, for its rail', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1194, 834) * 2;
      await pumpHome(tester, FakeRepository());
      expect(built(), ['Chats', 'Spaces']);

      // The first tap on a Space opens that Space, not the Spaces tab's root.
      await tester.tap(find.byType(RailButton).first);
      await tester.pumpAndSettle();
      expect(find.byType(SpaceDirectory), findsOneWidget);
      expect(find.text('# general'), findsOneWidget);
    });

    testWidgets('a window grown wide before Spaces was built builds it then', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(390, 844) * 2;
      await pumpHome(tester, FakeRepository());
      expect(built(), ['Chats']);
      final chats = tester.element(find.byType(ChatsTab));

      tester.view.physicalSize = const Size(1194, 834) * 2;
      await tester.pump();
      expect(built(), ['Chats', 'Spaces']);
      expect(tester.element(find.byType(ChatsTab)), same(chats));
      await tester.tap(find.byType(RailButton).first);
      await tester.pumpAndSettle();
      expect(find.byType(SpaceDirectory), findsOneWidget);
    });

    testWidgets('You asks for the storage each time it comes into view, and at no other', (tester) async {
      final repository = await pumpHome(tester, _CountedStorage());
      // Built behind Chats, it asks for nothing.
      await tester.pumpAndSettle();
      expect(built(), names);
      expect(repository.asked, 0);

      await select(tester, 'You');
      await tester.pumpAndSettle();
      expect(repository.asked, 1);

      // A theme's change reaches the tab every frame of its fade, and asks nothing more.
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final before = Theme.of(tester.element(find.byType(YouTab))).brightness;
      tester.platformDispatcher.platformBrightnessTestValue = before == Brightness.dark
          ? Brightness.light
          : Brightness.dark;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byType(YouTab))).brightness, isNot(before));
      expect(repository.asked, 1);

      await select(tester, 'Chats');
      await tester.pumpAndSettle();
      expect(repository.asked, 1);
      await select(tester, 'You');
      await tester.pumpAndSettle();
      expect(repository.asked, 2);
    });

    testWidgets('You asks for the storage when it is the tab picked first', (tester) async {
      final repository = await pumpHome(tester, _CountedStorage());
      await select(tester, 'You');
      await tester.pumpAndSettle();
      expect(repository.asked, 1);
    });

    testWidgets('the app\'s icon is parsed while the session restores, once for every screen after', (tester) async {
      const icon = 'assets/logo/app-icon-rounded.svg';
      final assets = _CountedAssets();
      final repository = _HeldRestore();
      await tester.pumpWidget(
        DefaultAssetBundle(
          bundle: assets,
          child: DuvetApp(repository: repository),
        ),
      );
      await tester.pump();
      expect(find.byType(FCircularProgress), findsOneWidget);
      expect(find.byType(AppIcon), findsNothing);
      expect(assets.asked.where((a) => a == icon), hasLength(1));

      // The icon the home builds finds the picture kept: the file isn't read again.
      repository.signIn();
      repository.restores.single.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(AppIcon), findsOneWidget);
      for (final tab in names.skip(1)) {
        await select(tester, tab);
        await tester.pumpAndSettle();
      }
      expect(assets.asked.where((a) => a == icon), hasLength(1));
    });
  });

  testWidgets('signing in shows the conversations', (tester) async {
    await pumpApp(tester, signedIn: false);
    await openSignIn(tester);

    await tester.enterText(find.byType(EditableText).at(0), 'gaby@duvet.chat');
    await tester.enterText(find.byType(EditableText).at(1), 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t reach Duvet. Check your connection.'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).at(1), 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('4 members'), findsOneWidget);
  });

  // forui's delegates bring material_ui's localizations, and the framework's TextField reads its own: without
  // flutter_localizations' too, only English had them, and in any other language the fields failed to build.
  testWidgets('signing in works in another language', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es', 'ES')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await pumpApp(tester, signedIn: false);
    await openSignIn(tester);

    await tester.enterText(find.byType(EditableText).at(0), 'gaby@duvet.chat');
    await tester.enterText(find.byType(EditableText).at(1), 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
  });

  testWidgets('a DM shows the other person\'s presence, in the chats list and its top bar, as it changes', (
    tester,
  ) async {
    final repository = await pumpApp(tester);
    Finder dot(String userId, Presence? presence) =>
        find.byWidgetPredicate((w) => w is PresenceAvatar && w.member.userId == userId && w.presence == presence);
    Finder inTopBar(String text) => find.descendant(of: find.byType(GlassTopBar), matching: find.text(text));
    expect(dot(FakeRepository.maya, Presence.online), findsOneWidget);
    expect(dot(FakeRepository.leo, null), findsOneWidget, reason: 'nothing told about Leo: no dot');
    expect(find.byType(PresenceAvatar), findsNWidgets(2), reason: 'a group has none');

    await openMaya(tester);
    expect(inTopBar('Online'), findsOneWidget);
    repository.presence.value = {FakeRepository.maya: Presence.doNotDisturb};
    await tester.pump();
    expect(inTopBar('Do not disturb'), findsOneWidget);
    repository.presence.value = {FakeRepository.maya: Presence.offline};
    await tester.pump();
    expect(inTopBar('Offline'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(dot(FakeRepository.maya, Presence.offline), findsOneWidget);
    await tester.tap(find.text('Design crew'));
    await tester.pumpAndSettle();
    expect(inTopBar('Offline'), findsNothing);
    expect(inTopBar('Online'), findsNothing);
  });

  // #84: someone connected only from the mobile app shows a phone rather than the dot.
  testWidgets('a DM\'s avatar in the chats list shows a phone while its person is connected only on mobile', (
    tester,
  ) async {
    final repository = await pumpApp(tester);
    Finder phoneOf(String userId) => find.descendant(
      of: find.byWidgetPredicate((w) => w is PresenceAvatar && w.member.userId == userId),
      matching: find.byType(PresencePhone),
    );
    expect(phoneOf(FakeRepository.maya), findsNothing);

    repository.mobileOnly.value = {FakeRepository.maya};
    await tester.pump();
    expect(phoneOf(FakeRepository.maya), findsOneWidget);
    // Offline, the ring, as anyone's.
    repository.presence.value = {FakeRepository.maya: Presence.offline};
    await tester.pump();
    expect(phoneOf(FakeRepository.maya), findsNothing);
  });

  testWidgets('a chat loads its history and takes live messages', (tester) async {
    final repository = await pumpApp(tester);
    final unreadTitle = tester.widget<Text>(find.text('Maya'));
    expect(unreadTitle.style?.fontWeight, FontWeight.w700);

    await openMaya(tester);
    expect(find.text('Hey! Did you see the new tab bar?'), findsOneWidget);
    expect(find.text('Yes, way better than the side panels.'), findsOneWidget);
    expect(repository.reads.last, (const ConversationTarget('c-maya'), 'm2'));
    expect(repository.unread.value, isNot(contains('c-maya')));

    repository.pushTyping('c-maya', const TypingUser(userId: FakeRepository.maya, name: 'Maya'));
    // A broadcast stream delivers in a microtask, after the first frame.
    await tester.pump();
    await tester.pump();
    expect(find.text('Maya is typing…'), findsOneWidget);

    repository.push(
      'c-maya',
      MessageCreated(FakeRepository.message('m4', author: FakeRepository.maya, name: 'Maya', text: 'Shipping it')),
    );
    await tester.pump();
    expect(find.text('Shipping it'), findsOneWidget);
    expect(find.text('Maya is typing…'), findsNothing);
    // The open chat stays read.
    expect(repository.unread.value, isNot(contains('c-maya')));

    // Someone's delete: its place eases shut, then it's gone.
    repository.push('c-maya', const MessageDeleted('m4'));
    await tester.pump();
    expect(find.text('Shipping it'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Shipping it'), findsNothing);
  });

  testWidgets('a sent message shows once, even when the gateway echo comes first', (tester) async {
    final repository = await pumpApp(tester);
    await openMaya(tester);

    repository.holdSends = Completer();
    await tester.enterText(find.byType(EditableText), 'On my way');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pump();
    expect(find.text('On my way'), findsOneWidget);
    expect(repository.sent.single.content, 'On my way');

    // The gateway's echo carries the nonce the composer sent.
    final nonce = repository.sent.single.nonce;
    repository.push(
      'c-maya',
      MessageCreated(
        FakeRepository.message('sent-1', author: FakeRepository.me.id, name: 'Gaby', text: 'On my way', nonce: nonce),
      ),
    );
    await tester.pump();
    repository.holdSends!.complete();
    await tester.pumpAndSettle();
    expect(find.text('On my way'), findsOneWidget);
  });

  testWidgets('spaces drill down to a room', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    expect(find.text('Design Guild'), findsOneWidget);

    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    expect(find.text('VOICE'), findsOneWidget);
    // Each room previews its last message.
    expect(find.text('Leo: Pushed the new type ramp'), findsOneWidget);
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    expect(find.text('Pushed the new type ramp'), findsOneWidget);
  });

  testWidgets('an opened room joins the recent chats', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Spaces').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chats').last);
    await tester.pumpAndSettle();
    // "# room · Space" over "Author: text".
    expect(find.text('# general · Design Guild'), findsOneWidget);
    expect(find.text('Leo: Pushed the new type ramp'), findsOneWidget);
    // The DMs never opened here still follow.
    expect(find.text('Leo'), findsOneWidget);
  });

  testWidgets('back in front, the app tells the session, which renews if that came due', (tester) async {
    final repository = await pumpApp(tester);
    expect(repository.cameToFrontTimes, 0);
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(repository.cameToFrontTimes, 0);
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(repository.cameToFrontTimes, 1);
  });

  // FCM counts the app in front from the moment it shows, and hands it messages from then (lib/push): its own notices
  // come back then too, not once it's resumed.
  testWidgets('in sight again, the app is in front at once; out of sight, in the background', (tester) async {
    final repository = await pumpApp(tester);
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect((repository.wentToBackTimes, repository.cameToFrontTimes), (1, 0));
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(repository.cameToFrontTimes, 1);
  });

  // audio_service starts an engine of its own for its media service, which runs main() with no state and no screen:
  // its notices keep quiet, as the phone's notifications tell of what comes, until a screen shows it.
  test('the app shows as it starts when its state says so, or before any state with a screen to show on', () {
    expect(shownAtStart(AppLifecycleState.resumed, Size.zero), isTrue);
    expect(shownAtStart(AppLifecycleState.inactive, Size.zero), isTrue);
    expect(shownAtStart(null, const Size(1080, 2400)), isTrue);
    expect(shownAtStart(null, Size.zero), isFalse);
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached]) {
      expect(shownAtStart(state, const Size(1080, 2400)), isFalse, reason: '$state');
    }
  });

  testWidgets('a notification that started the app on screen is read at once', (tester) async {
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    var reads = 0;
    await tester.pumpWidget(DuvetApp(repository: FakeRepository(), readLaunch: () => reads++));
    expect(reads, 1);
  });

  testWidgets('signing out returns to the login screen', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('You').last);
    await tester.pumpAndSettle();
    expect(find.text('@gaby'), findsOneWidget);

    // Below the fold, so not built yet: dragged into view.
    await tester.scrollUntilVisible(find.text('Sign out'), 200, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Talk with your people.'), findsOneWidget);
  });

  test('facehash hashes names as facehash-sv does', () {
    // Reference values from facehash-sv's stringHash, run in Node.
    expect(Facehash.hash('Maya'), 2390972);
    expect(Facehash.hash('Duvet'), 66401620);
    expect(Facehash.hash('gaby'), 3164849);
    expect(Facehash.hash('a much longer display name to overflow 32 bits'), 401172730);
    expect(Facehash.hash('ñandú 🐢'), 1745150799);
  });

  testWidgets('an avatar stays round in a wider gutter', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          child: SizedBox(width: 40, child: UserAvatar(name: 'maya', size: 32)),
        ),
      ),
    );
    expect(tester.getSize(find.byType(Facehash)), const Size(32, 32));
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('facehash shows the initial as its mouth until it talks', (tester) async {
    Widget face(double mouthOpen) => MaterialApp(
      home: Facehash(name: 'maya', mouthOpen: mouthOpen),
    );
    await tester.pumpWidget(face(0));
    expect(find.text('M'), findsOneWidget);
    await tester.pumpWidget(face(0.5));
    expect(find.text('M'), findsNothing);
    // Let a blink run its course, then tear down with no timer left.
    await tester.pump(const Duration(seconds: 7));
  });
}
