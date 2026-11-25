import 'package:duvet/data/scope.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/encryption/gate.dart';
import 'package:duvet/encryption/recovery_key.dart';
import 'package:duvet/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import '../support/fake_repository.dart';

// The first device's recovery key and the app's word on encrypted conversations (PLAN-E2E-CLIENTES.md, Task 13): the
// desktop's RecoveryKeySheet.test.ts and the gate's rulings of its review.
const _key = 'abcdEFGHjkmnPQRS23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

Widget _app(Widget child, {FakeRepository? repository}) {
  final app = MaterialApp(
    theme: Duvet.material(Brightness.light),
    home: FTheme(
      data: Duvet.theme(Brightness.light),
      child: Scaffold(body: child),
    ),
  );
  return repository == null ? app : RepositoryScope(repository: repository, child: app);
}

/// A repository whose Set up makes the identity, as the engine does, and shows its key.
class _Repository extends FakeRepository {
  @override
  Future<void> makeIdentity() async {
    await super.makeIdentity();
    encryption.value = const EngineState.firstDevice(recoveryKey: _key);
  }
}

void main() {
  group('the recovery key', () {
    testWidgets('the_key_shows_in_12_groups_of_4', (tester) async {
      await tester.pumpWidget(_app(RecoveryKeyPage(recoveryKey: _key, onSaved: () async {}, onLater: () async {})));
      final groups = keyGroups(_key);
      expect(groups, hasLength(12));
      expect(groups.every((group) => group.length == 4), isTrue);
      expect(groups.join(), _key);
      // Each group drawn, in its order: row by row, four to a row.
      final drawn = [
        for (final text in tester.widgetList<Text>(find.byType(Text)))
          if (groups.contains(text.data)) text.data,
      ];
      expect(drawn, groups);
      expect(find.text(Notice.recoveryTitle.text), findsOneWidget);
    });

    testWidgets("nothing_goes_on_until_i_saved_it_is_ticked", (tester) async {
      var saved = 0;
      await tester.pumpWidget(
        _app(RecoveryKeyPage(recoveryKey: _key, onSaved: () async => saved++, onLater: () async {})),
      );
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(saved, 0);
      // Back leaves nothing either.
      expect(await tester.binding.handlePopRoute(), isTrue);
      expect(find.byType(RecoveryKeyPage), findsOneWidget);

      await tester.tap(find.text(Notice.recoverySaved.text));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(saved, 1);
    });

    testWidgets('a_failed_upload_says_so,_and_later_puts_it_off', (tester) async {
      var later = 0;
      await tester.pumpWidget(
        _app(
          RecoveryKeyPage(
            recoveryKey: _key,
            onSaved: () async => throw Exception('offline'),
            onLater: () async => later++,
          ),
        ),
      );
      expect(find.text('Later'), findsNothing);
      await tester.tap(find.text(Notice.recoverySaved.text));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text(recoveryFailed), findsOneWidget);
      await tester.ensureVisible(find.text('Later'));
      await tester.tap(find.text('Later'));
      await tester.pump();
      expect(later, 1);
    });
  });

  group('the gate', () {
    Future<_Repository> gate(WidgetTester tester, EngineState state) async {
      final repository = _Repository()..encryption.value = state;
      await tester.pumpWidget(_app(const EncryptionBanner(), repository: repository));
      return repository;
    }

    testWidgets('each_state_says_its_words,_and_nothing_while_starting_or_ready', (tester) async {
      final repository = await gate(tester, EngineState.starting);
      expect(find.byType(Text), findsNothing);
      for (final (state, words) in [
        (const EngineState.firstDevice(), 'Set up end-to-end encryption for your direct messages.'),
        (EngineState.removed, Notice.removedDevice.text),
        (EngineState.locked, Notice.locked.text),
        (EngineState.unsupported, Notice.noE2eHere.text),
        (const EngineState.update('1.1.0'), Notice.update.text),
        (const EngineState.update(null), Notice.noE2eHere.text),
        (
          const EngineState.failed(lostKey: true),
          "Your encrypted conversations can't be opened on this device: its key is gone.",
        ),
      ]) {
        repository.encryption.value = state;
        await tester.pump();
        expect(find.text(words), findsOneWidget, reason: '$state');
      }
      expect(find.text(Notice.deleteDevice.text), findsOneWidget);
      repository.encryption.value = EngineState.ready;
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('set_up_makes_the_identity_and_shows_its_key_until_it_is_done_with', (tester) async {
      final repository = await gate(tester, const EngineState.firstDevice());
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps, ['makeIdentity']);
      expect(find.byType(RecoveryKeyPage), findsOneWidget);
      // Saved and uploaded: the engine goes on, and the key's screen goes.
      repository.encryption.value = EngineState.ready;
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryKeyPage), findsNothing);
    });

    // M6 of the desktop's review: what deletes the device's data asks first.
    testWidgets('setting_up_again_asks_before_it_deletes_anything', (tester) async {
      final repository = await gate(tester, EngineState.removed);
      await tester.tap(find.text('Set up again'));
      await tester.pumpAndSettle();
      expect(find.text(startOverQuestion), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps, isEmpty);

      await tester.tap(find.text('Set up again'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up again').last);
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps, ['startOver']);
    });
  });
}
