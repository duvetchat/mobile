import 'dart:async';

import 'package:clock/clock.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/gifs.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/avatar.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart';
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

/// The fake, with the room permissions a test takes away, sends and pins the
/// API refuses, and an edit answered as the API answers it: the message
/// alone, without its files, reactions or reply.
class _Fake extends FakeRepository {
  final denied = <(String, int)>{};

  /// Takes [bit] away in [roomId].
  void deny(int bit, [String roomId = 'r-general']) => denied.add((roomId, bit));

  @override
  bool canInRoom(String spaceId, String roomId, int bit) =>
      !denied.contains((roomId, bit)) && super.canInRoom(spaceId, roomId, bit);

  /// The API's reason for refusing sends and pins, while set.
  String? refusal;

  /// Holds back the history while set; and the chats whose history came.
  Completer<void>? holdHistory;
  final opens = <String>[];

  @override
  Future<List<ChatMessage>> messages(ChatTarget target, {String? before}) async {
    await holdHistory?.future;
    if (before == null) opens.add(target.id);
    return super.messages(target, before: before);
  }

  @override
  Future<ChatMessage> send(
    ChatTarget target,
    String content, {
    required String nonce,
    List<OutgoingFile> files = const [],
    Sticker? sticker,
    String? replyTo,
    bool? mentionRepliedUser,
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    if (refusal case final reason?) throw ActionFailed(reason);
    return super.send(
      target,
      content,
      nonce: nonce,
      files: files,
      sticker: sticker,
      replyTo: replyTo,
      mentionRepliedUser: mentionRepliedUser,
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  @override
  Future<void> pin(ChatTarget target, String messageId, {required bool pinned}) async {
    if (refusal case final reason?) throw ActionFailed(reason);
    return super.pin(target, messageId, pinned: pinned);
  }

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
      // After the dust.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(repository.deletes, ['m3']);
      expect(find.text('Pushed the new type ramp'), findsNothing);
      semantics.dispose();
    });

    testWidgets('in a DM every member pins, and deletes only their own, as the API has it', (tester) async {
      await openMaya(tester);
      await longPress(tester, 'Hey! Did you see the new tab bar?');
      expect(find.bySemanticsLabel('Pin'), findsOneWidget);
      expect(find.bySemanticsLabel('Delete'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await longPress(tester, 'Yes, way better than the side panels.');
      expect(find.bySemanticsLabel('Pin'), findsOneWidget);
      expect(find.bySemanticsLabel('Delete'), findsOneWidget);
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
      // With no divider it opens at its bottom, which reads it.
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

    testWidgets('a chat opened at its divider is read at the bottom, not on opening', (tester) async {
      final repository = await openMaya(
        tester,
        setUp: (r) {
          longChat(r);
          r.lastRead['c-maya'] = 'h9';
          r.unread.value = {'c-maya'};
        },
      );
      // It opens at its divider, above its newest messages: nothing is read.
      expect(find.text('New messages'), findsOneWidget);
      expect(repository.reads, isEmpty);
      expect(repository.unread.value, contains('c-maya'));

      // Left and opened again, it's still unread, at its divider.
      await tapLabel(tester, 'Back');
      expect(repository.unread.value, contains('c-maya'));
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      expect(find.text('New messages'), findsOneWidget);
      expect(repository.reads, isEmpty);

      // Scrolled down to the bottom, it's read.
      await tester.drag(list, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(repository.reads.last.$2, 'h39');
      expect(repository.unread.value, isNot(contains('c-maya')));
      semantics.dispose();
    });

    testWidgets('one read further back than its first page opens above that page, and is read at the bottom', (
      tester,
    ) async {
      // The newest 100 messages, and 50 older ones: the last read is among those.
      ChatMessage line(int i) => FakeRepository.message(
        'u${i.toString().padLeft(3, '0')}',
        author: _maya,
        name: 'Maya',
        text: 'Line $i',
        at: DateTime(2026, 10, 23, 8, i),
      );
      final repository = await openMaya(
        tester,
        setUp: (r) {
          r.history['c-maya'] = [for (var i = 100; i < 200; i++) line(i)];
          r.olderPages['c-maya'] = [
            [for (var i = 50; i < 100; i++) line(i)],
          ];
          r.lastRead['c-maya'] = 'u060';
          r.unread.value = {'c-maya'};
        },
      );
      // Above the oldest message of the first page, where it opens, and where it stays when the older page comes:
      // nothing is read.
      expect(find.text('New messages'), findsOneWidget);
      expect(find.text('Line 100'), findsOneWidget);
      expect(tester.getTopLeft(find.text('New messages')).dy, lessThan(tester.getTopLeft(find.text('Line 100')).dy));
      expect(repository.reads, isEmpty);
      expect(repository.unread.value, contains('c-maya'));

      await tester.drag(list, const Offset(0, -20000));
      await tester.pumpAndSettle();
      expect(repository.reads.last.$2, 'u199');
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

    testWidgets('a chat that opens as the app goes to the background is read once it comes back', (tester) async {
      final repository = await pumpApp(tester, (r) => r.holdHistory = Completer<void>());
      await tester.tap(find.text('Maya'));
      // Its history is loading: a spinner, which never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      repository.holdHistory!.complete();
      await tester.pump();
      expect(repository.opens, ['c-maya']);
      expect(repository.reads, isEmpty);

      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(repository.reads.single.$2, 'm2');
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

  testWidgets('one person under two names stays one run: the history\'s nickname, a live message\'s name', (
    tester,
  ) async {
    final repository = await openGeneral(
      tester,
      setUp: (r) => r.history['r-general'] = [
        FakeRepository.message(
          'n1',
          author: FakeRepository.leo,
          name: 'Nick',
          text: 'From the history',
          at: DateTime(2026, 10, 23, 9),
        ),
      ],
    );
    repository.push(
      'r-general',
      MessageCreated(
        FakeRepository.message(
          'n2',
          author: FakeRepository.leo,
          name: 'Leo',
          text: 'Live',
          at: DateTime(2026, 10, 23, 9, 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // One run: its first message's name, once.
    expect(find.text('Nick'), findsOneWidget);
    expect(find.text('Leo'), findsNothing);
    semantics.dispose();
  });

  group('profile changes', () {
    const avatar = 'https://api.duvet.chat/attachments/00000000-0000-4000-8000-0000000000cc';
    Finder avatarAt(String url) => find.byWidgetPredicate((w) => w is UserAvatar && w.url == url);

    testWidgets('someone\'s new name and avatar show on their messages and the quotes of them, not a webhook\'s', (
      tester,
    ) async {
      final repository = await openGeneral(
        tester,
        setUp: (r) => r.history['r-general'] = [
          FakeRepository.message('h1', author: _maya, name: 'Maya', text: 'Ship the ramp?'),
          // A webhook posting under her name.
          ChatMessage(
            id: 'h2',
            authorId: null,
            authorName: 'Maya',
            fromBot: true,
            fromWebhook: true,
            webhookId: 'w-1',
            content: 'Deployed',
            createdAt: DateTime(2026, 10, 23, 9, 1),
          ),
          FakeRepository.message(
            'h3',
            author: FakeRepository.leo,
            name: 'Leo',
            text: 'Shipped',
            at: DateTime(2026, 10, 23, 9, 2),
            reply: const MessageReply(messageId: 'h1', authorId: _maya, authorName: 'Maya', content: 'Ship the ramp?'),
          ),
        ],
      );
      expect(find.text('Maya'), findsNWidgets(2));

      repository.push('r-general', const AuthorChanged(_maya, name: 'Maya O.', avatarUrl: avatar));
      await tester.pumpAndSettle();
      expect(find.text('Maya O.'), findsOneWidget);
      expect(avatarAt(avatar), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Replying to Maya O\.: Ship the ramp\?')), findsOneWidget);
      // The webhook's.
      expect(find.text('Maya'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('and on theirs in a DM', (tester) async {
      final repository = await openMaya(tester);
      repository.push('c-maya', const AuthorChanged(_maya, name: 'Maya O.', avatarUrl: avatar));
      await tester.pumpAndSettle();
      expect(find.text('Maya O.'), findsOneWidget);
      expect(avatarAt(avatar), findsOneWidget);
      semantics.dispose();
    });
  });

  testWidgets('a sticker or a GIF sent while replying answers that message, and the strip closes', (tester) async {
    GifSource.instance = _Gifs();
    final repository = await openGeneral(tester);
    Future<void> replyToLeo() async {
      await tester.drag(find.text('Pushed the new type ramp'), const Offset(-120, 0));
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

    const roll = BotCommand(
      id: 'cmd-roll',
      applicationId: 'app-ballot',
      appName: 'Ballot',
      name: 'roll',
      description: 'Roll the dice',
      options: [
        BotCommandOption(type: OptionKind.integer, name: 'sides'),
        BotCommandOption(type: OptionKind.number, name: 'odds'),
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

    testWidgets('an emoji is one character in a command\'s text, as the API counts it', (tester) async {
      final repository = await openGeneral(tester, setUp: (r) => r.botCommands = const [echo]);
      await tester.enterText(find.byType(EditableText), '/echo');
      await tester.pumpAndSettle();
      await tapLabel(tester, RegExp(r'^/echo'));
      // Two characters, though four UTF-16 units.
      await tester.enterText(find.byType(EditableText).last, '😀😀');
      await tapLabel(tester, 'Send /echo');
      expect(find.text('Takes 3 characters at least'), findsOneWidget);
      // Five characters, though ten units.
      await tester.enterText(find.byType(EditableText).last, '😀😀😀😀😀');
      await tapLabel(tester, 'Send /echo');
      expect(repository.interactions, ['command echo text=😀😀😀😀😀']);
      semantics.dispose();
    });

    testWidgets('a command\'s numbers are what the API takes: integers in digits, numbers finite', (tester) async {
      final repository = await openGeneral(tester, setUp: (r) => r.botCommands = const [roll]);
      await tester.enterText(find.byType(EditableText), '/roll');
      await tester.pumpAndSettle();
      await tapLabel(tester, RegExp(r'^/roll'));
      Finder field(int i) =>
          find.descendant(of: find.byType(DuvetTextField).at(i), matching: find.byType(EditableText));
      for (final (sides, odds) in [('0x1F', 'NaN'), ('+5', 'Infinity'), ('9007199254740992', '1e400')]) {
        await tester.enterText(field(0), sides);
        await tester.enterText(field(1), odds);
        await tapLabel(tester, 'Send /roll');
        expect(find.text('A whole number'), findsOneWidget, reason: sides);
        expect(find.text('A number'), findsOneWidget, reason: odds);
      }
      await tester.enterText(field(0), '9007199254740991');
      await tester.enterText(field(1), '0.5');
      await tapLabel(tester, 'Send /roll');
      expect(repository.interactions, ['command roll sides=9007199254740991 odds=0.5']);
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

  group('errors', () {
    testWidgets('a send the API refuses says why', (tester) async {
      await openGeneral(tester, setUp: (r) => r.refusal = 'You don’t have permission to send messages in this room');
      await tester.enterText(find.byType(EditableText), 'Hello?');
      await tester.pump();
      await tapLabel(tester, 'Send');
      expect(find.text('You don’t have permission to send messages in this room'), findsOneWidget);
      expect(find.bySemanticsLabel('Message not sent'), findsWidgets);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
    });

    testWidgets('a pin or an unpin the API refuses says why, and stays as it was', (tester) async {
      await openGeneral(
        tester,
        setUp: (r) {
          r.refusal = 'A room has 250 pinned messages at most';
          r.pinned['r-general'] = [r.history['r-general']!.single.copyWith(pinned: true)];
        },
      );
      await longPress(tester, 'Pushed the new type ramp');
      await tapLabel(tester, 'Pin');
      expect(find.text('A room has 250 pinned messages at most'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await longPress(tester, 'Pushed the new type ramp');
      expect(find.bySemanticsLabel('Pin'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // The list keeps a pin the server kept.
      await tapLabel(tester, 'More');
      await tapLabel(tester, 'Pinned messages');
      await tapLabel(tester, 'Unpin Leo’s message');
      expect(find.text('1 message in #general'), findsOneWidget);
      expect(find.bySemanticsLabel('Unpin Leo’s message'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
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
