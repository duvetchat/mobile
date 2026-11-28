import 'dart:convert';
import 'dart:io';

import 'package:duvet/e2e/cbor.dart';
import 'package:duvet/e2e/conventions.dart';
import 'package:duvet/e2e/files.dart';
import 'package:duvet/e2e/sync.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';

// What step 5's fuzzing of the desktop kept (PLAN-E2E-CLIENTES.md, «Lo que el paso 5 revisa»): inputs of another
// device or of the server, each with the desktop's answer, which the desktop's fuzz-corpus.test.ts holds it to and this
// holds the mobile app's readers to. Where they differ, the two engines separate (Review Focus 9). The file is the
// desktop's, copied as it is (testing/e2e-fuzz-corpus.json there).
final corpus = jsonDecode(File('test/e2e/e2e-fuzz-corpus.json').readAsStringSync()) as Map<String, dynamic>;
List<Map<String, dynamic>> cases(String reader) => (corpus[reader] as List).cast<Map<String, dynamic>>();

/// A case whose input can't reach the mobile app's reader: its types don't hold it.
final class _Unreachable {
  const _Unreachable();
}

const _unreachable = _Unreachable();

/// A reader's answers to its cases beside the corpus's, each different one named by its case's place; [unreachable]
/// counts the cases whose input never reaches the reader here.
void holds(
  String reader,
  Object? Function(Map<String, dynamic> c) read,
  Object? Function(Map<String, dynamic> c) answer, {
  int unreachable = 0,
}) {
  final all = cases(reader);
  expect(all, isNotEmpty);
  final differ = <String>[];
  var skipped = 0;
  for (final (at, c) in all.indexed) {
    final got = read(c);
    if (got is _Unreachable) {
      skipped++;
      continue;
    }
    final want = answer(c);
    if (!equals(want).matches(got, {})) differ.add('#$at: ${jsonEncode(got)}, the desktop ${jsonEncode(want)}');
  }
  expect(differ, isEmpty, reason: '$reader: ${differ.length} of ${all.length} differ');
  expect(skipped, unreachable, reason: '$reader: cases whose input the app never reads');
}

const _drawnNames = {
  Drawn.voiceNote: 'voice_note',
  Drawn.sticker: 'sticker',
  Drawn.nothing: 'nothing',
  Drawn.message: 'message',
};

/// A file as the desktop's shownFile writes it.
Map<String, Object?>? _fileJson(ShownFile? file) => file == null
    ? null
    : {
        'id': file.id,
        'key': file.key,
        'sha256': file.sha256,
        'size': file.size,
        'name': file.name,
        'said': file.said,
        'width': ?file.width,
        'height': ?file.height,
        'duration_ms': ?file.durationMs,
        'waveform': ?file.waveform,
        'thumbnail': ?file.thumbnail,
        if (file.thumbnailRef case final ref?)
          'thumbnail_ref': {'id': ref.id, 'key': ref.key, 'sha256': ref.sha256, 'size': ref.size},
      };

/// The fields of an entry the core takes, as both apps carry them: without its generation and epoch, which the mobile
/// app's entryOf leaves aside, `deleted` only when true and `mentions` only when it names someone, as each app writes
/// them, and no field that's null.
Map<String, Object?> _coreFields(Map<String, Object?> entry) => {
  for (final key in const [
    'seq',
    'kind',
    'data',
    'sent_at',
    'message_id',
    'sender_user',
    'sender_device',
    'statement',
    'mentions',
    'reply_to',
    'deleted',
  ])
    if (entry[key] case final value?)
      if (!(key == 'deleted' && value == false) && !(key == 'mentions' && value is List && value.isEmpty)) key: value,
};

/// The entry an event carries here, as the gateway's client parses the event (one it can't read it drops: its
/// listener catches the throw) and the engine takes it.
Object? _entryHere(Map<String, dynamic> event) {
  final duvet.GatewayEventPayload? payload;
  try {
    payload = duvet.GatewayEnvelope.fromJson({'op': 0, 's': 1, 'event': 'payload', 'd': event}).d;
  } catch (_) {
    return null;
  }
  final carried = payload == null ? null : carriedEntry(payload);
  if (carried == null) return null;
  return {'id': carried.conversation, 'entry': _coreFields(carried.entry), 'generation': ?carried.generation};
}

const _mlsEvents = {'MLS_COMMIT', 'MLS_WELCOME', 'MLS_PROPOSAL'};

/// The event with the fields the desktop's entry never reads, which the app's client needs to read the event at all,
/// as the API sends them: a message's times, an edit's and a deletion's ID and an edit's time, an MLS event's epoch,
/// an entry's generation and epoch (which neither app hands the core: the mobile app's entryOf leaves them aside). An
/// MLS event's generation, which the desktop reads where there is one, is given where there's none.
Map<String, dynamic> _asTheApiSends(Map<String, dynamic> event) {
  final (type, data) = (event['type'], event['data']);
  if (data is! Map<String, dynamic>) return event;
  const at = '2026-11-26T10:00:00Z';
  const id = '0193a4b2-0000-7000-8000-0000000000ee';
  final entry = data['entry'];
  return {
    ...event,
    'data': {
      ...data,
      ...switch (type) {
        'DM_MESSAGE_CREATE' => const {'created_at': at, 'updated_at': at},
        'DM_MESSAGE_UPDATE' => const {'id': id, 'edited_at': at},
        'DM_MESSAGE_DELETE' => const {'id': id},
        _ when _mlsEvents.contains(type) => {'epoch': 0, if (!data.containsKey('generation')) 'generation': 0},
        _ => const <String, Object?>{},
      },
      if (entry is Map<String, dynamic>) 'entry': {...entry, 'generation': 0, 'epoch': 0},
    },
  };
}

/// The entry the app's engine takes of an event the client reads ([_asTheApiSends]): without the generation it was
/// given, where the event had none.
Object? _entryTaken(Map<String, dynamic> event) {
  final taken = _entryHere(_asTheApiSends(event));
  final data = event['data'];
  final given = _mlsEvents.contains(event['type']) && data is Map && !data.containsKey('generation');
  return taken is Map<String, Object?> && given ? ({...taken}..remove('generation')) : taken;
}

Object? _entryThere(Object? answer) => switch (answer) {
  {'id': final String id, 'entry': final Map<String, Object?> entry} => {
    'id': id,
    'entry': _coreFields(entry),
    'generation': ?(answer as Map)['generation'],
  },
  _ => null,
};

void main() {
  test('the seeds a real core made name their devices', () {
    final seeds = corpus['seeds'] as Map<String, dynamic>;
    expect(certificateDevice(seeds['certificate'] as String), seeds['certificate_device']);
    expect(listDevices(seeds['device_list'] as String), seeds['list_devices']);
    expect(commitmentDevice(seeds['commitment'] as String), seeds['commitment_device']);
  });

  test('approval frames', () {
    holds('approval_frames', (c) {
      final frame = readApprovalFrame(c['message'] as String);
      return frame == null
          ? null
          : {'duvet': 'approval', 'step': frame.step.name, 'data': frame.data, 'name': ?frame.name};
    }, (c) => c['frame']);
  });

  test("files' names", () => holds('names', (c) => cleanName(c['name'] as String), (c) => c['clean']));

  test("files' types, by their bytes", () {
    holds('types', (c) => sniffType(base64Decode(c['bytes'] as String)), (c) => c['type']);
  });

  test('thumbnails drawn, by their headers', () {
    holds('thumbnails', (c) => thumbnailDrawn(base64Decode(c['bytes'] as String)), (c) => c['drawn']);
  });

  // A message's files reach drawnAs as maps alone: the app reads the core's rows so (ShownMessage.of), and the core
  // writes each file as one. The cases with another value among them are the desktop's alone.
  test('what a message is drawn as', () {
    holds(
      'drawn',
      (c) {
        final message = c['message'] as Map<String, dynamic>;
        final files = message['attachments'] as List;
        if (files.any((file) => file is! Map)) return _unreachable;
        return _drawnNames[drawnAs(
          text: message['text'] as String?,
          attachments: [for (final file in files) (file as Map).cast<String, Object?>()],
          sticker: c['sticker'] as bool,
        )];
      },
      (c) => c['drawn'],
      unreachable: 15,
    );
  });

  test('CBOR read or refused', () {
    holds('cbor', (c) => cbor(base64Decode(c['bytes'] as String)) != null, (c) => c['read']);
  });

  test('the device a certificate names', () {
    holds('certificates', (c) => certificateDevice(c['certificate'] as String), (c) => c['device']);
  });

  test('the devices a list names', () {
    holds('device_lists', (c) => listDevices(c['list'] as String), (c) => c['devices']);
  });

  test('the device a commitment names', () {
    holds('commitments', (c) => commitmentDevice(c['commitment'] as String), (c) => c['device']);
  });

  test('a file of a message, as it is shown', () {
    holds('shown_files', (c) => _fileJson(shownFile(c['file'])), (c) => c['shown']);
  });

  // The app's gateway client (duvet_client's GatewayEnvelope) reads an event whole, and drops one its models can't
  // read: a message without its created_at, an MLS event without its generation, an edit without its id. The desktop
  // reads the entry alone, and takes it. Those drops cost a queue read (the queue brings what a lost event carried),
  // and are counted here; the entry the engine takes of each event, once its client reads it, is the desktop's.
  test('the entry an event carries', () {
    holds('event_entries', (c) => _entryTaken(c['event'] as Map<String, dynamic>), (c) => _entryThere(c['entry']));
    final dropped = [
      for (final (at, c) in cases('event_entries').indexed)
        if (c['entry'] != null && _entryHere(c['event'] as Map<String, dynamic>) == null) at,
    ];
    expect(dropped, [0, 1, 2, 3, 17, 22, 28, 32, 58, 62], reason: 'the events the client drops and the desktop reads');
  });
}
