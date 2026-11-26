import 'dart:async';
import 'dart:convert';

import 'package:duvet/data/scope.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/encryption/gate.dart';
import 'package:duvet/encryption/recovery_key.dart';
import 'package:duvet/theme.dart';
import 'package:duvet/widgets/chrome.dart';
import 'package:duvet/widgets/rows.dart' show TextAction;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Android's save dialog as file_picker opens it (ACTION_CREATE_DOCUMENT): what it was handed, saved where the person
/// picked.
class _SaveDialog extends FilePickerPlatform {
  final saved = <({String fileName, Uint8List bytes, String mimeType})>[];

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saved.add((fileName: fileName, bytes: bytes, mimeType: mimeType));
    return Uri.parse('content://com.android.externalstorage.documents/document/primary%3ADuvet%2F$fileName');
  }
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

    // The desktop's Copy and Download (M4 of the review). Save file goes through Android's own save dialog, which
    // writes the file only where the person picks: never through the share sheet, whose copies stay in the app's cache
    // (I1).
    testWidgets('offers_to_copy_the_key_and_to_download_it', (tester) async {
      final dialog = _SaveDialog();
      final before = FilePickerPlatform.instance;
      FilePickerPlatform.instance = dialog;
      addTearDown(() => FilePickerPlatform.instance = before);
      final copied = <Object?>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map<Object?, Object?>)['text']);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(_app(RecoveryKeyPage(recoveryKey: _key, onSaved: () async {}, onLater: () async {})));
      final grouped = keyGroups(_key).join(' ');

      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, [grouped]);
      expect(find.text('Copied'), findsOneWidget);

      await tester.tap(find.text('Save file'));
      await tester.pump();
      final saved = dialog.saved.single;
      expect((saved.fileName, saved.mimeType), ('duvet-recovery-key.txt', 'text/plain'));
      expect(utf8.decode(saved.bytes), 'Duvet recovery key\n\n$grouped\n');
      // Copied goes back to Copy.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Copy'), findsOneWidget);
    });

    // I2 of the desktop's review: the key saved, what's left is its upload.
    testWidgets('after_a_failed_upload,_later_closes_the_sheet_beside_continue,_which_tries_again', (tester) async {
      var tries = 0;
      var later = 0;
      await tester.pumpWidget(
        _app(
          RecoveryKeyPage(
            recoveryKey: _key,
            onSaved: () async {
              tries++;
              throw Exception('offline');
            },
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
      // Continue tries again.
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(tries, 2);
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

    // M3 of the review: the key's page follows the state, as the desktop's dialog does: no bar, nor its ×, stands in
    // for it.
    testWidgets("with_the_key_made,_draws_no_bar:_the_key's_dialog_has_the_screen", (tester) async {
      await gate(tester, const EngineState.firstDevice(recoveryKey: _key));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryKeyPage), findsOneWidget);
      // The page's title alone, and nothing of a bar under the page.
      expect(find.text(Notice.recoveryTitle.text, skipOffstage: false), findsOneWidget);
      expect(find.text('Show key', skipOffstage: false), findsNothing);
      expect(
        find.byWidgetPredicate((widget) => widget is IconAction && widget.label == 'Dismiss', skipOffstage: false),
        findsNothing,
      );
    });

    // M3: the key's page takes its own route away as the key goes, never the route above it: an incoming call's.
    testWidgets("the_key's_page_goes_with_its_key,_and_never_takes_the_route_above_it", (tester) async {
      final repository = await gate(tester, const EngineState.firstDevice());
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryKeyPage), findsOneWidget);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Ringing')))));
      await tester.pumpAndSettle();

      repository.encryption.value = EngineState.ready;
      await tester.pumpAndSettle();
      expect(find.text('Ringing'), findsOneWidget);
      expect(find.byType(RecoveryKeyPage, skipOffstage: false), findsNothing);
      // Back from the call, the app, with the key's page gone.
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(EncryptionBanner), findsOneWidget);
      expect(find.byType(RecoveryKeyPage, skipOffstage: false), findsNothing);
    });

    // Task 25: a rotation's new key has the screen; one cut before its upload is finished by the person's tap, which
    // runs the same rotation again (Change security keys), its key's page following.
    testWidgets("a_rotation's_new_key_has_the_screen,_and_one_cut_before_its_upload_is_finished_by_the_person's_tap", (
      tester,
    ) async {
      final repository = await gate(tester, const EngineState.rotation(recoveryKey: _key));
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryKeyPage), findsOneWidget);
      // Why this key, in the desktop's words: the keys changed, and the recovery key with them.
      expect(find.text(rotationWhy), findsOneWidget);
      expect(find.text('Finish', skipOffstage: false), findsNothing);
      // Saved: the key's page goes, with no bar.
      repository.encryption.value = EngineState.ready;
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryKeyPage), findsNothing);
      expect(find.byType(Text), findsNothing);

      repository.encryption.value = const EngineState.rotation();
      await tester.pumpAndSettle();
      expect(find.text('Finish changing your security keys.'), findsOneWidget);
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps, ['changeKeys']);
    });

    // Review 24's I1 and review 25's I1: a key change that can't finish says why, with the one way out this core
    // leaves: no Finish, and this device's data deleted and set up again, as another device's change of keys can't
    // reach it (duvetchat/e2e#49).
    testWidgets("a_key_change_that_can't_finish_says_why,_with_deleting_this_device's_data", (tester) async {
      await gate(tester, const EngineState.rotation(stuck: true));
      await tester.pumpAndSettle();
      expect(find.textContaining("This change of your security keys can't finish"), findsOneWidget);
      expect(find.textContaining("delete this device's data and set it up again"), findsOneWidget);
      expect(find.textContaining('on another device'), findsNothing);
      expect(find.text('Finish'), findsNothing);
      expect(find.text(Notice.deleteDevice.text), findsOneWidget);
    });

    // Task 33: a new device's restore shows as it goes, a strip with nothing to press but its ×, which hides it alone:
    // a later strip of the ready state still shows.
    testWidgets("a_new_device's_restore_shows_as_it_goes,_with_nothing_to_press_but_its_×", (tester) async {
      final repository = await gate(tester, EngineState.ready);
      expect(find.byType(Text), findsNothing);
      repository.backup.value = const BackupShown.restoring(12, 40);
      await tester.pump();
      expect(find.text('Restoring your messages: 12 of 40'), findsOneWidget);
      expect(find.byType(TextAction), findsNothing);
      repository.backup.value = const BackupShown.restoring(13, 40);
      await tester.pump();
      expect(find.text('Restoring your messages: 13 of 40'), findsOneWidget);
      // Its × hides the restore's strip, and only it.
      await tester.tap(find.byWidgetPredicate((widget) => widget is IconAction && widget.label == 'Dismiss'));
      await tester.pump();
      expect(find.byType(Text), findsNothing);
      repository.encryption.value = const EngineState.rotation();
      await tester.pump();
      expect(find.text('Finish changing your security keys.'), findsOneWidget);
      // Done, nothing of it shows; nor does a pause, which Settings says.
      repository
        ..encryption.value = EngineState.ready
        ..backup.value = const BackupShown.paused(BackupPause.full);
      await tester.pump();
      expect(find.byType(Text), findsNothing);
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
