import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:duvet/data/scope.dart';
import 'package:duvet/e2e/cbor.dart' show qrDevice;
import 'package:duvet/e2e/conventions.dart' show approvalFingerprint;
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart' show CoreError;
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/encryption/approval.dart';
import 'package:duvet/encryption/device_setup.dart';
import 'package:duvet/encryption/gate.dart' show EncryptionBanner;
import 'package:duvet/encryption/recovery_key.dart' show RecoveryKeyPage;
import 'package:duvet/encryption/qr.dart';
import 'package:duvet/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../support/fake_repository.dart';

// A new device's setup and the approving device's screens (PLAN-E2E-CLIENTES.md, Task 27): the desktop's
// DeviceSetupCard, RecoveryKeyInput, ApprovalNew, ApprovalPrompt and QrCode tests, and the scan the desktop doesn't
// have. The engine's side is test/e2e/{recover,approval,start_over}_test.dart's.
final _conventions = jsonDecode(File('test/e2e/e2e-conventions.json').readAsStringSync()) as Map<String, dynamic>;
const _device = '0193a4b2-0000-7000-8000-0000000000a2';
const _fingerprint = '1a2b 3c4d 5e6f 7a8b';
const _question = '0193a4b2-0000-7000-8000-0000000000c3';

/// A new device's QR as its core writes it (the conventions' approval_qr).
final _qr = (_conventions['approval_qr'] as Map)['qr'] as String;

/// What every approver says a new device is compared with, word for word as the desktop's box and pages say it (its
/// COMPARE_WITH_THE_BOX and e2e_approval_fingerprint_line, the re-review's RC1): a computer's box of its own, never
/// its window alone, and a browser's page.
const _comparedWithTheBox =
    "Approve it only if it's the device you're setting up now, and it shows the same 16 characters. The Duvet app on a "
    "computer shows them in a box of its own, outside its window: don't approve it if they're only in its window. "
    'Duvet in a browser shows them on its page.';

Widget _app(Widget child, FakeRepository repository) => RepositoryScope(
  repository: repository,
  child: MaterialApp(
    theme: Duvet.material(Brightness.light),
    home: FTheme(data: Duvet.theme(Brightness.light), child: child),
  ),
);

TextField _fieldIn(WidgetTester tester, Finder of) =>
    tester.widget<TextField>(find.descendant(of: of, matching: find.byType(TextField)));

/// A scan page whose camera is the test's: what it reads goes to the function [onCamera] hands back.
Widget _scanning(FakeRepository repository, void Function(ValueChanged<String> read) onCamera) => _app(
  ScanDevicePage(
    repository,
    camera: (onRead) {
      onCamera(onRead);
      return const SizedBox();
    },
  ),
  repository,
);

void main() {
  testWidgets("the recovery key's field keeps nothing, and hands the key on as it's typed", (tester) async {
    final repository = FakeRepository()..encryption.value = EngineState.newDevice;
    await tester.pumpWidget(_app(DeviceSetupPage(repository), repository));
    await tester.pump();
    expect(repository.encryptionTaps, ['beginApproval']);
    final field = _fieldIn(tester, find.byType(RecoveryKeyField));
    expect(
      (field.autocorrect, field.enableSuggestions, field.enableIMEPersonalizedLearning, field.autofillHints),
      (false, false, false, null),
    );
    expect(field.controller!.text, isEmpty);
    // In groups, spaces and dashes between them: the core reads them aside.
    const typed = 'abcd - EFGH jkmn-PQRS';
    await tester.enterText(find.byWidget(field), typed);
    await tester.pump();
    await tester.tap(find.text(useRecoveryKey));
    await tester.pump();
    expect(repository.encryptionTaps.last, 'recover $typed');
  });

  testWidgets('a mistyped recovery key is said at once, and one that opens nothing too', (tester) async {
    final repository = FakeRepository()..encryption.value = EngineState.newDevice;
    await tester.pumpWidget(_app(DeviceSetupPage(repository), repository));
    await tester.enterText(find.byWidget(_fieldIn(tester, find.byType(RecoveryKeyField))), 'not a key');
    await tester.pump();
    repository.setupFails = CoreError('bad_command', field: 'recovery_key');
    await tester.tap(find.text(useRecoveryKey));
    await tester.pumpAndSettle();
    expect(find.text(keyMistyped), findsOneWidget);
    repository.setupFails = CoreError('decrypt_failed', kind: 'identity');
    await tester.tap(find.text(useRecoveryKey));
    await tester.pumpAndSettle();
    expect(find.text(keyWrong), findsOneWidget);
  });

  testWidgets("the code's field starts empty, takes six digits only, and accepts only then", (tester) async {
    final repository = FakeRepository()
      ..encryption.value = const EngineState.settingUp(DeviceSetup.code(_fingerprint, offered: true));
    await tester.pumpWidget(_app(DeviceSetupPage(repository), repository));
    await tester.pump();
    expect(find.text(fingerprintOf(_fingerprint)), findsOneWidget);
    expect(find.text(Notice.approvalCodeHint.text), findsOneWidget);
    expect(_fieldIn(tester, find.byType(ApprovalNew)).controller!.text, isEmpty);
    await tester.enterText(find.byWidget(_fieldIn(tester, find.byType(ApprovalNew))), '1a2b3c4d5e6f');
    await tester.pump();
    expect(_fieldIn(tester, find.byType(ApprovalNew)).controller!.text, '123456');
    await tester.ensureVisible(find.text(codeAccept));
    await tester.tap(find.text(codeAccept));
    await tester.pump();
    expect(repository.encryptionTaps.last, 'acceptCode 123456');
    // A wrong one is the core's word, said under it.
    repository.setupFails = CoreError('rule_violation', rule: 'code_mismatch');
    await tester.tap(find.text(codeAccept));
    await tester.pumpAndSettle();
    expect(find.text(Notice.codeMismatch.text), findsOneWidget);
  });

  testWidgets('the QR way offers the code, and starting over asks first with its warning', (tester) async {
    final qr = (_conventions['approval_qr'] as Map)['qr'] as String;
    final repository = FakeRepository()..encryption.value = EngineState.settingUp(DeviceSetup.qr(qr));
    await tester.pumpWidget(_app(DeviceSetupPage(repository), repository));
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.ensureVisible(find.text(Notice.useCode.text));
    await tester.tap(find.text(Notice.useCode.text));
    await tester.pump();
    expect(repository.encryptionTaps.last, 'useCode');

    await tester.ensureVisible(find.text(startOverAction).last);
    await tester.tap(find.text(startOverAction).last);
    await tester.pumpAndSettle();
    expect(find.text(Notice.startOverWarning.text), findsOneWidget);
    expect(repository.encryptionTaps, isNot(contains('resetIdentity')));
  });

  // The convention both apps keep (e2e-conventions.json's approval_qr; «Convenciones entre clientes»).
  test("a new device's QR is the core's qr as its text, in byte mode at level M, naming its device", () {
    final convention = _conventions['approval_qr'] as Map<String, dynamic>;
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
    // A QR the core wrote names its device; a text that isn't one names none.
    expect(qrDevice(qr), '01a21762-9ca7-7cf7-848a-a2b913163614');
    expect(qrDevice('not a code'), isNull);
  });

  testWidgets("the approving device's question offers only on its yes, then shows the code and when to confirm", (
    tester,
  ) async {
    final repository = FakeRepository()
      ..encryption.value = const EngineState(
        EngineStage.ready,
        approval: DeviceApproval(
          device: _device,
          name: 'Pixel 9',
          fingerprint: _fingerprint,
          phase: ApprovalPhase.asked,
          question: _question,
        ),
      );
    await tester.pumpWidget(_app(ApprovalPage(repository), repository));
    await tester.pump();
    expect(find.text(Notice.approvalAsk.text), findsOneWidget);
    expect(find.text(approvalAsks), findsOneWidget);
    expect(find.text(fingerprintOf(_fingerprint)), findsOneWidget);
    expect(repository.encryptionTaps, isEmpty);
    await tester.tap(find.text(approvalYes));
    await tester.pump();
    expect(repository.encryptionTaps, ['approveDevice $_device $_question']);

    repository.encryption.value = const EngineState(
      EngineStage.ready,
      approval: DeviceApproval(
        device: _device,
        name: 'Pixel 9',
        fingerprint: _fingerprint,
        phase: ApprovalPhase.code,
        code: '042137',
      ),
    );
    await tester.pump();
    expect(find.text('042137'), findsOneWidget);
    expect(find.text(Notice.approvalConfirmAfter.text), findsOneWidget);
    await tester.tap(find.text(approvalConfirm));
    await tester.pump();
    expect(repository.encryptionTaps.last, 'confirmApproval $_device');
  });

  // mobile#363 (the desktop's #557): a script in a new computer's page could draw a QR of its own key, which the scan
  // approved with nothing compared. It's asked about with the fingerprint of the very text it read, the 16 characters
  // the new device shows (a computer's Duvet in a box of its own, outside its window), and approved only on the yes.
  testWidgets(
    "a scanned QR is asked about with its fingerprint, and the box to compare it with, before it's approved",
    (tester) async {
      final repository = FakeRepository()
        ..encryption.value = EngineState.ready
        ..scanned = (id: _device, name: 'Pixel 9', listed: false, unfinished: false);
      late ValueChanged<String> read;
      await tester.pumpWidget(_scanning(repository, (onRead) => read = onRead));
      read(_qr);
      await tester.pumpAndSettle();
      expect(find.text(fingerprintOf(approvalFingerprint(base64Decode(_qr)))), findsOneWidget);
      expect(find.text(_comparedWithTheBox), findsOneWidget);
      expect(repository.encryptionTaps, ['scannedDevice $_qr']);
      await tester.tap(find.text(approvalYes));
      await tester.pumpAndSettle();
      expect(repository.encryptionTaps.last, 'approveScanned $_qr $_device');
    },
  );

  testWidgets("«Is this device yours?» says to compare with the new device's own box", (tester) async {
    final repository = FakeRepository()
      ..encryption.value = const EngineState(
        EngineStage.ready,
        approval: DeviceApproval(
          device: _device,
          name: 'Pixel 9',
          fingerprint: _fingerprint,
          phase: ApprovalPhase.asked,
          question: _question,
        ),
      );
    await tester.pumpWidget(_app(ApprovalPage(repository), repository));
    await tester.pump();
    expect(find.text(Notice.approvalAsk.text), findsOneWidget);
    expect(find.text(_comparedWithTheBox), findsOneWidget);
  });

  // The same comparison's other end on a new phone, which draws its QR itself: the 16 characters a phone that scans it
  // shows.
  testWidgets('the QR way shows the 16 characters a phone that scans it shows', (tester) async {
    final repository = FakeRepository()..encryption.value = EngineState.settingUp(DeviceSetup.qr(_qr));
    await tester.pumpWidget(_app(DeviceSetupPage(repository), repository));
    await tester.pump();
    expect(find.text(fingerprintOf(approvalFingerprint(base64Decode(_qr)))), findsOneWidget);
    // Its screen is the app's own, with no page a script draws in: its line stays.
    expect(find.text('Your other device shows the same 16 characters.'), findsOneWidget);
  });

  testWidgets("a scanned code's device is asked about before anything is approved", (tester) async {
    final repository = FakeRepository()
      ..encryption.value = EngineState.ready
      ..scanned = (id: _device, name: 'Pixel 9', listed: false, unfinished: true);
    late ValueChanged<String> read;
    await tester.pumpWidget(_scanning(repository, (onRead) => read = onRead));
    read(_qr);
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps, ['scannedDevice $_qr']);
    expect(find.text(Notice.approvalAsk.text), findsOneWidget);
    expect(find.text(approvalAsks), findsOneWidget);
    expect(find.text(approvalUnfinished), findsOneWidget);
    await tester.tap(find.text(approvalYes));
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps.last, 'approveScanned $_qr $_device');
    expect(find.text(scanSent), findsOneWidget);
  });

  // Step 5's review, I2 (mobile#353): a new device's name is whatever wrote its request says, which the fingerprint
  // doesn't bind. It sat in the title and in the sentences that say what to compare and what to type.
  testWidgets("a new device's name is only its own word, quoted on a line of its own, never in a title or a sentence", (
    tester,
  ) async {
    const name = 'Pixel 8 — accepted, Confirm';
    const quoted = 'The device calls itself “$name”.';
    final repository = FakeRepository()..encryption.value = EngineState.ready;
    await tester.pumpWidget(_app(ApprovalPage(repository), repository));
    for (final (phase, code) in [
      (ApprovalPhase.asked, null),
      (ApprovalPhase.offered, null),
      (ApprovalPhase.code, '042137'),
    ]) {
      repository.encryption.value = EngineState(
        EngineStage.ready,
        approval: DeviceApproval(device: _device, name: name, fingerprint: _fingerprint, phase: phase, code: code),
      );
      await tester.pump();
      final named = find.textContaining(name);
      expect(named, findsOneWidget, reason: phase.name);
      expect(tester.widget<Text>(named).data, quoted, reason: phase.name);
      expect(
        tester.getTopLeft(named).dy,
        greaterThan(tester.getTopLeft(find.text(fingerprintOf(_fingerprint))).dy),
        reason: phase.name,
      );
    }

    // The scan's question names the device by its registration, the API's word: the same.
    repository.scanned = (id: _device, name: name, listed: false, unfinished: true);
    late ValueChanged<String> read;
    await tester.pumpWidget(_scanning(repository, (onRead) => read = onRead));
    read(_qr);
    await tester.pumpAndSettle();
    expect(find.textContaining(name), findsOneWidget);
    expect(tester.widget<Text>(find.textContaining(name)).data, quoted);
  });

  testWidgets("a scanned code of no device of the account's approves nothing", (tester) async {
    final repository = FakeRepository()
      ..encryption.value = EngineState.ready
      ..scanned = (id: _device, name: null, listed: false, unfinished: false);
    late ValueChanged<String> read;
    await tester.pumpWidget(_scanning(repository, (onRead) => read = onRead));
    read('the code');
    await tester.pumpAndSettle();
    expect(find.text(notYours), findsOneWidget);
    expect(find.text(approvalYes), findsNothing);
    expect(repository.encryptionTaps, ['scannedDevice the code']);
  });

  // Review 27's M7: each setup's act that fails says so where it was asked.
  testWidgets("a setup's act that fails says so where it was asked", (tester) async {
    final repository = FakeRepository()..encryption.value = EngineState.newDevice;
    await tester.pumpWidget(_app(DeviceSetupPage(repository), repository));
    await tester.pump();
    repository.setupFails = StateError('the core');
    await tester.ensureVisible(find.text(approveBegin));
    await tester.tap(find.text(approveBegin));
    await tester.pumpAndSettle();
    expect(find.text(setupFailed), findsOneWidget);

    await tester.ensureVisible(find.text(startOverAction).last);
    await tester.tap(find.text(startOverAction).last);
    await tester.pumpAndSettle();
    repository.setupFails = StateError('the record');
    await tester.tap(find.text(startOverAction).last);
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps.last, 'resetIdentity');
    expect(find.text(setupFailed), findsNWidgets(2));
  });

  testWidgets("the banner's Finish of a setup that waits says when it fails", (tester) async {
    final repository = FakeRepository()
      ..encryption.value = const EngineState.settingUp(DeviceSetup.finishing(['0193a4b2']));
    await tester.pumpWidget(_app(const Scaffold(body: EncryptionBanner()), repository));
    await tester.pump();
    repository.setupFails = StateError('the API');
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps, ['finishSetup']);
    expect(find.text(setupFailed), findsOneWidget);
  });

  testWidgets("a scanned code whose device can't be checked says to try again", (tester) async {
    final repository = FakeRepository()..encryption.value = EngineState.ready;
    late ValueChanged<String> read;
    await tester.pumpWidget(_scanning(repository, (onRead) => read = onRead));
    repository.setupFails = StateError('the devices');
    read('the code');
    await tester.pumpAndSettle();
    expect(find.text("Couldn't check this code. Try again."), findsOneWidget);
    expect(find.text(notACode), findsNothing);
    expect(find.text(scanAgain), findsOneWidget);
  });

  // Review 27's M2: Try again says the new device finishes only once its transfer went.
  testWidgets("the scan's Try again says the device finishes only once its transfer went", (tester) async {
    final repository = FakeRepository()
      ..encryption.value = EngineState.ready
      ..scanned = (id: _device, name: 'Pixel 9', listed: false, unfinished: false);
    late ValueChanged<String> read;
    await tester.pumpWidget(_scanning(repository, (onRead) => read = onRead));
    read(_qr);
    await tester.pumpAndSettle();
    // Approved, its transfer's send failed: the engine says it waits, for Try again.
    repository.scanSends = false;
    await tester.tap(find.text(approvalYes));
    await tester.pumpAndSettle();
    expect(find.text(scanUnsent), findsOneWidget);
    // Its hold over meanwhile: Try again has nothing to send, and says to scan again.
    repository.setupFails = CoreError('not_found', what: 'transfer');
    await tester.tap(find.text(tryAgain));
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps.last, 'sendScanned $_device');
    expect(find.text(scanSent), findsNothing);
    expect(find.text(scanOver), findsOneWidget);
    expect(find.text(scanAgain), findsOneWidget);
    // Scanned again and sent: said once it went.
    await tester.tap(find.text(scanAgain));
    await tester.pumpAndSettle();
    repository.scanSends = true;
    read(_qr);
    await tester.pumpAndSettle();
    await tester.tap(find.text(approvalYes));
    await tester.pumpAndSettle();
    expect(find.text(scanSent), findsOneWidget);
  });

  // Review 27's M3: a new device started again, the user's devices changed while it was being set up, says so on the
  // banner and on its setup's page, whichever way it lost: its first list from the page, or a start over's upload from
  // its key's page.
  testWidgets('a first list another one beat is said on the banner and on the setup page', (tester) async {
    final repository = FakeRepository()..encryption.value = EngineState.newDevice;
    await tester.pumpWidget(_app(const Scaffold(body: EncryptionBanner()), repository));
    await tester.tap(find.text('Set up'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byWidget(_fieldIn(tester, find.byType(RecoveryKeyField))), 'the key');
    await tester.pump();
    await tester.tap(find.text(useRecoveryKey));
    // The engine starts the installation again, the page going with the old device.
    repository.encryption.value = EngineState.starting;
    await tester.pumpAndSettle();
    repository.encryption.value = const EngineState(EngineStage.newDevice, listChanged: true);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSetupPage), findsNothing);
    expect(find.text(setupAgain), findsOneWidget);
    await tester.tap(find.text('Set up'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSetupPage), findsOneWidget);
    expect(find.text(setupAgain), findsOneWidget);
  });

  testWidgets("a start over another identity beat is said once its key's page goes", (tester) async {
    const key = 'abcdEFGHjkmnPQRS23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
    final repository = FakeRepository()
      ..encryption.value = const EngineState.settingUp(DeviceSetup.reset, recoveryKey: key);
    await tester.pumpWidget(_app(const Scaffold(body: EncryptionBanner()), repository));
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryKeyPage), findsOneWidget);
    repository.encryption.value = EngineState.starting;
    await tester.pumpAndSettle();
    repository.encryption.value = const EngineState(EngineStage.newDevice, listChanged: true);
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryKeyPage), findsNothing);
    expect(find.text(setupAgain), findsOneWidget);
  });

  // Review 27's M5: a yes refused while another device this one approved sets up says why.
  testWidgets("the approving device's yes says why it waits for another device it approved", (tester) async {
    final repository = FakeRepository()
      ..encryption.value = const EngineState(
        EngineStage.ready,
        approval: DeviceApproval(
          device: _device,
          name: 'Pixel 9',
          fingerprint: _fingerprint,
          phase: ApprovalPhase.asked,
          question: _question,
        ),
      )
      ..setupFails = CoreError('approval_waits');
    await tester.pumpWidget(_app(ApprovalPage(repository), repository));
    await tester.pump();
    await tester.tap(find.text(approvalYes));
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps, ['approveDevice $_device $_question']);
    expect(find.text(anotherWaits), findsOneWidget);
  });
}
