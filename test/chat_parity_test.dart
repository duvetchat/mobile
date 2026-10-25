import 'package:clock/clock.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/gifs.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;
final _me = FakeRepository.me.id;

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// The fake, with the room permissions a test takes away, and an edit
/// answered as the API answers it: the message alone, without its files,
/// reactions or reply.
class _Fake extends FakeRepository {
  final denied = <(String, int)>{};

  /// Takes [bit] away in [roomId].
  void deny(int bit, [String roomId = 'r-general']) => denied.add((roomId, bit));

  @override
  bool canInRoom(String spaceId, String roomId, int bit) =>
      !denied.contains((roomId, bit)) && super.canInRoom(spaceId, roomId, bit);

  @override
  Future<ChatMessage> edit(ChatTarget target, String messageId, String content) async {
    await super.edit(target, messageId, content);
    return ChatMessage(
      id: messageId,
      authorId: FakeRepository.me.id,
      authorName: 'gaby',
      content: content,
      createdAt: DateTime(2026, 10, 23, 9),
      edited: true,
    );
  }
}

/// What the chat does as the desktop app does: updates, moderation, bots'
/// messages, live notices, spoilers, mentions, reading and sending.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<_Fake> pumpApp(WidgetTester tester, void Function(_Fake r)? setUp) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = _Fake();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    setUp?.call(repository);
    return repository;
  }

  Future<_Fake> openMaya(WidgetTester tester, {void Function(_Fake r)? setUp}) async {
    final repository = await pumpApp(tester, setUp);
    await tester.tap(find.text('Maya'));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<_Fake> openGeneral(WidgetTester tester, {void Function(_Fake r)? setUp}) async {
    final repository = await pumpApp(tester, setUp);
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> longPress(WidgetTester tester, String text) async {
    await tester.longPress(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).hitTestable().last);
    await tester.pumpAndSettle();
  }

  group('updates', () {
    ChatMessage notes() => ChatMessage(
      id: 'm9',
      authorId: _maya,
      authorName: 'Maya',
      content: 'see the notes',
      createdAt: DateTime(2026, 10, 23, 10),
      pinned: true,
      reply: MessageReply(
        messageId: 'm2',
        authorId: _me,
        authorName: 'Gaby',
        content: 'Yes, way better than the side panels.',
      ),
      reactions: [
        Reaction(emoji: '👍', users: {_maya}),
      ],
      attachments: const [
        MessageAttachment(
          id: 'a',
          filename: 'notes.pdf',
          contentType: 'application/pdf',
          url: 'https://example.invalid/notes.pdf',
        ),
      ],
    );

    testWidgets('a link preview\'s update keeps the file, reactions, reply, pin and author', (tester) async {
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(notes()));
      await tester.pumpAndSettle();
      // What MESSAGE_UPDATE carries for it: none of those, and no author.
      repository.push(
        'c-maya',
        MessageUpdated(
          ChatMessage(
            id: 'm9',
            authorId: _maya,
            authorName: 'Unknown',
            content: 'see the notes',
            createdAt: DateTime(2026, 10, 23, 10),
            embeds: const [MessageEmbed(title: 'The notes', url: 'https://duvet.chat/notes')],
          ),
          withAuthor: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The notes'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^PDF, notes\.pdf')), findsOneWidget);
      expect(find.bySemanticsLabel('👍 1'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Replying to Gaby: Yes, way better')), findsOneWidget);
      expect(find.text('Maya'), findsWidgets);
      expect(find.text('Unknown'), findsNothing);
      await longPress(tester, 'see the notes');
      expect(find.bySemanticsLabel('Unpin'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('an edit shows in the replies that quote it', (tester) async {
      final repository = await openMaya(tester);
      repository.push('c-maya', MessageCreated(notes()));
      await tester.pumpAndSettle();
      repository.push(
        'c-maya',
        MessageUpdated(
          ChatMessage(
            id: 'm2',
            authorId: _me,
            authorName: 'Gaby',
            content: 'Yes, much better.',
            createdAt: DateTime(2026, 10, 23, 9),
            edited: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^Replying to Gaby: Yes, much better\.')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('saving your own edit keeps the message\'s file and reactions', (tester) async {
      final repository = await openMaya(
        tester,
        setUp: (r) => r.history['c-maya']![1] = ChatMessage(
          id: 'm2',
          authorId: _me,
          authorName: 'Gaby',
          content: 'Yes, way better than the side panels.',
          createdAt: DateTime(2026, 10, 23, 9),
          reactions: [
            Reaction(emoji: '👍', users: {_maya}),
          ],
          attachments: const [
            MessageAttachment(
              id: 'a',
              filename: 'panels.pdf',
              contentType: 'application/pdf',
              url: 'https://example.invalid/panels.pdf',
            ),
          ],
        ),
      );
      await longPress(tester, 'Yes, way better than the side panels.');
      await tapLabel(tester, 'Edit');
      await tester.enterText(find.byType(EditableText), 'Yes, much better.');
      await tester.pump();
      await tapLabel(tester, 'Save edit');
      expect(repository.edits.single, ('m2', 'Yes, much better.'));
      expect(find.text('Yes, much better.'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^PDF, panels\.pdf')), findsOneWidget);
      expect(find.bySemanticsLabel('👍 1'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('moderation', () {
    testWidgets('in a room, ManageMessages deletes someone else\'s message, and only it does', (tester) async {
      final repository = await openGeneral(tester, setUp: (r) => r.deny(Perm.manageMessages));
      await longPress(tester, 'Pushed the new type ramp');
      expect(find.bySemanticsLabel('Reply'), findsWidgets);
      expect(find.bySemanticsLabel('Delete'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      repository.denied.clear();
      await longPress(tester, 'Pushed the new type ramp');
      await tapLabel(tester, 'Delete');
      expect(find.text('Delete this message?'), findsOneWidget);
      await tapLabel(tester, 'Delete for everyone');
      expect(repository.deletes, ['m3']);
      expect(find.text('Pushed the new type ramp'), findsNothing);
      semantics.dispose();
    });

    testWidgets('without PinMessages, a room offers neither Pin nor Unpin', (tester) async {
      await openGeneral(
        tester,
        setUp: (r) {
          r.deny(Perm.pinMessages);
          r.pinned['r-general'] = [r.history['r-general']!.single];
        },
      );
      await longPress(tester, 'Pushed the new type ramp');
      expect(find.bySemanticsLabel('Reply'), findsWidgets);
      expect(find.bySemanticsLabel('Pin'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Pinned messages');
      expect(find.text('1 message in #general'), findsOneWidget);
      expect(find.bySemanticsLabel('Unpin Leo’s message'), findsNothing);
      semantics.dispose();
    });
  });

  group('bots\' answers', () {
    ChatMessage answer(String id, String text, {bool ephemeral = true, bool loading = false, DateTime? at}) =>
        ChatMessage(
          id: id,
          authorId: 'u-ballot',
          authorName: 'Ballot',
          fromBot: true,
          content: text,
          createdAt: at ?? DateTime(2026, 10, 23, 9, 5),
          isEphemeral: ephemeral,
          isLoading: loading,
        );

    testWidgets('one to the user alone says so, takes nothing of the room\'s, and goes when dismissed', (tester) async {
      final repository = await openGeneral(tester);
      repository.push('r-general', MessageCreated(answer('e1', 'Your vote counts')));
      await tester.pumpAndSettle();
      expect(find.text('Only you can see this'), findsOneWidget);
      // Not the room's message the user read up to.
      expect(repository.reads.map((r) => r.$2), isNot(contains('e1')));

      await longPress(tester, 'Your vote counts');
      expect(find.bySemanticsLabel('Copy text'), findsOneWidget);
      expect(find.bySemanticsLabel('Quick reactions'), findsNothing);
      expect(find.bySemanticsLabel('Reply'), findsNothing);
      expect(find.bySemanticsLabel('Pin'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // It outlives leaving the room, until it's dismissed.
      await tapLabel(tester, 'Back');
      await tester.tap(find.text('# general'));
      await tester.pumpAndSettle();
      expect(find.text('Your vote counts'), findsOneWidget);
      await tapLabel(tester, 'Dismiss message');
      expect(find.text('Your vote counts'), findsNothing);
      expect(repository.dismissed, ['e1']);
      semantics.dispose();
    });

    testWidgets('a deferred one: the bot is thinking, and past 15 minutes it did not respond', (tester) async {
      final repository = await openGeneral(tester);
      repository.push('r-general', MessageCreated(answer('l1', '', ephemeral: false, loading: true, at: clock.now())));
      await tester.pumpAndSettle();
      expect(find.text('Ballot is thinking…'), findsOneWidget);

      await tester.pump(const Duration(minutes: 15));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Ballot is thinking…'), findsNothing);
      expect(find.text('The application did not respond'), findsOneWidget);

      // Its bot completes it, late.
      repository.push('r-general', MessageUpdated(answer('l1', 'Here it is', ephemeral: false)));
      await tester.pumpAndSettle();
      expect(find.text('Here it is'), findsOneWidget);
      expect(find.text('The application did not respond'), findsNothing);
      semantics.dispose();
    });
  });

  group('live', () {
    testWidgets('a pin made elsewhere: the menu offers Unpin, and an open pins list loads again', (tester) async {
      final repository = await openGeneral(tester);
      repository.push('r-general', const MessagePinned('m3', pinned: true));
      await tester.pumpAndSettle();
      await longPress(tester, 'Pushed the new type ramp');
      expect(find.bySemanticsLabel('Unpin'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      repository.push('r-general', const MessagePinned('m3', pinned: false));
      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Pinned messages');
      expect(find.text('Nothing pinned yet'), findsOneWidget);
      repository.pinned['r-general'] = [repository.history['r-general']!.single];
      repository.push('r-general', const MessagePinned('m3', pinned: true));
      await tester.pumpAndSettle();
      expect(find.text('1 message in #general'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('who\'s recording a voice message shows above the composer, beside who\'s typing', (tester) async {
      final repository = await openGeneral(tester);
      repository.pushTyping('r-general', const TypingUser(userId: _maya, name: 'Maya', recording: true));
      // A broadcast stream delivers in a microtask, after the first frame.
      await tester.pump();
      await tester.pump();
      expect(find.text('Maya is recording a voice message'), findsOneWidget);

      repository.pushTyping('r-general', const TypingUser(userId: FakeRepository.leo, name: 'Leo'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Leo is typing… · Maya is recording a voice message'), findsOneWidget);

      // Maya types now: that replaces her recording.
      repository.pushTyping('r-general', const TypingUser(userId: _maya, name: 'Maya'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Maya and Leo are typing…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(find.textContaining('typing'), findsNothing);
      semantics.dispose();
    });
  });

  testWidgets('spoiler videos, audio and files stay covered until tapped, as pictures do', (tester) async {
    final repository = await openMaya(tester);
    MessageAttachment file(String id, String name, String type) =>
        MessageAttachment(id: id, filename: name, contentType: type, url: 'https://example.invalid/$id');
    repository.push(
      'c-maya',
      MessageCreated(
        ChatMessage(
          id: 'sp',
          authorId: _maya,
          authorName: 'Maya',
          content: '',
          createdAt: DateTime(2026, 10, 23, 10),
          attachments: [
            file('v', 'SPOILER_ending.mp4', 'video/mp4'),
            file('s', 'SPOILER_theme.mp3', 'audio/mpeg'),
            file('d', 'SPOILER_script.pdf', 'application/pdf'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Spoiler, Video, ending.mp4'), findsOneWidget);
    expect(find.bySemanticsLabel('Spoiler, Audio file, theme.mp3'), findsOneWidget);
    expect(find.bySemanticsLabel('Spoiler, File, script.pdf'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Video, ending\.mp4')), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^PDF, script\.pdf')), findsNothing);

    await tapLabel(tester, 'Spoiler, File, script.pdf');
    expect(find.bySemanticsLabel(RegExp(r'^PDF, script\.pdf')), findsOneWidget);
    expect(find.bySemanticsLabel('Spoiler, Video, ending.mp4'), findsOneWidget);
    semantics.dispose();
  });

  group('mentions', () {
    Finder outlined() => find.byWidgetPredicate(
      (w) => w is Container && ((w.decoration as BoxDecoration?)?.border as Border?)?.top.width == 1.5,
    );

    testWidgets('a reply to the user that mentions them is outlined; one sent without the mention isn\'t', (
      tester,
    ) async {
      final repository = await openMaya(tester);
      MessageReply toMe({required bool mention}) => MessageReply(
        messageId: 'm2',
        authorId: _me,
        authorName: 'Gaby',
        content: 'Yes, way better than the side panels.',
        mentionAuthor: mention,
      );
      repository.push(
        'c-maya',
        MessageCreated(
          FakeRepository.message('r1', author: _maya, name: 'Maya', text: 'A quiet reply', reply: toMe(mention: false)),
        ),
      );
      repository.push(
        'c-maya',
        MessageCreated(
          FakeRepository.message('r2', author: _maya, name: 'Maya', text: 'A loud reply', reply: toMe(mention: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(outlined(), findsOneWidget);
      expect(find.ancestor(of: find.text('A loud reply'), matching: outlined()), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a v2 message whose text displays mention the user is outlined', (tester) async {
      final repository = await openGeneral(tester);
      repository.push(
        'r-general',
        MessageCreated(
          ChatMessage(
            id: 'v2',
            authorId: 'u-ballot',
            authorName: 'Ballot',
            fromBot: true,
            content: '',
            createdAt: DateTime(2026, 10, 23, 9, 5),
            isComponentsV2: true,
            components: componentsFromJson([
              {
                'type': 17,
                'components': [
                  {'type': 10, 'content': 'Your turn, <@$_me>'},
                ],
              },
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.ancestor(of: find.text('Your turn, @Gaby'), matching: outlined()), findsOneWidget);
      semantics.dispose();
    });
  });

  group('reading', () {
    // Enough of Maya's messages to scroll.
    void longChat(_Fake r) => r.history['c-maya'] = [
      for (var i = 0; i < 40; i++)
        FakeRepository.message('h$i', author: _maya, name: 'Maya', text: 'Line $i', at: DateTime(2026, 10, 23, 9, i)),
    ];
    ChatMessage later(String id, String text) =>
        FakeRepository.message(id, author: _maya, name: 'Maya', text: text, at: DateTime(2026, 10, 23, 10));
    final list = find.byWidgetPredicate((w) => w is ListView && w.reverse);

    testWidgets('a new message is read at the bottom, not while the reader is further up', (tester) async {
      final repository = await openMaya(tester, setUp: longChat);
      // Opening the chat reads it.
      expect(repository.reads.last.$2, 'h39');
      repository.push('c-maya', MessageCreated(later('n1', 'At the bottom')));
      await tester.pumpAndSettle();
      expect(repository.reads.last.$2, 'n1');

      await tester.drag(list, const Offset(0, 600));
      await tester.pumpAndSettle();
      repository.push('c-maya', MessageCreated(later('n2', 'While you were up there')));
      await tester.pumpAndSettle();
      expect(repository.reads.last.$2, 'n1');
      expect(repository.unread.value, contains('c-maya'));

      await tester.drag(list, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(repository.reads.last.$2, 'n2');
      expect(repository.unread.value, isNot(contains('c-maya')));
      semantics.dispose();
    });

    testWidgets('nor while the app is in the background: when it comes back', (tester) async {
      final repository = await openMaya(tester, setUp: longChat);
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      repository.push('c-maya', MessageCreated(later('n1', 'While the phone was locked')));
      await tester.pumpAndSettle();
      expect(repository.reads.last.$2, 'h39');

      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(repository.reads.last.$2, 'n1');
      semantics.dispose();
    });

    testWidgets('a thread reads nothing, nor the chat under it: that one does once back on top', (tester) async {
      final repository = await openGeneral(tester, setUp: (r) => r.threads['m3'] = [r.history['r-general']!.single]);
      await longPress(tester, 'Pushed the new type ramp');
      await tapLabel(tester, 'View thread');
      final reads = repository.reads.length;
      repository.push(
        'r-general',
        MessageCreated(
          FakeRepository.message(
            't1',
            author: _maya,
            name: 'Maya',
            text: 'Looks great',
            reply: const MessageReply(messageId: 'm3', authorName: 'Leo', content: 'Pushed the new type ramp'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Looks great'), findsOneWidget);
      expect(repository.reads.length, reads);

      await tapLabel(tester, 'Back');
      expect(repository.reads.last.$2, 't1');
      semantics.dispose();
    });
  });

  testWidgets('different webhooks, or one under another name, start runs of their own', (tester) async {
    ChatMessage hook(String id, String webhook, String name, int minute) => ChatMessage(
      id: id,
      authorId: null,
      authorName: name,
      fromBot: true,
      fromWebhook: true,
      webhookId: webhook,
      content: 'Run $id',
      createdAt: DateTime(2026, 10, 23, 9, minute),
    );
    await openGeneral(
      tester,
      setUp: (r) => r.history['r-general'] = [
        hook('a', 'w-1', 'Deploys', 0),
        hook('b', 'w-2', 'Deploys', 1),
        hook('c', 'w-2', 'Alerts', 2),
        hook('d', 'w-2', 'Alerts', 3),
      ],
    );
    // A name and a tag over each run's first message: three runs.
    expect(find.text('WEBHOOK'), findsNWidgets(3));
    expect(find.text('Deploys'), findsNWidgets(2));
    expect(find.text('Alerts'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a sticker or a GIF sent while replying answers that message, and the strip closes', (tester) async {
    GifSource.instance = _Gifs();
    final repository = await openGeneral(tester);
    Future<void> replyToLeo() async {
      await tester.tap(find.text('Pushed the new type ramp'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Pushed the new type ramp'));
      await tester.pumpAndSettle();
      expect(find.text('Replying to Leo — Pushed the new type ramp'), findsOneWidget);
    }

    await replyToLeo();
    await tapLabel(tester, 'Add photos, a sticker or a mention');
    await tapLabel(tester, 'Sticker');
    await tapLabel(tester, 'Sticker, wave');
    expect((repository.sent.last.sticker?.id, repository.sent.last.replyTo), (FakeRepository.wave.id, 'm3'));
    expect(find.textContaining('Replying to Leo'), findsNothing);

    await replyToLeo();
    await tapLabel(tester, 'Emoji and stickers');
    await tester.tap(find.text('GIFs'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'GIF, party');
    expect((repository.sent.last.content, repository.sent.last.replyTo), (_Gifs.party.url, 'm3'));
    expect(find.textContaining('Replying to Leo'), findsNothing);
    semantics.dispose();
  });

  group('commands and selects', () {
    const echo = BotCommand(
      id: 'cmd-echo',
      applicationId: 'app-ballot',
      appName: 'Ballot',
      name: 'echo',
      description: 'Say it back',
      options: [BotCommandOption(type: OptionKind.string, name: 'text', required: true, minLength: 3, maxLength: 5)],
    );
    const note = BotCommand(
      id: 'cmd-note',
      applicationId: 'app-ballot',
      appName: 'Ballot',
      name: 'note',
      description: 'Keep a note',
      options: [BotCommandOption(type: OptionKind.string, name: 'text', required: true)],
    );
    const goTo = BotCommand(
      id: 'cmd-go',
      applicationId: 'app-ballot',
      appName: 'Ballot',
      name: 'go',
      description: 'Go somewhere',
      options: [
        BotCommandOption(type: OptionKind.room, name: 'where', required: true, roomTypes: [1]),
      ],
    );

    // A category, a room the user can't see, a voice room.
    void rooms(_Fake r) {
      r.adminRoomList['s-guild'] = const [
        AdminRoom(id: 'cat', name: 'Talk', kind: AdminRoomKind.category, position: 0),
        AdminRoom(id: 'r-general', name: 'general', kind: AdminRoomKind.text, position: 1),
        AdminRoom(id: 'r-mods', name: 'mods', kind: AdminRoomKind.text, position: 2),
        AdminRoom(id: 'r-lounge', name: 'lounge', kind: AdminRoomKind.voice, position: 3),
      ];
      r.deny(Perm.viewChannels, 'r-mods');
    }

    testWidgets('commands are for the rooms the user can write in', (tester) async {
      final repository = await openGeneral(
        tester,
        setUp: (r) {
          r.botCommands = const [echo];
          r.deny(Perm.sendMessages);
        },
      );
      await tester.enterText(find.byType(EditableText), '/e');
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^Commands')), findsNothing);
      await tester.enterText(find.byType(EditableText), '/echo');
      await tester.pump();
      await tapLabel(tester, 'Send');
      expect(find.text('/echo'), findsWidgets);
      expect(find.bySemanticsLabel('Send /echo'), findsNothing);
      expect(repository.sent.last.content, '/echo');

      repository.denied.clear();
      await tester.enterText(find.byType(EditableText), '/ec');
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp(r'^Commands, 1')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a command\'s texts take the lengths the API does', (tester) async {
      final repository = await openGeneral(tester, setUp: (r) => r.botCommands = const [echo, note]);
      await tester.enterText(find.byType(EditableText), '/echo');
      await tester.pumpAndSettle();
      await tapLabel(tester, RegExp(r'^/echo'));
      await tester.enterText(find.byType(EditableText).last, 'ab');
      await tapLabel(tester, 'Send /echo');
      expect(find.text('Takes 3 characters at least'), findsOneWidget);
      await tester.enterText(find.byType(EditableText).last, 'abcdef');
      await tapLabel(tester, 'Send /echo');
      expect(find.text('Takes 5 characters at most'), findsOneWidget);
      await tester.enterText(find.byType(EditableText).last, 'abcd');
      await tapLabel(tester, 'Send /echo');
      expect(repository.interactions, ['command echo text=abcd']);

      // 6000 at most, when the option says nothing.
      await tester.enterText(find.byType(EditableText), '/note');
      await tester.pumpAndSettle();
      await tapLabel(tester, RegExp(r'^/note'));
      await tester.enterText(find.byType(EditableText).last, 'x' * 6001);
      await tapLabel(tester, 'Send /note');
      expect(find.text('Takes 6000 characters at most'), findsOneWidget);
      expect(repository.interactions, hasLength(1));
      semantics.dispose();
    });

    testWidgets('a room select offers the rooms the user can see, of the types it takes', (tester) async {
      ChatMessage picker(String id, String placeholder, List<int> types) => ChatMessage(
        id: id,
        authorId: 'u-ballot',
        authorName: 'Ballot',
        fromBot: true,
        content: 'Where to?',
        createdAt: DateTime(2026, 10, 23, 9, 5),
        components: componentsFromJson([
          {
            'type': 1,
            'components': [
              {'type': 8, 'custom_id': id, 'placeholder': placeholder, 'room_types': ?(types.isEmpty ? null : types)},
            ],
          },
        ]),
      );
      await openGeneral(
        tester,
        setUp: (r) {
          rooms(r);
          r.history['r-general'] = [
            picker('any', 'Pick a room', const []),
            picker('voice', 'Pick a voice room', const [2]),
          ];
        },
      );
      await tapLabel(tester, 'Pick a room');
      expect(find.text('Talk'), findsOneWidget);
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('#lounge'), findsOneWidget);
      expect(find.text('#mods'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tapLabel(tester, 'Pick a voice room');
      expect(find.text('#lounge'), findsOneWidget);
      expect(find.text('#general'), findsNothing);
      expect(find.text('Talk'), findsNothing);
      semantics.dispose();
    });

    testWidgets('a command\'s room option offers the same, of its own room types', (tester) async {
      await openGeneral(
        tester,
        setUp: (r) {
          rooms(r);
          r.botCommands = const [goTo];
        },
      );
      await tester.enterText(find.byType(EditableText), '/go');
      await tester.pumpAndSettle();
      await tapLabel(tester, RegExp(r'^/go'));
      expect(find.text('#general'), findsOneWidget);
      expect(find.text('#lounge'), findsNothing);
      expect(find.text('#mods'), findsNothing);
      expect(find.text('Talk'), findsNothing);
      semantics.dispose();
    });
  });
}

class _Gifs implements GifSource {
  static const party = Gif(
    id: 'g1',
    url: 'https://media.tenor.com/party.gif',
    preview: 'https://media.tenor.com/party-tiny.gif',
    width: 200,
    height: 150,
    description: 'party',
  );

  @override
  String get attribution => 'GIFs from Tenor';

  @override
  Future<List<Gif>> trending() async => const [party];

  @override
  Future<List<Gif>> search(String query) async => const [party];
}
