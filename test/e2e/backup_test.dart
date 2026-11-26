import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:duvet/e2e/backup.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/failures.dart';
import 'package:duvet/e2e/store.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// The encrypted backup (PLAN-E2E-CLIENTES.md, Task 33, its Task 32 in Dart; decisions 20, 21 and 44 to 46), on real
// cores through the fake API: a day that ended goes up with the app quiet, by the version its build answered, in the
// place of the copy it names; another device's copy is taken in before the day is built over it; a new device restores
// the days, newest conversation first; a change of keys moves the old days to the new key; a full quota pauses it all
// for a day, and a day too large to keep is set aside while the rest goes on. The fake dates the messages a day or more
// back (sentAtOffset), as the API dated them then, since the core seals only days that ended by its own clock. Then the
// backup's own rules, on a stub core and API: what's counted against a day or a segment, the pass at the latest,
// nothing before the device is ready, the inbox first, listings that never end, the 32 MiB caps, the record's one
// write, and one writer. The desktop's backup tests, case for case.
const _slow = Timeout(Duration(minutes: 3));
const _minute = Duration(minutes: 1);
const _day = Duration(days: 1);
const _segments = '/api/users/@me/backup/segments';
final RouteMatch _segmentPut = (method: 'PUT', path: RegExp(r'^/api/users/@me/backup/segments/[0-9a-f-]{36}/'));
const _inbox = '/api/users/@me/devices/@me/inbox';

/// The UTC day of an instant, YYYY-MM-DD, as the core writes a backup's days.
String _dayOf(DateTime at) => at.toUtc().toIso8601String().substring(0, 10);

/// The UTC day [ago] back.
String _daysBack(Duration ago) => _dayOf(DateTime.now().subtract(ago));

/// A request as the timeline says it: its method, path and query.
String _said(http.Request request) =>
    '${request.method} ${request.url.path}${request.url.hasQuery ? '?${request.url.query}' : ''}';

List<String> _putsIn(List<String> timeline) => [
  for (final line in timeline)
    if (line.startsWith('PUT $_segments/')) line,
];

/// The segments a device downloaded, by ID, in the order it asked for them.
List<String> _downloadsIn(List<String> timeline) => [
  for (final line in timeline)
    if (RegExp('^GET $_segments/([0-9a-f-]{36})\$').firstMatch(line) case final match?) match[1]!,
];

/// The days of a list of segments, in order.
List<String> _days(List<duvet.BackupSegment> segments) => [for (final s in segments) s.day]..sort();

final _random = Random();

/// Text no deflate makes smaller: what makes a day's segment as large as its messages.
String _noise(int length) => String.fromCharCodes(List.generate(length, (_) => 33 + _random.nextInt(94)));

/// A command the core was asked, with what it answered: none while it hasn't, or for one it refused.
class _Asked {
  _Asked(this.command);
  final Map<String, Object?> command;
  Object? answer;
}

/// A host that tells each command it's asked, in [asked] with its answer, and by its name in [timeline].
class _Telling implements CoreHost {
  _Telling(this._host, this.asked, this.timeline);
  final CoreHost _host;
  final List<_Asked> asked;
  final List<String> timeline;

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    final entry = _Asked(command);
    asked.add(entry);
    timeline.add(command['cmd']! as String);
    final answer = await _host.handle<T>(command);
    entry.answer = answer;
    return answer;
  }

  @override
  Future<Opened> open(String userId) => _host.open(userId);

  @override
  Future<Uint8List> sealFile(String key, String attachmentId, Uint8List plain, {void Function(int)? progress}) =>
      _host.sealFile(key, attachmentId, plain, progress: progress);

  @override
  Future<Uint8List> openFile(String key, String attachmentId, Uint8List sealed, {void Function(int)? progress}) =>
      _host.openFile(key, attachmentId, sealed, progress: progress);

  @override
  Future<Map<String, Object?>> share(Map<String, Object?> command) => _host.share(command);

  @override
  Future<Uint8List> sharePart(String shareId, int n) => _host.sharePart(shareId, n);

  @override
  Future<void> dropShare(String shareId) => _host.dropShare(shareId);

  @override
  Future<Map<String, Object?>> importShare(String shareId, List<Uint8List> parts) => _host.importShare(shareId, parts);

  @override
  Future<void> close() => _host.close();

  @override
  Future<void> destroy(String userId) => _host.destroy(userId);
}

/// An http client on the fake whose requests go in [timeline], which [watch] sees too, and which [answer] can answer
/// itself.
http.Client _watching(
  FakeApi fake,
  List<String> timeline, {
  void Function(http.Request request, FakeApi fake)? watch,
  Future<http.Response?> Function(http.Request request)? answer,
}) => watchedClient(
  fake,
  seen: (request) {
    timeline.add(_said(request));
    watch?.call(request, fake);
  },
  answer: answer,
);

/// The text a device's core shows of a message: null while it holds none.
Future<String?> _textOn(TestDevice device, String conversation, String id) async {
  final shown = (await device.engine.messages(conversation, [id])).firstOrNull;
  return shown?.status == MessageStatus.ok ? shown!.text : null;
}

/// The days the device's core holds due to go up (backup_due), as conversation/day.
Future<List<String>> _dueOn(TestDevice device) async => [
  for (final day
      in ((await device.host.handle<Map<String, Object?>>({'cmd': 'backup_due'}))['segments']! as List)
          .cast<Map<String, Object?>>())
    '${day['conversation_id']}/${day['day']}',
];

/// The ID of the key the device's core seals the backup with now (the backup's own way to read it).
Future<String> _sealsWith(TestDevice device) async =>
    (await device.host.handle<Map<String, Object?>>({
          'cmd': 'backup_segment',
          'conversation_id': '00000000-0000-0000-0000-000000000000',
          'day': '2026-01-01',
        }))['key_id']!
        as String;

/// The device's message, as the API dates it [ago] back, once every device of [all] holds it as the API dated it (the
/// sender's core too, which dates its own message by its own clock until the queue brings it back).
Future<duvet.DirectMessage> _sent(
  FakeApi fake,
  TestDevice from,
  String conversation,
  String text,
  Duration ago,
  List<TestDevice> all,
) async {
  fake.sentAtOffset = -ago.inMilliseconds;
  final duvet.DirectMessage? message;
  try {
    message = await from.engine.sendMessage(Outgoing(conversationId: conversation, nonce: uuidv4(), text: text));
  } finally {
    fake.sentAtOffset = 0;
  }
  if (message == null) throw StateError("the message wasn't sent");
  final sent = message;
  for (final device in all) {
    await until(() async {
      final shown = (await device.engine.messages(conversation, [sent.id])).firstOrNull;
      return shown?.status == MessageStatus.ok && shown!.sentAt == sent.sentAt;
    }, what: '${device.user} holding the message as the API dated it');
  }
  return sent;
}

typedef _Dm = ({
  FakeApi fake,
  TestDevice a,
  TestDevice b,
  String conversation,
  List<String> timeline,
  List<_Asked> asked,
  http.Client client,
});

/// Ana's and Bo's first devices in a DM whose group Ana made, Ana's core telling what it's asked and hearing what
/// [hears] says; every request of theirs in the timeline, which [watch] sees too.
Future<_Dm> _dm({
  void Function(http.Request request, FakeApi fake)? watch,
  bool Function(GatewayEvent event)? hears,
}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  final timeline = <String>[];
  final asked = <_Asked>[];
  final client = _watching(fake, timeline, watch: watch);
  final conversation = fake.addConversation(group: false, members: [ana, bo]);
  final a = await firstDevice(
    fake,
    ana,
    host: _Telling(TestHost().gate, asked, timeline),
    client: client,
    hears: hears,
  );
  final b = await firstDevice(fake, bo, client: client);
  await a.engine.openConversation(conversation);
  await sameGroup([a, b], conversation);
  return (fake: fake, a: a, b: b, conversation: conversation, timeline: timeline, asked: asked, client: client);
}

/// Another device of the first one's user, approved by it and in the conversation's group with [others].
Future<TestDevice> _phoneOf(
  FakeApi fake,
  TestDevice first,
  String conversation,
  List<TestDevice> others,
  http.Client client, {
  bool Function(GatewayEvent event)? hears,
}) async {
  final phone = await approvedDevice(fake, first, client: client, hears: hears);
  await phone.engine.openConversation(conversation);
  await sameGroup([first, ...others, phone], conversation);
  return phone;
}

/// What a segment holds, as another device of its user reads it: the texts of these messages, once it's imported.
Future<List<String?>> _heldIn(
  FakeApi fake,
  TestDevice first,
  String segment,
  String conversation,
  List<String> ids,
) async {
  final other = await approvedDevice(fake, first);
  final data = await other.api.segment(segment);
  await other.host.handle<Object?>({'cmd': 'backup_import', 'data': base64Encode(data), 'deleted': <String>[]});
  final texts = [for (final id in ids) await _textOn(other, conversation, id)];
  await other.engine.stop();
  return texts;
}

/// A first device of the user's, and the recovery key it showed before it was saved.
Future<({TestDevice device, String key})> _withKey(FakeApi fake, String user, http.Client client) async {
  final device = testDevice(fake, user, client: client);
  await device.engine.start();
  await device.engine.makeIdentity();
  final key = shownKey(device.state)!;
  await device.engine.keySaved();
  return (device: device, key: key);
}

/// The ID of the copy the API shows of the device's user's day.
Future<String> _shownCopyOf(TestDevice device, String day) async =>
    (await device.api.segments()).firstWhere((segment) => segment.day == day).id;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  group('the encrypted backup', () {
    test(
      "a_day_goes_up_once_it's_whole,_and_is_confirmed_with_the_version_its_segment_answered",
      () async {
        final (:fake, :a, :b, :conversation, :timeline, :asked, client: _) = await _dm();
        final day = _daysBack(_day);
        await _sent(fake, a, conversation, 'from yesterday', _day, [a, b]);
        await _sent(fake, a, conversation, 'from today', Duration.zero, [a, b]);
        // Yesterday ended; today goes on.
        expect(await _dueOn(a), ['$conversation/$day']);

        timeline.clear();
        asked.clear();
        a.clock.advance(_minute);
        await until(() => timeline.contains('backup_uploaded'), what: 'the day confirmed');
        await turnEnded(a);
        // Once the app was quiet a minute: one upload, of yesterday alone, in the place of none.
        final put = 'PUT $_segments/$conversation/$day?replaces=none';
        expect(_putsIn(timeline), [put]);
        // Confirmed after the API took it, with what its build answered.
        final build = asked.firstWhere((e) => e.command['cmd'] == 'backup_segment' && e.command['day'] == day);
        final built = build.answer! as Map<String, Object?>;
        expect(
          [
            for (final e in asked)
              if (e.command['cmd'] == 'backup_uploaded') e.command,
          ],
          [
            {
              'cmd': 'backup_uploaded',
              'conversation_id': conversation,
              'day': day,
              'complete': built['complete'],
              'version': built['version'],
            },
          ],
        );
        expect(timeline.indexOf(put), lessThan(timeline.indexOf('backup_uploaded')));
        expect(await _dueOn(a), isEmpty);
        expect(_days(await a.api.segments()), [day]);

        // Nothing more goes up while nothing changes.
        timeline.clear();
        a.clock.advance(_minute);
        await turnEnded(a);
        expect(_putsIn(timeline), isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's M9 and M5: a row only that copy held survives the day built over it, and shows.
    test(
      "a_day_another_device_uploaded_first_is_imported,_with_what_only_it_held,_then_built_again",
      () async {
        var listening = true;
        final (:fake, :a, :b, :conversation, :timeline, asked: _, :client) = await _dm(hears: (_) => listening);
        final day = _daysBack(_day);
        // Bo writes before Ana's phone is set up: the phone never holds it, as it joins the group after.
        final early = await _sent(fake, b, conversation, 'before her phone', _day, [a, b]);
        final phone = await _phoneOf(fake, a, conversation, [b], client);
        final late = await _sent(fake, b, conversation, 'with her phone', _day, [a, b, phone]);
        // Her first device backs the day up, then hears nothing more: what Bo writes next reaches her phone alone.
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 1, what: "her first device's copy");
        await turnEnded(a);
        final theirs = (await a.api.segments()).single;
        listening = false;
        final later = await _sent(fake, b, conversation, "after her first device's copy", _day, [b, phone]);
        expect(await _textOn(phone, conversation, early.id), isNull);

        final changed = <String>[];
        final heard = phone.engine.messagesChanged.listen(changed.add);
        addTearDown(heard.cancel);
        timeline.clear();
        phone.clock.advance(_minute);
        await until(() async => (await phone.api.segments()).firstOrNull?.id != theirs.id, what: "the phone's copy");
        await turnEnded(phone);
        // The phone's day holds what that copy lacks, and the copy holds a row the phone lacks: the copy comes down and
        // is taken in, then the day is built again in its place.
        final puts = _putsIn(timeline);
        expect(puts, [
          'PUT $_segments/$conversation/$day?replaces=none',
          'PUT $_segments/$conversation/$day?replaces=${theirs.id}',
        ]);
        expect(_downloadsIn(timeline), [theirs.id]);
        final download = timeline.indexOf('GET $_segments/${theirs.id}');
        expect(download, greaterThan(timeline.indexOf(puts[0])));
        expect(download, lessThan(timeline.indexOf(puts[1])));
        // What only that copy held is on the phone now, and its views were told.
        expect(await _textOn(phone, conversation, early.id), 'before her phone');
        expect(changed, contains(conversation));
        // One copy of the day now, the phone's, with all of it.
        final ours = (await a.api.segments()).single;
        expect(await _heldIn(fake, a, ours.id, conversation, [early.id, late.id, later.id]), [
          'before her phone',
          'with her phone',
          "after her first device's copy",
        ]);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_deletion_sends_its_day_up_again_without_the_message',
      () async {
        final (:fake, :a, :b, :conversation, :timeline, :asked, client: _) = await _dm();
        final day = _daysBack(_day);
        final kept = await _sent(fake, a, conversation, 'kept', _day, [a, b]);
        final gone = await _sent(fake, a, conversation, 'deleted for everyone', _day, [a, b]);
        // Edited the same day: the API dates the edit's entry as it takes it.
        fake.sentAtOffset = -_day.inMilliseconds;
        await a.engine.editMessage(conversation, gone.id, 'edited, then deleted');
        await until(() async => await _textOn(b, conversation, gone.id) == 'edited, then deleted');
        fake.sentAtOffset = 0;
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 1, what: 'the first copy');
        await turnEnded(a);
        final before = (await a.api.segments()).single;

        // Deleted for everyone, a day later: its day goes up again, built without it, in the copy's place.
        await a.engine.deleteMessage(conversation, gone.id);
        await until(() async => (await b.engine.messages(conversation, [gone.id])).isEmpty);
        timeline.clear();
        asked.clear();
        a.clock.advance(_minute);
        await until(() => timeline.contains('backup_uploaded'), what: 'the day confirmed again');
        await turnEnded(a);
        expect(_putsIn(timeline), ['PUT $_segments/$conversation/$day?replaces=${before.id}']);
        final build = asked.firstWhere((e) => e.command['cmd'] == 'backup_segment' && e.command['day'] == day);
        expect(build.command['deleted'], [gone.id]);
        // The copy that held it is gone, and the new one holds neither the message nor its edit.
        final after = (await a.api.segments()).single;
        expect(after.id, isNot(before.id));
        expect(await _heldIn(fake, a, after.id, conversation, [kept.id, gone.id]), ['kept', null]);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's I1: a copy that still holds a message the API saw deleted since restores without it.
    test(
      "a_message_deleted_after_its_day_went_up_stays_out_of_a_new_device's_restore",
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final timeline = <String>[];
        final client = _watching(fake, timeline);
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final (device: a, :key) = await _withKey(fake, ana, client);
        final b = await firstDevice(fake, bo, client: client);
        await a.engine.openConversation(conversation);
        await sameGroup([a, b], conversation);
        final kept = await _sent(fake, a, conversation, 'kept', _day, [a, b]);
        final gone = await _sent(fake, a, conversation, 'deleted for everyone', _day, [a, b]);
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 1, what: 'the day backed up');
        await turnEnded(a);
        final copy = (await a.api.segments()).single;
        // Deleted for everyone, then her device stops before a pass builds the day again: the copy still holds it.
        await a.engine.deleteMessage(conversation, gone.id);
        await until(() async => (await b.engine.messages(conversation, [gone.id])).isEmpty);
        await a.engine.stop();

        final n = testDevice(fake, ana, client: client);
        await n.engine.start();
        timeline.clear();
        await n.engine.recover(key);
        await until(() async => await _textOn(n, conversation, kept.id) == 'kept', what: 'the day restored');
        await turnEnded(n);
        // It restored that copy, and the message isn't in its database.
        expect(_downloadsIn(timeline), [copy.id]);
        expect(await _textOn(n, conversation, gone.id), isNull);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_new_device_restores_its_days,_newest_conversations_first,_and_the_rows_that_waited_fill_in',
      () async {
        final fake = FakeApi();
        final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
        final timeline = <String>[];
        final client = _watching(fake, timeline);
        final older = fake.addConversation(group: false, members: [ana, bo]);
        final newer = fake.addConversation(group: false, members: [ana, cy]);
        final (device: a, :key) = await _withKey(fake, ana, client);
        final b = await firstDevice(fake, bo, client: client);
        final c = await firstDevice(fake, cy, client: client);
        await a.engine.openConversation(older);
        await a.engine.openConversation(newer);
        await sameGroup([a, b], older);
        await sameGroup([a, c], newer);
        // The older conversation's days are three and two days back; the newer one's, yesterday.
        final first = await _sent(fake, a, older, 'three days back', _day * 3, [a, b]);
        final second = await _sent(fake, b, older, 'two days back', _day * 2, [a, b]);
        final third = await _sent(fake, c, newer, 'yesterday', _day, [a, c]);
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 3, what: 'three days backed up');
        await turnEnded(a);
        final segments = await a.api.segments();
        String idOf(String conversation, Duration ago) =>
            segments.firstWhere((s) => s.conversationId == conversation && s.day == _daysBack(ago)).id;

        // A new device of Ana's, set up with her recovery key: none of it can come from its queues. Its download of
        // the older conversation's first day never reaches the API, as if the network dropped there.
        final n = testDevice(fake, ana, client: client);
        final changed = <String>[];
        final heard = n.engine.messagesChanged.listen(changed.add);
        addTearDown(heard.cancel);
        await n.engine.start();
        timeline.clear();
        fake.cutRequest((method: 'GET', path: '$_segments/${idOf(older, _day * 2)}'));
        await n.engine.recover(key);
        await until(() async => await _textOn(n, newer, third.id) == 'yesterday', what: 'the newer day restored');
        await turnEnded(n);
        // The newer conversation is in; the restore stopped at the older one, and shows no progress while it waits.
        expect(n.backups, contains(const BackupShown.restoring(0, 3)));
        expect(n.engine.backup.value.stage, isNot(BackupStage.restoring));
        expect(await _textOn(n, older, second.id), isNull);

        // A minute later it picks up at the older conversation: the newer one isn't downloaded again.
        n.clock.advance(_minute);
        await until(() async => await _textOn(n, older, first.id) == 'three days back', what: 'the older days');
        await turnEnded(n);
        // Its restore: the newest conversation first, each day of it newest first, without what the API saw deleted.
        expect(_downloadsIn(timeline), [
          idOf(newer, _day),
          idOf(older, _day * 2),
          idOf(older, _day * 2),
          idOf(older, _day * 3),
        ]);
        for (final conversation in [newer, older]) {
          final deleted = 'GET /api/users/@me/conversations/$conversation/messages/deleted';
          expect(timeline.any((line) => line.startsWith(deleted)), isTrue, reason: conversation);
        }
        // The rows that waited fill in, and the views are told.
        expect(await _textOn(n, older, second.id), 'two days back');
        expect(changed, containsAll([newer, older]));
        // Nothing of the restore shows once it's done, and nothing went up meanwhile.
        expect(n.engine.backup.value.stage, isNot(BackupStage.restoring));
        expect(n.state, EngineState.ready);
        expect(_putsIn(timeline), isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      "a_segment_that_doesn't_open_is_skipped",
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final timeline = <String>[];
        final client = _watching(fake, timeline);
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final (device: a, :key) = await _withKey(fake, ana, client);
        final b = await firstDevice(fake, bo, client: client);
        await a.engine.openConversation(conversation);
        await sameGroup([a, b], conversation);
        final altered = await _sent(fake, a, conversation, 'in the altered copy', _day, [a, b]);
        final whole = await _sent(fake, b, conversation, 'in the whole copy', _day * 2, [a, b]);
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 2, what: 'two days backed up');
        await turnEnded(a);
        // The newest day's copy, the first a restore takes, is altered where the API keeps it.
        final newest = (await a.api.segments()).firstWhere((s) => s.day == _daysBack(_day));
        final bytes = fake.segmentFile(newest.id)!;
        bytes[bytes.length - 1] ^= 0xff;

        final n = testDevice(fake, ana, client: client);
        await n.engine.start();
        timeline.clear();
        await n.engine.recover(key);
        await until(() async => await _textOn(n, conversation, whole.id) == 'in the whole copy', what: 'the whole');
        await turnEnded(n);
        // The one that doesn't open stops nothing: it's skipped, the restore goes on and ends.
        expect(_downloadsIn(timeline), hasLength(2));
        expect(await _textOn(n, conversation, altered.id), isNull);
        expect(n.state, EngineState.ready);
        // And it's counted for the API, by its kind alone.
        n.clock.advance(_minute);
        await until(() => fake.decryptFailures.any((failure) => failure.kind == 'segment'), what: 'its report');
      },
      skip: noCore,
      timeout: _slow,
    );

    // The core's rule (backup_import's not_found backup_key): an approved or recovered device's next key may still
    // wait in its inbox, as a change of keys' transfer.
    test(
      "a_segment_under_a_key_this_device_doesn't_hold_yet_takes_the_inbox_first",
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final timeline = <String>[];
        final asked = <_Asked>[];
        final client = _watching(fake, timeline);
        final conversation = fake.addConversation(group: false, members: [ana, bo]);
        final (device: a, :key) = await _withKey(fake, ana, client);
        final b = await firstDevice(fake, bo, client: client);
        await a.engine.openConversation(conversation);
        await sameGroup([a, b], conversation);
        final message = await _sent(fake, a, conversation, 'under the new key', _day, [a, b]);
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 1, what: 'the day backed up');
        await turnEnded(a);
        final oldKey = (await a.api.segments()).single.keyId;

        // A new device of Ana's, which hears nothing after its start: its restore's first list never reaches the API.
        final n = testDevice(
          fake,
          ana,
          host: _Telling(TestHost().gate, asked, timeline),
          client: client,
          hears: (_) => false,
        );
        await n.engine.start();
        fake.cutRequest((method: 'GET', path: _segments));
        await n.engine.recover(key);
        await turnEnded(n);
        // Meanwhile Ana changes her keys on her first device, which moves the day to the new key and leaves the new
        // one in the new device's inbox, unread.
        await a.engine.changeKeys();
        await a.engine.keySaved();
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).every((s) => s.keyId != oldKey), what: 'the day moved');
        await turnEnded(a);

        // The restore goes again, its pass's first look at the inbox cut: the day's segment is under a key the new
        // device doesn't hold, so its inbox comes first, which brings it, and the segment opens.
        asked.clear();
        fake.cutRequest((method: 'GET', path: _inbox));
        n.clock.advance(_minute);
        await until(() async => await _textOn(n, conversation, message.id) == 'under the new key', what: 'restored');
        await turnEnded(n);
        final imports = [
          for (final e in asked)
            if (e.command['cmd'] == 'backup_import') e,
        ];
        expect([for (final e in imports) e.answer != null], [false, true]);
        final inbox = asked.indexWhere((e) => e.command['cmd'] == 'receive_direct');
        expect(inbox, greaterThan(asked.indexOf(imports[0])));
        expect(inbox, lessThan(asked.indexOf(imports[1])));
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'after_a_rotation_the_old_segments_move_to_the_new_key,_picking_up_where_they_stopped',
      () async {
        var cutting = false;
        var moved = 0;
        // The second move's upload never reaches the API, as if the app closed on it.
        final (:fake, :a, :b, :conversation, :timeline, asked: _, :client) = await _dm(
          watch: (request, api) {
            if (cutting && request.method == 'PUT' && _segmentPut.path.allMatches(request.url.path).isNotEmpty) {
              if (++moved == 2) api.cutRequest(_segmentPut);
            }
          },
        );
        final older = await _sent(fake, a, conversation, 'two days back', _day * 2, [a, b]);
        await _sent(fake, a, conversation, 'yesterday', _day, [a, b]);
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 2, what: 'two days backed up');
        await turnEnded(a);
        final before = await a.api.segments();
        final oldKey = before[0].keyId;
        expect([for (final s in before) s.keyId], [oldKey, oldKey]);

        // Ana changes her keys, and saves the new recovery key.
        await a.engine.changeKeys();
        await a.engine.keySaved();
        expect(a.state, EngineState.ready);
        cutting = true;
        timeline.clear();
        a.clock.advance(_minute);
        await until(() => moved == 2, what: 'the second move');
        await turnEnded(a);
        // The first day went over to the new key in its copy's place; the second is still under the old one: no day is
        // ever without its copy.
        final midway = await a.api.segments();
        expect(_days(midway), _days(before));
        expect(
          [
            for (final s in midway)
              if (s.keyId == oldKey) s.id,
          ],
          [before[1].id],
        );

        // The app starts again: the move picks up after the first, which isn't downloaded again.
        final again = await restarted(fake, a, client: client);
        timeline.clear();
        again.clock.advance(_minute);
        await until(
          () async => (await again.api.segments()).every((s) => s.keyId != oldKey),
          what: 'the move picked up',
        );
        await turnEnded(again);
        expect(_downloadsIn(timeline), [before[1].id]);
        final after = await again.api.segments();
        expect(_days(after), _days(before));
        // What moved still holds its day.
        final movedFirst = after.firstWhere((s) => s.day == before[0].day);
        expect(await _heldIn(fake, again, movedFirst.id, conversation, [older.id]), ['two days back']);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_full_quota_pauses_the_backup_and_says_so',
      () async {
        final (:fake, :a, :b, :conversation, :timeline, asked: _, :client) = await _dm();
        final day = _daysBack(_day);
        await _sent(fake, a, conversation, 'kept for later', _day, [a, b]);
        fake.refuse(
          _segmentPut,
          413,
          body: {'error': 'uploading a backup segment: not enough storage space for this file'},
        );
        a.clock.advance(_minute);
        await until(() => a.engine.backup.value.stage == BackupStage.paused, what: 'the pause');
        await turnEnded(a);
        expect(a.engine.backup.value, const BackupShown.paused(BackupPause.full));
        // What waits stays: the day is still due, and nothing confirmed it.
        expect(timeline, isNot(contains('backup_uploaded')));
        expect(await _dueOn(a), ['$conversation/$day']);

        // The review's I2: the app restarted during the pause says so at once, before any pass.
        final again = await restarted(fake, a, client: client);
        expect(again.engine.backup.value, const BackupShown.paused(BackupPause.full));

        // Quiet minutes don't try again: the next day does, and the backup goes on.
        timeline.clear();
        again.clock.advance(_minute);
        await turnEnded(again);
        expect(_putsIn(timeline), isEmpty);
        again.clock.advance(_day);
        await until(() => timeline.contains('backup_uploaded'), what: 'the day after');
        await turnEnded(again);
        expect(again.engine.backup.value, BackupShown.upToDate);
        expect(await _dueOn(again), isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's I1, and M9's body over 32 MiB: only a full storage pauses the pass.
    test(
      'a_day_too_large_to_keep_is_set_aside,_and_the_other_days_go_on',
      () async {
        final (:fake, :a, :b, :conversation, :timeline, asked: _, client: _) = await _dm();
        final (older, newer) = (_daysBack(_day * 2), _daysBack(_day));
        // The older day holds a long text, the newer one a short one: only the older passes the storage's limit for
        // one file, which the API answers in its words.
        await _sent(fake, a, conversation, _noise(16000), _day * 2, [a, b]);
        await _sent(fake, a, conversation, 'a short day', _day, [a, b]);
        fake.fileLimit = 4000;
        timeline.clear();
        a.clock.advance(_minute);
        await until(() => timeline.contains('backup_uploaded'), what: 'the newer day');
        await turnEnded(a);
        // The older day came first and didn't fit: it's set aside, and the newer one went up all the same.
        expect(_putsIn(timeline), [
          'PUT $_segments/$conversation/$older?replaces=none',
          'PUT $_segments/$conversation/$newer?replaces=none',
        ]);
        expect(_days(await a.api.segments()), [newer]);
        expect(await _dueOn(a), ['$conversation/$older']);
        expect(a.engine.backup.value, const BackupShown.paused(BackupPause.tooLarge));

        // Quiet minutes leave it alone.
        timeline.clear();
        a.clock.advance(_minute);
        await turnEnded(a);
        expect(_putsIn(timeline), isEmpty);

        // A day later it's tried again: with room for it now, it goes up, and the backup is up to date.
        fake.fileLimit = fileMost;
        timeline.clear();
        a.clock.advance(_day);
        await until(() => timeline.contains('backup_uploaded'), what: 'the older day, a day later');
        await turnEnded(a);
        expect(_putsIn(timeline), ['PUT $_segments/$conversation/$older?replaces=none']);
        expect(await _dueOn(a), isEmpty);
        expect(a.engine.backup.value, BackupShown.upToDate);

        // The API's «over 32 MiB» is a day too large too: the day is set aside, and nothing is confirmed.
        await _sent(fake, a, conversation, 'more for the newer day', _day, [a, b]);
        final copy = await _shownCopyOf(a, newer);
        fake.refuse(_segmentPut, 413, body: {'error': 'the request body is over 32 MiB'});
        timeline.clear();
        a.clock.advance(_minute);
        await until(() => a.engine.backup.value.stage == BackupStage.paused, what: 'the newer day set aside');
        await turnEnded(a);
        expect(_putsIn(timeline), ['PUT $_segments/$conversation/$newer?replaces=$copy']);
        expect(timeline, isNot(contains('backup_uploaded')));
        expect(await _dueOn(a), ['$conversation/$newer']);
        expect(a.engine.backup.value, const BackupShown.paused(BackupPause.tooLarge));
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's I3, and M9's 409 without `current`.
    test(
      "the_backup_says_it's_up_to_date_only_once_a_pass_found_nothing_due,_and_nothing_failed_since",
      () async {
        final (:fake, :a, :b, :conversation, :timeline, asked: _, client: _) = await _dm();
        // No pass yet: nothing says it's up to date.
        expect(a.engine.backup.value, BackupShown.uploading);
        a.clock.advance(_minute);
        await until(() => a.engine.backup.value == BackupShown.upToDate, what: 'up to date');
        await turnEnded(a);

        // A day that ended goes up; the API's 409 that names no copy (its bucket moved under the upload) is a failure
        // that passes: nothing came down, nothing is confirmed, and it isn't up to date.
        await _sent(fake, a, conversation, 'from yesterday', _day, [a, b]);
        fake.refuse(_segmentPut, 409, body: {'error': 'the storage bucket moved: try again'});
        timeline.clear();
        a.clock.advance(_minute);
        await until(() => _putsIn(timeline).length == 1, what: 'the upload kept out');
        await turnEnded(a);
        expect(_downloadsIn(timeline), isEmpty);
        expect(timeline, isNot(contains('backup_uploaded')));
        expect(a.engine.backup.value, BackupShown.uploading);
        // Tried again a minute later, it goes up, and nothing waits.
        a.clock.advance(_minute);
        await until(() => timeline.contains('backup_uploaded'), what: 'the day confirmed');
        await turnEnded(a);
        expect(a.engine.backup.value, BackupShown.upToDate);
        expect(a.backups, contains(BackupShown.uploading));

        // A change of keys that waits for its key to be saved backs nothing up: no longer up to date.
        await a.engine.changeKeys();
        a.clock.advance(_minute);
        await until(() => a.engine.backup.value == BackupShown.uploading, what: 'no longer up to date');
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's I4: the rule that stands between a device behind on its keys and another device's newer copy.
    test(
      "another_device's_copy_under_a_key_this_device_doesn't_hold_stays_where_it_is",
      () async {
        var listening = true;
        final (:fake, :a, :b, :conversation, :timeline, asked: _, client: _) = await _dm();
        // Ana's phone, which hears nothing once she changes her keys, and whose inbox reads nothing then: it never
        // learns of the change.
        final phoneClient = _watching(
          fake,
          timeline,
          answer: (request) async => !listening && request.method == 'GET' && request.url.path == _inbox
              ? http.Response('[]', 200, headers: {'content-type': 'application/json'})
              : null,
        );
        final phone = await _phoneOf(fake, a, conversation, [b], phoneClient, hears: (_) => listening);
        final day = _daysBack(_day);
        await _sent(fake, a, conversation, 'one day of it', _day, [a, b, phone]);
        // Her first device backs the day up, then moves it to the key it changes to.
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 1, what: 'the day backed up');
        await turnEnded(a);
        listening = false;
        await a.engine.changeKeys();
        await a.engine.keySaved();
        final newKey = await _sealsWith(a);
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).firstOrNull?.keyId == newKey, what: 'the day moved');
        await turnEnded(a);
        final moved = (await a.api.segments()).single;
        expect(await _sealsWith(phone), isNot(newKey));

        // The phone, still on the older key, has the day due: its copy goes up, and the API keeps it out (409).
        timeline.clear();
        phone.clock.advance(_minute);
        await until(() => _putsIn(timeline).isNotEmpty, what: "the phone's upload");
        await turnEnded(phone);
        // The copy that holds the day came down and doesn't open here: it stays, nothing goes up in its place, and the
        // day waits for the key.
        expect(_putsIn(timeline), ['PUT $_segments/$conversation/$day?replaces=none']);
        expect(_downloadsIn(timeline), contains(moved.id));
        expect([for (final s in await a.api.segments()) s.id], [moved.id]);
        expect(await _dueOn(phone), ['$conversation/$day']);
        expect(phone.engine.backup.value, BackupShown.uploading);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's M9: a copy no core opens holds nothing anyone reads.
    test(
      "another_device's_copy_that_doesn't_open_is_built_over",
      () async {
        final (:fake, :a, :b, :conversation, :timeline, asked: _, :client) = await _dm();
        final phone = await _phoneOf(fake, a, conversation, [b], client);
        final day = _daysBack(_day);
        final message = await _sent(fake, a, conversation, 'kept by this device', _day, [a, b, phone]);
        phone.clock.advance(_minute);
        await until(() async => (await phone.api.segments()).length == 1, what: "the phone's copy");
        await turnEnded(phone);
        final theirs = (await phone.api.segments()).single;
        // Altered where the API keeps it.
        final bytes = fake.segmentFile(theirs.id)!;
        bytes[bytes.length - 1] ^= 0xff;

        timeline.clear();
        a.clock.advance(_minute);
        await until(() => timeline.contains('backup_uploaded'), what: "the first device's copy");
        await turnEnded(a);
        // It came down, didn't open, and the day was built in its place.
        expect(_putsIn(timeline), [
          'PUT $_segments/$conversation/$day?replaces=none',
          'PUT $_segments/$conversation/$day?replaces=${theirs.id}',
        ]);
        expect(_downloadsIn(timeline), [theirs.id]);
        final ours = (await a.api.segments()).single;
        expect(ours.id, isNot(theirs.id));
        expect(await _heldIn(fake, a, ours.id, conversation, [message.id]), ['kept by this device']);
        // Counted for the API, by its kind alone.
        a.clock.advance(_minute);
        await until(() => fake.decryptFailures.any((failure) => failure.kind == 'segment'), what: 'its report');
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's M9: two devices of the user's with the new key move the same segments at once.
    test(
      'two_devices_moving_at_once_leave_each_day_one_copy,_under_the_new_key',
      () async {
        final (:fake, :a, :b, :conversation, :timeline, asked: _, :client) = await _dm();
        final phone = await _phoneOf(fake, a, conversation, [b], client);
        final older = await _sent(fake, a, conversation, 'two days back', _day * 2, [a, b, phone]);
        final newer = await _sent(fake, a, conversation, 'yesterday', _day, [a, b, phone]);
        // Her first device backs both days up; her phone takes them in, as it holds the same.
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 2, what: 'two days backed up');
        await turnEnded(a);
        phone.clock.advance(_minute);
        await turnEnded(phone);
        expect(await _dueOn(phone), isEmpty);
        final before = await a.api.segments();

        // Ana changes her keys on her first device, whose transfer her phone takes.
        await a.engine.changeKeys();
        await a.engine.keySaved();
        final newKey = await _sealsWith(a);
        await until(() async => await _sealsWith(phone) == newKey, what: 'the new key on the phone');
        // Both move: their first uploads wait for each other, then go in the order they came.
        fake.gather(_segmentPut, 2);
        timeline.clear();
        a.clock.advance(_minute);
        phone.clock.advance(_minute);
        await until(() async => (await a.api.segments()).every((s) => s.keyId == newKey), what: 'every day moved');
        await Future.wait([turnEnded(a), turnEnded(phone)]);
        // Each tried each segment, and the second to come for one was kept out: one copy a day, which holds the day.
        expect(_putsIn(timeline), hasLength(4));
        final after = await a.api.segments();
        expect(_days(after), _days(before));
        String copyOf(String day) => after.firstWhere((s) => s.day == day).id;
        expect(await _heldIn(fake, a, copyOf(before[0].day), conversation, [older.id]), ['two days back']);
        expect(await _heldIn(fake, a, copyOf(before[1].day), conversation, [newer.id]), ['yesterday']);
        // Neither took it for a failure: both moves ended, and both are up to date.
        for (final device in [a, phone]) {
          expect(device.store.read(backupMove), {'key': newKey});
          expect(device.engine.backup.value, BackupShown.upToDate);
        }
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's M10: the move a lost device left halfway is finished by a new installation.
    test(
      "a_new_installation_moves_what_a_lost_device's_move_left_under_the_old_key",
      () async {
        var cutting = false;
        var moved = 0;
        final (:fake, :a, :b, :conversation, timeline: _, asked: _, :client) = await _dm(
          watch: (request, api) {
            if (cutting && request.method == 'PUT' && _segmentPut.path.allMatches(request.url.path).isNotEmpty) {
              if (++moved == 2) api.cutRequest(_segmentPut);
            }
          },
        );
        final older = await _sent(fake, a, conversation, 'two days back', _day * 2, [a, b]);
        final newer = await _sent(fake, a, conversation, 'yesterday', _day, [a, b]);
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 2, what: 'two days backed up');
        await turnEnded(a);
        final before = await a.api.segments();
        final oldKey = before[0].keyId;
        // Ana changes her keys: her device moves the first day, then is lost on the second.
        await a.engine.changeKeys();
        final key = a.state.rotating ? a.state.recoveryKey : null;
        if (key == null) fail('the change of keys showed no recovery key');
        await a.engine.keySaved();
        cutting = true;
        a.clock.advance(_minute);
        await until(() => moved == 2, what: 'the second move');
        await turnEnded(a);
        await a.engine.stop();
        expect([
          for (final s in await a.api.segments())
            if (s.keyId == oldKey) s.id,
        ], hasLength(1));

        // A new installation of Ana's, set up with her new recovery key, which brings the older backup key too.
        final n = testDevice(fake, a.user, client: client);
        await n.engine.start();
        await n.engine.recover(key);
        await until(() async => await _textOn(n, conversation, older.id) == 'two days back', what: 'restored');
        await turnEnded(n);
        // Its first pass moves what isn't under its key; each day keeps its copy, which holds it.
        n.clock.advance(_minute);
        await turnEnded(n);
        final after = await n.api.segments();
        expect([
          for (final s in after)
            if (s.keyId == oldKey) s.id,
        ], isEmpty);
        expect(_days(after), _days(before));
        String copyOf(String day) => after.firstWhere((s) => s.day == day).id;
        expect(await _heldIn(fake, n, copyOf(before[0].day), conversation, [older.id]), ['two days back']);
        expect(await _heldIn(fake, n, copyOf(before[1].day), conversation, [newer.id]), ['yesterday']);
      },
      skip: noCore,
      timeout: _slow,
    );

    // The review's M15.
    test(
      "a_moved_day's_next_upload_replaces_the_copy_it_moved_to",
      () async {
        final (:fake, :a, :b, :conversation, :timeline, asked: _, client: _) = await _dm();
        final day = _daysBack(_day);
        final gone = await _sent(fake, a, conversation, 'deleted after the move', _day, [a, b]);
        await _sent(fake, a, conversation, 'kept', _day, [a, b]);
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).length == 1, what: 'the day backed up');
        await turnEnded(a);
        final first = (await a.api.segments()).single;
        await a.engine.changeKeys();
        await a.engine.keySaved();
        a.clock.advance(_minute);
        await until(() async => (await a.api.segments()).firstOrNull?.keyId != first.keyId, what: 'the day moved');
        await turnEnded(a);
        final moved = (await a.api.segments()).single;

        // A deletion sends the day up again: in the place of the copy it moved to, with nothing to take in first.
        await a.engine.deleteMessage(conversation, gone.id);
        await until(() async => (await b.engine.messages(conversation, [gone.id])).isEmpty);
        timeline.clear();
        a.clock.advance(_minute);
        await until(() => timeline.contains('backup_uploaded'), what: 'the day confirmed again');
        await turnEnded(a);
        expect(_putsIn(timeline), ['PUT $_segments/$conversation/$day?replaces=${moved.id}']);
        expect(_downloadsIn(timeline), isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );
  });

  // The backup's own rules, on a stub core and API: no cryptography, only what the backup decides from their answers.
  group("the backup's rules", () {
    // The review's M7: a day the API refuses for good (here a day past tomorrow, from a clock a day ahead).
    test('a_day_that_fails_three_passes_in_a_row_is_set_aside,_and_the_days_after_it_go_up', () async {
      const due = ['2026-11-20', '2026-11-21'];
      final confirmed = <String>{};
      final puts = <String>[];
      final stub = _onAStub(
        core: {
          'backup_due': (_) => {
            'segments': [
              for (final day in due)
                if (!confirmed.contains(day)) {'conversation_id': _c, 'day': day, 'complete': true},
            ],
          },
          'backup_uploaded': (command) {
            confirmed.add(command['day']! as String);
            return <String, Object?>{};
          },
        },
        api: (api) => api.put = (conversation, day, bytes, replaces) async {
          puts.add(day);
          if (day == '2026-11-20') {
            throw _refusal(400, 'invalid day: a day is YYYY-MM-DD, in UTC, from 2026-01-01 to tomorrow');
          }
          return uuidv4();
        },
      );
      stub.backups.quiet();
      await stub.backups.settled();
      // Each pass stops at it, waiting a minute, then two, then four.
      await _moveOn(stub, _minute);
      await _moveOn(stub, _minute * 2);
      expect(puts, ['2026-11-20', '2026-11-20', '2026-11-20']);
      expect(confirmed, isEmpty);
      await _moveOn(stub, _minute * 4);
      // Set aside after the third: the next day goes up, and the one set aside isn't tried again before a day passed.
      expect(puts, ['2026-11-20', '2026-11-20', '2026-11-20', '2026-11-21']);
      expect(confirmed, {'2026-11-21'});
      expect(stub.backups.shown.value, BackupShown.uploading);
      await _moveOn(stub, _minute * 60);
      expect(puts, hasLength(4));
      await _moveOn(stub, _day);
      expect(puts.last, '2026-11-20');
      expect(((stub.store.read(backupSetAside)! as Map)['day:$_c/2026-11-20'] as Map)['fails'], 4);
    });

    // Round 3: a passing outage loses a restore no day. A download that never came whole is tried again a day later.
    test(
      "a_restore's_segment_that_failed_three_passes_in_a_row_is_tried_again_a_day_later,_while_the_rest_comes_in",
      () async {
        final (newer, older) = (_segmentOf(_s1, '2026-11-21'), _segmentOf(_s2, '2026-11-20'));
        var broken = true;
        final imported = <Object?>[];
        final stub = _onAStub(
          core: {
            'backup_import': (command) {
              imported.add(command['data']);
              return {'imported': 1};
            },
          },
          api: (api) => api
            ..listing = ((_) async => [newer, older])
            ..download = (id, _, _) async {
              if (id != newer.id) return Uint8List.fromList([2, 2, 2]);
              if (broken) throw http.ClientException('the stream ended before the file did');
              return Uint8List.fromList([1, 1, 1]);
            },
        );
        await stub.store.write(backupRestore, {'done': <String>[]});
        stub.backups.wake();
        await stub.backups.settled();
        // Each pass stops at it, waiting a minute, then two.
        await _moveOn(stub, _minute);
        await _moveOn(stub, _minute * 2);
        expect(imported, isEmpty);
        // Set aside after the third: the restore takes the rest, and stays due for the day it set aside.
        await _moveOn(stub, _minute * 4);
        expect(imported, ['AgIC']);
        expect(stub.store.read(backupRestore), {
          'done': [_c],
          'waiting': true,
        });
        // Until its day comes, a pass neither tries it again nor lists the backup for it.
        int listings() => stub.log.where((line) => line == 'segments').length;
        final listed = listings();
        await _moveOn(stub, _minute * 60);
        expect(listings(), listed);
        expect(imported, ['AgIC']);
        // A day later the storage answers again: the day comes in, and the restore is over.
        broken = false;
        await _moveOn(stub, _day);
        expect(imported, ['AgIC', 'AQEB']);
        expect(stub.store.read(backupRestore), isNull);
        expect(stub.store.read(backupSetAside), isNull);
      },
    );

    // Round 3: never imported without its deleted messages, nor left out of the restore for a passing outage.
    test("a_conversation_whose_deleted_messages_didn't_come_three_passes_in_a_row_is_restored_a_day_later,_the_others_"
        'meanwhile', () async {
      const first = '0193a4b2-0000-7000-8000-0000000c0011';
      const second = '0193a4b2-0000-7000-8000-0000000c0012';
      // The first conversation's day is the newer one: the restore comes to it first.
      final segments = [
        _segmentOf(_s1, '2026-11-21', conversation: first),
        _segmentOf(_s2, '2026-11-20', conversation: second),
      ];
      var down = true;
      final imported = <Object?>[];
      final stub = _onAStub(
        core: {
          'backup_import': (command) {
            imported.add(command['data']);
            return {'imported': 1};
          },
        },
        api: (api) => api
          ..listing = ((_) async => segments)
          ..download = ((id, _, _) async => Uint8List.fromList(id == _s1 ? [1, 1, 1] : [2, 2, 2]))
          ..deleted = (conversation, _) async {
            if (conversation == first && down) throw http.ClientException('fetch failed');
            return <String>[];
          },
      );
      await stub.store.write(backupRestore, {'done': <String>[]});
      stub.backups.wake();
      await stub.backups.settled();
      await _moveOn(stub, _minute);
      await _moveOn(stub, _minute * 2);
      expect(imported, isEmpty);
      // Set aside after the third: the other conversation comes in, and nothing of the first without its list.
      await _moveOn(stub, _minute * 4);
      expect(imported, ['AgIC']);
      expect(stub.log.where((line) => line == 'segment'), hasLength(1));
      expect(stub.store.read(backupRestore), {
        'done': [second],
        'waiting': true,
      });
      // A day later its list comes: its day comes in, and the restore is over.
      down = false;
      await _moveOn(stub, _day);
      expect(imported, ['AgIC', 'AQEB']);
      expect(stub.store.read(backupRestore), isNull);
      expect(stub.store.read(backupSetAside), isNull);
    });

    // The review's I1: what the API saw deleted goes with every segment the backup opens, as with every day it builds.
    test("a_restore,_another_device's_copy_and_a_move_take_what_the_API_saw_deleted", () async {
      const gone = ['0193a4b2-0000-7000-8000-0000000d0001', '0193a4b2-0000-7000-8000-0000000d0002'];
      // A restore's segment.
      final restored = <Object?>[];
      final restore = _onAStub(
        core: {
          'backup_import': (command) {
            restored.add(command['deleted']);
            return {'imported': 1};
          },
        },
        api: (api) => api
          ..listing = ((_) async => [_segmentOf(_s1, '2026-11-21')])
          ..deleted = ((_, _) async => gone),
      );
      await restore.store.write(backupRestore, {'done': <String>[]});
      restore.backups.wake();
      await restore.backups.settled();
      expect(restored, [gone]);
      // Another device's copy of a day this device builds, which the API answers with a 409 that names it.
      final takenIn = <Object?>[];
      var held = true;
      final copy = _onAStub(
        core: {
          'backup_due': (_) => {
            'segments': [
              {'conversation_id': _c, 'day': '2026-11-20', 'complete': true},
            ],
          },
          'backup_import': (command) {
            takenIn.add(command['deleted']);
            return {'imported': 1};
          },
        },
        api: (api) => api
          ..deleted = ((_, _) async => gone)
          ..put = (conversation, day, bytes, replaces) async {
            if (!held) return uuidv4();
            held = false;
            throw duvet.DuvetApiException(
              action: 'test the backup',
              statusCode: 409,
              body: jsonEncode({'error': 'another segment holds this day', 'current': _s2}),
            );
          },
      );
      copy.backups.quiet();
      await copy.backups.settled();
      expect(takenIn, [gone]);
      // A move's segment.
      final moved = <Object?>[];
      final move = _onAStub(
        core: {
          'backup_reencrypt': (command) {
            moved.add(command['deleted']);
            return {'data': 'AAEC', 'key_id': 'current'};
          },
        },
        api: (api) => api
          ..listing = ((_) async => [_segmentOf(_s1, '2026-11-21', keyId: 'older')])
          ..deleted = ((_, _) async => gone),
      );
      await move.store.write(backupMove, {'key': 'older'});
      move.backups.quiet();
      await move.backups.settled();
      expect(moved, [gone]);
    });

    // Round 3: a key this device doesn't hold yet may still come, with a change of keys' transfer.
    test("a_restore's_segment_under_a_key_this_device_doesn't_hold_is_tried_again_a_day_later", () async {
      var held = false;
      final imported = <Object?>[];
      final stub = _onAStub(
        core: {
          'backup_import': (command) {
            if (!held) throw CoreError('not_found', message: 'no such backup key', what: 'backup_key');
            imported.add(command['data']);
            return {'imported': 1};
          },
        },
        api: (api) => api.listing = (_) async => [_segmentOf(_s1, '2026-11-21')],
      );
      await stub.store.write(backupRestore, {'done': <String>[]});
      stub.backups.wake();
      await stub.backups.settled();
      // Its inbox first, then once more: still no key, so the day is set aside, and the restore stays due for it.
      expect(stub.log.where((line) => line == 'inbox'), hasLength(2));
      expect(imported, isEmpty);
      expect(stub.store.read(backupRestore), {
        'done': [_c],
        'waiting': true,
      });
      // A day later the key is here: the day comes in, and the restore is over.
      held = true;
      await _moveOn(stub, _day);
      expect(imported, ['AAEC']);
      expect(stub.store.read(backupRestore), isNull);
    });

    // The review's M7: a move's segment that never comes down whole stops the move no more; it stays under its key,
    // which the older keys a device holds still open.
    test("a_move's_segment_that_failed_three_passes_in_a_row_is_passed_over", () async {
      final segments = [_segmentOf(_s1, '2026-11-21', keyId: 'older'), _segmentOf(_s2, '2026-11-20', keyId: 'older')];
      final put = <String>[];
      final stub = _onAStub(
        api: (api) => api
          ..listing = ((_) async => segments)
          ..download = (id, _, _) async {
            if (id == _s1) throw http.ClientException('the stream ended before the file did');
            return Uint8List.fromList([1, 2, 3]);
          }
          ..put = (conversation, day, bytes, replaces) async {
            put.add('$day $replaces');
            return uuidv4();
          },
      );
      await stub.store.write(backupMove, {'key': 'older'});
      stub.backups.quiet();
      await stub.backups.settled();
      await _moveOn(stub, _minute);
      await _moveOn(stub, _minute * 2);
      expect(put, isEmpty);
      await _moveOn(stub, _minute * 4);
      expect(put, ['2026-11-20 $_s2']);
      expect(stub.store.read(backupMove), {'key': 'current'});
      expect(stub.store.read(backupSetAside), isNull);
    });

    test("a_network_that_doesn't_answer_counts_against_no_day", () async {
      var down = true;
      final puts = <String>[];
      final stub = _onAStub(
        core: {
          'backup_due': (_) => {
            'segments': [
              if (puts.isEmpty || down) {'conversation_id': _c, 'day': '2026-11-20', 'complete': true},
            ],
          },
        },
        api: (api) => api
          ..deleted = (_, _) async {
            if (down) throw http.ClientException('fetch failed');
            return <String>[];
          }
          ..put = (conversation, day, bytes, replaces) async {
            puts.add(day);
            return uuidv4();
          },
      );
      stub.backups.quiet();
      await stub.backups.settled();
      for (final minutes in [1, 2, 4, 8, 16]) {
        await _moveOn(stub, _minute * minutes);
      }
      expect(stub.store.read(backupSetAside), isNull);
      // Back up, the day goes at the next pass.
      down = false;
      await _moveOn(stub, _minute * 32);
      expect(puts, ['2026-11-20']);
    });

    // The review's M8: however busy the app, a pass at the latest 30 minutes after the last one ended, and as a day
    // ends.
    test('a_pass_runs_30_minutes_after_the_last_one_ended_at_the_latest,_and_as_the_UTC_day_ends', () async {
      final stub = _onAStub();
      Duration toDayEnd() => Duration(milliseconds: _dayMs - stub.clock.now().millisecondsSinceEpoch % _dayMs);
      // A minute into a UTC day.
      stub.clock.advance(toDayEnd() + _minute);
      int passes() => stub.log.where((line) => line == 'backup_due').length;
      stub.backups.wake();
      await _moveOn(stub, _minute * 29);
      expect(passes(), 0);
      await _moveOn(stub, _minute);
      expect(passes(), 1);
      await _moveOn(stub, _minute * 30);
      expect(passes(), 2);
      // Ten minutes before the day ends, the next pass is as it ends.
      stub.clock.advance(toDayEnd() - _minute * 10);
      await stub.backups.settled();
      final before = passes();
      stub.backups.quiet();
      await stub.backups.settled();
      await _moveOn(stub, _minute * 10 + const Duration(seconds: 2));
      expect(passes(), before + 2);
    });

    // The review's M12: a new device waiting at Finish makes no request for its restore.
    test('before_the_device_is_ready,_a_pass_makes_no_request_and_asks_nothing_of_the_core', () async {
      final stub = _onAStub(ready: () => false);
      await stub.store.write(backupRestore, {'done': <String>[]});
      stub.backups.quiet();
      await stub.backups.settled();
      stub.backups.wake();
      await stub.backups.settled();
      expect(stub.log, isEmpty);
      expect(stub.backups.shown.value, BackupShown.uploading);
    });

    // The review's M6, the core's rule: before the copy work, the transfers waiting.
    test('a_pass_takes_the_inbox_before_anything_else', () async {
      final stub = _onAStub(
        core: {
          'backup_due': (_) => {
            'segments': [
              {'conversation_id': _c, 'day': '2026-11-20', 'complete': true},
            ],
          },
        },
      );
      await stub.store.write(backupRestore, {'done': <String>[]});
      stub.backups.quiet();
      await stub.backups.settled();
      expect(stub.log.first, 'inbox');
      expect(stub.log, contains('putSegment'));
    });

    // The review's M13: full pages forever list no backup.
    test('a_listing_whose_pages_never_end_stops_at_a_thousand_of_them', () async {
      final full = [
        for (var i = 0; i < 1000; i++) _segmentOf('0193a4b2-0000-7000-8000-${'$i'.padLeft(12, '0')}', '2026-11-20'),
      ];
      final ids = [for (final s in full) s.id];
      int listed(List<String> log, String name) => log.where((line) => line == name).length;
      // The restore's list of the segments (of a conversation it's done with: a list that ends restores none of them).
      var pages = 0;
      final restore = _onAStub(api: (api) => api.listing = (_) async => ++pages > 1001 ? [] : full);
      await restore.store.write(backupRestore, {
        'done': [_c],
      });
      restore.backups.wake();
      await restore.backups.settled();
      expect(listed(restore.log, 'segments'), 1000);
      // A conversation's deleted messages.
      var deletedPages = 0;
      final deleted = _onAStub(
        api: (api) => api
          ..listing = ((_) async => [full[0]])
          ..deleted = (_, _) async => ++deletedPages > 1001 ? <String>[] : ids,
      );
      await deleted.store.write(backupRestore, {'done': <String>[]});
      deleted.backups.wake();
      await deleted.backups.settled();
      expect(listed(deleted.log, 'deletedMessages'), 1000);
      // The move's.
      var movePages = 0;
      final move = _onAStub(api: (api) => api.listing = (_) async => ++movePages > 1001 ? [] : full);
      await move.store.write(backupMove, {'key': 'older'});
      move.backups.quiet();
      await move.backups.settled();
      expect(listed(move.log, 'segments'), 1000);
    });

    // Task 32's review, I2: the API keeps no segment past 32 MiB, so a download that goes past it is cut, and what came
    // of it is never taken in.
    test("a_segment's_download_past_32_MiB_is_cut_off,_and_nothing_of_it_is_taken_in", () async {
      final imported = <Object?>[];
      var aborted = false;
      final stub = _onAStub(
        core: {
          'backup_import': (command) {
            imported.add(command['data']);
            return {'imported': 1};
          },
        },
        api: (api) => api
          ..listing = ((_) async => [_segmentOf(_s1, '2026-11-21')])
          ..download = (id, onProgress, abortTrigger) async {
            onProgress?.call(maxSegmentBytes + 1, -1);
            await abortTrigger;
            aborted = true;
            throw http.RequestAbortedException(Uri.parse('https://storage.test/segment'));
          },
      );
      await stub.store.write(backupRestore, {'done': <String>[]});
      stub.backups.wake();
      await stub.backups.settled();
      expect(aborted, isTrue);
      expect(imported, isEmpty);
      // Counted against its day, as its bytes are the API's answer: three passes of it set it aside.
      expect(((stub.store.read(backupSetAside)! as Map)['restore:$_c/2026-11-21'] as Map)['fails'], 1);
    });

    // The API takes no body past 32 MiB: such a day never goes, and is set aside as too large, while the rest goes on.
    test('a_day_whose_segment_is_past_32_MiB_never_goes_up,_and_is_set_aside_as_too_large', () async {
      final puts = <String>[];
      final stub = _onAStub(
        core: {
          'backup_due': (_) => {
            'segments': [
              {'conversation_id': _c, 'day': '2026-11-20', 'complete': true},
              {'conversation_id': _c, 'day': '2026-11-21', 'complete': true},
            ],
          },
          'backup_segment': (command) => {
            ..._built,
            if (command['day'] == '2026-11-20') 'data': base64Encode(Uint8List(maxSegmentBytes + 1)),
          },
        },
        api: (api) => api.put = (conversation, day, bytes, replaces) async {
          puts.add(day);
          return uuidv4();
        },
      );
      stub.backups.quiet();
      await stub.backups.settled();
      expect(puts, ['2026-11-21']);
      expect(stub.backups.shown.value, const BackupShown.paused(BackupPause.tooLarge));
      expect(((stub.store.read(backupSetAside)! as Map)['day:$_c/2026-11-20'] as Map)['too_large'], isTrue);
    });

    // Two writes of a file aren't atomic: the key the move goes to and how far it went are one write each time.
    test("the_key_seen_and_the_move's_place_go_in_one_write", () async {
      final store = _Writes();
      final segments = [_segmentOf(_s1, '2026-11-20', keyId: 'older'), _segmentOf(_s2, '2026-11-21', keyId: 'older')];
      final stub = _onAStub(store: store, api: (api) => api.listing = (_) async => segments);
      stub.backups.quiet();
      await stub.backups.settled();
      final moves = [
        for (final (key, value) in store.written)
          if (key == backupMove) value,
      ];
      expect(moves, [
        {'key': 'current', 'after': _s1},
        {'key': 'current', 'after': _s2},
        {'key': 'current'},
      ]);
      // Nothing else holds either.
      expect({for (final (key, _) in store.written) key}, {backupMove});
    });

    // Review Focus 2 and Ruling 23: only the app's engine, the one with a screen, backs up, restores or moves.
    test('a_background_engine_never_backs_up,_restores_or_moves', () async {
      final gate = CoreGate(serves: false, keys: MemoryKeys());
      final refused = throwsA(isA<CoreError>().having((e) => (e.code, e.field), 'code', ('bad_command', 'cmd')));
      for (final cmd in ['backup_due', 'backup_segment', 'backup_uploaded', 'backup_import', 'backup_reencrypt']) {
        await expectLater(gate.handle<Object?>({'cmd': cmd}), refused, reason: cmd);
      }
    });
  });
}

// The stub's parts.

const _c = '0193a4b2-0000-7000-8000-0000000c0001';
const _built = {'data': 'AAEC', 'key_id': 'current', 'complete': true, 'version': 1};
const _s1 = '0193a4b2-0000-7000-8000-000000050001';
const _s2 = '0193a4b2-0000-7000-8000-000000050002';
const _dayMs = 24 * 3600 * 1000;

duvet.BackupSegment _segmentOf(String id, String day, {String keyId = 'current', String conversation = _c}) =>
    duvet.BackupSegment(
      id: id,
      conversationId: conversation,
      day: day,
      complete: true,
      keyId: keyId,
      size: 3,
      createdAt: DateTime.utc(2026, 11),
    );

/// The API's answer of [status], in its words, as the client gives it.
duvet.DuvetApiException _refusal(int status, String error) =>
    duvet.DuvetApiException(action: 'test the backup', statusCode: status, body: jsonEncode({'error': error}));

/// A core that answers each command as the test says, and tells it in the log.
class _StubCore implements CoreHost {
  _StubCore(this._log, this._answers);
  final List<String> _log;
  final Map<String, Object? Function(Map<String, Object?> command)> _answers;

  @override
  Future<T> handle<T>(Map<String, Object?> command) async {
    final cmd = command['cmd']! as String;
    _log.add(cmd);
    final answer = _answers[cmd] ?? (throw StateError('the stub core has no $cmd'));
    return answer(command) as T;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The backup's routes as the test says, each told in the log by its name.
class _StubApi implements duvet.E2eApi {
  _StubApi(this._log);
  final List<String> _log;

  Future<List<duvet.BackupSegment>> Function(String? after) listing = (_) async => [];
  Future<List<String>> Function(String conversationId, String? after) deleted = (_, _) async => [];
  Future<Uint8List> Function(String id, void Function(int, int)? onProgress, Future<void>? abortTrigger) download =
      (_, _, _) async => Uint8List.fromList([0, 1, 2]);
  Future<String> Function(String conversationId, String day, List<int> bytes, String? replaces) put =
      (_, _, _, _) async => uuidv4();

  @override
  Future<List<duvet.BackupSegment>> segments({String? conversationId, String? after, String? identity}) {
    _log.add('segments');
    return listing(after);
  }

  @override
  Future<List<String>> deletedMessages(String conversationId, {String? after, int? limit}) {
    _log.add('deletedMessages');
    return deleted(conversationId, after);
  }

  @override
  Future<Uint8List> segment(
    String segmentId, {
    void Function(int received, int total)? onProgress,
    Future<void>? abortTrigger,
  }) {
    _log.add('segment');
    return download(segmentId, onProgress, abortTrigger);
  }

  @override
  Future<String> putSegment(
    String conversationId,
    String day,
    List<int> segment, {
    String? replaces,
    void Function(int sent, int total)? onProgress,
    Future<void>? abortTrigger,
  }) {
    _log.add('putSegment');
    return put(conversationId, day, segment, replaces);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A record in memory that tells each write, in order.
class _Writes extends MemoryStore {
  final written = <(String, Object?)>[];

  @override
  Future<void> write(String key, Object? value) {
    written.add((key, value));
    return super.write(key, value);
  }
}

typedef _Stub = ({Backups backups, TestClock clock, MemoryStore store, List<String> log});

/// The backup on a stub core and API, on a clock of the test's. The log tells, in order, each core command, request
/// and look at the inbox it made; [ready] says whether the device backs up.
_Stub _onAStub({
  Map<String, Object? Function(Map<String, Object?> command)> core = const {},
  void Function(_StubApi api)? api,
  bool Function()? ready,
  MemoryStore? store,
}) {
  final clock = TestClock();
  final record = store ?? MemoryStore();
  final log = <String>[];
  final host = _StubCore(log, {
    'backup_due': (_) => {'segments': <Object?>[]},
    'backup_segment': (_) => _built,
    'backup_uploaded': (_) => <String, Object?>{},
    'backup_import': (_) => {'imported': 1},
    'backup_reencrypt': (_) => {'data': 'AAEC', 'key_id': 'current'},
    ...core,
  });
  final routes = _StubApi(log);
  api?.call(routes);
  final backups = Backups(
    host: host,
    api: routes,
    store: record,
    clock: clock,
    failures: Failures(routes, clock),
    turn: (work) =>
        (ready ?? () => true)() ? work() : Future.error(CoreError('not_ready', message: "this device doesn't back up")),
    inbox: () async => log.add('inbox'),
    changed: (_) {},
    update: (_) {},
  );
  addTearDown(backups.stop);
  return (backups: backups, clock: clock, store: record, log: log);
}

/// Runs what's due as the clock moves on, then what that started, settled.
Future<void> _moveOn(_Stub stub, Duration by) async {
  stub.clock.advance(by);
  await stub.backups.settled();
}
