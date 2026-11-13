import 'dart:async';

import 'package:duvet/data/models.dart';
import 'package:duvet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' show FCircularProgress;

import 'support/fake_repository.dart';

const _maya = FakeRepository.maya;

/// The fake, with the chat's latest page held back or refused while a test
/// says, and what it was asked for.
class _Fake extends FakeRepository {
  Completer<void>? holdHistory;
  Object? refuseHistory;

  /// The `before` of each older page asked for.
  final befores = <String>[];

  /// The newest message each open of a chat went by.
  final opens = <String?>[];

  @override
  Future<List<ChatMessage>> messages(ChatTarget target, {String? before}) async {
    if (before != null) {
      befores.add(before);
    } else {
      await holdHistory?.future;
      if (refuseHistory case final e?) throw e;
    }
    return super.messages(target, before: before);
  }

  /// Holds back search results while set.
  Completer<void>? holdSearch;

  @override
  Future<SearchPage> search(SearchQuery query) async {
    await holdSearch?.future;
    return super.search(query);
  }

  @override
  void opened(ChatTarget target, String title, {ChatMessage? latest}) {
    opens.add(latest?.id);
    super.opened(target, title, latest: latest);
  }
}

ChatMessage _said(String id, String text, {int minute = 0}) =>
    FakeRepository.message(id, author: _maya, name: 'Maya', text: text, at: DateTime(2026, 10, 23, 9, minute));

/// Opening a chat: what was kept of it at once, then its latest; or, with
/// nothing kept, messages drawn as blocks until it comes.
void main() {
  late SemanticsHandle semantics;
  final list = find.byWidgetPredicate((w) => w is ListView && w.reverse);
  final skeleton = find.bySemanticsLabel('Loading messages');

  /// Opens Maya's chat with its history held back.
  Future<_Fake> openHeld(WidgetTester tester, {Size size = const Size(390, 844), void Function(_Fake r)? setUp}) async {
    semantics = tester.ensureSemantics();
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repository = _Fake();
    await tester.pumpWidget(DuvetApp(repository: repository));
    await tester.pumpAndSettle();
    repository.holdHistory = Completer<void>();
    setUp?.call(repository);
    await tester.tap(find.text('Maya'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The switch from the blocks, if anything was kept, done.
    await tester.pump();
    return repository;
  }

  Future<void> release(WidgetTester tester, _Fake repository) async {
    repository.holdHistory!.complete();
    await tester.pumpAndSettle();
  }

  group('with nothing kept', () {
    for (final (name, size) in [('a small phone', const Size(360, 640)), ('a tall screen', const Size(430, 1100))]) {
      testWidgets('blocks in the messages\' shape fill $name until they come, and nothing else', (tester) async {
        final repository = await openHeld(tester, size: size);
        expect(tester.takeException(), isNull);
        expect(skeleton, findsOneWidget);
        expect(find.byType(FCircularProgress), findsNothing);
        expect(list, findsNothing);
        expect(find.text('Hey! Did you see the new tab bar?'), findsNothing);

        await release(tester, repository);
        expect(skeleton, findsNothing);
        expect(find.text('Hey! Did you see the new tab bar?'), findsOneWidget);
        semantics.dispose();
      });
    }

    testWidgets('a history that fails says so, as before', (tester) async {
      final repository = await openHeld(tester, setUp: (r) => r.refuseHistory = const ActionFailed('Offline'));
      await release(tester, repository);
      expect(skeleton, findsNothing);
      expect(find.text('Couldn’t load messages'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('with a kept page', () {
    testWidgets('it shows at once, read from nothing, and the latest replaces it in place', (tester) async {
      final repository = await openHeld(
        tester,
        setUp: (r) {
          r.cachedPages['c-maya'] = [_said('k1', 'Deleted since'), _said('k2', 'Before the edit', minute: 1)];
          r.history['c-maya'] = [_said('k2', 'After the edit', minute: 1), _said('k3', 'Came since', minute: 2)];
        },
      );
      expect(skeleton, findsNothing);
      expect(find.text('Deleted since'), findsOneWidget);
      expect(find.text('Before the edit'), findsOneWidget);
      // Nothing is read or opened from it: the latest page does that.
      expect(repository.reads, isEmpty);
      expect(repository.opens, isEmpty);
      // Nor are older pages asked for from it.
      await tester.drag(list, const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(repository.befores, isEmpty);

      await release(tester, repository);
      expect(find.text('Deleted since'), findsNothing);
      expect(find.text('Before the edit'), findsNothing);
      expect(find.text('After the edit'), findsOneWidget);
      expect(find.text('Came since'), findsOneWidget);
      expect(repository.opens, ['k3']);
      expect(repository.reads.single.$2, 'k3');
      semantics.dispose();
    });

    testWidgets('a message pushed meanwhile stays, after the latest page', (tester) async {
      final repository = await openHeld(
        tester,
        setUp: (r) {
          r.cachedPages['c-maya'] = [_said('k1', 'Kept')];
          r.history['c-maya'] = [_said('k1', 'Kept'), _said('k2', 'Fetched', minute: 1)];
        },
      );
      repository.push('c-maya', MessageCreated(_said('k3', 'Pushed', minute: 2)));
      await tester.pump();
      expect(find.text('Pushed'), findsOneWidget);
      expect(repository.reads, isEmpty);

      await release(tester, repository);
      expect(find.text('Kept'), findsOneWidget);
      expect(find.text('Fetched'), findsOneWidget);
      expect(find.text('Pushed'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Fetched')).dy, lessThan(tester.getTopLeft(find.text('Pushed')).dy));
      expect(repository.reads.last.$2, 'k3');
      semantics.dispose();
    });

    testWidgets('one with nothing in common with the latest goes, and older pages come from the latest', (
      tester,
    ) async {
      final repository = await openHeld(
        tester,
        setUp: (r) {
          r.cachedPages['c-maya'] = [_said('a1', 'Long ago')];
          r.history['c-maya'] = [for (var i = 0; i < 100; i++) _said('h${i.toString().padLeft(3, '0')}', 'Line $i')];
          r.olderPages['c-maya'] = [
            [_said('g1', 'Older')],
          ];
        },
      );
      expect(find.text('Long ago'), findsOneWidget);

      await release(tester, repository);
      expect(find.text('Long ago'), findsNothing);
      expect(find.text('Line 99'), findsOneWidget);
      await tester.drag(list, const Offset(0, 20000));
      await tester.pumpAndSettle();
      expect(repository.befores.first, 'h000');
      semantics.dispose();
    });

    testWidgets('it stays when the latest fails, and the latest comes once the gateway is back', (tester) async {
      final repository = await openHeld(
        tester,
        setUp: (r) {
          r.refuseHistory = const ActionFailed('Offline');
          r.cachedPages['c-maya'] = [_said('k1', 'Kept')];
          r.history['c-maya'] = [_said('k1', 'Kept'), _said('k2', 'Fetched', minute: 1)];
        },
      );
      await release(tester, repository);
      expect(find.text('Kept'), findsOneWidget);
      expect(find.text('Couldn’t load messages'), findsNothing);
      expect(repository.reads, isEmpty);

      repository.refuseHistory = null;
      repository.resume();
      await tester.pumpAndSettle();
      expect(find.text('Fetched'), findsOneWidget);
      expect(repository.reads.last.$2, 'k2');
      semantics.dispose();
    });
  });

  testWidgets('search results on their way are rows drawn as blocks, not a spinner', (tester) async {
    final repository = await openHeld(tester);
    await release(tester, repository);
    repository.holdSearch = Completer<void>();
    await tester.tap(find.bySemanticsLabel('Search').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'tab bar');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.bySemanticsLabel('Searching'), findsOneWidget);
    expect(find.byType(FCircularProgress), findsNothing);

    repository.holdSearch!.complete();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Searching'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('^Maya, .*Did you see the new tab bar')), findsOneWidget);
    semantics.dispose();
  });
}
