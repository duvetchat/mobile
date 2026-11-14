import 'package:clock/clock.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/people.dart' show RoleChip;
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/glass.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'support/fake_repository.dart';
import 'support/fonts.dart';

/// The design-system components and screens, drawn in both themes. Update
/// them with `flutter test --update-goldens test/goldens_test.dart`.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    await loadAppFonts();
    final icons = FontLoader('packages/forui_lucide/ForuiLucideIcons')
      ..addFont(rootBundle.load('packages/forui_lucide/assets/lucide.ttf'));
    await icons.load();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  void phone(WidgetTester tester, {double height = 844}) {
    tester.view.physicalSize = Size(390 * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  // Real soft shadows, not the test binding's solid stand-ins, while [body]
  // runs.
  Future<void> withShadows(Future<void> Function() body) async {
    debugDisableShadows = false;
    try {
      await body();
    } finally {
      debugDisableShadows = true;
    }
  }

  Widget themed(Brightness b, Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: Duvet.material(b),
    home: FTheme(
      data: Duvet.theme(b),
      child: Scaffold(backgroundColor: Duvet.theme(b).colors.background, body: child),
    ),
  );

  for (final b in Brightness.values) {
    testWidgets(
      'components, ${b.name}',
      (tester) => withShadows(() async {
        phone(tester, height: 1040);
        await tester.pumpWidget(
          themed(
            b,
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Overline('Information'),
                  const ListRow(
                    title: 'announcements',
                    hash: true,
                    snippet: 'Ana: Crit night moves to Thursday',
                    unread: true,
                  ),
                  const ListRow(title: 'design-crit', hash: true, snippet: 'Jon: pushed v3 of the cards'),
                  const ListRow(title: 'general', hash: true, snippet: 'Sam: coffee after?', selected: true),
                  const ListRow(
                    title: 'Maya Okafor',
                    snippet: 'sent the new shadow tokens ok?',
                    trailing: '9:41',
                    mentions: 2,
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: SpaceCard(
                            space: const Space(id: 'a', name: 'Design Guild', onlineCount: 128),
                            onTap: () {},
                            unread: true,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SpaceCard(
                            space: const Space(id: 'b', name: 'Bogotá Night Runners', onlineCount: 7),
                            onTap: () {},
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        DuvetButton(label: 'Join', variant: ButtonVariant.primary, onPressed: () {}),
                        const SizedBox(width: 8),
                        DuvetButton(label: 'Invite', onPressed: () {}),
                        const SizedBox(width: 8),
                        DuvetButton(label: 'Leave', variant: ButtonVariant.destructive, onPressed: () {}),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SearchField()),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GlassSurface(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            GlassRow(icon: FLucideIcons.reply, label: 'Reply', onPressed: () {}),
                            GlassRow(icon: FLucideIcons.trash2, label: 'Delete', destructive: true, onPressed: () {}),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  DuvetTabBar(
                    index: 1,
                    items: const [
                      (icon: FLucideIcons.messageCircle, label: 'Chats'),
                      (icon: FLucideIcons.layoutGrid, label: 'Spaces'),
                      (icon: FLucideIcons.phone, label: 'Calls'),
                      (icon: FLucideIcons.user, label: 'You'),
                    ],
                    onChange: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/components_${b.name}.png'));
      }),
    );

    testWidgets(
      'chat, ${b.name}',
      // On the messages' day, so the separator says "Today" whenever it runs.
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 10, 23, 12)),
        () => withShadows(() async {
          phone(tester);
          final repository = FakeRepository();
          final appearance = Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
          await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
          await tester.pumpAndSettle();
          repository.history['c-maya']!.addAll([
            FakeRepository.message(
              'm5',
              author: FakeRepository.maya,
              name: 'Maya',
              text: '**Release checklist** for v3:\n- swap to `shadow-float`\n- retest the ||pressed inset||',
              reactions: [
                Reaction(emoji: '👍', users: {FakeRepository.maya, FakeRepository.me.id}),
              ],
            ),
            FakeRepository.message(
              'm6',
              author: FakeRepository.me.id,
              name: 'Gaby',
              text: 'Checking dark now',
              reply: const MessageReply(messageId: 'm5', authorName: 'Maya', content: 'Release checklist'),
            ),
          ]);
          await tester.tap(find.text('Maya'));
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/chat_${b.name}.png'));
        }),
      ),
    );

    // Prism is dark's alone so far. Animations off: the bubble lit as it is mid-list.
    if (b == Brightness.dark) {
      testWidgets(
        'a mention of the user lighting its bubble, at rest',
        (tester) => withClock(
          Clock.fixed(DateTime(2026, 10, 23, 12)),
          () => withShadows(() async {
            phone(tester);
            tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
              disableAnimations: true,
            );
            addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
            final repository = FakeRepository();
            final appearance = Appearance(MemoryAppearanceStore())..value = ThemeMode.dark;
            await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
            await tester.pumpAndSettle();
            repository.history['c-maya']!.add(
              FakeRepository.message(
                'm5',
                author: FakeRepository.maya,
                name: 'Maya',
                text: '<@${FakeRepository.me.id}> can you check the bubble shadows before we ship Friday?',
              ),
            );
            await tester.tap(find.text('Maya'));
            await tester.pumpAndSettle();
            await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/prism_dark.png'));
          }),
        ),
      );
    }

    // The ghost in the screens: Welcome, a tab root's night sky, a new DM.
    Future<FakeRepository> app(WidgetTester tester, {bool signedIn = true}) async {
      phone(tester);
      final repository = FakeRepository(signedIn: signedIn);
      final appearance = Appearance(MemoryAppearanceStore())
        ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
      await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets(
      'welcome, ${b.name}',
      (tester) => withShadows(() async {
        await app(tester, signedIn: false);
        await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/welcome_${b.name}.png'));
      }),
    );

    testWidgets(
      'chats, ${b.name}',
      (tester) => withShadows(() async {
        await app(tester);
        await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/chats_${b.name}.png'));
      }),
    );

    testWidgets(
      'empty DM, ${b.name}',
      (tester) => withShadows(() async {
        await app(tester);
        await tester.tap(find.text('Leo'));
        await tester.pumpAndSettle();
        await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/empty_dm_${b.name}.png'));
      }),
    );

    // #215: a profile's roles, held ones in their color or gradient.
    testWidgets('role chips, ${b.name}', (tester) async {
      phone(tester, height: 120);
      await tester.pumpWidget(
        themed(
          b,
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                const RoleChip(role: RoleTag('Moderator', color: 0x30A46C)),
                const RoleChip(role: RoleTag('Designer', color: 0x8E4EC6, colorVia: 0xD6409F, colorTo: 0xF76B15)),
                const RoleChip(role: RoleTag('Plain')),
                RoleChip(role: const RoleTag('Helpers', color: 0xE5484D), held: false, onTap: () {}),
                RoleChip(role: const RoleTag('Crew', color: 0x0090FF, colorTo: 0xD6A400), held: false, onTap: () {}),
                RoleChip(role: const RoleTag('Guests'), held: false, onTap: () {}),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/role_chips_${b.name}.png'));
    });
  }
}

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}
