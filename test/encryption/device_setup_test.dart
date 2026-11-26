import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:duvet/data/scope.dart';
import 'package:duvet/e2e/cbor.dart' show qrDevice;
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/host.dart' show CoreError;
import 'package:duvet/e2e/notices.dart';
import 'package:duvet/encryption/approval.dart';
import 'package:duvet/encryption/device_setup.dart';
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
    // A text that isn't a QR the core wrote names no device (the fixture's is the convention's text, not one).
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
        ),
      );
    await tester.pumpWidget(_app(ApprovalPage(repository), repository));
    await tester.pump();
    expect(find.text(Notice.approvalAsk.text), findsOneWidget);
    expect(find.text(approvalAsks('Pixel 9')), findsOneWidget);
    expect(find.text(fingerprintOf(_fingerprint)), findsOneWidget);
    expect(repository.encryptionTaps, isEmpty);
    await tester.tap(find.text(approvalYes));
    await tester.pump();
    expect(repository.encryptionTaps, ['approveDevice $_device']);

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

  testWidgets("a scanned code's device is asked about before anything is approved", (tester) async {
    final repository = FakeRepository()
      ..encryption.value = EngineState.ready
      ..scanned = (id: _device, name: 'Pixel 9', listed: false, unfinished: true);
    late ValueChanged<String> read;
    await tester.pumpWidget(_scanning(repository, (onRead) => read = onRead));
    read('the code');
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps, ['scannedDevice the code']);
    expect(find.text(Notice.approvalAsk.text), findsOneWidget);
    expect(find.text(approvalAsks('Pixel 9')), findsOneWidget);
    expect(find.text(approvalUnfinished('Pixel 9')), findsOneWidget);
    await tester.tap(find.text(approvalYes));
    await tester.pumpAndSettle();
    expect(repository.encryptionTaps.last, 'approveScanned the code $_device');
    expect(find.text(scanSent), findsOneWidget);
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
}
