import 'dart:convert';
import 'dart:typed_data';

import 'package:duvet/e2e/cbor.dart';
import 'package:flutter_test/flutter_test.dart';

// The CBOR the core writes its signed objects in, read only to tell which device a certificate, a list, a commitment
// or a QR names (lib/e2e/cbor.dart): the server's word, or another device's. The desktop's cbor.test.ts.
const _device = '01020304-0506-0708-090a-0b0c0d0e0f10';
final _deviceBytes = List.generate(16, (i) => i + 1);

List<int> _text(String text) => [0x60 | text.length, ...utf8.encode(text)];
List<int> _bytes(List<int> bytes) => [0x58, bytes.length, ...bytes];

/// `{body, sig}`, as the core signs an object.
Uint8List _signed(List<int> body) =>
    Uint8List.fromList([0xa2, ..._text('body'), ..._bytes(body), ..._text('sig'), ..._bytes(List.filled(64, 0))]);

/// `{device}`, as a certificate's body, a commitment and a QR name a device.
final _naming = [0xa1, ..._text('device'), 0x50, ..._deviceBytes];

/// `{version, devices}`, as a list's body.
final _listing = [0xa2, ..._text('version'), 0x01, ..._text('devices'), 0x81, 0x50, ..._deviceBytes];

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/// [value] in each other form base64 takes, which the core and the API never write: without its padding, its padding
/// escaped, with stray bits in its last character, in the URL's alphabet, with a space, with a line break.
List<String> _otherForms(String value) {
  final bare = value.replaceAll(RegExp(r'=+$'), '');
  final padding = value.length - bare.length;
  final last = bare.length - 1;
  return [
    if (padding > 0) ...[
      bare,
      value.replaceAll('=', '%3D'),
      bare.substring(0, last) + _alphabet[_alphabet.indexOf(bare[last]) | 1] + '=' * padding,
    ],
    if (value.contains(RegExp('[+/]'))) value.replaceAll('+', '-').replaceAll('/', '_'),
    ' $value',
    '$value\n',
  ];
}

void main() {
  group('base64 is read only in the form the core and the API write it', () {
    final certificate = base64Encode(_signed(_naming));
    final list = base64Encode(_signed(_listing));
    final commitment = base64Encode(_naming);

    test('as they write it, each names its device', () {
      expect(certificateDevice(certificate), _device);
      expect(listDevices(list), [_device]);
      expect(commitmentDevice(commitment), _device);
      expect(qrDevice(commitment), _device);
    });

    test('in any other form, none names one', () {
      // Dart's base64Decode takes the URL's alphabet and an escaped padding, which the desktop's atob refuses, as atob
      // takes what base64Decode refuses: only the one form reads the same in both apps.
      for (final form in _otherForms(certificate)) {
        expect(certificateDevice(form), isNull, reason: form);
      }
      for (final form in _otherForms(list)) {
        expect(listDevices(form), isNull, reason: form);
      }
      for (final form in _otherForms(commitment)) {
        expect(commitmentDevice(form), isNull, reason: form);
        expect(qrDevice(form), isNull, reason: form);
      }
    });
  });

  // Step 5's fuzzing, with the desktop's last finding: Dart's utf8.decode drops a text's leading byte order mark, which
  // the core keeps (Rust's from_utf8), so a key the core reads as another key was the one without it here.
  test("a text's byte order mark is the text's, as the core reads it", () {
    const mark = [0xef, 0xbb, 0xbf];
    expect(cbor(Uint8List.fromList([0x63, ...mark])), '\u{feff}');
    expect(cbor(Uint8List.fromList([0x66, ...mark, ...mark])), '\u{feff}\u{feff}');
    // {"<mark>a": 1, "a": 2}: two keys, as the core reads them.
    expect(cbor(Uint8List.fromList([0xa2, 0x64, ...mark, 0x61, 0x01, 0x61, 0x61, 0x02])), {'\u{feff}a': 1, 'a': 2});
    // A certificate whose device is under "<mark>device" names none.
    final marked = [0xa1, 0x69, ...mark, ...utf8.encode('device'), 0x50, ..._deviceBytes];
    expect(certificateDevice(base64Encode(_signed(marked))), isNull);
    expect(commitmentDevice(base64Encode(marked)), isNull);
  });
}
