import 'dart:convert';

import 'package:duvet/data/cache.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/links.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/media.dart';
import 'package:duvet/widgets/message_content.dart' show ImageViewer;
import 'package:duvet/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

const _ballot = 'u-ballot';

BotModal _meetup() => BotModal.fromJson(
  {
    'custom_id': 'meetup',
    'title': 'Plan a meetup',
    'components': [
      {
        'type': 18,
        'id': 1,
        'label': 'Title',
        'component': {'type': 4, 'id': 2, 'custom_id': 'title', 'style': 1, 'max_length': 40},
      },
      {
        'type': 18,
        'label': 'Notes',
        'component': {'type': 4, 'custom_id': 'notes', 'style': 2, 'required': false},
      },
      {
        'type': 18,
        'label': 'Remind people the day before',
        'component': {'type': 23, 'custom_id': 'remind'},
      },
    ],
  },
  applicationId: 'app-ballot',
  roomId: 'r-general',
  messageId: 'poll',
);

/// M9 · Bots & interactions.
void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  Future<FakeRepository> pumpGeneral(WidgetTester tester, {List<ChatMessage>? history}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = FakeRepository();
    repository.botCommands = const [
      BotCommand(
        id: 'cmd-poll',
        applicationId: 'app-ballot',
        appName: 'Ballot',
        name: 'poll',
        description: 'Start a vote',
        options: [
          BotCommandOption(type: OptionKind.string, name: 'question', required: true),
          BotCommandOption(
            type: OptionKind.integer,
            name: 'hours',
            choices: [(name: 'One day', value: 24), (name: 'One week', value: 168)],
          ),
        ],
      ),
      BotCommand(id: 'cmd-ping', applicationId: 'app-ballot', appName: 'Ballot', name: 'ping', description: 'Pong'),
    ];
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    if (history != null) repository.history['r-general'] = history;
    await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Design Guild'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('# general'));
    await tester.pumpAndSettle();
    return repository;
  }

  Future<void> tapLabel(WidgetTester tester, Pattern label) async {
    await tester.tap(find.bySemanticsLabel(label).hitTestable().last);
    await tester.pumpAndSettle();
  }

  ChatMessage poll() => ChatMessage(
    id: 'poll',
    authorId: _ballot,
    authorName: 'Ballot',
    fromBot: true,
    content: 'Which book next?',
    createdAt: DateTime(2026, 10, 23, 9),
    components: componentsFromJson([
      {
        'type': 1,
        'components': [
          {'type': 2, 'custom_id': 'vote-a', 'style': 1, 'label': 'Dune'},
          {'type': 2, 'custom_id': 'vote-b', 'style': 2, 'label': 'Piranesi'},
          {'type': 2, 'style': 5, 'label': 'Results', 'url': 'https://example.com/r'},
        ],
      },
      {
        'type': 1,
        'components': [
          {
            'type': 3,
            'custom_id': 'genre',
            'placeholder': 'Pick a genre',
            'options': [
              {'label': 'Sci-fi', 'value': 'sf'},
              {'label': 'Fantasy', 'value': 'fantasy'},
            ],
          },
        ],
      },
    ]),
  );

  test('the offline cache keeps a bot message\'s controls', () {
    final raw = [
      {
        'type': 1,
        'components': [
          {'type': 2, 'custom_id': 'vote-a', 'style': 1, 'label': 'Dune'},
        ],
      },
    ];
    final m = ChatMessage(
      id: 'poll',
      authorId: _ballot,
      authorName: 'Ballot',
      fromBot: true,
      content: '',
      createdAt: DateTime(2026, 10, 23),
      components: componentsFromJson(raw),
      rawComponents: raw,
    );
    final back = messageFromJson(jsonDecode(jsonEncode(messageToJson(m))) as Map<String, Object?>);
    expect(back.fromBot, isTrue);
    expect(back.components.single.children.single.label, 'Dune');
  });

  test('bot invite links name the bot; plain invites stay invites', () {
    const id = '0190a3b2-0000-7000-8000-000000000002';
    expect(parseBotInvite('https://duvet.chat/invite.html?bot=$id'), id);
    expect(parseBotInvite('https://duvet.chat/invite?bot=$id'), id);
    expect(parseBotInvite('https://duvet.chat/invite?bot=nope'), isNull);
    expect(parseBotInvite('https://duvet.chat/invite/abc'), isNull);
  });

  test('a modal checks its fields as the API does, then answers labels', () {
    final modal = _meetup();
    final values = initialValues(modal);
    expect(values, {'title': '', 'notes': '', 'remind': false});
    final empty = modalAnswers(modal, values);
    expect(empty.components, isNull);
    expect(empty.problems, {'title': 'This field is required'});
    values['title'] = 'x' * 41;
    expect(modalAnswers(modal, values).problems['title'], 'Must be at most 40 characters');
    values
      ..['title'] = 'Chapter 4'
      ..['remind'] = true;
    expect(modalAnswers(modal, values).components, [
      {
        'type': 18,
        'id': 1,
        'component': {'type': 4, 'id': 2, 'custom_id': 'title', 'value': 'Chapter 4'},
      },
      {
        'type': 18,
        'component': {'type': 4, 'custom_id': 'notes', 'value': ''},
      },
      {
        'type': 18,
        'component': {'type': 23, 'custom_id': 'remind', 'value': true},
      },
    ]);
  });

  testWidgets('a webhook\'s message says WEBHOOK, as on the desktop, and the cache keeps it', (tester) async {
    final hook = ChatMessage(
      id: 'hook',
      authorId: null,
      authorName: 'Deploys',
      fromBot: true,
      fromWebhook: true,
      content: 'Deployed the API',
      createdAt: DateTime(2026, 10, 24, 9),
    );
    await pumpGeneral(tester, history: [hook]);
    expect(find.text('WEBHOOK'), findsOneWidget);
    expect(find.text('BOT'), findsNothing);
    expect(find.bySemanticsLabel('Deploys, webhook,’s profile'), findsOneWidget);
    final back = messageFromJson(jsonDecode(jsonEncode(messageToJson(hook))) as Map<String, Object?>);
    expect(back.fromWebhook, isTrue);
    semantics.dispose();
  });

  testWidgets('a bot message: rounded-square avatar, BOT tag, buttons and a select', (tester) async {
    final repository = await pumpGeneral(tester, history: [poll()]);
    expect(find.text('BOT'), findsOneWidget);
    expect(find.bySemanticsLabel('Ballot, bot,’s profile'), findsOneWidget);
    await tapLabel(tester, 'Dune');
    expect(repository.interactions, ['component vote-a']);

    await tapLabel(tester, 'Pick a genre');
    await tapLabel(tester, 'Fantasy');
    expect(repository.interactions.last, 'component genre fantasy');
    semantics.dispose();
  });

  const videoUrl = 'https://api.duvet.chat/api/proxy/video?exp=1&sig=abc&url=https%3A%2F%2Fcdn.example%2Fclip.mp4';
  const pictureUrl = 'https://cdn.example/cat.png';
  List<Map<String, Object?>> gallery() => [
    {
      'type': 12,
      'items': [
        {
          'media': {'url': pictureUrl, 'content_type': 'image/png'},
        },
        {
          'media': {'url': videoUrl, 'content_type': 'video/mp4'},
        },
        {
          'media': {'url': 'javascript:alert(1)'},
        },
      ],
    },
  ];

  test('a gallery keeps each item\'s content type (#176)', () {
    final items = componentsFromJson(gallery()).single.gallery;
    expect([for (final i in items) (i.url, i.contentType)], [(pictureUrl, 'image/png'), (videoUrl, 'video/mp4')]);
  });

  const fileUrl = 'https://api.duvet.chat/attachments/f-1?sig=abc';
  List<Map<String, Object?>> v2() => [
    {
      'type': 17,
      'accent_color': 0x5865F2,
      'spoiler': true,
      'components': [
        {'type': 10, 'content': 'The butler did it'},
      ],
    },
    {
      'type': 9,
      'components': [
        {'type': 10, 'content': 'Cover art'},
      ],
      'accessory': {
        'type': 11,
        'description': 'Cover',
        'media': {'url': pictureUrl},
      },
    },
    {
      'type': 13,
      'name': 'report.pdf',
      'size': 2048,
      'file': {'url': fileUrl, 'attachment_id': 'f-1'},
    },
    {
      'type': 12,
      'items': [
        {
          'media': {'url': pictureUrl, 'content_type': 'image/png'},
          'description': 'A cat',
          'spoiler': true,
        },
      ],
    },
  ];

  test('v2 components keep their accent color, spoilers, a file\'s name and size, and a gallery item\'s', () {
    final [container, _, file, gallery] = componentsFromJson(v2());
    expect((container.accentColor, container.spoiler), (0x5865F2, true));
    expect((file.mediaUrl, file.mediaAttachmentId, file.fileName, file.fileSize), (fileUrl, 'f-1', 'report.pdf', 2048));
    final item = gallery.gallery.single;
    expect((item.description, item.spoiler), ('A cat', true));
  });

  testWidgets('v2: a spoiler stays covered until tapped, a file is a file, and a thumbnail enlarges', (tester) async {
    final message = ChatMessage(
      id: 'v2',
      authorId: _ballot,
      authorName: 'Ballot',
      fromBot: true,
      content: '',
      createdAt: DateTime(2026, 10, 23, 9),
      isComponentsV2: true,
      components: componentsFromJson(v2()),
    );
    await pumpGeneral(tester, history: [message]);
    // The container's and the gallery item's.
    expect(find.bySemanticsLabel('Spoiler'), findsNWidgets(2));
    expect(find.byWidgetPredicate((w) => w is ColoredBox && w.color == const Color(0xFF5865F2)), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'report\.pdf')), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Spoiler').first);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Spoiler'), findsOneWidget);

    await tapLabel(tester, 'Cover');
    expect(find.byType(ImageViewer), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a gallery\'s video item is a play tile, not a picture (#176)', (tester) async {
    final message = ChatMessage(
      id: 'clips',
      authorId: _ballot,
      authorName: 'Ballot',
      fromBot: true,
      content: '',
      createdAt: DateTime(2026, 10, 23, 9),
      components: componentsFromJson(gallery()),
    );
    await pumpGeneral(tester, history: [message]);
    bool network(Widget w, String url) => w is Image && w.image is NetworkImage && (w.image as NetworkImage).url == url;
    expect(find.byWidgetPredicate((w) => network(w, pictureUrl)), findsOneWidget);
    expect(find.byWidgetPredicate((w) => network(w, videoUrl)), findsNothing);
    expect(find.byType(PlayMark), findsOneWidget);
    expect(find.bySemanticsLabel('Video'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a bot\'s profile removes it from the Space, after asking, for those who manage bots', (tester) async {
    final repository = await pumpGeneral(tester, history: [poll()]);
    await tapLabel(tester, 'Ballot, bot,’s profile');
    await tapLabel(tester, 'Remove from Space');
    expect(find.text('Remove Ballot from Design Guild?'), findsOneWidget);
    expect(repository.botsRemoved, isEmpty);
    await tapLabel(tester, 'Remove from Space');
    expect(repository.botsRemoved, [('s-guild', _ballot)]);
    expect(find.bySemanticsLabel('Remove from Space'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a bot removed from the members list leaves it', (tester) async {
    final repository = await pumpGeneral(tester);
    repository.extraRoomMembers.add(const Member(userId: _ballot, username: 'ballot', alias: 'Ballot', isBot: true));
    await tapLabel(tester, 'More');
    await tapLabel(tester, 'Members');
    await tester.tap(find.text('Ballot').last);
    await tester.pumpAndSettle();
    // Below the profile's roles.
    await tester.ensureVisible(find.bySemanticsLabel('Remove from Space').last);
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Remove from Space');
    await tapLabel(tester, 'Remove from Space');
    expect(repository.botsRemoved, [('s-guild', _ballot)]);
    expect(find.text('Ballot'), findsNothing);
    semantics.dispose();
  });

  testWidgets('without Manage bots, a bot\'s profile has no Remove from Space', (tester) async {
    final repository = await pumpGeneral(tester, history: [poll()]);
    repository
      ..spaceOwner = false
      ..spacePerms = Perm.all & ~Perm.manageBots & ~Perm.administrator;
    await tapLabel(tester, 'Ballot, bot,’s profile');
    expect(find.bySemanticsLabel('Remove from Space'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a failed interaction says the desktop\'s text', (tester) async {
    final repository = await pumpGeneral(tester, history: [poll()]);
    repository.refusals['useComponent'] = 'The application did not respond';
    await tapLabel(tester, 'Dune');
    expect(find.text('The application did not respond'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a button that opens a modal: a glass sheet that checks, then submits', (tester) async {
    final repository = await pumpGeneral(tester, history: [poll()]);
    repository.nextModal = _meetup();
    await tapLabel(tester, 'Piranesi');
    expect(find.text('Plan a meetup'), findsOneWidget);
    expect(find.text('From Ballot · a bot in Design Guild'), findsOneWidget);

    await tapLabel(tester, 'Submit');
    expect(find.text('This field is required'), findsOneWidget);
    expect(repository.submitted, isEmpty);

    await tester.enterText(
      find.descendant(of: find.byType(DuvetTextField).first, matching: find.byType(EditableText)),
      'Chapter 4',
    );
    await tapLabel(tester, 'Remind people the day before');
    await tapLabel(tester, 'Submit');
    expect(find.text('Plan a meetup'), findsNothing);
    final answers = repository.submitted.single;
    expect((answers.first['component'] as Map)['value'], 'Chapter 4');
    expect((answers.last['component'] as Map)['value'], true);
    semantics.dispose();
  });

  testWidgets('slash commands: suggestions above the composer, options, then it runs', (tester) async {
    final repository = await pumpGeneral(tester);
    await tester.enterText(find.byType(EditableText), '/p');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^Commands, 2')), findsOneWidget);
    await tester.enterText(find.byType(EditableText), '/po');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp(r'^Commands, 1')), findsOneWidget);
    await tapLabel(tester, RegExp(r'^/poll'));

    // Its form: the question is required.
    expect(find.text('/poll'), findsWidgets);
    await tapLabel(tester, 'Send /poll');
    expect(find.text('This one is required'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, 'Next book?');
    await tester.tap(find.text('One week'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Send /poll');
    expect(repository.interactions, ['command poll hours=168 question=Next book?']);
    expect(repository.sent, isEmpty);

    // A command with no options runs from the composer's Send.
    await tester.enterText(find.byType(EditableText), '/ping');
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Send');
    expect(repository.interactions.last, 'command ping');
    semantics.dispose();
  });

  testWidgets('a bot invite link is a card: add the bot to a Space', (tester) async {
    final repository = await pumpGeneral(
      tester,
      history: [
        FakeRepository.message(
          'inv',
          author: FakeRepository.maya,
          name: 'Maya',
          text: 'Add this one https://duvet.chat/invite?bot=0190a3b2-0000-7000-8000-000000000002',
        ),
      ],
    );
    expect(find.bySemanticsLabel('Invite for the bot Ballot'), findsOneWidget);
    await tapLabel(tester, 'Add to a Space');
    await tapLabel(tester, 'Design Guild');
    expect(repository.botsAdded, [('s-guild', '0190a3b2-0000-7000-8000-000000000002')]);
    expect(find.text('Added to Design Guild'), findsOneWidget);
    semantics.dispose();
  });
}
