import 'package:duvet/data/call_history.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/voice.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/people.dart' show PersonRow;
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'support/fake_repository.dart';
import 'support/fake_voice.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

const _maya = FakeRepository.maya;
const _noorBanner = 'https://example.invalid/noor-banner.png';
const _samBanner = 'https://example.invalid/sam-banner.png';
const _mayaBanner = 'https://example.invalid/maya-banner.png';

// In #general besides the usual three: Noor and Sam, each with a banner.
const _noor = Member(userId: 'u-noor', username: 'noor', alias: 'Noor', bannerUrl: _noorBanner);
const _sam = Member(userId: 'u-sam', username: 'sam', alias: 'Sam', bannerUrl: _samBanner);

/// The banners behind what's shown, by URL: the decoration image each is.
Map<String, DecorationImage> _shown(WidgetTester tester) => {
  for (final box in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)))
    if ((box.decoration as BoxDecoration?)?.image case final image?
        when image.image is ResizeImage && (image.image as ResizeImage).imageProvider is NetworkImage)
      ((image.image as ResizeImage).imageProvider as NetworkImage).url: image,
};

/// Each banner's opacity, by URL.
Map<String, double> _banners(WidgetTester tester) => {
  for (final MapEntry(:key, :value) in _shown(tester).entries) key: value.opacity,
};

/// Issue #43: members' banners, faintly behind them wherever they're listed.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<FakeRepository> pumpApp(WidgetTester tester, {void Function(FakeRepository r)? setUp}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    setUp?.call(repository);
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> openGeneral(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
  }

  Future<void> openMembers(WidgetTester tester) async {
    await openGeneral(tester);
    await tapLabel(tester, 'More');
    await tapLabel(tester, 'Members');
  }

  void inGeneral(FakeRepository r) => r
    ..extraRoomMembers.addAll([_noor, _sam])
    ..presence.value = {'u-noor': Presence.online, 'u-sam': Presence.offline};

  testWidgets('the member list: behind those who have one, fainter while they\'re offline', (tester) async {
    await pumpApp(tester, setUp: inGeneral);
    await openMembers(tester);
    expect(_banners(tester), {_noorBanner: 0.15, _samBanner: 0.09}, reason: 'none for those without one');
    semantics.dispose();
  });

  testWidgets('only a look: the row reads as it did', (tester) async {
    await pumpApp(tester, setUp: inGeneral);
    await openMembers(tester);
    expect(find.bySemanticsLabel('Noor, Online · @noor'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('decoded once, at one size whatever the row: half the screen\'s pixels, never past the upload\'s', (
    tester,
  ) async {
    await pumpApp(tester, setUp: inGeneral);
    await openMembers(tester);
    for (final image in _shown(tester).values) {
      final resized = image.image as ResizeImage;
      expect(resized.width, (390 * 3 / 2).round());
      expect(resized.allowUpscaling, isFalse);
    }
    semantics.dispose();
  });

  testWidgets('@ suggestions: faded as the member list fades them, by their presence in the Space', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) => r
        ..extraRoomMembers.addAll([_noor, _sam])
        // Noor is online, but not in this Space; Sam's presence isn't known.
        ..presence.value = {'u-noor': Presence.online, spacePresenceKey('u-noor', 's-guild'): Presence.offline},
    );
    await openGeneral(tester);
    await tester.enterText(find.byType(EditableText), 'hi @');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Noor, @noor'), findsOneWidget);
    expect(_banners(tester), {_noorBanner: 0.09, _samBanner: 0.09});
    semantics.dispose();
  });

  testWidgets('friends: behind them, and still there while the row is pressed', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) => r.friendsOnServer = const Friends(
        friends: [Member(userId: _maya, username: 'maya', alias: 'Maya', bannerUrl: _mayaBanner)],
      ),
    );
    await tester.tap(find.bySemanticsLabel('Friends').hitTestable().first);
    await tester.pumpAndSettle();
    expect(_banners(tester), {_mayaBanner: 0.15}, reason: 'Maya is online');

    final press = await tester.startGesture(tester.getCenter(find.text('Maya').last));
    await tester.pumpAndSettle();
    final pressed = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((b) => b.decoration as BoxDecoration?)
        .firstWhere((d) => d?.image != null)!;
    expect(pressed.color, isNot(Colors.transparent), reason: 'pressed');
    expect(pressed.image, isNotNull, reason: 'the banner over the press, not under it');
    await press.cancel();
    semantics.dispose();
  });

  testWidgets('a row to pick someone: their banner behind, read as a pick', (tester) async {
    semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: Duvet.material(Brightness.light),
        home: FTheme(
          data: Duvet.theme(Brightness.light),
          child: Scaffold(
            body: PersonRow(member: _sam, presence: Presence.online, checked: true, onTap: () {}),
          ),
        ),
      ),
    );
    expect(_banners(tester), {_samBanner: 0.15});
    final node = tester.getSemantics(find.byType(PersonRow));
    expect(node.label, 'Sam, @sam');
    expect(node.flagsCollection.isChecked.toString(), contains('isTrue'));
    semantics.dispose();
  });

  testWidgets('a voice room: behind the tile of whoever is in it', (tester) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository()
      ..people = [
        for (final m in FakeRepository.everyone)
          m.userId == _maya ? const Member(userId: _maya, username: 'maya', alias: 'Maya', bannerUrl: _mayaBanner) : m,
      ];
    final voice = VoiceController(
      repository: repository,
      engine: FakeVoiceEngine(),
      historyStore: MemoryCallHistoryStore(),
      clock: () => DateTime(2026, 10, 26, 10),
    );
    await tester.pumpWidget(DuvetApp(repository: repository, voice: voice));
    await tester.pumpAndSettle();
    repository.voiceSignaling.push(
      const duvet.VoiceStateUpdatedEvent(
        duvet.VoiceStateEvent(roomId: 'r-lounge', userId: _maya, joined: true, muted: false, version: 3),
      ),
    );
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('lounge'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.bySemanticsLabel('Maya'), findsOneWidget);
    expect(_banners(tester), {_mayaBanner: 0.15});
    await tester.pumpWidget(const SizedBox());
    voice.dispose();
    semantics.dispose();
  });
}
