import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duvet/data/appearance.dart';
import 'package:duvet/data/emoji_catalog.dart';
import 'package:duvet/data/models.dart';
import 'package:duvet/data/scope.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart' show CoreError;
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/encryption/qr.dart';
import 'package:duvet/encryption/safety_number.dart';
import 'package:duvet/main.dart';
import 'package:duvet/people.dart' show showProfileSheet;
import 'package:duvet/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../support/fake_repository.dart';

// A contact's security number, their mark and their changed key in the app's views (PLAN-E2E-CLIENTES.md, Task 29;
// decision 25): the desktop's SafetyNumber, VerifiedMark, KeyChangeNotice, ConversationView and Chat cases, and the
// scan the desktop doesn't have. The engine's side is test/e2e/contacts_test.dart's.
final _conventions = jsonDecode(File('test/e2e/e2e-conventions.json').readAsStringSync()) as Map<String, dynamic>;
const _maya = FakeRepository.maya;
const _digits = '12345 67890 12345 67890 12345 67890 12345 67890 12345 67890 12345 67890';
const SafetyNumber _number = (digits: _digits, qr: 'AQID');

Widget _app(Widget child, FakeRepository repository) => RepositoryScope(
  repository: repository,
  child: MaterialApp(
    theme: Duvet.material(Brightness.light),
    home: FTheme(data: Duvet.theme(Brightness.light), child: child),
  ),
);

/// Maya's security number's page, its camera the test's: what it reads goes to the function [onCamera] hands back.
Widget _page(FakeRepository repository, {void Function(ValueChanged<String> read)? onCamera}) => _app(
  SafetyNumberPage(
    repository,
    userId: _maya,
    name: 'Maya',
    camera: (onRead) {
      onCamera?.call(onRead);
      return const SizedBox();
    },
  ),
  repository,
);

/// The app, on a phone, with Maya's DM open, [setUp] run once the app is up.
Future<FakeRepository> _inMayasDM(WidgetTester tester, {void Function(FakeRepository repository)? setUp}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final repository = FakeRepository()..encryption.value = EngineState.ready;
  final appearance = Appearance(MemoryAppearanceStore());
  await appearance.load();
  addTearDown(appearance.dispose);
  await tester.pumpWidget(DuvetApp(repository: repository, appearance: appearance));
  await tester.pumpAndSettle();
  setUp?.call(repository);
  await tester.tap(find.text('Maya'));
  await tester.pumpAndSettle();
  return repository;
}

/// What's typed in the chat's message box now.
String _draft(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText).last).controller.text;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(EditableText).last, text);
  await tester.pump();
}

/// A tap on what [finder] finds, scrolled into view first: a list builds only what's near its view.
Future<void> _tapIn(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapLabel(WidgetTester tester, String label) async {
  await tester.tap(find.bySemanticsLabel(label).last);
  await tester.pumpAndSettle();
}

/// The phone's camera as mobile_scanner's platform sees it: its starts counted, each answering a moment later, as a
/// camera does.
class _Camera extends MobileScannerPlatform {
  var starts = 0;

  /// What it reads, as it reads it.
  final read = StreamController<BarcodeCapture?>.broadcast();

  @override
  Stream<BarcodeCapture?> get barcodesStream => read.stream;

  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();

  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();

  @override
  Widget buildCameraView() => const SizedBox();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    starts++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.unavailable,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> updateScanWindow(Rect? window) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    EmojiCatalog.debugUse(await EmojiCatalog.load());
  });

  group("a contact's security number", () {
    testWidgets('shows_its_60_digits_in_12_groups_of_5,_its_code,_and_mark_as_verified', (tester) async {
      final repository = FakeRepository()..safetyNumbers[_maya] = _number;
      await tester.pumpWidget(_page(repository));
      await tester.pumpAndSettle();
      expect(find.text('12345'), findsNWidgets(6));
      expect(find.text('67890'), findsNWidgets(6));
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text(Notice.verified.text), findsNothing);
      await _tapIn(tester, find.text(Notice.markVerified.text));
      expect(repository.encryptionTaps, ['verifyContact $_maya $_digits']);
      // Verified: the mark, and no button to mark them again.
      expect(find.text(Notice.verified.text), findsOneWidget);
      expect(find.text(Notice.markVerified.text), findsNothing);
    });

    testWidgets('a_contact_the_person_verified_wears_its_mark_there', (tester) async {
      final repository = FakeRepository()
        ..safetyNumbers[_maya] = _number
        ..contacts.value = const ContactsShown(verified: {_maya: true});
      await tester.pumpWidget(_page(repository));
      await tester.pumpAndSettle();
      expect(find.text(Notice.verified.text), findsOneWidget);
      expect(find.text(Notice.markVerified.text), findsNothing);
    });

    testWidgets('a_number_that_changed_meanwhile_is_shown_anew,_and_says_so', (tester) async {
      final repository = FakeRepository()
        ..safetyNumbers[_maya] = _number
        ..verifyAnswer = false;
      await tester.pumpWidget(_page(repository));
      await tester.pumpAndSettle();
      const now = '99999 67890 12345 67890 12345 67890 12345 67890 12345 67890 12345 67890';
      repository.safetyNumbers[_maya] = (digits: now, qr: 'BAUG');
      await _tapIn(tester, find.text(Notice.markVerified.text));
      expect(find.text(safetyChanged('Maya')), findsOneWidget);
      expect(find.text('99999'), findsOneWidget);
      expect(find.text(Notice.verified.text), findsNothing);
    });

    testWidgets("says_why_there's_no_number:_no_identity_of_theirs_yet,_or_one_that_didn't_load", (tester) async {
      final repository = FakeRepository()..safetyNumberError = CoreError('needs_identities', users: const [_maya]);
      await tester.pumpWidget(_page(repository));
      await tester.pumpAndSettle();
      expect(find.text(safetyNone('Maya')), findsOneWidget);
      expect(find.text(Notice.markVerified.text), findsNothing);

      repository.safetyNumberError = Exception('offline');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_page(repository));
      await tester.pumpAndSettle();
      expect(find.text(safetyFailed), findsOneWidget);
    });

    // Rule 6 of review 28's list for this task: the text read goes unchanged to the core, for the contact whose number
    // is open.
    testWidgets("scanning_hands_the_code's_text_to_the_core_as_read,_for_the_contact_whose_number_is_open", (
      tester,
    ) async {
      final repository = FakeRepository()..safetyNumbers[_maya] = _number;
      ValueChanged<String>? read;
      await tester.pumpWidget(_page(repository, onCamera: (onRead) => read = onRead));
      await tester.pumpAndSettle();
      expect(read, isNull, reason: 'the camera opens on the tap alone');
      await _tapIn(tester, find.text(scanTheirCode));
      // A text as a scanner reads it, with what a code can hold.
      const scanned = 'omF2AWV1c2Vyc4Ki+/=';
      read!(scanned);
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps, ['verifyScanned $_maya $scanned']);
      expect(find.text(Notice.verified.text), findsOneWidget);
    });

    testWidgets("a_scanned_code_that_doesn't_match_says_so,_and_one_that_isn't_a_number's_says_that", (tester) async {
      final repository = FakeRepository()
        ..safetyNumbers[_maya] = _number
        ..verifyAnswer = false;
      ValueChanged<String>? read;
      await tester.pumpWidget(_page(repository, onCamera: (onRead) => read = onRead));
      await tester.pumpAndSettle();
      await _tapIn(tester, find.text(scanTheirCode));
      read!('another pair');
      await tester.pumpAndSettle();
      expect(find.text(codesDontMatch('Maya')), findsOneWidget);
      expect(find.text(Notice.verified.text), findsNothing);

      repository.verifyScannedError = CoreError('bad_command', field: 'qr');
      await _tapIn(tester, find.text(scanAgain));
      read!('not a code');
      await tester.pumpAndSettle();
      expect(find.text(notASecurityCode), findsOneWidget);
    });

    // Review 29's Minor 5: the scanner's widget starts the camera, once for each scan; a start of the page's own beside
    // it would be refused while the widget's is under way.
    testWidgets('scan_their_code_starts_the_camera_once_for_each_scan', (tester) async {
      final camera = _Camera();
      final before = MobileScannerPlatform.instance;
      MobileScannerPlatform.instance = camera;
      addTearDown(() => MobileScannerPlatform.instance = before);
      final repository = FakeRepository()
        ..safetyNumbers[_maya] = _number
        ..verifyAnswer = false;
      await tester.pumpWidget(_app(SafetyNumberPage(repository, userId: _maya, name: 'Maya'), repository));
      await tester.pumpAndSettle();
      await _tapIn(tester, find.text(scanTheirCode));
      await tester.pump(const Duration(seconds: 1));
      expect(camera.starts, 1);
      // A code read, which doesn't match: Scan again builds the scanner anew, which starts the camera again.
      camera.read.add(const BarcodeCapture(barcodes: [Barcode(rawValue: 'another pair')]));
      await tester.pumpAndSettle();
      expect(find.text(codesDontMatch('Maya')), findsOneWidget);
      await _tapIn(tester, find.text(scanAgain));
      await tester.pump(const Duration(seconds: 1));
      expect(camera.starts, 2);
    });
  });

  // The convention both apps keep (e2e-conventions.json's safety_qr; «Convenciones entre clientes»).
  test("a_security_number's_qr_is_the_core's_qr_as_its_text,_in_byte_mode_at_level_M", () {
    final convention = _conventions['safety_qr'] as Map<String, dynamic>;
    final qr = convention['qr'] as String;
    expect(convention['text'], qr);
    expect(convention['error_correction'], 'M');
    final code = ApprovalQr.codeOf(qr);
    expect(code.errorCorrectLevel, QrErrorCorrectLevel.M);
    // The same modules as the text's bytes put in byte mode by hand: nothing decoded, nothing changed.
    final byHand = QrCode(code.typeNumber, QrErrorCorrectLevel.M)
      ..addByteData(ByteData.sublistView(Uint8List.fromList(utf8.encode(qr))));
    final (drawn, expected) = (QrImage(code), QrImage(byHand));
    for (var row = 0; row < drawn.moduleCount; row++) {
      for (var col = 0; col < drawn.moduleCount; col++) {
        expect(drawn.isDark(row, col), expected.isDark(row, col));
      }
    }
  });

  test('what_waits_for_the_yes_says_the_strong_words,_naming_them', () {
    expect(heldFor(['Maya']), Notice.keyChangedVerified.fill({'name': 'Maya'}));
    expect(heldFor(['Maya', 'Leo']), Notice.keyChangedVerified.fill({'name': 'Maya and Leo'}));
  });

  group("a contact's changed key in their conversations", () {
    testWidgets('its_notice_shows_over_the_message_box,_the_strong_one_for_a_verified_contact,_and_closes', (
      tester,
    ) async {
      final repository = await _inMayasDM(
        tester,
        setUp: (repository) =>
            repository.keyChanges['c-maya'] = {_maya: const KeyChange(verified: false, change: 'c1')},
      );
      final plain = find.text(Notice.keyChanged.fill({'name': 'Maya'}));
      expect(plain, findsOneWidget);
      // Over the message box: above its field.
      expect(tester.getBottomLeft(plain).dy, lessThan(tester.getTopLeft(find.byType(EditableText).last).dy));
      await _tapLabel(tester, closeNotice);
      expect(repository.encryptionTaps, ['closeKeyChange $_maya c1']);
      expect(plain, findsNothing);

      repository.keyChanges['c-maya'] = {_maya: const KeyChange(verified: true, change: 'c2')};
      repository.contacts.value = const ContactsShown(changes: {_maya: KeyChange(verified: true, change: 'c2')});
      await tester.pumpAndSettle();
      expect(
        find.text('${Notice.keyChanged.fill({'name': 'Maya'})} ${Notice.keyChangedVerified.fill({'name': 'Maya'})}'),
        findsOneWidget,
      );
      // Its Verify security number opens the number.
      repository.safetyNumbers[_maya] = _number;
      await tester.tap(find.text(Notice.verifyNumber.text).last);
      await tester.pumpAndSettle();
      expect(find.byType(SafetyNumberPage), findsOneWidget);
    });

    // Rule 8 of review 28's list for this task: a no keeps what was written.
    testWidgets("a_verified_contact's_changed_key_asks_before_sending,_and_a_no_keeps_the_draft", (tester) async {
      final repository = await _inMayasDM(
        tester,
        setUp: (repository) =>
            repository.keyChanges['c-maya'] = {_maya: const KeyChange(verified: true, closed: true, change: 'c1')},
      );
      // A closed strong notice still asks: closing it isn't the yes.
      const replying = 'Replying to Maya — Hey! Did you see the new tab bar?';
      await tester.longPress(find.text('Hey! Did you see the new tab bar?'));
      await tester.pumpAndSettle();
      await _tapLabel(tester, 'Reply');
      await _type(tester, 'are you still you?');
      await _tapLabel(tester, 'Send');
      expect(find.text(heldFor(['Maya'])), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.sent, isEmpty);
      expect(_draft(tester), 'are you still you?');
      expect(find.text(replying), findsOneWidget);

      await _tapLabel(tester, 'Send');
      await tester.tap(find.text(Notice.sendAnyway.text));
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps, ['confirmKeyChanges $_maya:c1']);
      expect([for (final sent in repository.sent) (sent.content, sent.replyTo)], [('are you still you?', 'm1')]);
      expect(_draft(tester), isEmpty);
      expect(find.text(replying), findsNothing);
    });

    // Review 29's Important 2: the ask waits for the engine's turn, which the work ahead of it can make long. What was
    // typed leaves the box as the send begins, so an Enter meanwhile sends nothing twice.
    testWidgets('two_sends_before_the_ask_answers_post_one_message', (tester) async {
      final repository = await _inMayasDM(tester, setUp: (repository) => repository.holdKeyChanges = Completer());
      await _type(tester, 'just once');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      repository.holdKeyChanges!.complete();
      await tester.pumpAndSettle();
      expect([for (final sent in repository.sent) sent.content], ['just once']);
      expect(_draft(tester), isEmpty);
    });

    // The same with a file: the send waits for the upload limit before it takes the box, and one that finds the box
    // taken by then sends nothing.
    testWidgets('two_sends_of_a_file_before_the_upload_limit_answers_post_one_message', (tester) async {
      const file = OutgoingFile(path: '/plan.txt', name: 'plan.txt', contentType: 'text/plain', sizeBytes: 4);
      final repository = await _inMayasDM(
        tester,
        setUp: (repository) {
          repository.holdUploadLimit = Completer();
          repository.drafts['c-maya'] = const ChatDraft(text: 'the plan', files: [file]);
        },
      );
      await _tapLabel(tester, 'Send');
      await _tapLabel(tester, 'Send');
      repository.holdUploadLimit!.complete();
      await tester.pumpAndSettle();
      expect([for (final sent in repository.sent) (sent.content, sent.files.length)], [('the plan', 1)]);
      expect(_draft(tester), isEmpty);
    });

    // What a send took out of the box while the ask waited stays the chat's draft when the person leaves the chat
    // meanwhile: it isn't sent, and the box has it again as the chat opens.
    testWidgets('a_chat_left_while_the_ask_waits_keeps_what_was_typed_as_its_draft', (tester) async {
      final repository = await _inMayasDM(tester, setUp: (repository) => repository.holdKeyChanges = Completer());
      await _type(tester, 'for later');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await _tapLabel(tester, 'Back');
      repository.holdKeyChanges!.complete();
      await tester.pumpAndSettle();
      expect(repository.sent, isEmpty);
      expect(repository.drafts['c-maya']?.text, 'for later');
      await tester.tap(find.text('Maya'));
      await tester.pumpAndSettle();
      expect(_draft(tester), 'for later');
    });

    testWidgets("an_edit's_no_keeps_its_box,_and_what_was_typed_in_it", (tester) async {
      final repository = await _inMayasDM(
        tester,
        setUp: (repository) => repository.history['c-maya']!.add(
          FakeRepository.message('m9', author: FakeRepository.me.id, name: 'Gaby', text: 'my own words'),
        ),
      );
      await tester.longPress(find.text('my own words'));
      await tester.pumpAndSettle();
      await _tapLabel(tester, 'Edit');
      repository.keyChanges['c-maya'] = {_maya: const KeyChange(verified: true, change: 'c1')};
      await _type(tester, 'edited');
      await _tapLabel(tester, 'Save edit');
      expect(find.text(heldFor(['Maya'])), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.edits, isEmpty);
      expect(_draft(tester), 'edited');
      expect(find.bySemanticsLabel('Save edit'), findsWidgets);
    });

    testWidgets("a_DM_wears_its_contact's_mark", (tester) async {
      await _inMayasDM(
        tester,
        setUp: (repository) => repository.contacts.value = const ContactsShown(verified: {_maya: true}),
      );
      expect(find.byType(VerifiedMark), findsOneWidget);
    });
  });

  group("a contact's profile", () {
    Future<FakeRepository> profile(WidgetTester tester, {ContactsShown contacts = ContactsShown.none}) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final repository = FakeRepository()
        ..encryption.value = EngineState.ready
        ..safetyNumbers[_maya] = _number
        ..contacts.value = contacts;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showProfileSheet(
                    context,
                    member: const Member(userId: _maya, username: 'maya', alias: 'Maya'),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          repository,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('offers_their_security_number,_and_looks_at_them_as_it_opens', (tester) async {
      final repository = await profile(tester);
      expect(repository.contactLooks, [_maya]);
      expect(find.byType(VerifiedMark), findsNothing);
      await _tapLabel(tester, Notice.verifyNumber.text);
      expect(find.byType(SafetyNumberPage), findsOneWidget);
      expect(find.text('12345'), findsWidgets);
    });

    testWidgets("wears_a_verified_contact's_mark", (tester) async {
      await profile(tester, contacts: const ContactsShown(verified: {_maya: true}));
      expect(find.byType(VerifiedMark), findsOneWidget);
    });
  });
}
