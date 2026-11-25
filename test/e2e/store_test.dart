import 'dart:convert';
import 'dart:io';

import 'package:duvet/e2e/store.dart';
import 'package:flutter_test/flutter_test.dart';

// The engine's record on disk (lib/e2e/store.dart; M2 of the review): `e2e/<user_id>/client.json`, each write the
// whole record, written beside the file and renamed over it, one at a time and in order. It holds the device's keys,
// and the inbox messages kept for later, which their senders never send again.
const _user = '01936d4e-8f00-7000-8000-000000000001';

void main() {
  late Directory folder;
  late File file;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('duvet-record-');
    file = File('${folder.path}/e2e/$_user/client.json');
  });
  tearDown(() => folder.deleteSync(recursive: true));

  Future<FileEngineStore> open() => FileEngineStore.open(_user, folder: () async => folder);
  Object? onDisk() => jsonDecode(file.readAsStringSync());

  test(
    'a_write_goes_beside_the_record_and_takes_its_place:_one_cut_leaves_the_one_before,_and_holds_up_none_after',
    () async {
      final store = await open();
      expect(store.read(keptDevice), isNull);
      await store.write(keptDevice, 'd-1');
      expect(onDisk(), {keptDevice: 'd-1'});
      expect(File('${file.path}.next').existsSync(), isFalse);

      // A write cut before its rename: here, one whose file beside the record can't be written.
      final beside = Directory('${file.path}.next')..createSync();
      await expectLater(store.write(keptLater, ['m-1']), throwsA(isA<FileSystemException>()));
      expect(onDisk(), {keptDevice: 'd-1'});

      // The next write goes, with the whole record by then, and a new record reads it back.
      beside.deleteSync();
      await store.write(keptDevice, 'd-2');
      expect(onDisk(), {
        keptDevice: 'd-2',
        keptLater: ['m-1'],
      });
      final again = await open();
      expect(again.read(keptDevice), 'd-2');
      expect(again.read(keptLater), ['m-1']);
      // Null forgets a value.
      await again.write(keptLater, null);
      expect(onDisk(), {keptDevice: 'd-2'});
    },
  );

  test('writes_land_in_their_order', () async {
    final store = await open();
    // None awaited before the next: each waits for the one before, and the file ends with the last.
    await Future.wait([for (var at = 0; at < 20; at++) store.write(keptDevice, 'd-$at')]);
    expect(onDisk(), {keptDevice: 'd-19'});
    expect(File('${file.path}.next').existsSync(), isFalse);
  });

  test("a_record_that_doesn't_read_starts_empty", () async {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{"device": "d-1", "device_ke');
    final store = await open();
    for (final key in deviceRecord) {
      expect(store.read(key), isNull, reason: key);
    }
    // Its first write replaces it.
    await store.write(keptDevice, 'd-2');
    expect(onDisk(), {keptDevice: 'd-2'});

    // A user ID that isn't a UUID never names a folder.
    await expectLater(FileEngineStore.open('../x', folder: () async => folder), throwsArgumentError);
  });
}
