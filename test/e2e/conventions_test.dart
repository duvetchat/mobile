import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:flutter_test/flutter_test.dart';

// What the mobile app and the desktop do alike (PLAN-E2E-CLIENTES.md, its conventions between clients): each case of
// the file both repositories carry, which the desktop's conventions.test.ts reads too.
final conventions = jsonDecode(File('test/e2e/e2e-conventions.json').readAsStringSync()) as Map<String, dynamic>;
List<Map<String, dynamic>> cases(String name) => (conventions[name] as List).cast<Map<String, dynamic>>();
List<Map<String, Object?>> files(Object? list) => (list as List).cast<Map<String, Object?>>();

const _drawn = {
  'voice_note': Drawn.voiceNote,
  'sticker': Drawn.sticker,
  'nothing': Drawn.nothing,
  'message': Drawn.message,
};

void main() {
  group("a message's envelope", () {
    for (final c in cases('envelopes')) {
      test(c['case'] as String, () {
        expect(messageEnvelope(c['text'] as String, files(c['attachments'])), c['envelope']);
      });
    }
  });

  group('what a message is drawn as', () {
    for (final c in cases('messages')) {
      test(c['case'] as String, () {
        final message = c['message'] as Map<String, dynamic>;
        final drawn = drawnAs(
          text: message['text'] as String?,
          attachments: files(message['attachments']),
          sticker: c['sticker'] as bool,
        );
        expect(drawn, _drawn[c['drawn']]);
      });
    }
  });

  group("a file's name", () {
    for (final c in cases('names')) {
      test(c['case'] as String, () => expect(cleanName(c['name'] as String), c['clean']));
    }
  });

  group("a file's type, by its bytes", () {
    test('both apps read the same first bytes of a file', () => expect(sniffPrefix, conventions['sniff_prefix']));
    for (final c in cases('types')) {
      test(c['case'] as String, () {
        // A case's bytes, then as many zero bytes as it says, then its tail.
        final head = base64Decode(c['bytes'] as String);
        final tail = base64Decode(c['tail'] as String? ?? '');
        final bytes = Uint8List(head.length + (c['zeros'] as int? ?? 0) + tail.length)
          ..setAll(0, head)
          ..setAll(head.length + (c['zeros'] as int? ?? 0), tail);
        expect(sniffType(bytes), c['type']);
      });
    }
  });

  // Task 19's review, I3: a thumbnail's header can claim any size, read before anything decodes it.
  group('a thumbnail drawn, by its header', () {
    final thumbnails = conventions['thumbnails'] as Map<String, dynamic>;
    test('both apps draw a thumbnail up to the same side', () => expect(thumbnailSide, thumbnails['most_side']));
    for (final c in (thumbnails['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['case'] as String, () => expect(thumbnailDrawn(base64Decode(c['bytes'] as String)), c['drawn']));
    }
  });

  group('an approval frame in the inbox', () {
    for (final c in cases('approval_frames')) {
      test(c['case'] as String, () {
        final frame = readApprovalFrame(c['message'] as String);
        expect(
          frame == null
              ? null
              : {'duvet': 'approval', 'step': frame.step.name, 'data': frame.data, 'name': ?frame.name},
          c['frame'],
        );
        // A frame written again is the same message byte for byte, or the one its cleaned name makes.
        if (frame != null) expect(approvalFrameMessage(frame), c['rewritten'] ?? c['message']);
      });
    }
  });

  group("an approval's fingerprint, which the approving computer's box and the new device's screen show", () {
    for (final c in cases('approval_fingerprints')) {
      test(c['case'] as String, () {
        expect(approvalFingerprint(base64Decode(c['commitment'] as String)), c['fingerprint']);
      });
    }
  });

  group('uuidv7', () {
    test('is a version 7 UUID whose first 48 bits are the time it was made', () {
      final at = DateTime.utc(2026, 11, 24, 21, 30, 5, 123).millisecondsSinceEpoch;
      final id = uuidv7(at);
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(int.parse(id.replaceAll('-', '').substring(0, 12), radix: 16), at);
    });

    test('sorts by the time it was made, and two are never the same', () {
      final ids = [uuidv7(1), uuidv7(2), uuidv7(256), uuidv7(1 << 40), uuidv7()];
      expect([...ids]..sort(), ids);
      expect({for (var i = 0; i < 1000; i++) uuidv7(5)}, hasLength(1000));
    });
  });
}
