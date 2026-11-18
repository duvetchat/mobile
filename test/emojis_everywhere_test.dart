import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

// A second Space, with an emoji named as the first Space's and a sticker of its own.
const _books = Space(
  id: 's-books',
  name: 'Book Club',
  sections: [
    RoomSection(
      name: null,
      rooms: [Room(id: 'r-books', spaceId: 's-books', name: 'books', kind: RoomKind.text, position: 0)],
    ),
  ],
);
const _bookParty = CustomEmoji(
  id: '0e0e0e0e-0000-4000-8000-000000000002',
  name: 'party',
  url: 'https://example.invalid/book-party.png',
  spaceId: 's-books',
);
const _shelf = Sticker(
  id: '05050505-0000-4000-8000-000000000002',
  name: 'shelf',
  attachmentId: '05050505-0000-4000-8000-0000000000bb',
  url: 'https://example.invalid/shelf.png',
  spaceId: 's-books',
);

// An emoji of a Space the user isn't in.
const _stranger = '0e0e0e0e-0000-4000-8000-0000000000ff';
const _strangerUrl = 'https://example.invalid/emojis/$_stranger';

String? _urlOf(Widget w) => switch (w) {
  Image(image: ResizeImage(imageProvider: NetworkImage(:final url))) => url,
  Image(image: NetworkImage(:final url)) => url,
  _ => null,
};

Finder _imageAt(String url) => find.byWidgetPredicate((w) => _urlOf(w) == url);

void main() {
  late SemanticsHandle semantics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    DeepLinkSource.instance = _NoLinks();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  group('reactions go by their emoji', () {
    ChatMessage cheers(List<Reaction> reactions) => ChatMessage(
      id: 'm',
      authorId: FakeRepository.maya,
      authorName: 'Maya',
      content: 'cheers',
      createdAt: DateTime(2026, 10, 23, 9),
      reactions: reactions,
    );

    test('two Spaces\' emojis of one name are two reactions, each taken back alone', () {
      final first = cheers([
        Reaction(emoji: 'party', emojiId: FakeRepository.party.id, users: {FakeRepository.maya}),
      ]);
      final both = first.reacted('party', FakeRepository.me.id, add: true, emojiId: _bookParty.id);
      expect([for (final r in both.reactions) r.key], [FakeRepository.party.id, _bookParty.id]);
      expect(
        [for (final r in both.reactions) r.users],
        [
          {FakeRepository.maya},
          {FakeRepository.me.id},
        ],
      );
      expect(both.reactedWith(FakeRepository.me.id, _bookParty.id), isTrue);
      expect(both.reactedWith(FakeRepository.me.id, FakeRepository.party.id), isFalse);

      final one = both.reacted('party', FakeRepository.maya, add: false, emojiId: FakeRepository.party.id);
      expect([for (final r in one.reactions) r.key], [_bookParty.id]);
    });

    test('a Unicode emoji is its own key', () {
      final m = cheers(const []).reacted('👍', FakeRepository.me.id, add: true);
      expect((m.reactions.single.key, m.reactedWith(FakeRepository.me.id, '👍')), ('👍', true));
    });
  });

  test('by Space: as the Spaces are listed, the given one first, without a Space not listed', () {
    const spaces = [Space(id: 'a', name: 'A'), Space(id: 'b', name: 'B'), Space(id: 'c', name: 'C')];
    final groups = bySpace(['c1', 'a1', 'x1', 'b1', 'a2'], (s) => s[0], spaces, first: 'b');
    expect([for (final g in groups) g.space.id], ['b', 'a', 'c']);
    expect(
      [for (final g in groups) g.items],
      [
        ['b1'],
        ['a1', 'a2'],
        ['c1'],
      ],
    );
  });

  group('in the app', () {
    Future<FakeRepository> pumpApp(WidgetTester tester, [void Function(FakeRepository r)? setUp]) async {
      semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final repository = FakeRepository();
      await tester.pumpWidget(DuvetApp(repository: repository));
      await tester.pumpAndSettle();
      repository.spaces.value = [...repository.spaces.value, _books];
      repository.spaceEmojis.add(_bookParty);
      repository.spaceStickers.add(_shelf);
      setUp?.call(repository);
      return repository;
    }

    Future<void> tapLabel(WidgetTester tester, Pattern label) async {
      await tester.tap(find.bySemanticsLabel(label).hitTestable().last);
      await tester.pumpAndSettle();
    }

    Future<void> openRoom(WidgetTester tester, String space, String room) async {
      await tester.tap(find.descendant(of: find.byType(DuvetTabBar), matching: find.text('Spaces')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(space));
      await tester.pumpAndSettle();
      await tester.tap(find.text('# $room'));
      await tester.pumpAndSettle();
    }

    double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

    testWidgets('a DM\'s picker offers every Space\'s emojis and stickers, under their Spaces', (tester) async {
      final repository = await pumpApp(tester);
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();

      await tapLabel(tester, 'Emoji and stickers');
      expect(find.bySemanticsLabel('party'), findsNWidgets(2));
      expect(_imageAt(_bookParty.url), findsOneWidget);
      // In a DM, as the Spaces are listed.
      expect(top(tester, 'DESIGN GUILD'), lessThan(top(tester, 'BOOK CLUB')));

      await tapLabel(tester, 'Stickers');
      expect(find.text('BOOK CLUB'), findsOneWidget);
      expect(find.bySemanticsLabel('Sticker, wave'), findsOneWidget);
      await tapLabel(tester, 'Sticker, shelf');
      expect((repository.sent.last.target.id, repository.sent.last.sticker?.id), ('c-maya', _shelf.id));
      semantics.dispose();
    });

    testWidgets('a room\'s picker puts its own Space first', (tester) async {
      await pumpApp(tester);
      await openRoom(tester, 'Book Club', 'books');

      await tapLabel(tester, 'Emoji and stickers');
      expect(top(tester, 'BOOK CLUB'), lessThan(top(tester, 'DESIGN GUILD')));
      semantics.dispose();
    });

    testWidgets('a message draws an emoji of a Space the reader isn\'t in from the API', (tester) async {
      await pumpApp(tester, (r) {
        r.history['c-maya']!.add(
          FakeRepository.message(
            'm-x',
            author: FakeRepository.maya,
            name: 'Maya',
            text: 'look <:$_stranger:> and <:${FakeRepository.party.id}:>',
          ),
        );
      });
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();

      expect(_imageAt(_strangerUrl), findsOneWidget);
      expect(_imageAt(FakeRepository.party.url), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a reaction with an emoji of a Space the reader isn\'t in is drawn from the API', (tester) async {
      await pumpApp(tester, (r) {
        r.history['c-maya']!.add(
          FakeRepository.message(
            'm-x',
            author: FakeRepository.maya,
            name: 'Maya',
            text: 'cake?',
            reactions: [
              Reaction(emoji: 'cake', emojiId: _stranger, users: {FakeRepository.maya}),
            ],
          ),
        );
      });
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();

      expect(_imageAt(_strangerUrl), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('reacting with another Space\'s emoji of the same name adds it, not takes the first back', (
      tester,
    ) async {
      final repository = await pumpApp(tester, (r) {
        r.history['c-maya']!.add(
          FakeRepository.message(
            'm-x',
            author: FakeRepository.maya,
            name: 'Maya',
            text: 'shipped',
            reactions: [
              Reaction(emoji: 'party', emojiId: FakeRepository.party.id, users: {FakeRepository.me.id}),
            ],
          ),
        );
      });
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();

      await tapLabel(tester, 'Add reaction');
      await tester.tap(_imageAt(_bookParty.url).hitTestable().first);
      await tester.pumpAndSettle();
      expect(repository.reactions.last, ('m-x', 'party', true));
      expect(find.bySemanticsLabel(':party: 1, you reacted'), findsNWidgets(2));
      semantics.dispose();
    });

    testWidgets('a bot\'s buttons and select options draw their emojis, of any Space', (tester) async {
      await pumpApp(tester, (r) {
        r.history['r-general'] = [
          ChatMessage(
            id: 'menu',
            authorId: '0b0b0b0b-0000-4000-8000-000000000001',
            authorName: 'Bakery',
            fromBot: true,
            content: 'What will it be?',
            createdAt: DateTime(2026, 10, 23, 9),
            components: componentsFromJson([
              {
                'type': 1,
                'components': [
                  {
                    'type': 2,
                    'custom_id': 'cake',
                    'style': 1,
                    'label': 'Order',
                    'emoji': {'id': _stranger, 'name': 'cake'},
                  },
                  {
                    'type': 2,
                    'custom_id': 'tada',
                    'style': 2,
                    'label': 'Party',
                    'emoji': {'name': '🎉'},
                  },
                ],
              },
              {
                'type': 1,
                'components': [
                  {
                    'type': 3,
                    'custom_id': 'size',
                    'placeholder': 'Pick a size',
                    'options': [
                      {
                        'label': 'Small',
                        'value': 's',
                        'emoji': {'id': _stranger, 'name': 'cake'},
                      },
                      {
                        'label': 'Big',
                        'value': 'b',
                        'emoji': {'name': '🍰'},
                      },
                    ],
                  },
                ],
              },
            ]),
          ),
        ];
      });
      await openRoom(tester, 'Design Guild', 'general');

      // The custom emoji is drawn, not written out by name; a Unicode one stays in the text.
      expect(_imageAt(_strangerUrl), findsOneWidget);
      expect(find.text('cake Order'), findsNothing);
      expect(find.text('Order'), findsOneWidget);
      expect(find.text('🎉 Party'), findsOneWidget);

      await tapLabel(tester, 'Pick a size');
      expect(_imageAt(_strangerUrl), findsNWidgets(2));
      expect(find.text('🍰'), findsOneWidget);
      semantics.dispose();
    });
  });
}
