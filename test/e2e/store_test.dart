import 'dart:convert';
import 'dart:io';

import 'package:duvet/e2e/store.dart';
import 'package:duvet/e2e/sync.dart' show recordRefusedGeneration, refusedGenerationsIn;
import 'package:flutter_test/flutter_test.dart';

// The engine's record on disk (lib/e2e/store.dart; M2 of the review): `e2e/<user_id>/client.json`, each write the file
// as it is then with the store's own changes, written beside it and renamed over it, one at a time and in order. It
// holds the device's keys, and the inbox messages kept for later, which their senders never send again.
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
  // What's left beside the record: no write's file once it's done.
  List<String> beside() => [
    for (final entry in file.parent.listSync())
      if (entry.path != file.path) entry.path,
  ];
  // A write cut before its rename: here, one whose rename is refused, a folder standing in the record's place, which
  // is back as it was after.
  Future<void> cut(Future<void> Function() write) async {
    final before = file.renameSync('${file.path}.before');
    final blocker = Directory(file.path)..createSync();
    await expectLater(write(), throwsA(isA<FileSystemException>()));
    blocker.deleteSync();
    before.renameSync(file.path);
  }

  test(
    'a_write_goes_beside_the_record_and_takes_its_place:_one_cut_leaves_the_one_before,_and_holds_up_none_after',
    () async {
      final store = await open();
      expect(store.read(keptDevice), isNull);
      await store.write(keptDevice, 'd-1');
      expect(onDisk(), {keptDevice: 'd-1'});
      expect(beside(), isEmpty);

      await cut(() => store.write(keptLater, ['m-1']));
      expect(onDisk(), {keptDevice: 'd-1'});

      // The next write goes, with what the cut one changed, and a new record reads it back.
      await store.write(keptDevice, 'd-2');
      expect(onDisk(), {
        keptDevice: 'd-2',
        keptLater: ['m-1'],
      });
      expect(beside(), isEmpty);
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
    expect(beside(), isEmpty);
  });

  // Task 29 (contacts.dart): another engine of the phone (a push's) writes the record while this one has it open, and
  // this one takes those keys again once the core is its own, writing nothing; its next write keeps them.
  test('a_refresh_takes_what_another_engine_wrote,_and_the_next_write_keeps_it', () async {
    final app = await open();
    await app.write(keptDevice, 'd-1');
    final push = await open();
    await push.write(keyChanges, {
      'bo': {'verified': true, 'change': 'c1'},
    });
    expect(app.read(keyChanges), isNull);
    await app.refresh([keyChanges, verifiedContacts]);
    expect(app.read(keyChanges), {
      'bo': {'verified': true, 'change': 'c1'},
    });
    await app.write(keptDevice, 'd-2');
    expect(onDisk(), {
      keptDevice: 'd-2',
      keyChanges: {
        'bo': {'verified': true, 'change': 'c1'},
      },
    });
    // A key the file no longer has goes from memory too.
    await push.write(keyChanges, null);
    await app.refresh([keyChanges]);
    expect(app.read(keyChanges), isNull);
    // A change of its own the file hasn't taken yet stays, and the next write takes it.
    await cut(() => app.write(verifiedContacts, ['u']));
    await app.refresh([keyChanges, verifiedContacts]);
    expect(app.read(verifiedContacts), ['u']);
    await app.write(keptDevice, 'd-3');
    expect(onDisk(), {
      keptDevice: 'd-3',
      verifiedContacts: ['u'],
    });
  });

  // Review 29's Minor 4: a push's engine read the record as it started, and the app's engine wrote its contacts after.
  // The push's own write then (a refused generation, applied through the app's core) changes its key alone, never the
  // app's contacts back to its copy.
  test("a_push's_write_changes_its_own_key_alone,_never_the_app's_back_to_its_copy", () async {
    final app = await open();
    await app.write(keyChanges, {'u': 'before'});
    final push = await pushRecord(_user, folder: () async => folder);
    await app.write(keyChanges, {'u': 'after'});
    await app.write(verifiedContacts, ['u']);
    await push.write(refusedGenerations, {'c': 2});
    expect(onDisk(), {
      keyChanges: {'u': 'after'},
      verifiedContacts: ['u'],
      refusedGenerations: {'c': 2},
    });
    // What it forgets goes alone too.
    await push.write(refusedGenerations, null);
    expect(onDisk(), {
      keyChanges: {'u': 'after'},
      verifiedContacts: ['u'],
    });
  });

  // mobile#345: the app's engine holds the record while a push's engine records a refused generation (sync.dart, a
  // welcome refused through the app's core). The app's next write, of another key or of the refusals themselves,
  // keeps it, and what the app reads after is the file's; the push's later write keeps the app's change too.
  test("a_push's_refused_generation_outlives_the_app's_next_writes", () async {
    final app = await open();
    await app.write(keptDevice, 'd-1');
    expect(refusedGenerationsIn(app), isEmpty);
    final push = await pushRecord(_user, folder: () async => folder);
    await recordRefusedGeneration(push, 'c1', 1);
    await app.write(keptDevice, 'd-2');
    expect(onDisk(), {
      keptDevice: 'd-2',
      refusedGenerations: {'c1': 1},
    });
    expect(refusedGenerationsIn(app), {'c1': 1});
    // The app's own refusal of another conversation, then the person's yes to the push's.
    await recordRefusedGeneration(app, 'c2', 3);
    expect(refusedGenerationsIn(await open()), {'c1': 1, 'c2': 3});
    await recordRefusedGeneration(app, 'c1', null);
    // The push's engine, still open, refuses a third: the first stays gone.
    await recordRefusedGeneration(push, 'c3', 2);
    expect(onDisk(), {
      keptDevice: 'd-2',
      refusedGenerations: {'c2': 3, 'c3': 2},
    });
    expect(refusedGenerationsIn(app), {'c2': 3, 'c3': 2});
    // Two in a row, the first not taken by the file yet as the second reads: both stay.
    await Future.wait([recordRefusedGeneration(app, 'c4', 1), recordRefusedGeneration(app, 'c5', 1)]);
    expect(refusedGenerationsIn(await open()), {'c2': 3, 'c3': 2, 'c4': 1, 'c5': 1});
  });

  // Two engines writing at the same moment (the app's and a push's, each in its isolate) write each its own file beside
  // the record: the record is always one write's whole file, and no write fails for the other's.
  test('two_stores_writing_at_once_never_mix_their_files', () async {
    final app = await open();
    final push = await pushRecord(_user, folder: () async => folder);
    await Future.wait([
      for (var at = 0; at < 10; at++) ...[
        app.write(keptLater, [for (var line = 0; line < 100; line++) 'm-$at-$line']),
        push.write(refusedGenerations, {'c': at}),
      ],
    ]);
    expect(onDisk(), isA<Map<String, Object?>>());
    expect(beside(), isEmpty);
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
