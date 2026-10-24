import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/deep_links.dart';
import 'package:duvet/main.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}

/// Spaces as the desktop has them: what the user may see and do in each.
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
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    setUp?.call(repository);
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('Chats leaves out a room its Space no longer lists to the user', (tester) async {
    await pumpApp(
      tester,
      setUp: (r) {
        r.recentChats.opened(const RoomTarget(spaceId: 's-guild', roomId: 'r-general'), '# general');
        // A room the user can't see any more.
        r.recentChats.opened(const RoomTarget(spaceId: 's-guild', roomId: 'r-secret'), '# secret');
        // A Space the gateway hasn't told of yet: its room stays.
        r.recentChats.opened(const RoomTarget(spaceId: 's-later', roomId: 'r-news'), '# news');
      },
    );
    expect(find.bySemanticsLabel(RegExp(r'^# general')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^# news')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^# secret')), findsNothing);
    semantics.dispose();
  });
}
