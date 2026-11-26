// What a whole 64 MiB shared history takes in the app's process (PLAN-E2E-CLIENTES.md, Task 31's first check): made
// with history_share and imported with history_import through the app's gate (lib/e2e/core_gate.dart), as both
// commands carry the package's parts in base64 inside one JSON. Not under test/, so `flutter test` doesn't run it:
//
//     flutter test benchmark/history_memory.dart
//
// Linux only (the vendored core's host build; no core, no run). Each step's peak is the process's resident set, the
// Dart VM's and the core's together, read every millisecond by an isolate of its own while the step runs (VmRSS), less
// what was resident as it began: what the step adds on top of an app that already runs. arm64 Android runs the same
// Dart and the same core. HISTORY_MEMORY_MESSAGES sets how many messages of HISTORY_MEMORY_CHARS characters the
// sharer holds: by default more than a package takes, so "all" is cut to what fits.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';

import '../test/support/core_lib.dart';
import '../test/support/engines.dart';
import '../test/support/fake_api.dart';

final _env = Platform.environment;
final _messages = int.tryParse(_env['HISTORY_MEMORY_MESSAGES'] ?? '') ?? 3000;
final _chars = int.tryParse(_env['HISTORY_MEMORY_CHARS'] ?? '') ?? 29000;

const _mib = 1 << 20;

int _status(String field) {
  final line = File('/proc/self/status').readAsLinesSync().firstWhere((line) => line.startsWith('$field:'));
  return int.parse(RegExp(r'(\d+)').firstMatch(line)![1]!) * 1024;
}

/// The process's peak while [step] runs, past what was resident as it began, read by [_sample] on its own isolate:
/// the main isolate's own work (a reply's JSON decoded) doesn't stop it.
Future<({T value, int added, int resident, Duration took})> _measured<T>(Future<T> Function() step) async {
  final answers = ReceivePort();
  final replies = StreamIterator<Object?>(answers);
  final sampler = await Isolate.spawn(_sample, answers.sendPort);
  await replies.moveNext();
  final stop = replies.current! as SendPort;
  final before = _status('VmRSS');
  final watch = Stopwatch()..start();
  final value = await step();
  watch.stop();
  stop.send(null);
  await replies.moveNext();
  final peak = max(replies.current! as int, _status('VmRSS'));
  await replies.cancel();
  answers.close();
  sampler.kill();
  return (value: value, added: peak - before, resident: peak, took: watch.elapsed);
}

/// Reads the resident set every millisecond until told to stop, then answers the most it read.
Future<void> _sample(SendPort answer) async {
  final stop = ReceivePort();
  answer.send(stop.sendPort);
  var stopped = false;
  stop.listen((_) => stopped = true);
  var most = 0;
  while (!stopped) {
    most = max(most, _status('VmRSS'));
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  stop.close();
  answer.send(most);
}

String _mb(int bytes) => '${(bytes / _mib).toStringAsFixed(1)} MiB';

/// Text deflate can't make much smaller: random letters of the base64 alphabet, six bits a character.
String _text(Random random) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  return String.fromCharCodes([for (var i = 0; i < _chars; i++) alphabet.codeUnitAt(random.nextInt(64))]);
}

Future<void> _observe(TestDevice device, List<String> users) async {
  for (final identity in await device.api.identities(users)) {
    await device.host.handle<Object?>({
      'cmd': 'observe_user',
      'user_id': identity.userId,
      'identity_key': identity.identityKey,
      'device_list': identity.deviceList,
      'certificates': identity.certificates,
    });
  }
}

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  test(
    'a whole package, shared and imported',
    () async {
      final fake = FakeApi();
      final (ana, bo) = (fake.addUser(), fake.addUser());
      final a = await firstDevice(fake, ana);
      final b = await firstDevice(fake, bo);
      final dm = (await a.engine.createDM(bo)).id;
      await sameGroup([a, b], dm);
      // Both engines stopped, their cores open: Ana's sends by hand, and Bo's holds none of it, as a member who joined
      // later.
      await stoppedByHand(a);
      await stoppedByHand(b);
      final random = Random(31);
      final sending = Stopwatch()..start();
      for (var i = 0; i < _messages; i++) {
        final nonce = uuidv4();
        final made = await a.host.handle<Map<String, Object?>>({
          'cmd': 'encrypt',
          'conversation_id': dm,
          'nonce': nonce,
          'envelope': {'text': _text(random)},
        });
        final message = await a.api.sendMessage(
          dm,
          duvet.EncryptedMessage(ciphertext: made['ciphertext']! as String, nonce: nonce),
        );
        await a.host.handle<Object?>({
          'cmd': 'sent',
          'conversation_id': dm,
          'nonce': nonce,
          'message_id': message.id,
          'seq': message.seq,
        });
      }
      sending.stop();
      // ignore: avoid_print
      print('$_messages messages of $_chars characters sent in ${sending.elapsed.inSeconds} s');

      final gateA = a.host as CoreGate;
      final gateB = b.host as CoreGate;
      await _observe(a, [bo]);
      final certificates = (await a.api.identity(bo)).certificates;
      final shared = await _measured(
        () => gateA.share({
          'cmd': 'history_share',
          'conversation_id': dm,
          'to_user': bo,
          'range': 'all',
          'devices': certificates,
        }),
      );
      final made = shared.value;
      final shareId = made['share_id']! as String;
      final parts = made['parts']! as int;
      // ignore: avoid_print
      print(
        'history_share: ${_mb(made['size']! as int)} in $parts parts, truncated ${made['truncated']}; '
        'the step added ${_mb(shared.added)} at its peak (${_mb(shared.resident)} resident), in ${shared.took.inSeconds} s',
      );

      // Bo's device takes the key, then imports parts of its own, as a download gives them.
      await _observe(b, [ana]);
      final key = (made['keys']! as List).cast<Map<String, Object?>>().single;
      final sender = (await b.api.identity(ana)).certificates.single;
      await gateB.handle<Object?>({'cmd': 'receive_direct', 'message': key['message'], 'from_certificate': sender});
      final downloaded = [for (var n = 0; n < parts; n++) Uint8List.fromList(await gateA.sharePart(shareId, n))];
      await gateA.dropShare(shareId);
      final imported = await _measured(() => gateB.importShare(shareId, downloaded));
      // ignore: avoid_print
      print(
        'history_import: ${imported.value['imported']} records; the step added ${_mb(imported.added)} at its peak '
        '(${_mb(imported.resident)} resident, the ${_mb(downloaded.fold(0, (sum, part) => sum + part.length))} of parts '
        'downloaded before it not counted), in ${imported.took.inSeconds} s',
      );
      // ignore: avoid_print
      print(jsonEncode({'share_added': shared.added, 'import_added': imported.added, 'size': made['size']}));
    },
    skip: noCore,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
