import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/e2e/decrypted_files.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/encryption/recovery_key.dart';
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
import 'package:image/image.dart' as img;

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

    // An encrypted conversation's message this device doesn't hold yet waits for it, with why (Task 17).
    testWidgets(
      'a waiting row, ${b.name}',
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 10, 23, 12)),
        () => withShadows(() async {
          phone(tester);
          final repository = FakeRepository();
          final appearance = Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
          await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
          await tester.pumpAndSettle();
          repository.history['c-maya']!.add(
            ChatMessage(
              id: 'm5',
              authorId: FakeRepository.maya,
              authorName: 'Maya',
              content: '',
              createdAt: DateTime(2026, 10, 23, 9, 5),
              waiting: true,
            ),
          );
          await tester.tap(find.text('Maya'));
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/waiting_${b.name}.png'));
        }),
      ),
    );

    // An encrypted conversation's files on their way down, each with how far it is (Task 19): a picture in its box with
    // its thumbnail, a video, downloaded whole before it plays, and a file to save.
    testWidgets(
      'an attachment downloading, ${b.name}',
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 10, 23, 12)),
        () => withShadows(() async {
          phone(tester);
          DecryptedFiles.instance = DecryptedFiles(folder: () async => Directory.systemTemp)..useOpener(_HeldFiles());
          addTearDown(() => DecryptedFiles.instance.useOpener(null));
          final repository = FakeRepository();
          final appearance = Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
          await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
          await tester.pumpAndSettle();
          final (picture, video, report) = (
            _sealed('p1', 'garden.jpg', 'image/jpeg', 300000, width: 1600, height: 1200, thumbnail: _thumbnail()),
            _sealed('v1', 'tour.mp4', 'video/mp4', 400000),
            _sealed('f1', 'report.pdf', 'application/pdf', 1200000),
          );
          repository.history['c-maya']!.add(
            ChatMessage(
              id: 'm6',
              authorId: FakeRepository.maya,
              authorName: 'Maya',
              content: '',
              createdAt: DateTime(2026, 10, 23, 9, 6),
              attachments: [picture, video, report],
            ),
          );
          for (final file in [picture, video, report]) {
            unawaited(DecryptedFiles.instance.open(file.sealed!, file.url, 'm6'));
          }
          await tester.tap(find.text('Maya'));
          await tester.pumpAndSettle();
          // The thumbnail decoded, as a phone draws it.
          await tester.runAsync(() async {
            for (final element in find.byType(Image).evaluate()) {
              final image = (element.widget as Image).image;
              if ((image is ResizeImage ? image.imageProvider : image) is MemoryImage) {
                await precacheImage(image, element);
              }
            }
          });
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/attachment_downloading_${b.name}.png'));
        }),
      ),
    );

    // #292: the desktop's flat rows: the user's own on the left too, a
    // group's second message under its first, a reply's quote over its head
    // line, and a mention of the user washed.
    testWidgets(
      'chat in flat rows, ${b.name}',
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 10, 23, 12)),
        () => withShadows(() async {
          phone(tester);
          final repository = FakeRepository();
          final appearance = Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light
            ..messageLayout = MessageLayout.flat;
          await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
          await tester.pumpAndSettle();
          repository.history['c-maya']!.addAll([
            FakeRepository.message(
              'm5',
              author: FakeRepository.maya,
              name: 'Maya',
              text: '**Release checklist** for v3:\n- swap to `shadow-float`\n- retest the ||pressed inset||',
              at: DateTime(2026, 10, 23, 9, 1),
              reactions: [
                Reaction(emoji: '👍', users: {FakeRepository.maya, FakeRepository.me.id}),
              ],
            ),
            FakeRepository.message(
              'm6',
              author: FakeRepository.maya,
              name: 'Maya',
              text: '<@${FakeRepository.me.id}> can you check them in dark?',
              at: DateTime(2026, 10, 23, 9, 2),
            ),
            FakeRepository.message(
              'm7',
              author: FakeRepository.me.id,
              name: 'Gaby',
              text: 'Checking dark now',
              at: DateTime(2026, 10, 23, 9, 3),
              reply: const MessageReply(messageId: 'm5', authorName: 'Maya', content: 'Release checklist'),
            ),
          ]);
          await tester.tap(find.text('Maya'));
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/chat_flat_${b.name}.png'));
        }),
      ),
    );

    // Animations off: the bubble lit as it is mid-list.
    testWidgets(
      'a mention of the user lighting its bubble, at rest, ${b.name}',
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 10, 23, 12)),
        () => withShadows(() async {
          phone(tester);
          tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
            disableAnimations: true,
          );
          addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
          final repository = FakeRepository();
          final appearance = Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
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
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/prism_${b.name}.png'));
        }),
      ),
    );

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

    // #284: You, with the desktop's settings sections, each a page of its own.
    testWidgets(
      'you, ${b.name}',
      (tester) => withShadows(() async {
        await app(tester);
        await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('You')));
        await tester.pumpAndSettle();
        await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/you_${b.name}.png'));
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

    // The first device's recovery key, before it's saved (PLAN-E2E-CLIENTES.md, Task 13).
    testWidgets(
      'recovery key, ${b.name}',
      (tester) => withShadows(() async {
        phone(tester);
        await tester.pumpWidget(
          themed(
            b,
            RecoveryKeyPage(
              recoveryKey: 'abcdEFGHjkmnPQRS23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
              onSaved: () async {},
              onLater: () async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/recovery_key_${b.name}.png'));
      }),
    );
  }
}

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// Files whose downloads stop where [share] of them came, for good: they stay on their way.
class _HeldFiles implements FileOpener {
  static const share = 0.42;

  @override
  Future<Uint8List> download(String id, String url, int most, void Function(int received)? progress) {
    progress?.call((most * share).floor());
    return Completer<Uint8List>().future;
  }

  @override
  Future<Uint8List> open(String key, String id, Uint8List sealed, void Function(int done)? progress) =>
      Completer<Uint8List>().future;

  @override
  void failed() {}
}

/// A file of an encrypted conversation's message, sealed, of [size] bytes, its sides and its thumbnail as it says.
MessageAttachment _sealed(
  String id,
  String name,
  String said,
  int size, {
  int? width,
  int? height,
  String? thumbnail,
}) => MessageAttachment(
  id: id,
  filename: name,
  contentType: said,
  url: 'https://api.duvet.test/attachments/$id?sig=golden&exp=4102444800',
  sizeBytes: size,
  sealed: ShownFile(
    id: id,
    key: 'a2V5',
    sha256: 'c2hh',
    size: size,
    name: name,
    said: said,
    width: width,
    height: height,
    thumbnail: thumbnail,
  ),
);

/// A picture's thumbnail as its message carries it: 32 × 24, a green field under a darker sky.
String _thumbnail() {
  final picture = img.Image(width: 32, height: 24);
  for (final pixel in picture) {
    pixel
      ..r = pixel.y < 10 ? 40 : 90
      ..g = pixel.y < 10 ? 70 : 150
      ..b = pixel.y < 10 ? 120 : 70;
  }
  return base64Encode(img.encodePng(picture));
}
