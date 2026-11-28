import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A new device's QR (PLAN-E2E-CLIENTES.md, «Convenciones entre clientes», and Ruling 21): the core's `qr` as its text,
/// unchanged, in byte mode (the qr package's for any string) at error correction M, dark on light inside the
/// standard's quiet zone of four modules, whatever the theme: an inverted code isn't read by every scanner.
class ApprovalQr extends StatelessWidget {
  const ApprovalQr(this.text, {super.key});

  final String text;

  /// The code's side, its quiet zone aside.
  static const side = 216.0;

  /// The code of [text], as it's drawn: the text's bytes in byte mode, at error correction M.
  static QrCode codeOf(String text) => QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M);

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'A code for setting up this device',
    child: ExcludeSemantics(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(12))),
        child: QrImageView.withQr(
          qr: codeOf(text),
          size: side,
          // About four of its modules, at the side and the version a 200-character text takes.
          padding: const EdgeInsets.all(20),
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
          dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
        ),
      ),
    ),
  );
}

/// The camera, reading QR codes (Ruling 21): built only once the person tapped to scan, which is when Android asks for
/// the camera's permission, never at start. Each text it reads goes to [onRead] as it is; a camera the app can't use
/// (no permission, none on this phone) is [onUnavailable]'s, which says to approve by code instead.
class QrScanner extends StatelessWidget {
  const QrScanner({required this.controller, required this.onRead, required this.onUnavailable, super.key});

  final MobileScannerController controller;
  final ValueChanged<String> onRead;
  final Widget Function(BuildContext context) onUnavailable;

  @override
  Widget build(BuildContext context) => MobileScanner(
    controller: controller,
    onDetect: (capture) {
      for (final barcode in capture.barcodes) {
        if (barcode.rawValue case final text? when text.isNotEmpty) return onRead(text);
      }
    },
    errorBuilder: (context, _) => onUnavailable(context),
  );
}
