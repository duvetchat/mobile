import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_e2e/duvet_e2e.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// The core's plugin in the app itself (PLAN-E2E-PLATAFORMAS.md, Task 12), which CI's ios job runs on a simulator: the
// framework Xcode embedded from the plugin's Swift package, which flutter_rust_bridge opens by its name, as the app
// does on a phone. Nothing hands the core a library here, unlike test/support/core_lib.dart.
const ana = '0193a4b2-0000-7000-8000-000000000001';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('duvet-core-'));
  tearDown(() => folder.deleteSync(recursive: true));
  String config() => jsonEncode({'path': '${folder.path}/core.db'});
  Uint8List key() => Uint8List.fromList(List.generate(32, (i) => i * 7));

  /// Runs a command on [core], and its `ok`.
  Future<Object?> run(DuvetE2eCore core, Map<String, Object?> command) async {
    final reply = jsonDecode(await core.handle(jsonEncode(command))) as Map<String, Object?>;
    expect(reply, contains('ok'), reason: '$reply');
    return reply['ok'];
  }

  test('the core opens, makes its device and answers status', () async {
    final app = File(Platform.resolvedExecutable).parent.path;
    expect(File('$app/Frameworks/duvet_e2e.framework/duvet_e2e').existsSync(), isTrue, reason: 'in $app');

    final core = await DuvetE2e.open(config(), key());
    final device = uuidv7();
    await run(core, {'cmd': 'create_device', 'user_id': ana, 'device_id': device});
    final status = await run(core, {'cmd': 'status'}) as Map<String, Object?>;
    expect(status['device_id'], device);
    expect(status['key_storage'], 'provided');
    await core.close();
  });

  test('a second open of the same database is locked', () async {
    final core = await DuvetE2e.open(config(), key());
    await expectLater(
      DuvetE2e.open(config(), key()),
      throwsA(isA<DuvetE2eException>().having((error) => error.code, 'code', 'locked')),
    );
    await core.close();
    // Closed, it opens again.
    await (await DuvetE2e.open(config(), key())).close();
  });
}
