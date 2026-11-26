import 'dart:convert';
import 'dart:io';
import 'dart:ui' show IsolateNameServer;

import 'package:duvet/data/cache.dart';
import 'package:duvet/e2e/contacts.dart';
import 'package:duvet/e2e/core_gate.dart';
import 'package:duvet/e2e/deviceless.dart' show CatchUps, makeCatchUp;
import 'package:duvet/e2e/engine.dart';
import 'package:duvet/e2e/identity.dart' show observeOn;
import 'package:duvet/e2e/store.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:duvet/push/background.dart';
import 'package:duvet/push/push_message.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/core_lib.dart';
import '../support/engines.dart';
import '../support/fake_api.dart';

// Contacts (PLAN-E2E-CLIENTES.md, Task 29; decision 25): the security number two people compare, the mark of one the
// person verified, scanning the other's code, and a changed key's notice in their conversations, which a verified
// contact's makes wait for the person's yes before anything more goes there. The core decides each of them; what it
// refuses changes nothing. The desktop's contacts.test.ts, case for case, and Android's scan and background engines.
const _slow = Timeout(Duration(minutes: 3));
final _digits = matches(RegExp(r'^(\d{5} ){11}\d{5}$'));

typedef _Pair = ({FakeApi fake, String ana, String bo, String dm, TestDevice a, TestDevice b});

/// Ana and Bo, friends with a DM, each with a first device set up: no group yet. Ana's on [aHost], her record [store],
/// her requests seen by [seen] (or changed by [client]), and hearing what [hears] lets through.
Future<_Pair> _anaAndBo({
  List<http.Request>? seen,
  http.Client Function(FakeApi fake)? client,
  EngineStore? store,
  TestHost? aHost,
  bool Function(GatewayEvent event)? hears,
}) async {
  final fake = FakeApi();
  final (ana, bo) = (fake.addUser(), fake.addUser());
  fake.befriend(ana, bo);
  final dm = fake.addConversation(group: false, members: [ana, bo]);
  final a = await firstDevice(
    fake,
    ana,
    host: aHost?.gate,
    store: store,
    client: client?.call(fake) ?? (seen == null ? null : watchedClient(fake, seen: seen.add)),
    hears: hears,
  );
  final b = await firstDevice(fake, bo);
  return (fake: fake, ana: ana, bo: bo, dm: dm, a: a, b: b);
}

/// The device's user changes their keys (Settings → Devices), the new recovery key saved: its upload tells the others.
Future<void> _newKeys(TestDevice device) async {
  await device.engine.changeKeys();
  await device.engine.keySaved();
  expect(device.state, EngineState.ready);
}

/// What the device shows of its contacts now.
ContactsShown _shown(TestDevice device) => device.engine.contacts.value;

/// The ID of the change of [user]'s key the device shows, which a close or a yes names.
String _changeOf(TestDevice device, String user) => _shown(device).changes[user]?.change ?? '';

/// Waits for the device to note [user]'s changed key: what the gateway's IDENTITY_UPDATE has it observe.
Future<void> _changeNoted(TestDevice device, String user) =>
    until(() => _shown(device).changes[user] != null, what: "the contact's changed key noted");

/// Both devices in the DM's group.
Future<void> _inGroup(TestDevice a, TestDevice b, String dm) async {
  await a.engine.openConversation(dm);
  await b.engine.openConversation(dm);
  await sameGroup([a, b], dm);
}

/// Ana's and Bo's devices in their DM's group, Bo verified by Ana; then Bo's new keys, a strong change on Ana's.
Future<void> _verifiedWithNewKeys(TestDevice a, TestDevice b, String dm) async {
  await _inGroup(a, b, dm);
  final number = await a.engine.safetyNumber(b.user);
  expect(await a.engine.verifyContact(b.user, number.digits), isTrue);
  await _newKeys(b);
  await _changeNoted(a, b.user);
  expect(_shown(a).changes[b.user]?.verified, isTrue);
}

/// What a send was refused with: the hold's `key_changed`, say.
Future<CoreError> _refusal(Future<Object?> sending) async {
  try {
    await sending;
  } on CoreError catch (error) {
    return error;
  }
  fail('it went');
}

/// A send the hold refused, for these users.
void _expectHeld(CoreError error, List<String> users) {
  expect(error.code, 'key_changed');
  expect(error.users, users);
}

/// The posts of messages to the conversation that reached the API.
int _posts(List<http.Request> seen, String dm) =>
    seen.where((r) => r.method == 'POST' && r.url.path == '/api/users/@me/conversations/$dm/messages').length;

Outgoing _message(String dm, [String text = 'hi']) => Outgoing(conversationId: dm, nonce: uuidv4(), text: text);

/// A signed object's base64 with one byte of its signature changed.
String _flipped(String signed) {
  final bytes = base64Decode(signed);
  bytes[bytes.length - 1] ^= 0x01;
  return base64Encode(bytes);
}

/// An observe_user answer, as the core gives one.
Map<String, Object?> _seen(String state, {required bool verified, bool? wasVerified, String? reason}) => {
  'state': state,
  'verified': verified,
  'was_verified': ?wasVerified,
  'reason': ?reason,
};

/// A change as its fields are, its ID aside.
(bool, bool, bool)? _kind(KeyChange? change) =>
    change == null ? null : (change.verified, change.closed, change.confirmed);

void main() {
  setUpAll(() async {
    if (coreLibrary != null) await loadCore();
  });

  group("the notices of a contact's changed key", () {
    test("a_changed_key's_notice_shows_in_every_conversation_with_that_person,_until_it's_closed", () {
      const changes = {
        'bo': KeyChange(verified: false, change: 'c1'),
        'cy': KeyChange(verified: true, closed: true, change: 'c2'),
      };
      // Their DM, a group with them, and a group without them.
      expect(changedIn(changes, ['ana', 'bo']), ['bo']);
      expect(changedIn(changes, ['ana', 'bo', 'cy', 'dee']), ['bo']);
      expect(changedIn(changes, ['ana', 'dee']), isEmpty);
    });

    test("what_waits_for_the_person's_yes_is_a_verified_contact's_change_they_haven't_said_yes_to", () {
      const changes = {
        'bo': KeyChange(verified: true, change: 'c1'),
        'cy': KeyChange(verified: true, closed: true, change: 'c2'),
        'dee': KeyChange(verified: true, confirmed: true, change: 'c3'),
        'eve': KeyChange(verified: false, change: 'c4'),
      };
      expect(waitingForYes(changes, ['ana', 'bo', 'cy', 'dee', 'eve']), ['bo', 'cy']);
      expect(waitingForYes(changes, ['ana', 'eve']), isEmpty);
    });

    test('a_second_change_before_the_person_was_done_with_the_first_keeps_its_strong_notice,_open_again', () {
      final contacts = Contacts(MemoryStore(), 'ana');
      contacts.observed('bo', _seen('new', verified: false));
      contacts.observed('bo', _seen('changed', verified: false, wasVerified: true));
      contacts.close('bo', contacts.shown.value.changes['bo']!.change);
      // The core unmarked them with the first change: the second's was_verified is false.
      contacts.observed('bo', _seen('changed', verified: false, wasVerified: false));
      final second = contacts.shown.value.changes['bo'];
      expect(_kind(second), (true, false, false));
      // Once said yes to, a later change of a contact no longer verified is a plain one.
      contacts.confirm([(user: 'bo', change: second!.change)]);
      contacts.observed('bo', _seen('changed', verified: false, wasVerified: false));
      expect(_kind(contacts.shown.value.changes['bo']), (false, false, false));
    });

    // Review 28's Minor 6: a yes or a close the person gave a change is that change's, not one that came while they
    // looked.
    test('a_yes,_and_a_close,_are_for_the_change_the_person_was_shown,_not_one_that_came_since', () {
      final contacts = Contacts(MemoryStore(), 'ana');
      contacts.observed('bo', _seen('changed', verified: false, wasVerified: true));
      final shown = contacts.shown.value.changes['bo']!;
      contacts.observed('bo', _seen('changed', verified: false, wasVerified: false));
      final now = contacts.shown.value.changes['bo']!;
      expect(now.change, isNot(shown.change));
      contacts.confirm([(user: 'bo', change: shown.change)]);
      contacts.close('bo', shown.change);
      expect(contacts.shown.value.changes['bo'], now);
      expect(contacts.holding(['bo']), ['bo']);
      contacts.confirm([(user: 'bo', change: now.change)]);
      contacts.close('bo', now.change);
      expect(contacts.shown.value.changes, isEmpty);
    });

    // Review 28's Minor 4: a refused list is no change, but the core's refusal still says whether the identity it holds
    // is verified, so a contact's mark shows after a start before any observation the core takes.
    test('a_refused_observation_says_no_change,_and_keeps_the_mark_of_the_identity_the_core_holds', () {
      var told = 0;
      final contacts = Contacts(MemoryStore(), 'ana');
      contacts.shown.addListener(() => told++);
      contacts.observed('bo', _seen('rejected', verified: true, reason: 'wrong_user'));
      expect(contacts.shown.value.changes, isEmpty);
      expect(contacts.shown.value.verified, {'bo': true});
      expect(told, 1);
      // The user's own observations are no contact's.
      contacts.observed('ana', _seen('same', verified: true));
      expect(contacts.shown.value.verified, {'bo': true});
    });

    // Review 28's Minor 5: the core says `changed` once. Whom the person verified is kept at the tap, so a change the
    // record never took is one the next start finds: the core holds that contact unverified, and nothing was noted.
    test('a_verified_contact_the_core_holds_unverified,_with_no_change_kept,_is_a_strong_change', () {
      final store = MemoryStore();
      Contacts(store, 'ana').verifiedNow('bo', true);
      expect(store.read(verifiedContacts), ['bo']);
      final again = Contacts(store, 'ana');
      again.observed('bo', _seen('same', verified: false));
      expect(again.shown.value.changes['bo']?.verified, isTrue);
      expect(again.holding(['bo']), ['bo']);
      // Kept as verified until the person is done with the change: a record that refuses it finds it at each start.
      expect(store.read(verifiedContacts), ['bo']);
      final change = again.shown.value.changes['bo']!.change;
      again.confirm([(user: 'bo', change: change)]);
      again.close('bo', change);
      expect(store.read(verifiedContacts), isNull);
      again.observed('bo', _seen('same', verified: false));
      expect(again.shown.value.changes, isEmpty);
    });

    // Review 28's Minor 5: what the record kept is read back at a start, each change with its ID, closed or said yes to
    // as it was.
    test('the_changes_the_record_kept_are_there_again_at_a_start,_each_as_it_was', () {
      final store = MemoryStore();
      final contacts = Contacts(store, 'ana');
      contacts.observed('bo', _seen('changed', verified: false, wasVerified: false));
      contacts.observed('cy', _seen('changed', verified: false, wasVerified: true));
      contacts.confirm([(user: 'cy', change: contacts.shown.value.changes['cy']!.change)]);
      final again = Contacts(store, 'ana');
      expect(again.shown.value.changes, contacts.shown.value.changes);
      final cy = again.shown.value.changes['cy']!;
      expect(_kind(cy), (true, false, true));
      expect(again.holding(['bo', 'cy']), isEmpty);
      // The record names users and words alone: user IDs, booleans and the changes' own IDs.
      final record = jsonDecode(store.kept[keyChanges]!) as Map<String, Object?>;
      expect(record.keys, unorderedEquals(['bo', 'cy']));
      expect(record['cy'], {'verified': true, 'confirmed': true, 'change': cy.change});
    });

    test('a_device_that_starts_again_with_nothing_starts_without_them', () {
      expect(deviceRecord, containsAll([keyChanges, verifiedContacts]));
      final store = MemoryStore();
      final contacts = Contacts(store, 'ana')
        ..verifiedNow('bo', true)
        ..observed('cy', _seen('changed', verified: false, wasVerified: false));
      contacts.forget();
      expect(contacts.shown.value.changes, isEmpty);
      expect(contacts.shown.value.verified, isEmpty);
      expect(store.kept.keys, isNot(anyOf(contains(keyChanges), contains(verifiedContacts))));
    });

    // Rule 2 of review 28's list for this task: another engine of this phone (a push's) noted a change in the record
    // while this one didn't hold the core. Once it holds it, the change is there.
    test("what_another_engine_wrote_to_the_record_is_taken_once_the_core_is_this_engine's", () async {
      final store = MemoryStore();
      final app = Contacts(store, 'ana');
      final push = Contacts(store, 'ana');
      push.observed('bo', _seen('changed', verified: false, wasVerified: true));
      expect(app.shown.value.changes, isEmpty);
      await app.reload();
      expect(app.shown.value.changes, push.shown.value.changes);
      expect(app.holding(['bo']), ['bo']);
    });
  });

  group('contacts', () {
    test(
      'both_sides_see_the_same_60_digits',
      () async {
        final (fake: _, :ana, :bo, dm: _, :a, :b) = await _anaAndBo();
        final ours = await a.engine.safetyNumber(bo);
        expect(ours.digits, _digits);
        expect(ours.qr, isNotEmpty);
        // The same number, and the same code, whichever of the two looks.
        expect(await b.engine.safetyNumber(ana), ours);
        // Looking marks no one.
        expect(_shown(a).verified[bo], isNot(isTrue));
        // New keys make a new number, the same again on both sides.
        await _newKeys(b);
        final now = await a.engine.safetyNumber(bo);
        expect(now.digits, _digits);
        expect(now.digits, isNot(ours.digits));
        expect(await b.engine.safetyNumber(ana), now);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_verified_contact_wears_its_mark',
      () async {
        final (:fake, :ana, :bo, dm: _, :a, :b) = await _anaAndBo();
        expect(await a.engine.contact(bo), isFalse);
        final number = await a.engine.safetyNumber(bo);
        expect(await a.engine.verifyContact(bo, number.digits), isTrue);
        expect(_shown(a).verified[bo], isTrue);
        expect(await a.engine.contact(bo), isTrue);
        // Only on the person's own act: Bo's device doesn't mark Ana, however often it looks at her.
        expect((await b.engine.safetyNumber(ana)).digits, number.digits);
        expect(await b.engine.contact(ana), isFalse);
        expect(_shown(b).verified[ana], isFalse);
        // The mark is the core's: the app started again shows it once it looks at Bo.
        final again = await restarted(fake, a);
        expect(await again.engine.contact(bo), isTrue);
        expect(_shown(again).verified[bo], isTrue);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'mark_as_verified_marks_the_number_the_person_compared,_never_one_that_changed_meanwhile',
      () async {
        final (fake: _, ana: _, :bo, dm: _, :a, :b) = await _anaAndBo();
        final number = await a.engine.safetyNumber(bo);
        await _newKeys(b);
        await _changeNoted(a, bo);
        expect(await a.engine.verifyContact(bo, number.digits), isFalse);
        expect(await a.engine.contact(bo), isFalse);
        // The new number, compared, verifies them: their change is done with.
        final now = await a.engine.safetyNumber(bo);
        expect(now.digits, isNot(number.digits));
        expect(await a.engine.verifyContact(bo, now.digits), isTrue);
        expect(_shown(a).changes, isEmpty);
        expect(_shown(a).verified[bo], isTrue);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_changed_key_shows_its_notice_once_for_each_change',
      () async {
        final (fake: _, ana: _, :bo, :dm, :a, :b) = await _anaAndBo();
        expect(await a.engine.contact(bo), isFalse);
        var told = 0;
        a.engine.contacts.addListener(() => told++);
        // Bo's new keys: the gateway's IDENTITY_UPDATE has Ana's device look at him again.
        await _newKeys(b);
        await _changeNoted(a, bo);
        final first = _shown(a).changes[bo]!;
        expect(_kind(first), (false, false, false));
        final once = told;
        expect(once, greaterThan(0));
        // Seen again, the same key is no new change: no second notice.
        expect(await a.engine.contact(bo), isFalse);
        await a.engine.openConversation(dm);
        await a.engine.safetyNumber(bo);
        expect(_shown(a).changes, {bo: first});
        expect(told, once);
        // Kept until it's closed, whatever restarts.
        expect(a.store.read(keyChanges), {
          bo: {'verified': false, 'change': first.change},
        });
        // Closed, it's gone, and the same key never brings it back.
        await a.engine.closeKeyChange(bo, first.change);
        expect(_shown(a).changes, isEmpty);
        expect(a.store.read(keyChanges), isNull);
        await a.engine.contact(bo);
        expect(_shown(a).changes, isEmpty);
        // Another change, its own notice.
        await _newKeys(b);
        await _changeNoted(a, bo);
        expect(_shown(a).changes[bo]?.change, isNot(first.change));
        // The record names users alone, never a key.
        final identity = await a.api.identity(bo);
        expect(jsonEncode((a.store as MemoryStore).kept), isNot(contains(identity.identityKey)));
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      "a_conversation_opened_shows_its_members'_changed_keys,_an_event_missed_or_not",
      () async {
        // Ana's device hears no IDENTITY_UPDATE: as one away while Bo's keys changed, past what the gateway keeps.
        final (fake: _, ana: _, :bo, :dm, :a, :b) = await _anaAndBo(hears: (event) => event.type != 'IDENTITY_UPDATE');
        expect(await a.engine.contact(bo), isFalse);
        await _newKeys(b);
        await turnEnded(a);
        expect(_shown(a).changes, isEmpty);
        await a.engine.openConversation(dm);
        expect(_kind(_shown(a).changes[bo]), (false, false, false));
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      "a_verified_contact's_changed_key_asks_before_the_next_message_goes",
      () async {
        final seen = <http.Request>[];
        final (fake: _, :ana, :bo, :dm, :a, :b) = await _anaAndBo(seen: seen);
        await _verifiedWithNewKeys(a, b, dm);
        expect(waitingForYes(_shown(a).changes, [ana, bo]), [bo]);
        expect(_shown(a).verified[bo], isFalse);

        // The next message waits for the person's yes: nothing goes to the API, and it waits on this device.
        final posted = _posts(seen, dm);
        final message = _message(dm, 'are you still you?');
        final held = await _refusal(a.engine.sendMessage(message));
        _expectHeld(held, [bo]);
        expect(_posts(seen, dm), posted);
        expect([for (final pending in await a.engine.pendingMessages(dm)) pending.nonce], [message.nonce]);
        // Closing the notice isn't the yes: a Retry waits still.
        await a.engine.closeKeyChange(bo, _changeOf(a, bo));
        expect(_kind(_shown(a).changes[bo]), (true, true, false));
        final again = await _refusal(a.engine.resendMessage(dm, message.nonce));
        _expectHeld(again, [bo]);
        expect(_posts(seen, dm), posted);

        // The person's yes: what waited goes on its own, and Bo reads it; the change is done with.
        duvet.DirectMessage? went;
        a.engine.sent.listen((sent) {
          if (sent.nonce == message.nonce) went = sent.message;
        });
        await a.engine.confirmKeyChanges([(user: bo, change: _changeOf(a, bo))]);
        expect(_shown(a).changes, isEmpty);
        await until(() => went != null, what: 'the message that waited sent');
        expect(_posts(seen, dm), posted + 1);
        await until(
          () async => (await b.engine.messages(dm, [went!.id])).firstOrNull?.text == 'are you still you?',
          what: 'Bo reads it',
        );
        // What the person sends after their yes goes as ever.
        expect(await a.engine.sendMessage(_message(dm, 'ok')), isNotNull);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_rejected_list_changes_nothing_and_says_nothing',
      () async {
        final fake = FakeApi();
        final (ana, bo, cy) = (fake.addUser(), fake.addUser(), fake.addUser());
        fake.befriend(ana, bo);
        fake.befriend(ana, cy);
        // What the API serves of Bo, as the test forges it: as it is, until a test says otherwise. Every identity
        // served is kept as it came, so Cy's is at hand to forge from.
        final served = <String, Map<String, Object?>>{};
        Map<String, Object?> Function(Map<String, Object?> identity) forge = (identity) => identity;
        final client = watchedClient(
          fake,
          change: (request, answered) async {
            if (request.url.path != '/api/users/identities' || answered.statusCode != 200) return answered;
            final listed = (jsonDecode(answered.body) as List).cast<Map<String, Object?>>();
            for (final identity in listed) {
              served[identity['user_id']! as String] = identity;
            }
            return http.Response(
              jsonEncode([for (final identity in listed) identity['user_id'] == bo ? forge(identity) : identity]),
              200,
              headers: answered.headers,
            );
          },
        );
        final a = await firstDevice(fake, ana, client: client);
        await firstDevice(fake, bo);
        await firstDevice(fake, cy);
        final number = await a.engine.safetyNumber(bo);
        expect(await a.engine.verifyContact(bo, number.digits), isTrue);
        await a.api.identities([cy]);
        final cys = served[cy]!;
        var told = 0;
        a.engine.contacts.addListener(() => told++);

        // Another user's list served under Bo's name: the core refuses it.
        Map<String, Object?> theirs(Map<String, Object?> identity) => {...cys, 'user_id': identity['user_id']};
        forge = theirs;
        expect(await a.engine.contact(bo), isTrue);
        // A list its identity didn't sign: the core refuses that too.
        forge = (identity) => {...identity, 'device_list': _flipped(identity['device_list']! as String)};
        expect(await a.engine.contact(bo), isTrue);
        // The number is still the one of the identity this device holds of Bo: the one the person compared.
        expect((await a.engine.safetyNumber(bo)).digits, number.digits);
        // Nothing changed and nothing was said: the mark stays, and no notice.
        expect(_shown(a).changes, isEmpty);
        expect(_shown(a).verified[bo], isTrue);
        expect(a.store.read(keyChanges), isNull);
        expect(told, 0);
        // Review 28's Minor 4: started again, before any list the core takes, a refused one keeps Bo's mark on show.
        forge = theirs;
        final again = await restarted(fake, a, client: client);
        expect(await again.engine.contact(bo), isTrue);
        expect(_shown(again).changes, isEmpty);
        expect(_shown(again).verified[bo], isTrue);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'nothing_the_server_says_alone_marks_or_unmarks_anyone',
      () async {
        final (:fake, :ana, :bo, :dm, :a, :b) = await _anaAndBo();
        await _inGroup(a, b, dm);
        final number = await a.engine.safetyNumber(bo);
        expect(await a.engine.verifyContact(bo, number.digits), isTrue);
        // A new device of Bo's, on his list: IDENTITY_UPDATE again, the same identity, still verified, no notice.
        int heard() => a.heard.where((event) => event.type == 'IDENTITY_UPDATE').length;
        final before = heard();
        await approvedDevice(fake, b);
        await until(() => heard() > before, what: "the new device's IDENTITY_UPDATE");
        await a.engine.openConversation(dm);
        expect(await a.engine.contact(bo), isTrue);
        expect(_shown(a).changes, isEmpty);
        expect(_shown(a).verified[bo], isTrue);
        // However often it's seen, the server's answer marks no one the person didn't verify.
        for (var n = 0; n < 3; n++) {
          expect(await b.engine.contact(ana), isFalse);
        }
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 28's Important 1: what goes to a conversation reaches whom its group holds, whatever the API lists. A
    // server that lists the group without Bo while his new key's leaf is in it takes away neither the hold nor his
    // notice.
    test(
      "a_verified_contact's_changed_key_holds_what_goes_to_their_group,_though_the_API_lists_it_without_them",
      () async {
        final seen = <http.Request>[];
        final (:fake, ana: _, :bo, :dm, :a, :b) = await _anaAndBo(seen: seen);
        await _verifiedWithNewKeys(a, b, dm);
        fake.dropMembers(dm, [bo]);
        final again = await restarted(fake, a, client: watchedClient(fake, seen: seen.add));
        final changes = await again.engine.keyChangesIn(dm);
        expect(changes.keys, [bo]);
        expect(changes[bo]?.verified, isTrue);
        final posted = _posts(seen, dm);
        final held = await _refusal(again.engine.sendMessage(_message(dm, 'still you?')));
        _expectHeld(held, [bo]);
        expect(_posts(seen, dm), posted);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 28's Important 2: an edit is the message's new text: it waits for the yes as a message does.
    test(
      "an_edit_after_a_verified_contact's_changed_key_sends_nothing_until_the_yes",
      () async {
        final seen = <http.Request>[];
        final (fake: _, ana: _, :bo, :dm, :a, :b) = await _anaAndBo(seen: seen);
        await _inGroup(a, b, dm);
        final sent = (await a.engine.sendMessage(_message(dm, 'first')))!;
        final number = await a.engine.safetyNumber(bo);
        await a.engine.verifyContact(bo, number.digits);
        await _newKeys(b);
        await _changeNoted(a, bo);
        final path = '/api/users/@me/conversations/$dm/messages/${sent.id}';
        int edits() => seen.where((r) => r.method == 'PATCH' && r.url.path == path).length;
        await a.engine.editMessage(dm, sent.id, 'edited');
        await turnEnded(a);
        // Its backoff's tries find the hold still there.
        a.clock.advance(const Duration(minutes: 2));
        await turnEnded(a);
        expect(edits(), 0);
        await a.engine.confirmKeyChanges([(user: bo, change: _changeOf(a, bo))]);
        await until(() => edits() == 1, what: 'the edit sent after the yes');
        await until(
          () async => (await b.engine.messages(dm, [sent.id])).firstOrNull?.text == 'edited',
          what: 'Bo reads the edit',
        );
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      "an_edit_made_again_on_a_409,_whose_queue_brought_a_verified_contact's_changed_key,_waits_for_the_yes",
      () async {
        final seen = <http.Request>[];
        // Ana's device hears neither Bo's IDENTITY_UPDATE nor his commit: only the 409's read of the queue brings them.
        var deaf = false;
        final (:fake, ana: _, :bo, :dm, :a, :b) = await _anaAndBo(
          seen: seen,
          hears: (event) => !(deaf && (event.type == 'IDENTITY_UPDATE' || event.type == 'MLS_COMMIT')),
        );
        await _inGroup(a, b, dm);
        final sent = (await a.engine.sendMessage(_message(dm, 'first')))!;
        final number = await a.engine.safetyNumber(bo);
        await a.engine.verifyContact(bo, number.digits);
        deaf = true;
        await _newKeys(b);
        // His device renews its leaf under his new keys: a commit in the queue Ana's device hasn't read.
        await stoppedByHand(b);
        await commitByHand(b, dm);
        expect(_shown(a).changes, isEmpty);
        final path = '/api/users/@me/conversations/$dm/messages/${sent.id}';
        fake.refuse((method: 'PATCH', path: path), 409, body: {'error': 'stale message', 'generation': 0, 'epoch': 1});
        int edits() => seen.where((r) => r.method == 'PATCH' && r.url.path == path).length;
        await a.engine.editMessage(dm, sent.id, 'edited');
        await turnEnded(a);
        // The 409's queue brought the change: the edit made again waits for the yes.
        expect(edits(), 1);
        expect(_shown(a).changes[bo]?.verified, isTrue);
        deaf = false;
        await a.engine.confirmKeyChanges([(user: bo, change: _changeOf(a, bo))]);
        await until(() => edits() == 2, what: 'the edit made again sent after the yes');
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 28's Important 3: a catch-up hands a member what was sent while they had no device; for a verified contact
    // whose key changed, it waits for the yes too, and goes once it's given.
    test(
      'a_catch-up_for_a_verified_contact_whose_key_changed_waits_for_the_yes',
      () async {
        final seen = <http.Request>[];
        final (:fake, ana: _, :bo, :dm, :a, :b) = await _anaAndBo(seen: seen);
        final share = RegExp(r'/history-shares/[0-9a-f-]+$');
        int shares() => seen.where((r) => r.method == 'PUT' && share.hasMatch(r.url.path)).length;
        await _inGroup(a, b, dm);
        final sent = (await a.engine.sendMessage(_message(dm, 'first')))!;
        final number = await a.engine.safetyNumber(bo);
        await a.engine.verifyContact(bo, number.digits);
        // Bo's devices aren't seen for 45 days: what Ana's sends now is noted for him.
        fake.setActive(bo, false);
        await a.engine.openConversation(dm);
        await until(
          () => a.engine.conversationState(dm) == ConversationState.noDevice([bo]),
          what: 'Bo without a device',
        );
        await _newKeys(b);
        await _changeNoted(a, bo);
        // Her edit of a message he read is noted for his new keys, which a catch-up would carry it to.
        await a.engine.editMessage(dm, sent.id, 'edited');
        // He's seen again, and his device writes: the apply of it names him due a catch-up, which waits.
        fake.setActive(bo, true);
        await a.engine.openConversation(dm);
        final back = (await b.engine.sendMessage(_message(dm, 'back')))!;
        await until(
          () async => (await a.engine.messages(dm, [back.id])).firstOrNull?.text == 'back',
          what: "Bo's message on Ana's device",
        );
        await turnEnded(a);
        expect(shares(), 0);
        await a.engine.confirmKeyChanges([(user: bo, change: _changeOf(a, bo))]);
        await until(() => shares() > 0, what: 'the catch-up sent after the yes');
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 28's I3, the hold itself: while a verified contact's change waits for the yes, their catch-up is made
    // for no one, and waits held, with no try counted and nothing retried by time, until the yes asks for it again.
    test(
      "a_held_contact's_catch-up_is_made_for_no_one_and_waits_for_the_yes",
      () async {
        final (fake: _, ana: _, :bo, :dm, :a, :b) = await _anaAndBo();
        await _verifiedWithNewKeys(a, b, dm);
        await expectLater(
          makeCatchUp(a.engine, dm, bo),
          throwsA(isA<CoreError>().having((error) => error.code, 'code', 'key_changed')),
        );
        final turns = <Future<void> Function()>[];
        final catchUps = CatchUps(a.engine, turns.add)..due(dm, [bo]);
        await turns.removeAt(0)();
        a.clock.advance(const Duration(hours: 2));
        expect(turns, isEmpty);
        catchUps.again();
        expect(turns, hasLength(1));
        await a.engine.confirmKeyChanges([(user: bo, change: _changeOf(a, bo))]);
        await expectLater(makeCatchUp(a.engine, dm, bo), completes);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 29's Important 1: a catch-up whose own identity round brings a verified contact's changed key. The server
    // answers their new identity's certificates, then their old identity to the catch-up's look, then the new one to
    // the look the core asks for: the change is noted mid-make, and the package sealed under it sends nothing past its
    // PUT before the person's yes, which sends the rest. What Ana noted while Bo had no identity goes to any of his.
    test(
      "a_catch-up_whose_own_identity_round_brings_a_verified_contact's_changed_key_waits_for_the_yes",
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        final seen = <http.Request>[];
        final asked = <Map<String, Object?>>[];
        TestDevice? b;
        // From [deaf] on, Ana's device hears neither Bo's new keys nor his commits, and the server lies once.
        var deaf = false;
        var lied = false;
        var lie = false;
        http.Response? old;
        bool onlyBo(http.Request r) =>
            r.method == 'GET' && r.url.path == '/api/users/identities' && r.url.queryParameters['ids'] == bo;
        final a = await firstDevice(
          fake,
          ana,
          host: WatchedHost(TestHost().gate, [], commands: asked),
          client: watchedClient(
            fake,
            seen: seen.add,
            answer: (request) async {
              if (deaf && !lied && request.method == 'GET' && request.url.path == '/api/users/$bo/identity') {
                // The catch-up's first look: Bo has new keys by its answer, which the API passes on.
                lied = true;
                await _newKeys(b!);
                lie = true;
              } else if (lie && onlyBo(request)) {
                lie = false;
                return old;
              }
              return null;
            },
            change: (request, answered) async {
              if (!deaf && onlyBo(request)) old = answered;
              return answered;
            },
          ),
          hears: (event) => !(deaf && (event.type == 'IDENTITY_UPDATE' || event.type == 'MLS_COMMIT')),
        );
        final pastPut = RegExp(r'/history-shares/[0-9a-f-]+/(parts/\d+|complete)$|/api/devices/[0-9a-f-]+/inbox$');
        int past() => seen.where((r) => r.method != 'GET' && pastPut.hasMatch(r.url.path)).length;
        final put = RegExp(r'/history-shares/[0-9a-f-]+$');
        int puts() => seen.where((r) => r.method == 'PUT' && put.hasMatch(r.url.path)).length;
        final dm = (await a.engine.createDM(bo)).id;
        await a.engine.openConversation(dm);
        await until(() => a.engine.conversationState(dm) == ConversationState.noDevice([bo]), what: 'Bo without one');
        await a.engine.sendMessage(_message(dm, 'hi Bo'));
        // His first catch-up waits for the API's day (one a day for each member), its notes kept.
        fake.refuse((method: 'PUT', path: put), 429);
        b = await firstDevice(fake, bo);
        await until(() => puts() == 1, what: 'the first catch-up refused');
        await turnEnded(a);
        final number = await a.engine.safetyNumber(bo);
        expect(await a.engine.verifyContact(bo, number.digits), isTrue);
        expect(old, isNotNull);

        deaf = true;
        final before = past();
        a.clock.advance(const Duration(days: 1));
        await until(() => puts() == 2, what: "the second catch-up's PUT");
        await turnEnded(a);
        a.clock.advance(const Duration(hours: 1));
        await turnEnded(a);
        expect(lied, isTrue);
        expect(_shown(a).changes[bo]?.verified, isTrue);
        expect(past(), before);
        await a.engine.confirmKeyChanges([(user: bo, change: _changeOf(a, bo))]);
        await until(
          () => asked.any((c) => c['cmd'] == 'catch_up_delivered' && c['user_id'] == bo),
          what: 'the catch-up delivered after the yes',
        );
        expect(puts(), 2);
        await a.engine.stop();
        await b.engine.stop();
      },
      skip: noCore,
      timeout: _slow,
    );

    // Rule 3 with task 31's shares: a share of the conversation's history to a member whose verified key changed sends
    // no part, key or completion before the person's yes, which sends the rest.
    test(
      'a_share_to_a_verified_contact_whose_key_changed_waits_for_the_yes',
      () async {
        final seen = <http.Request>[];
        final (fake: _, ana: _, :bo, :dm, :a, :b) = await _anaAndBo(seen: seen);
        final pastPut = RegExp(r'/history-shares/[0-9a-f-]+/(parts/\d+|complete)$|/api/devices/[0-9a-f-]+/inbox$');
        int sent() => seen.where((r) => r.method != 'GET' && pastPut.hasMatch(r.url.path)).length;
        await _inGroup(a, b, dm);
        await a.engine.sendMessage(_message(dm, 'before'));
        final number = await a.engine.safetyNumber(bo);
        await a.engine.verifyContact(bo, number.digits);
        await _newKeys(b);
        await _changeNoted(a, bo);
        final before = sent();
        await a.engine.shareHistory(dm, bo, 'all');
        await turnEnded(a);
        a.clock.advance(const Duration(hours: 1));
        await turnEnded(a);
        expect(sent(), before);
        await a.engine.confirmKeyChanges([(user: bo, change: _changeOf(a, bo))]);
        await until(
          () => seen.any((r) => r.method != 'GET' && r.url.path.endsWith('/complete')),
          what: 'the share completed after the yes',
        );
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 28's Minor 5: a change and its hold outlast a restart; one the record never took is found again at each
    // start, as the person had verified the contact.
    test(
      "a_verified_contact's_changed_key_and_its_hold_outlast_a_restart,_even_one_the_record_didn't_take",
      () async {
        // Ana's storage refuses the changes' record, as a full one does: the change is noted for this run alone.
        final (:fake, ana: _, :bo, :dm, :a, :b) = await _anaAndBo(store: KeyRefusingStore(keyChanges));
        await _verifiedWithNewKeys(a, b, dm);
        expect(a.store.read(keyChanges), isNull);
        final again = await restarted(fake, a);
        expect(_shown(again).changes[bo]?.verified, isTrue);
        final held = await _refusal(again.engine.sendMessage(_message(dm)));
        _expectHeld(held, [bo]);
        // And after another restart: found again each time, until the person's yes.
        final third = await restarted(fake, again);
        expect(_shown(third).changes[bo]?.verified, isTrue);
        expect((await _refusal(third.engine.sendMessage(_message(dm)))).code, 'key_changed');
      },
      skip: noCore,
      timeout: _slow,
    );

    // One the record took is there after a restart as it was, its ID with it, and holds.
    test(
      "a_verified_contact's_changed_key_the_record_took_is_there_after_a_restart,_and_holds",
      () async {
        final (:fake, ana: _, :bo, :dm, :a, :b) = await _anaAndBo();
        await _verifiedWithNewKeys(a, b, dm);
        final change = _changeOf(a, bo);
        final again = await restarted(fake, a);
        expect(_shown(again).changes[bo], KeyChange(verified: true, change: change));
        final held = await _refusal(again.engine.sendMessage(_message(dm)));
        _expectHeld(held, [bo]);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 28's Minor 7: verifying the new number is a yes too: what waited goes.
    test(
      "verifying_a_contact's_new_number_sends_what_waited_for_the_yes",
      () async {
        final (fake: _, ana: _, :bo, :dm, :a, :b) = await _anaAndBo();
        await _verifiedWithNewKeys(a, b, dm);
        final message = _message(dm, 'waiting');
        await _refusal(a.engine.sendMessage(message));
        duvet.DirectMessage? went;
        a.engine.sent.listen((sent) {
          if (sent.nonce == message.nonce) went = sent.message;
        });
        final now = await a.engine.safetyNumber(bo);
        expect(await a.engine.verifyContact(bo, now.digits), isTrue);
        await until(() => went != null, what: 'what waited sent');
      },
      skip: noCore,
      timeout: _slow,
    );

    // Rule 4 of review 28's list for this task (the desktop's round 3): the engine hands verify_user the QR of the
    // security number it read in the same turn, so the core marks only while it pins the identities the person
    // compared. The desktop's «Mark as verified hands the core the digits the person compared».
    test(
      'mark_as_verified_hands_the_core_the_qr_of_the_number_the_person_compared',
      () async {
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        fake.befriend(ana, bo);
        final commands = <Map<String, Object?>>[];
        final a = await firstDevice(fake, ana, host: WatchedHost(TestHost().gate, [], commands: commands));
        await firstDevice(fake, bo);
        final number = await a.engine.safetyNumber(bo);
        expect(await a.engine.verifyContact(bo, number.digits), isTrue);
        expect(
          [
            for (final command in commands)
              if (command['cmd'] == 'verify_user') command,
          ],
          [
            {'cmd': 'verify_user', 'user_id': bo, 'qr': number.qr},
          ],
        );
      },
      skip: noCore,
      timeout: _slow,
    );

    // Android's own (Ruling 21): the person scans the contact's code from their phone, its text handed to the core as
    // read.
    test(
      "scanning_the_contact's_code_verifies_them,_by_its_text_as_read",
      () async {
        final (fake: _, :ana, :bo, dm: _, :a, :b) = await _anaAndBo();
        final theirs = await b.engine.safetyNumber(ana);
        expect(await a.engine.verifyScanned(bo, theirs.qr), isTrue);
        expect(_shown(a).verified[bo], isTrue);
        expect(await a.engine.contact(bo), isTrue);
        // Bo's device marks no one for it.
        expect(await b.engine.contact(ana), isFalse);
      },
      skip: noCore,
      timeout: _slow,
    );

    test(
      'a_scanned_qr_of_someone_else_does_not_verify',
      () async {
        final (:fake, :ana, :bo, dm: _, :a, :b) = await _anaAndBo();
        final cy = fake.addUser();
        fake.befriend(ana, cy);
        fake.befriend(bo, cy);
        final c = await firstDevice(fake, cy);
        // Cy's code with Ana, and Bo's with Cy: another pair's each, on Bo's page.
        final cysWithAna = await c.engine.safetyNumber(ana);
        final bosWithCy = await b.engine.safetyNumber(cy);
        expect(await a.engine.verifyScanned(bo, cysWithAna.qr), isFalse);
        expect(await a.engine.verifyScanned(bo, bosWithCy.qr), isFalse);
        expect(await a.engine.contact(bo), isFalse);
        // Nor does it unmark: Bo verified, another pair's code changes nothing, and notes no change.
        expect(await a.engine.verifyScanned(bo, (await b.engine.safetyNumber(ana)).qr), isTrue);
        expect(await a.engine.verifyScanned(bo, cysWithAna.qr), isFalse);
        expect(await a.engine.contact(bo), isTrue);
        expect(_shown(a).verified[bo], isTrue);
        expect(a.store.read(verifiedContacts), [bo]);
        expect(_shown(a).changes, isEmpty);
        // Nor is it any contact's but the one whose number is open: Cy isn't marked by it.
        expect(await a.engine.contact(cy), isFalse);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Rule 6: the same two users' code with other keys means the codes don't match, and the core unmarks the contact.
    test(
      'a_scanned_qr_of_the_same_two_users_with_other_keys_unmarks_the_contact',
      () async {
        final (:fake, :ana, :bo, dm: _, :a, :b) = await _anaAndBo();
        final before = await b.engine.safetyNumber(ana);
        expect(await a.engine.verifyScanned(bo, before.qr), isTrue);
        // Ana's own new keys: the code Bo's phone showed then is of the same two users, with her old key.
        await _newKeys(a);
        expect(await a.engine.verifyScanned(bo, before.qr), isFalse);
        expect(_shown(a).verified[bo], isFalse);
        expect(await a.engine.contact(bo), isFalse);
        // Her own scan unmarked him, and no key of his changed (review 29's Minor 3): nothing is noted or held, now or
        // at the next start.
        expect(_shown(a).changes, isEmpty);
        expect(a.engine.holding([bo]), isEmpty);
        expect(_shown(await restarted(fake, a)).changes, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 29's Minor 3: the look after a code that didn't match fails. The mark it took down stays down, as the core
    // may hold the contact unverified now, and nothing is noted then or at the next start.
    test(
      "a_scan_that_didn't_match_leaves_no_mark_on_show_when_the_look_after_it_fails",
      () async {
        final (:fake, :ana, :bo, dm: _, :a, :b) = await _anaAndBo();
        final before = await b.engine.safetyNumber(ana);
        expect(await a.engine.verifyScanned(bo, before.qr), isTrue);
        await _newKeys(a);
        fake.refuse((method: 'GET', path: '/api/users/identities'), 500);
        expect(await a.engine.verifyScanned(bo, before.qr), isFalse);
        expect(_shown(a).verified[bo], isFalse);
        expect(_shown(a).changes, isEmpty);
        final again = await restarted(fake, a);
        expect(_shown(again).verified[bo], isNot(isTrue));
        expect(_shown(again).changes, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Review 29's Minor 3, what stays: Bo's new keys, which Ana's device hasn't heard of, make the code his phone shows
    // one of the same two users with other keys. Her scan of it unmarks him, and the look after it brings his change,
    // strong, as she had verified him: what goes to him waits for her yes.
    test(
      "a_scan_of_a_verified_contact's_new_code,_their_change_unheard,_still_waits_for_the_yes",
      () async {
        var deaf = false;
        final (fake: _, :ana, :bo, :dm, :a, :b) = await _anaAndBo(
          hears: (event) => !(deaf && (event.type == 'IDENTITY_UPDATE' || event.type == 'MLS_COMMIT')),
        );
        await _inGroup(a, b, dm);
        final number = await a.engine.safetyNumber(bo);
        expect(await a.engine.verifyContact(bo, number.digits), isTrue);
        deaf = true;
        await _newKeys(b);
        expect(_shown(a).changes, isEmpty);
        expect(await a.engine.verifyScanned(bo, (await b.engine.safetyNumber(ana)).qr), isFalse);
        expect(_shown(a).verified[bo], isFalse);
        expect(_shown(a).changes[bo]?.verified, isTrue);
        _expectHeld(await _refusal(a.engine.sendMessage(_message(dm))), [bo]);
      },
      skip: noCore,
      timeout: _slow,
    );

    // Rule 2 of review 28's list for this task: Ana's app isn't running; a push's engine on her phone opens Bo's
    // message with her core and observes his new keys. The core says `changed` once: the change is in the record her
    // app's engine reads at its next start, and holds what goes to him.
    test(
      "a_change_a_push's_engine_observes_is_in_the_record_the_app's_engine_reads",
      () async {
        final host = TestHost();
        // Ana's record is the file on her phone, which her app and a push's engine each open on their own.
        final folder = Directory.systemTemp.createTempSync('duvet-record-');
        addTearDown(() => folder.deleteSync(recursive: true));
        Future<FileEngineStore> record(String user) => FileEngineStore.open(user, folder: () async => folder);
        final fake = FakeApi();
        final (ana, bo) = (fake.addUser(), fake.addUser());
        fake.befriend(ana, bo);
        final dm = fake.addConversation(group: false, members: [ana, bo]);
        final a = await firstDevice(fake, ana, host: host.gate, store: await record(ana));
        final b = await firstDevice(fake, bo);
        await _inGroup(a, b, dm);
        final number = await a.engine.safetyNumber(bo);
        expect(await a.engine.verifyContact(bo, number.digits), isTrue);
        await a.engine.stop();
        // Bo's device, another phone, shares this process, and its gate answers on the core's port: Ana's phone's push
        // engine mustn't find it there.
        IsolateNameServer.removePortNameMapping(corePortName);
        await _newKeys(b);
        // His device renews its leaf under his new keys, then writes: Ana's core asks for his identity applying them.
        await stoppedByHand(b);
        IsolateNameServer.removePortNameMapping(corePortName);
        await commitByHand(b, dm);
        final sent = await sentByHand(b, dm, 'after my new keys');
        final shown = await openedPush(
          Push.fromData(fake.pushOf(dm, sent.id))! as EncryptedMessagePush,
          earlier: const [],
          session: (token: a.token, sessionToken: 'session', refreshedAt: null, userId: ana),
          core: (wait) => CoreGate(serves: false, keys: host.keys, folder: () async => host.folder, lockedWait: wait),
          router: fakeRouter,
          duvetClient: engineClient,
          client: watchedClient(fake),
          // The push's engine opens the record as on the phone.
          store: (user) => pushRecord(user, folder: () async => folder),
          cache: MemoryChatCacheStore(),
        );
        expect(shown?.text, 'after my new keys');
        // On disk, in the record the push's engine opened: her app's, read before, doesn't have it yet.
        final noted = KeyChange.read(((await record(ana)).read(keyChanges)! as Map)[bo]);
        expect(noted?.verified, isTrue);
        expect(a.store.read(keyChanges), isNull);
        // Her app's next start, on the record it had open: once the core is its own, the very change the push's engine
        // noted is there (its ID: not one the start's look at her verified contacts would make anew), and holds.
        final again = await restarted(fake, a);
        expect(_shown(again).changes[bo], noted);
        expect((await _refusal(again.engine.sendMessage(_message(dm)))).code, 'key_changed');
      },
      skip: noCore,
      timeout: _slow,
    );

    // Rule 2, through the port: a push's engine whose gate runs its commands on the core the app's engine holds. The
    // observation is told where it ran, the app's engine, and to its record: the push's own notes nothing. Bo isn't
    // verified and has no group with Ana, so nothing at the app's start looks at him: the push's observation alone
    // brings his change.
    test(
      "an_observation_a_push's_engine_makes_through_the_app's_engine_is_noted_by_the_app's",
      () async {
        final host = TestHost();
        // Ana's app hears no IDENTITY_UPDATE either.
        bool deaf(GatewayEvent event) => event.type != 'IDENTITY_UPDATE';
        final (:fake, ana: _, :bo, dm: _, :a, :b) = await _anaAndBo(aHost: host, hears: deaf);
        expect(await a.engine.contact(bo), isFalse);
        await _newKeys(b);
        // Ana's app opens its core again, as at a start: its gate answers on the core's port.
        final app = await restarted(fake, a, hears: deaf);
        expect(_shown(app).changes, isEmpty);
        final itsRecord = MemoryStore();
        final push = Contacts(itsRecord, app.user);
        final gate = CoreGate(serves: false, keys: host.keys, folder: () async => host.folder)
          ..onObserved = push.observed;
        expect((await gate.open(app.user)).state, HostState.ready);
        await observeOn(gate, app.api, [bo]);
        await gate.close();
        expect(_kind(_shown(app).changes[bo]), (false, false, false));
        expect(app.store.read(keyChanges), {
          bo: {'verified': false, 'change': _changeOf(app, bo)},
        });
        expect(push.shown.value.changes, isEmpty);
        expect(itsRecord.kept, isEmpty);
      },
      skip: noCore,
      timeout: _slow,
    );
  });
}
