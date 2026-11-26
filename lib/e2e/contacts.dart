/// Contacts (PLAN-E2E-CLIENTES.md, Task 29; decision 25): other users as this device's core pins them. A changed key is
/// what observe_user says once for each new identity of theirs: its notice shows in every conversation with them until
/// the person closes it, and when the identity it replaced was one the person had verified, what goes to those
/// conversations waits for the person's yes first. Each change has an ID of its own, which a yes or a close names, so
/// neither reaches one that came after what the person was shown. The marks are the core's alone, from its answers to
/// observe_user and verify_user: a refusal (`rejected`) still says whether the identity the core holds is verified, and
/// says no change. Whom the person verified is kept too, from their tap, so a change the record never took is found
/// again: the core then holds that contact unverified, and nothing was noted. The record holds user IDs, booleans and
/// the changes' own IDs, never a key. The desktop's contacts.ts in Dart.
///
/// Whichever engine of this phone holds the core notes what it observes in the record (core_gate.dart's onObserved):
/// the app's, for its own observations and for those a push's engine asks of it, or a push's that opened the core
/// itself, which the app's engine takes from the record once the core is its own ([Contacts.reload]).
library;

import 'package:flutter/foundation.dart';

import 'store.dart';
import 'uuid.dart';

/// A contact's changed key, until the person is done with it: kept by user, with nothing but these words.
@immutable
class KeyChange {
  const KeyChange({required this.verified, this.closed = false, this.confirmed = false, required this.change});

  /// The identity it replaced was one the person had verified: the strong notice, and what goes waits for their yes.
  final bool verified;

  /// The person closed its notice.
  final bool closed;

  /// The person said to send all the same.
  final bool confirmed;

  /// Which change it is, a new ID each time: a yes or a close names the one the person was shown.
  final String change;

  KeyChange copyWith({bool? closed, bool? confirmed}) => KeyChange(
    verified: verified,
    closed: closed ?? this.closed,
    confirmed: confirmed ?? this.confirmed,
    change: change,
  );

  /// Done with: its notice closed, and no yes left to give.
  bool get doneWith => closed && (!verified || confirmed);

  Map<String, Object?> toJson() => {
    'verified': verified,
    if (closed) 'closed': true,
    if (confirmed) 'confirmed': true,
    'change': change,
  };

  /// What the record kept, as it's checked when read, as any record's: null for what isn't one. One kept without its
  /// ID gets a new one.
  static KeyChange? read(Object? kept) => switch (kept) {
    {'verified': final bool verified} => KeyChange(
      verified: verified,
      closed: kept['closed'] == true,
      confirmed: kept['confirmed'] == true,
      change: switch (kept['change']) {
        final String change when change.isNotEmpty => change,
        _ => uuidv4(),
      },
    ),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is KeyChange &&
      other.verified == verified &&
      other.closed == closed &&
      other.confirmed == confirmed &&
      other.change == change;

  @override
  int get hashCode => Object.hash(verified, closed, confirmed, change);

  @override
  String toString() =>
      'KeyChange(${verified ? 'verified' : 'plain'}${closed ? ', closed' : ''}${confirmed ? ', confirmed' : ''})';
}

/// A change as the person was shown it, which their yes names.
typedef ShownChange = ({String user, String change});

/// The security number with a contact (the core's safety_number): its 60 digits in 12 groups of 5, spaces between
/// them, and its QR's text, which the other's phone hands to verify_user.
typedef SafetyNumber = ({String digits, String qr});

/// What the views show of the person's contacts.
@immutable
class ContactsShown {
  const ContactsShown({this.changes = const {}, this.verified = const {}});

  static const none = ContactsShown();

  /// Each contact's changed key the person isn't done with, by user.
  final Map<String, KeyChange> changes;

  /// Whether the person verified each contact this device saw this run, by user.
  final Map<String, bool> verified;
}

/// Of a conversation's people, those whose changed key's notice shows there.
List<String> changedIn(Map<String, KeyChange> changes, Iterable<String> people) => [
  for (final user in people)
    if (changes[user] case final change? when !change.closed) user,
];

/// Of a conversation's people, those whose changed key makes what goes there wait for the person's yes.
List<String> waitingForYes(Map<String, KeyChange> changes, Iterable<String> people) => [
  for (final user in people)
    if (changes[user] case final change? when change.verified && !change.confirmed) user,
];

class Contacts {
  Contacts(this._store, this._own) : _changes = _kept(_store.read(keyChanges)), _listed = _listedIn(_store) {
    _shown.value = _now();
  }

  final EngineStore _store;

  /// The device's own user, whose observations are no contact's.
  final String _own;

  /// Whether the person verified each contact, as the core last said.
  final _verified = <String, bool>{};

  /// The changes, as the record keeps them, and this run as far as the record refuses them (its storage full).
  Map<String, KeyChange> _changes;

  /// Whom the person verified on this device, from their tap until they're done with a change of theirs.
  final Set<String> _listed;

  final _shown = ValueNotifier(ContactsShown.none);

  /// What the views show, as it changes.
  ValueListenable<ContactsShown> get shown => _shown;

  /// The record's last write, which an engine that lets the core go waits for (a push's: its isolate ends after).
  Future<void> get written => _written;
  Future<void> _written = Future.value();

  /// Whom the person verified, by the record: a start looks at them again, as a change of theirs may have been lost.
  List<String> verifiedUsers() => [..._listed];

  /// What the core answered of a user's observation (observe_user's `ok`): a refusal says no change, and still says
  /// whether the identity the core holds is verified.
  void observed(String user, Map<String, Object?> answer) {
    if (user == _own) return;
    final verified = answer['verified'] == true;
    var news = _verified[user] != verified;
    _verified[user] = verified;
    if (verified) _list(user, true);
    final before = _changes[user];
    // A change before the person was done with a verified one's keeps it strong: they never said yes to it; and so is
    // one of a contact they verified whose earlier change the record never took.
    final strong = (before != null && before.verified && !before.confirmed) || _listed.contains(user);
    if (answer['state'] == 'changed') {
      _write({..._changes, user: KeyChange(verified: answer['was_verified'] == true || strong, change: uuidv4())});
      news = true;
    } else if (!verified && before == null && _listed.contains(user)) {
      _write({..._changes, user: KeyChange(verified: true, change: uuidv4())});
      news = true;
    }
    if (news) _tell();
  }

  /// What the core answered of the person's verification: once they verified a contact, their change is done with.
  void verifiedNow(String user, bool verified) {
    _verified[user] = verified;
    if (verified) {
      _list(user, true);
      if (_changes.containsKey(user)) _write({..._changes}..remove(user));
    }
    _tell();
  }

  /// The person closed the notice of the user's [change] they were shown.
  void close(String user, String change) => _change(user, change, closed: true);

  /// The person's yes to sending, these changes known: none that came since they were shown.
  void confirm(List<ShownChange> shown) {
    for (final (:user, :change) in shown) {
      _change(user, change, confirmed: true);
    }
  }

  /// Of these users, those whose changed key makes what goes to them wait for the person's yes.
  List<String> holding(Iterable<String> users) => waitingForYes(_changes, users);

  /// This device starts again with nothing (its core gone): what it pinned and noted goes with it.
  void forget() {
    _verified.clear();
    _listed.clear();
    _keep(verifiedContacts, null);
    _write({});
    _tell();
  }

  /// What another engine of this phone wrote to the record while this one didn't hold the core (a push's, which noted
  /// a change the core said once), taken as the record holds it once the core is this engine's, before this engine
  /// observes or writes anything there. Nothing is written: an engine whose commands ran through the app's engine
  /// never overwrites what the app's noted.
  Future<void> reload() async {
    await _store.refresh([keyChanges, verifiedContacts]);
    _changes = _kept(_store.read(keyChanges));
    _listed
      ..clear()
      ..addAll(_listedIn(_store));
    _tell();
  }

  void _change(String user, String change, {bool? closed, bool? confirmed}) {
    final now = _changes[user];
    if (now == null || now.change != change) return;
    final next = now.copyWith(closed: closed, confirmed: confirmed);
    // Their yes, or a change done with: the person dealt with that change, so it's found no more.
    if (confirmed == true || next.doneWith) _list(user, false);
    _write(next.doneWith ? ({..._changes}..remove(user)) : {..._changes, user: next});
    _tell();
  }

  void _write(Map<String, KeyChange> changes) {
    _changes = changes;
    _keep(
      keyChanges,
      changes.isEmpty ? null : {for (final MapEntry(:key, :value) in changes.entries) key: value.toJson()},
    );
  }

  void _list(String user, bool on) {
    if (_listed.contains(user) == on) return;
    on ? _listed.add(user) : _listed.remove(user);
    _keep(verifiedContacts, _listed.isEmpty ? null : [..._listed]);
  }

  // A write the record refuses keeps this run's in memory: the verified list finds a lost change at the next start.
  // The log says only that it failed, never what the record holds.
  void _keep(String key, Object? value) {
    _written = _store.write(key, value).catchError((Object error) {
      debugPrint("e2e: the contacts' record wasn't kept: ${error.runtimeType}");
    });
  }

  ContactsShown _now() => ContactsShown(changes: Map.unmodifiable(_changes), verified: Map.unmodifiable(_verified));

  void _tell() => _shown.value = _now();
}

/// The changes a record keeps: what each holds is checked as it's read, as any record's.
Map<String, KeyChange> _kept(Object? record) => switch (record) {
  final Map<Object?, Object?> kept => {
    for (final MapEntry(:key, :value) in kept.entries)
      if (key is String) key: ?KeyChange.read(value),
  },
  _ => {},
};

Set<String> _listedIn(EngineStore store) => _listedOf(store.read(verifiedContacts)).toSet();

/// Whom a record says the person verified: user IDs, checked as they're read.
List<String> _listedOf(Object? record) => switch (record) {
  final List<Object?> users => [for (final user in users) ?(user is String ? user : null)],
  _ => const [],
};
