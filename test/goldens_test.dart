import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/e2e/decrypted_files.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/encryption/approval.dart' show ApprovalView;
import 'package:duvet/encryption/device_setup.dart';
import 'package:duvet/encryption/recovery_key.dart';
import 'package:duvet/encryption/safety_number.dart';
import 'package:duvet/main.dart';
import 'package:duvet/people.dart' show RoleChip;
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/glass.dart';
import 'package:duvet/widgets/rows.dart';
import 'package:duvet_client/duvet.dart' as duvet;
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

    // A member without a device, named over the message box before anything is sent; a restart that leaves someone
    // out, which asks first; and members that changed, with whom they are now (Task 23).
    for (final (name, state, restartLeavesOut) in [
      ('no_device', ConversationState.noDevice(const [FakeRepository.maya]), const <String>[]),
      ('restart_confirm', ConversationState.blocked(restart: Restart.mine), const [FakeRepository.leo]),
      ('members_changed', ConversationState.membersChanged, const <String>[]),
    ]) {
      testWidgets(
        '$name, ${b.name}',
        (tester) => withClock(
          Clock.fixed(DateTime(2026, 10, 23, 12)),
          () => withShadows(() async {
            phone(tester);
            final repository = FakeRepository()..restartLeavesOut = restartLeavesOut;
            final appearance = Appearance(MemoryAppearanceStore())
              ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
            await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
            await tester.pumpAndSettle();
            repository.conversationStates.value = {'c-maya': state};
            await tester.tap(find.text('Maya'));
            await tester.pumpAndSettle();
            if (restartLeavesOut.isNotEmpty) {
              await tester.tap(find.text(Notice.blockedOwner.text));
              await tester.pumpAndSettle();
            }
            await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/${name}_${b.name}.png'));
          }),
        ),
      );
    }

    // A member's share of an encrypted conversation's history (Task 31): its notice in the chat, and its offer over the
    // message box until the person adds it.
    testWidgets(
      'a shared history offered, ${b.name}',
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
              isNotice: true,
              sharedHistory: (toUserId: FakeRepository.me.id, toName: 'you', range: 'week'),
            ),
          );
          repository.historyOffers.value = {
            'c-maya': [
              const HistoryOffer(
                shareId: 's1',
                conversationId: 'c-maya',
                fromUserId: FakeRepository.maya,
                range: 'week',
              ),
            ],
          };
          await tester.tap(find.text('Maya'));
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/history_offer_${b.name}.png'));
        }),
      ),
    );

    // Sharing the conversation's history with another member, from the members sheet: how far back (Task 31).
    testWidgets(
      'sharing history, ${b.name}',
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 10, 23, 12)),
        () => withShadows(() async {
          phone(tester);
          final repository = FakeRepository()..encryption.value = EngineState.ready;
          final appearance = Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
          await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Maya'));
          await tester.pumpAndSettle();
          await tester.tap(find.bySemanticsLabel('More').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Members').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Maya').last);
          await tester.pumpAndSettle();
          // Maya's profile, opened from the members sheet, offers it under its buttons.
          await tester.ensureVisible(find.text(Notice.shareHistory.text));
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/member_share_history_${b.name}.png'));
          await tester.tap(find.text(Notice.shareHistory.text));
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/share_history_${b.name}.png'));
        }),
      ),
    );

    // A verified contact's changed key, its strong notice over the message box (Task 29).
    testWidgets(
      'a changed key, ${b.name}',
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 10, 23, 12)),
        () => withShadows(() async {
          phone(tester);
          final repository = FakeRepository()..encryption.value = EngineState.ready;
          final appearance = Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
          await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
          await tester.pumpAndSettle();
          repository.keyChanges['c-maya'] = {FakeRepository.maya: const KeyChange(verified: true, change: 'c1')};
          await tester.tap(find.text('Maya'));
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/key_changed_${b.name}.png'));
        }),
      ),
    );

    // A contact's profile, the person having verified them: the mark beside their name, their security number among
    // its actions, and their DM's mark behind it (Task 29).
    testWidgets(
      'a verified contact, ${b.name}',
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 10, 23, 12)),
        () => withShadows(() async {
          phone(tester);
          final semantics = tester.ensureSemantics();
          final repository = FakeRepository()
            ..encryption.value = EngineState.ready
            ..contacts.value = const ContactsShown(verified: {FakeRepository.maya: true});
          final appearance = Appearance(MemoryAppearanceStore())
            ..value = b == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
          await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Maya'));
          await tester.pumpAndSettle();
          await tester.tap(find.bySemanticsLabel('Maya’s profile').last);
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/verified_contact_${b.name}.png'));
          semantics.dispose();
        }),
      ),
    );

    // A contact's security number (Task 29): its 60 digits, its code as the core gives it, and Mark as verified.
    testWidgets(
      'a security number, ${b.name}',
      (tester) => withShadows(() async {
        phone(tester);
        final qr = (jsonDecode(File('test/e2e/e2e-conventions.json').readAsStringSync()) as Map)['safety_qr']['qr'];
        final repository = FakeRepository()
          ..safetyNumbers[FakeRepository.maya] = (
            digits: '02644 98738 31289 55883 56272 73681 86162 82950 01892 45686 92306 73116',
            qr: qr as String,
          );
        await tester.pumpWidget(themed(b, SafetyNumberPage(repository, userId: FakeRepository.maya, name: 'Maya')));
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/safety_number_${b.name}.png'));
      }),
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

    // Settings → Devices (PLAN-E2E-CLIENTES.md, Task 25): this phone, a computer not seen in 45 days, and a browser
    // never set up, on a fixed day so their last-seen dates don't move.
    testWidgets(
      'devices, ${b.name}',
      (tester) => withClock(
        Clock.fixed(DateTime(2026, 11, 25, 12)),
        () => withShadows(() async {
          final repository = await app(tester);
          final now = clock.now();
          duvet.Device device(String id, String name, String client, int days, {bool listed = true}) => duvet.Device(
            id: id,
            name: name,
            client: client,
            listed: listed,
            current: id.endsWith('a1'),
            createdAt: now.subtract(const Duration(days: 60)),
            lastSeenAt: now.subtract(Duration(days: days)),
          );
          repository
            ..encryption.value = EngineState.ready
            ..backup.value = BackupShown.upToDate
            ..deviceList = [
              device('0193a4b2-0000-7000-8000-0000000000a1', 'Pixel 8 Pro', 'android/1.1.0', 0),
              device('0193a4b2-0000-7000-8000-0000000000a2', 'Duvet for Windows', 'desktop-windows/1.2.0', 50),
              device('0193a4b2-0000-7000-8000-0000000000a3', 'Firefox on Linux', 'web/1.2.0', 1, listed: false),
            ];
          await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('You')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Devices'));
          await tester.pumpAndSettle();
          await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/devices_${b.name}.png'));
        }),
      ),
    );

    // A new device's restore of the encrypted backup (PLAN-E2E-CLIENTES.md, Task 33), as it goes: the Chats tab's
    // strip, with nothing to press but its ×.
    testWidgets(
      'backup restoring, ${b.name}',
      (tester) => withShadows(() async {
        final repository = await app(tester);
        repository
          ..encryption.value = EngineState.ready
          ..backup.value = const BackupShown.restoring(12, 40);
        await tester.pumpAndSettle();
        await expectLater(find.byType(DuvetApp), matchesGoldenFile('goldens/backup_restoring_${b.name}.png'));
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

    // A new device's setup (PLAN-E2E-CLIENTES.md, Task 27): its QR, which a phone of the person's scans, beside the
    // recovery key's field and starting over; its code's way once an approving device offered; and the approving
    // device's question, with the fingerprint the new device's screen shows.
    for (final (name, state) in [
      (
        'device_setup',
        EngineState.settingUp(
          DeviceSetup.qr(
            (jsonDecode(File('test/e2e/e2e-conventions.json').readAsStringSync()) as Map)['approval_qr']['qr']
                as String,
          ),
        ),
      ),
      ('device_setup_code', const EngineState.settingUp(DeviceSetup.code('1a2b 3c4d 5e6f 7a8b', offered: true))),
    ]) {
      testWidgets(
        '$name, ${b.name}',
        (tester) => withShadows(() async {
          phone(tester, height: 1100);
          final repository = FakeRepository()..encryption.value = state;
          await tester.pumpWidget(themed(b, DeviceSetupPage(repository)));
          await tester.pumpAndSettle();
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_${b.name}.png'));
        }),
      );
    }

    testWidgets(
      'device approval, ${b.name}',
      (tester) => withShadows(() async {
        phone(tester);
        await tester.pumpWidget(
          themed(
            b,
            ApprovalView(
              approval: const DeviceApproval(
                device: '0193a4b2-0000-7000-8000-0000000000a2',
                name: 'Pixel 9',
                fingerprint: '1a2b 3c4d 5e6f 7a8b',
                phase: ApprovalPhase.asked,
              ),
              onApprove: () {},
              onDecline: () {},
              onConfirm: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/device_approval_${b.name}.png'));
      }),
    );

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
