// The API as the encryption engine sees it, in memory, for the engine's tests (PLAN-E2E-CLIENTES.md, Task 9): the
// desktop's testing/fake-api.ts in Dart, with the same routes (PLAN-E2E-API.md, its routes A to K), answers, events and
// switches. It answers through an http.Client, as the API does, so duvet_client's own RestClient runs against it; a
// connection to the gateway hears its events. Switches lose an answer, cut a request before it reaches the API, hold
// requests until several have come, answer 426, 503, 409 or any refusal, hold events to let them go backwards, twice or
// a kind at a time, and take an entry's data out of its event. A request's events go out after its
// answer, at the next turn of the event loop, once the code that awaited the answer ran on to its next timer or I/O (on
// the desktop, two microtasks after it); each is its data as it was when the request sent it; holdEvents gives any
// other order. It reads what the core signs (CBOR, Ed25519) and an MLS message's framing as the API does, but runs no
// validator: a commit is taken by its generation and epoch alone, and of what it changes the fake knows only the
// devices its welcome brings, the one an external commit adds, and the user a removal takes out, who reads the queue up
// to it.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:duvet/e2e/cbor.dart';
import 'package:duvet/e2e/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'ed25519.dart';
import 'multipart.dart';

/// Where the fake answers: any origin does, only the path counts.
const fakeApiUrl = 'https://fake-api.test';

/// What a connection to the gateway hears: a dispatch's type and data.
typedef GatewayEvent = ({String type, Object? data});

/// Which requests a switch takes: its method (any without one) and its path, as written (a String) or by a RegExp.
typedef RouteMatch = ({String? method, Pattern path});

class _Answer {
  const _Answer(this.status, {this.body, this.headers = const {}});
  final int status;
  final Object? body;
  final Map<String, String> headers;
}

/// A refusal a route answers with, thrown from anywhere in it.
class _Refusal implements Exception {
  const _Refusal(this.answer);
  final _Answer answer;
}

_Refusal _fail(int status, String error, [Map<String, Object?> extra = const {}]) =>
    _Refusal(_Answer(status, body: {'error': error, ...extra}));

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
const _uuidPath = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
final _base64 = RegExp(r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$');
final _random = Random.secure();
Uint8List _randomBytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

// The API's limits (its GET /api/e2e gives them out), in bytes but for the counts.
const _limits = {
  'ciphertext_bytes': 32 << 10,
  'key_packages': 100,
  'last_resort_key_packages': 1,
  'key_package_bytes': 4 << 10,
  'inbox_message_bytes': 64 << 10,
  'history_share_parts': 64,
  'history_share_part_bytes': (1 << 20) + 16,
  'group_members': 20,
  'listed_devices': 20,
  'commit_bytes': 256 << 10,
  'welcome_bytes': 1 << 20,
  'group_info_bytes': 1 << 20,
  'encrypted_identity_bytes': 1 << 10,
  'wrapped_backup_key_bytes': 1 << 10,
  'wrapped_previous_backup_keys_bytes': 64 << 10,
  'certificate_bytes': 1 << 10,
  'device_list_bytes': 4 << 10,
  'epochs_behind': 5,
};
int _limit(String name) => _limits[name]!;

/// An event carries an entry's data up to this much; past it the client reads the entry from the queue.
const _maxEventData = 16 << 10;

/// A key package is handed out only with this much of its life left.
const _keyPackageMargin = 24 * 3600 * 1000;

/// Under this many single-use key packages left to hand out, a device hears KEY_PACKAGES_LOW.
const _keyPackagesLow = 20;
const _inboxMax = 1000;
const _noMax = 1 << 62;

// The labels the core signs its objects under: a signature covers label || 0x00 || body.
const _certificateLabel = 'duvet device certificate v1';
const _listLabel = 'duvet device list v1';
const _leaveLabel = 'duvet leave v1';
const _bindLabel = 'duvet device bind v1';

// -----------------------------------------------------------------------------------------------------------------
// What the fake reads of what the core makes.

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  var at = 0;

  Uint8List take(int n) {
    if (n < 0 || at + n > bytes.length) throw const FormatException('cut short');
    return Uint8List.sublistView(bytes, at, at += n);
  }

  int uint(int n) => take(n).fold(0, (value, byte) => value * 256 + byte);

  // An MLS vector's length takes 1, 2 or 4 bytes, as its first two bits say.
  Uint8List vector() {
    final first = uint(1);
    final more = switch (first >> 6) {
      0 => 0,
      1 => 1,
      2 => 3,
      _ => throw const FormatException('a length MLS never takes'),
    };
    return take(more == 0 ? first : (first & 0x3f) * (1 << (8 * more)) + uint(more));
  }

  int get left => bytes.length - at;
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A signed object's body, once its Ed25519 signature over label || 0x00 || body verifies with [key]; else null.
Map<String, Object?>? _signedBody(String label, Uint8List signed, Uint8List key) {
  final object = asMap(cbor(signed));
  final body = asBytes(object?['body']);
  final sig = asBytes(object?['sig'], 64);
  if (body == null || sig == null || key.length != 32) return null;
  if (!verifyEd25519(key, [...utf8.encode(label), 0, ...body], sig)) return null;
  final fields = asMap(cbor(body));
  return fields?['v'] == 1 ? fields : null;
}

typedef _Certificate = ({String user, String device, Uint8List signatureKey, Uint8List hpkeKey});

_Certificate? _readCertificate(Uint8List signed, Uint8List identityKey) {
  final body = _signedBody(_certificateLabel, signed, identityKey);
  final (user, device) = (asUuid(body?['user']), asUuid(body?['device']));
  final (signatureKey, hpkeKey) = (asBytes(body?['signature_key'], 32), asBytes(body?['hpke_key'], 32));
  if (user == null || device == null || signatureKey == null || hpkeKey == null) return null;
  return (user: user, device: device, signatureKey: signatureKey, hpkeKey: hpkeKey);
}

typedef _DeviceList = ({String user, int version, List<String> devices});

_DeviceList? _readDeviceList(Uint8List signed, Uint8List identityKey) {
  final body = _signedBody(_listLabel, signed, identityKey);
  final user = asUuid(body?['user']);
  final key = asBytes(body?['identity_key'], 32);
  final version = body?['version'];
  final listed = body?['devices'];
  if (user == null || key == null || !_equal(key, identityKey) || version is! int || listed is! List) return null;
  // The devices are in order, each once.
  final devices = <String>[];
  for (final raw in listed) {
    final device = asUuid(raw);
    if (device == null || device.compareTo(devices.lastOrNull ?? '') <= 0) return null;
    devices.add(device);
  }
  return (user: user, version: version, devices: devices);
}

const _public = 1;
const _private = 2;
const _welcome = 3;
const _groupInfo = 4;

/// What the API reads of an MLS message (RFC 9420): its wire format, and its group, epoch and sender or content. A
/// public message's sender type: 1 a member, 2 an external sender, 4 a new member's own commit; a private message's
/// content type: 1 an application message; a welcome's new members by their key packages' refs in base64.
typedef _Framing = ({
  int wire,
  String? conversation,
  int? generation,
  int? epoch,
  int? sender,
  int? content,
  List<String>? welcomed,
});

_Framing? _framing(Uint8List data) {
  try {
    final r = _Reader(data);
    if (r.uint(2) != 1) return null;
    final wire = r.uint(2);
    _Framing framed({
      String? conversation,
      int? generation,
      int? epoch,
      int? sender,
      int? content,
      List<String>? welcomed,
    }) => (
      wire: wire,
      conversation: conversation,
      generation: generation,
      epoch: epoch,
      sender: sender,
      content: content,
      welcomed: welcomed,
    );
    if (wire == _groupInfo) return framed();
    if (wire == _welcome) {
      r.uint(2); // its cipher suite
      final secrets = _Reader(r.vector());
      final welcomed = <String>[];
      while (secrets.left > 0) {
        welcomed.add(base64Encode(secrets.vector()));
        secrets.vector(); // the KEM output
        secrets.vector(); // the sealed group secrets
      }
      return framed(welcomed: welcomed);
    }
    if (wire != _public && wire != _private) return null;
    final group = r.vector();
    if (group.length != 20) return null;
    final epoch = r.uint(8);
    final conversation = asUuid(Uint8List.fromList(group.sublist(0, 16)));
    final generation = group.sublist(16).fold(0, (value, byte) => value * 256 + byte);
    return wire == _public
        ? framed(conversation: conversation, generation: generation, epoch: epoch, sender: r.uint(1))
        : framed(conversation: conversation, generation: generation, epoch: epoch, content: r.uint(1));
  } on FormatException {
    return null;
  }
}

/// A number in [bytes] bytes, big-endian, as TLS writes one.
List<int> _tlsUint(int n, int bytes) => [for (var i = bytes - 1; i >= 0; i--) (n >> (8 * i)) & 0xff];

/// A vector as TLS writes it in MLS: its length in 1, 2 or 4 bytes, as its first two bits say, then its bytes.
List<int> _tlsVector(List<int> bytes) {
  final n = bytes.length;
  final length = n < 0x40
      ? [n]
      : n < 0x4000
      ? [0x40 | (n >> 8), n & 0xff]
      : [0x80 | (n >> 24), ..._tlsUint(n, 3)];
  return [...length, ...bytes];
}

/// The devices with a leaf in the group a group info is of (RFC 9420's GroupInfo, its ratchet_tree extension), by
/// their leaf index, each read from its credential, the device's certificate; with the group's ID and epoch. Null for
/// anything that isn't a group info with its tree.
({Uint8List groupId, int epoch, Map<int, String> leaves})? _groupInfoLeaves(Uint8List data) {
  try {
    final r = _Reader(data);
    if (r.uint(2) != 1 || r.uint(2) != _groupInfo) return null;
    r.uint(4); // the context's version and cipher suite
    final groupId = r.vector();
    final epoch = r.uint(8);
    for (var skipped = 0; skipped < 3; skipped++) {
      r.vector(); // the tree hash, the transcript hash, the context's extensions
    }
    final extensions = _Reader(r.vector());
    Uint8List? tree;
    while (extensions.left > 0) {
      final type = extensions.uint(2);
      final value = extensions.vector();
      if (type == 2) tree = value;
    }
    if (tree == null) return null;
    // The extension's data is the tree, a vector of optional nodes.
    final nodes = _Reader(_Reader(tree).vector());
    final leaves = <int, String>{};
    for (var index = 0; nodes.left > 0; index++) {
      if (nodes.uint(1) == 0) continue; // a blank node
      final kind = nodes.uint(1);
      if (kind == 2) {
        for (var field = 0; field < 3; field++) {
          nodes.vector(); // a parent: its key, parent hash and unmerged leaves
        }
        continue;
      }
      if (kind != 1) return null;
      nodes.vector(); // its encryption key
      nodes.vector(); // its signature key
      final basic = nodes.uint(2) == 1;
      final identity = nodes.vector();
      for (var field = 0; field < 5; field++) {
        nodes.vector(); // its capabilities
      }
      switch (nodes.uint(1)) {
        case 1:
          nodes.take(16); // a key package's lifetime
        case 3:
          nodes.vector(); // a commit's parent hash
      }
      nodes.vector(); // its extensions
      nodes.vector(); // its signature
      final certificate = asMap(cbor(identity));
      final device = basic ? asUuid(asMap(cbor(asBytes(certificate?['body']) ?? identity))?['device']) : null;
      if (device != null) leaves[index ~/ 2] = device;
    }
    return (groupId: groupId, epoch: epoch, leaves: leaves);
  } on FormatException {
    return null;
  }
}

// -----------------------------------------------------------------------------------------------------------------
// What a request sends, read as the API reads it: a refusal for anything else.

/// A request's binary field, standard base64, as its text: from [min] bytes to [max] once decoded.
String _base64In(Object? value, String field, {int max = _noMax, int min = 0}) {
  if (value is! String || !_base64.hasMatch(value)) throw _fail(400, "$field isn't base64");
  final length = base64Decode(value).length;
  if (length > max) throw _fail(400, '$field is $max bytes at most');
  if (length < min) throw _fail(400, '$field is $min bytes at least');
  return value;
}

Uint8List _bytesIn(Object? value, String field, {int max = _noMax, int min = 0}) =>
    base64Decode(_base64In(value, field, max: max, min: min));

String _uuidIn(Object? value, String field) {
  if (value is! String || !_uuid.hasMatch(value)) throw _fail(400, "$field isn't a UUID");
  return value;
}

int _numberIn(Object? value, String field) {
  if (value is! int || value < 0) throw _fail(400, "$field isn't a number");
  return value;
}

// RFC 3339, as Go's time.Time reads one from JSON: a date, a time and its offset.
final _rfc3339 = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$');

/// A time as the API binds one (time.Time): RFC 3339 text, never a number; the instant it names, in UTC.
DateTime _timeIn(Object? value, String field) {
  final time = value is String && _rfc3339.hasMatch(value) ? DateTime.tryParse(value) : null;
  if (time == null) throw _fail(400, "$field isn't an RFC 3339 time");
  return time.toUtc();
}

/// A rotation's transfers, as the API binds them: an array of objects, each a device, its certificate and its message.
List<({String deviceId, String certificate, String message})> _transfersIn(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw _fail(400, 'transfers is an array');
  return [
    for (final transfer in value)
      if (transfer is! Map)
        throw _fail(400, 'a transfer is an object')
      else
        (
          deviceId: _uuidIn(transfer['device_id'], 'transfers.device_id'),
          certificate: _base64In(
            transfer['certificate'],
            'transfers.certificate',
            max: _limit('certificate_bytes'),
            min: 1,
          ),
          message: _base64In(transfer['message'], 'transfers.message', max: _limit('inbox_message_bytes'), min: 1),
        ),
  ];
}

// The platforms X-Duvet-Client names, as the API has them.
const _platforms = ['desktop-windows', 'desktop-macos', 'desktop-linux', 'web', 'android', 'ios'];

/// A version as the API reads one: major.minor.patch, each part 1 to 4 decimal digits; null for anything else.
List<int>? _versionIn(String text) {
  final parts = text.split('.');
  final digits = RegExp(r'^\d{1,4}$');
  return parts.length == 3 && parts.every(digits.hasMatch) ? [for (final part in parts) int.parse(part)] : null;
}

/// What X-Duvet-Client says the client is, `<platform>/<version>`, as the API reads it; null for anything else.
({String platform, List<int> version})? _clientIn(String? header) {
  final match = RegExp(r'^([^/]*)/(.*)$', dotAll: true).firstMatch(header ?? '');
  final version = match == null ? null : _versionIn(match[2]!);
  return version != null && _platforms.contains(match![1]) ? (platform: match[1]!, version: version) : null;
}

/// Whether a version is the least one or a later one.
bool _atLeast(List<int> version, List<int> least) {
  for (var i = 0; i < version.length; i++) {
    if (version[i] != least[i]) return version[i] > least[i];
  }
  return true;
}

// -----------------------------------------------------------------------------------------------------------------
// The fake's state.

class _Session {
  _Session(this.user, this.token, this.challenge);
  final String user;
  final String token;
  Uint8List challenge;
  String? device;
}

class _Device {
  _Device(this.id, this.user, this.name, this.client, this.signatureKey, this.hpkeKey, this.createdAt)
    : lastSeenAt = createdAt;
  final String id;
  final String user;
  final String name;
  final String? client;
  final Uint8List signatureKey;
  final Uint8List hpkeKey;
  final String createdAt;

  /// shortcut: set as it registers and by [FakeApi.lastSeen] alone; the API notes each device's requests, once an hour.
  String lastSeenAt;
  Uint8List? certificate;

  /// The identity that certified it.
  String? certifiedBy;
  var listed = false;
  var removed = false;
}

class _Identity {
  _Identity(this.id, this.identityKey, this.deviceList, this.version, this.changedAt, this.backup);
  final String id;
  final Uint8List identityKey;
  Uint8List deviceList;
  int version;
  final String changedAt;

  /// encrypted_identity, wrapped_backup_key and wrapped_previous_backup_keys, as they came.
  final Map<String, Object?> backup;
}

class _KeyPackage {
  _KeyPackage(this.data, this.expiresAt, this.lastResort);
  final String data;
  final int expiresAt;
  final bool lastResort;
  var handedOut = false;
}

class _Conversation {
  _Conversation(this.id, this.type, this.ownerId, this.createdAt, this.legacy, this.members);
  final String id;
  final int type;
  String ownerId;
  final String createdAt;
  final bool legacy;
  List<Map<String, Object?>> members;
  ({int generation, int epoch, String groupInfo})? group;

  /// The last number its queue gave: commits, welcomes, proposals, edits, deletions and messages share it.
  var seq = 0;

  /// The number its queue is whole from: what comes before it is gone (expireQueue).
  var floor = 1;
  final entries = <Map<String, Object?>>[];
  final messages = <Map<String, Object?>>[];
  final deleted = <String>{};

  /// The devices with a leaf in its group, by the number of the entry they have had it from.
  var leaves = <String, int>{};

  /// The users a removal took out, by its commit's number: out of the conversation, they read the queue up to it (the
  /// API's MlsDepartures).
  final departures = <String, int>{};

  /// What each commit taken answered, by its bytes: the same commit again gets it.
  final commits = <String, Map<String, Object?>>{};

  /// Who left its group, by their leave statement, while a leaf of theirs is in it: their removals are proposed.
  final leavers = <String, String>{};

  /// The removals proposed, by generation, epoch and leaf: one an epoch.
  final proposed = <String>{};

  /// All it holds, copied: what a request does to it afterwards doesn't reach the copy.
  _Conversation copy() => _Conversation(id, type, ownerId, createdAt, legacy, [for (final m in members) _clone(m)])
    ..group = group
    ..seq = seq
    ..floor = floor
    ..entries.addAll([for (final e in entries) _clone(e)])
    ..messages.addAll([for (final m in messages) _clone(m)])
    ..deleted.addAll(deleted)
    ..leaves = {...leaves}
    ..departures.addAll(departures)
    ..commits.addAll({for (final MapEntry(:key, :value) in commits.entries) key: _clone(value)})
    ..leavers.addAll(leavers)
    ..proposed.addAll(proposed);
}

class _Segment {
  _Segment(this.id, this.identity, this.conversationId, this.day, this.complete, this.keyId, this.size, this.file);
  final String id;

  /// The identity whose backup it's in: a rotation carries it on to the new one (the API's MoveBackupSegments).
  String identity;
  final String conversationId;
  final String day;
  final bool complete;
  final String keyId;
  final int size;
  final String createdAt = DateTime.now().toUtc().toIso8601String();
  final String file;
}

class _Share {
  _Share(
    this.id,
    this.conversationId,
    this.fromUser,
    this.fromDevice,
    this.toUser,
    this.kind,
    this.range,
    this.startsAt,
    this.size,
    this.parts,
  );
  final String id;
  final String conversationId;
  final String fromUser;
  final String fromDevice;
  final String toUser;
  final String kind;
  final String? range;
  final DateTime startsAt;
  final int size;
  final int parts;
  final uploaded = <int, String>{};
  var completed = false;
  final acked = <String>{};

  /// All it holds, copied: what a request does to it afterwards doesn't reach the copy.
  _Share copy() => _Share(id, conversationId, fromUser, fromDevice, toUser, kind, range, startsAt, size, parts)
    ..uploaded.addAll(uploaded)
    ..completed = completed
    ..acked.addAll(acked);
}

class _Connection {
  _Connection(this.user, this.device, this.listener);
  final String user;
  final String? device;
  final void Function(GatewayEvent event) listener;
}

class _Context {
  _Context(
    this.session,
    this.device,
    this.params,
    this.query,
    this.body,
    this.bytes,
    this.headers,
    this.queryAll,
    this.files,
  );
  final _Session? session;
  final _Device? device;
  final Map<String, String> params;
  final Map<String, String> query;

  /// The query's values, every one of a key that repeats (a search's `has`).
  final Map<String, List<String>> queryAll;
  final Map<String, Object?>? body;
  final Uint8List bytes;
  final Map<String, String> headers;

  /// A form's files, in their order: none for a JSON body.
  final List<FormPart> files;

  _Session get me => session!;
  Object? operator [](String field) => body?[field];
}

enum _Needs { nothing, session, device, listed }

/// A route: its method, its path, what its session needs, its handler, and whether any client may call it.
typedef _Route = ({String method, RegExp path, _Needs needs, _Answer Function(_Context ctx) handler, bool anyClient});

/// An event a request sends: to its user's connections, or to one device's.
typedef _Outgoing = ({String user, String? device, GatewayEvent event});

String _now() => DateTime.now().toUtc().toIso8601String();
int _unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
_Answer _ok(Object? body, [int status = 200]) => _Answer(status, body: body);
const _noContent = _Answer(204);

/// A copy of JSON's values, so what's sent is what was there then.
T _clone<T>(T value) => jsonDecode(jsonEncode(value)) as T;

// A switch's effects but an answer of its own: the answer lost, the request never reaching the API, a message's
// connection cut once its files went up, or the API's answer with nothing it did kept.
const _lose = #lose;
const _cut = #cut;
const _cutAfterFiles = #cutAfterFiles;
const _forget = #forget;

/// The most bytes one file of a message takes, as Duvet's storage does: past it, a 413.
const fileMost = 20 << 20;

/// A message's file the fake keeps, as the API's attachment row: whose, its sealed bytes' size and SHA-256, and the
/// message it's on (none while it isn't on one).
class _Attachment {
  _Attachment(this.id, this.owner, this.size, this.sha256, this.createdAt);
  final String id;
  final String owner;
  final int size;
  final String sha256;
  final String createdAt;
  String? message;
}

class FakeApi {
  FakeApi() {
    _routes = _table();
  }

  /// The seed of the API's own external sender's key, which signs the removals it proposes.
  final _senderSeed = _randomBytes(32);

  /// The API's Ed25519 public key, its groups' one external sender, in base64 (GET /api/e2e's). A test that sets
  /// another plays a server that changed it: the fake checks no commit against it. None is an API without one.
  late String? externalSender = base64Encode(ed25519PublicKey(_senderSeed));

  /// Pairs of friends, each as its two IDs in order, and users none of whose listed devices connected lately.
  final _friends = <String>{};
  final _inactive = <String>{};

  /// Users from whom the API keeps leave statements ([hideStatements]).
  final _hidden = <String>{};

  /// The API keeps leave statements from the user from now on: the proposals they hear and read come without them, as
  /// a server that would have their devices miss someone's leaving.
  void hideStatements(String user) => _hidden.add(user);

  /// An entry as [user] gets it: without its statement when the API keeps those from them.
  Map<String, Object?> _shownTo(String user, Map<String, Object?> entry) =>
      _hidden.contains(user) && entry.containsKey('statement') ? ({...entry}..remove('statement')) : entry;

  /// The cutover's instant, as GET /api/e2e gives it.
  String? cutoverAt;

  /// Take every entry's data out of its event, as one past 16 KiB travels: the client reads it from the queue.
  var stripData = false;

  /// What POST /api/e2e/decrypt-failures was told.
  final decryptFailures = <({String kind, Object? count})>[];

  /// The lowest version of each platform with end-to-end encryption (E2E_MIN_CLIENTS), which GET /api/e2e gives out:
  /// a request from a client below it, or of a platform it doesn't name, gets a 426. Day one's platforms, any version.
  Map<String, String> minClients = {'desktop-windows': '0.0.0', 'web': '0.0.0', 'android': '0.0.0'};

  final _users = <String>{};
  final _sessions = <String, _Session>{};
  final _devices = <String, _Device>{};
  final _identities = <String, _Identity>{};
  final _keyPackages = <String, Map<String, _KeyPackage>>{};
  final _conversations = <String, _Conversation>{};
  final _inboxes = <String, List<Map<String, Object?>>>{};

  /// What was left in each inbox, a rotation's transfers aside, for a test to replay ([replayInbox]).
  final _delivered = <({String from, String fromDevice, String to, String message})>[];
  final _segments = <String, _Segment>{};

  /// Each user's backup keys, by the key_id each identity's encrypted identity names (the API's UserBackupKeys): when a
  /// new identity retired each one (null: the current one); and when they last started over, which takes every key it
  /// retired out of the backup.
  final _backupKeys = <String, ({Map<String, DateTime?> retired, List<DateTime> resets})>{};

  /// The most bytes one file takes, as Duvet's storage does: a message's file, or a day of the backup. A test lowers
  /// it to have a day too large to keep.
  var fileLimit = fileMost;

  /// What the API's clock is off by, in ms, as it stamps a message or another entry of a conversation's queue
  /// (sent_at): a test's way to a message, an edit or a deletion of days ago, and so to a day of the backup that ended.
  var sentAtOffset = 0;
  final _shares = <String, _Share>{};

  /// When each package was made, as the API counts them toward its limits (PLAN-E2E-API.md, I): a user's ten shares an
  /// hour; their thirty catch-ups an hour, and one a day to each member of each conversation.
  final _sharesMade = <({String user, String kind, String conversation, String to, DateTime at})>[];
  final _files = <String, Uint8List>{};

  /// Messages' files, by their IDs: their bytes are in [_files].
  final _attachments = <String, _Attachment>{};

  /// The next message's request whose files go up has its connection cut before its message is taken.
  var _cuttingAfterFiles = false;

  /// The sealed bytes the API keeps of a message's file, by its ID; null for none.
  Uint8List? fileBytes(String id) => _attachments.containsKey(id) ? _files[id] : null;

  /// Where a file the fake keeps is downloaded from, signed now, as its message's reads give it.
  String signedUrlOf(String file) => _signedPath(file);

  /// The inbox messages that are a rotation's transfers, by ID.
  final _transfers = <String>{};

  /// What each message answers: the ID of the message it replies to, by its own.
  final _repliesTo = <String, String>{};
  final _connections = <_Connection>{};

  /// What the request being answered sends, which goes out once its answer is made.
  final _outbox = <_Outgoing>[];

  /// Events held for [releaseEvents], while holding.
  List<({_Connection connection, GatewayEvent event})>? _held;

  /// What the next request a switch takes gets: an answer of its own, its answer lost ([_lose]), never reaching the
  /// API ([_cut]), or the API's answer with nothing kept ([_forget]); every one from then on when it's [always].
  final _switches = <({RouteMatch match, Object effect, bool always})>[];

  /// Requests held until as many as each gate counts have come ([gather]).
  final _gates = <({RouteMatch match, int count, List<Completer<void>> waiting})>[];
  late final List<_Route> _routes;
  var _lastId = '';

  /// An ID the fake mints, always above the one before as the API's are: two in one millisecond still sort in turn.
  String _id() {
    var id = uuidv7();
    if (id.compareTo(_lastId) <= 0) {
      id = uuidv7(int.parse(_lastId.substring(0, 13).replaceFirst('-', ''), radix: 16) + 1);
    }
    return _lastId = id;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // What a test does around the routes.

  /// A user of the API, by their new ID.
  String addUser() {
    final id = _id();
    _users.add(id);
    return id;
  }

  /// A session of the user's, as a login gives it: its token and its challenge to bind a device with.
  ({String token, String deviceChallenge}) signIn(String user) {
    if (!_users.contains(user)) throw StateError('no user $user');
    final token = uuidv7();
    final challenge = _randomBytes(32);
    _sessions[token] = _Session(user, token, challenge);
    return (token: token, deviceChallenge: base64Encode(challenge));
  }

  /// The session ends, as one past its time does: each of its requests is refused (401) from now on.
  void endSession(String token) => _sessions.remove(token);

  /// The push of a conversation's message as the API sends it (push.EncryptedData; PLAN-E2E-API.md, its section on
  /// pushes): who wrote it ([authorName] as the API names them), where ([place]: a group's name, or nothing in a DM)
  /// and when, its number, and its queue entry as the queue gives it while the whole data fits FCM's 4096 bytes. Never
  /// its text.
  Map<String, String> pushOf(String conversationId, String messageId, {String authorName = 'Bo', String place = ''}) {
    final conv = _conversation(conversationId);
    final m = conv.messages.firstWhere((m) => m['id'] == messageId);
    final data = {
      'type': 'encrypted_message',
      'message_id': messageId,
      'author_id': m['author_id']! as String,
      'author_name': authorName,
      'author_avatar': '',
      'place': place,
      'sent_at': '${m['sent_at']}',
      'conversation_id': conversationId,
      'seq': '${m['seq']}',
    };
    final entry = jsonEncode(_messageEntry(m));
    return jsonEncode({...data, 'entry': entry}).length <= 4096 ? {...data, 'entry': entry} : data;
  }

  /// A conversation of these users (its members by their membership's ID, in this order), and its ID.
  String addConversation({required bool group, required List<String> members, String? owner, bool legacy = false}) {
    final id = _id();
    final at = _now();
    _conversations[id] = _Conversation(id, group ? 2 : 1, owner ?? members.first, at, legacy, [
      for (final user in members)
        {'id': _id(), 'conversation_id': id, 'user_id': user, 'created_at': at, 'updated_at': at},
    ]);
    return id;
  }

  /// A connection to the gateway of the session's, identified with its device (null for none): it hears READY at
  /// once, which says nothing of conversations or their groups, as the gateway's doesn't, then the events for its user,
  /// and for its device. Its end.
  void Function() connect(String token, String? device, void Function(GatewayEvent event) listener) {
    final session = _sessions[token];
    if (session == null) throw StateError('no such session');
    final connection = _Connection(session.user, device, listener);
    _connections.add(connection);
    listener((
      type: 'READY',
      data: {
        'user': {'id': session.user},
      },
    ));
    return () => _connections.remove(connection);
  }

  _Conversation _conversation(String id) => _conversations[id] ?? (throw StateError('no conversation $id'));

  /// Every conversation's ID.
  Iterable<String> get conversationIds => _conversations.keys;

  /// The conversation as an honest page draws it for [user], from what the fake lists now: a group with its owner and
  /// members, a DM as the user and the first other member listed; null for one the user isn't in. What an engine's
  /// test gives it as drawn, never the engine's own listing (N-C1 of step 4's closing re-review).
  Future<({bool group, String? owner, List<String> users})?> Function(String conversationId, {required bool fresh})
  drawnTo(String user) => (conversationId, {required fresh}) async {
    final conv = _conversations[conversationId];
    final users = [for (final m in conv?.members ?? const <Map<String, Object?>>[]) m['user_id']! as String];
    if (conv == null || !users.contains(user)) return null;
    final group = conv.type == 2;
    final others = [
      for (final other in users)
        if (other != user) other,
    ];
    return (group: group, owner: group ? conv.ownerId : null, users: [user, ...group ? others : others.take(1)]);
  };

  /// The conversation as the API lists it, for a server that answers another route with it.
  Map<String, Object?> viewOf(String conversationId) => _view(_conversation(conversationId), null);

  /// The ID of [user]'s membership of the conversation, which a removal and an addition make anew.
  String membershipOf(String conversationId, String user) =>
      _conversation(conversationId).members.firstWhere((member) => member['user_id'] == user)['id']! as String;

  /// The conversation's members change as the server alone changes them: these users join it, with no commit.
  void addMembers(String conversationId, List<String> users) {
    final conv = _conversation(conversationId);
    for (final user in users) {
      final at = _now();
      conv.members.add({'id': _id(), 'conversation_id': conv.id, 'user_id': user, 'created_at': at, 'updated_at': at});
    }
  }

  /// The conversation's members change as the server alone changes them: these users are taken out of it, with no
  /// commit and no statement, as a server that skips its rules would. The owner passes to the member who came first.
  void dropMembers(String conversationId, List<String> users) {
    final conv = _conversation(conversationId);
    conv.members = [
      for (final m in conv.members)
        if (!users.contains(m['user_id'])) m,
    ];
    if (users.contains(conv.ownerId) && conv.members.isNotEmpty) {
      conv.ownerId = conv.members.first['user_id']! as String;
    }
  }

  /// The conversation's owner, as a server that skips its rules names one: none of its members is told.
  void setOwner(String conversationId, String user) => _conversation(conversationId).ownerId = user;

  /// Two users become friends: each may claim the other's key packages and read their identity, as the API lets them.
  void befriend(String a, String b) => _friends.add(([a, b]..sort()).join(':'));

  /// A package complete for [to], from [from]'s first device, in [conversation], as a server that lists what it likes
  /// would have it: [parts] parts of a byte each, its size as said ([size], the parts' by default), no event and no
  /// notice. Its ID.
  String addShare({
    required String conversation,
    required String from,
    required String to,
    String kind = 'catch_up',
    String? range,
    int parts = 1,
    int? size,
  }) {
    final device = _devices.values.firstWhere((d) => d.user == from);
    final share = _Share(
      _id(),
      conversation,
      from,
      device.id,
      to,
      kind,
      range,
      DateTime.now().toUtc(),
      size ?? parts,
      parts,
    );
    for (var n = 0; n < parts; n++) {
      share.uploaded[n] = _keepFile(Uint8List(1));
    }
    share.completed = true;
    _shares[share.id] = share;
    return share.id;
  }

  /// Part [n] of the package grows by [bytes], as a storage that pads what it serves.
  void padSharePart(String shareId, int n, int bytes) {
    final file = _shares[shareId]!.uploaded[n]!;
    _files[file] = Uint8List.fromList([..._files[file]!, ...Uint8List(bytes)]);
  }

  /// The package listed again for [device], as if it never acknowledged it: a server that replays it.
  void unackShare(String shareId, String device) => _shares[shareId]!.acked.remove(device);

  /// Every message left in [device]'s inbox before (a rotation's transfers aside) left there again, each under a new
  /// ID, with its DEVICE_MESSAGE: a server that replays them.
  void replayInbox(String device) {
    for (final one in [..._delivered.where((one) => one.to == device)]) {
      _deliver(one.from, one.fromDevice, one.to, one.message);
    }
    final events = [..._outbox];
    _outbox.clear();
    Timer.run(() => _send(events));
  }

  bool _friendsWith(String a, String b) => _friends.contains(([a, b]..sort()).join(':'));

  /// Whether any listed device of the user's connected lately, as their identity's `active` says (decision 14).
  void setActive(String user, bool active) {
    if (active) {
      _inactive.remove(user);
    } else {
      _inactive.add(user);
    }
  }

  /// [user]'s membership made anew, as the API makes it when someone who left is added back: a new ID, after what came
  /// before it, with no commit (their device stays in the group).
  void rejoin(String conversationId, String user) {
    final conv = _conversation(conversationId);
    final at = _now();
    conv.members = [
      for (final member in conv.members)
        if (member['user_id'] == user)
          {'id': _id(), 'conversation_id': conv.id, 'user_id': user, 'created_at': at, 'updated_at': at}
        else
          member,
    ];
  }

  /// [count] encrypted messages of [author]'s, as the API lists them, whose bytes no device opens: rows only a page
  /// reads (a long absence's), in no event and no queue entry.
  void addOpaqueMessages(String conversationId, String author, int count) {
    final conv = _conversation(conversationId);
    for (var i = 0; i < count; i++) {
      final at = _now();
      conv.messages.add({
        'id': _id(),
        'conversation_id': conv.id,
        'author_id': author,
        'content': null,
        'type': 0,
        'created_at': at,
        'updated_at': at,
        'nonce': null,
        'ciphertext': base64Encode([i & 0xff]),
        'seq': ++conv.seq,
        'sent_at': DateTime.now().millisecondsSinceEpoch + sentAtOffset,
        'generation': conv.group?.generation ?? 0,
        'epoch': conv.group?.epoch ?? 0,
        'sender_device_id': null,
        'edited_at': null,
        'mentions': <String>[],
        'message_reference': null,
        'referenced_message': null,
        'attachment_ids': <String>[],
        'sticker_attachment_id': null,
      });
    }
  }

  /// A row of [author]'s in the conversation as a server lists one of its own making: of [type], with no number and no
  /// ciphertext, and a picture of the server's that a page and its event list. In the conversation's pages when
  /// [listed]; in no event (a test tells one). Its row.
  Map<String, Object?> addMadeUpRow(String conversationId, String author, {int type = 0, bool listed = true}) {
    final conv = _conversation(conversationId);
    final at = _now();
    final picture = _id();
    final row = <String, Object?>{
      'id': _id(),
      'conversation_id': conv.id,
      'author_id': author,
      'content': null,
      'type': type,
      'created_at': at,
      'updated_at': at,
      'attachments': [
        {
          'id': picture,
          'filename': 'words.png',
          'content_type': 'image/png',
          'size_bytes': 1,
          'created_at': at,
          'url': '/attachments/$picture',
        },
      ],
    };
    if (listed) conv.messages.add(row);
    return _clone(row);
  }

  /// The conversation is deleted, as the API deletes one: no list has it, and its routes answer 404.
  void deleteConversation(String conversationId) => _conversations.remove(_conversation(conversationId).id);

  /// The conversation's queue is whole only from [floor] on: a read from before it is a 410, as the API's once it
  /// expired.
  void expireQueue(String conversationId, int floor) => _conversation(conversationId).floor = floor;

  /// The device was last seen at [at] (an RFC 3339 time), as the API notes a device's requests.
  void lastSeen(String deviceId, String at) =>
      (_devices[deviceId] ?? (throw StateError('no device $deviceId'))).lastSeenAt = at;

  /// The device's registration goes, as a new password's remove_devices takes each one: the user's signed list still
  /// names it (step 3's ruling 23), with no certificate the API serves.
  void dropDevice(String deviceId) {
    final device = _devices[deviceId] ?? (throw StateError('no device $deviceId'));
    _removeDevices(device.user, [device]);
    final events = [..._outbox];
    _outbox.clear();
    Timer.run(() => _send(events));
  }

  /// The next request [match] takes never reaches the API: the client fails, and nothing is done.
  void cutRequest(RouteMatch match) => _switches.add((match: match, effect: _cut, always: false));

  /// The requests [match] takes wait until [count] of them have come, then go on in the order they came: once.
  void gather(RouteMatch match, int count) => _gates.add((match: match, count: count, waiting: []));

  /// The next request [match] takes does its work, and its answer is lost: the client fails, as with a cut connection.
  void loseAnswer(RouteMatch match) => _switches.add((match: match, effect: _lose, always: false));

  /// The next message [match] takes has its files go up, then its connection cut: the files stay up, on no message,
  /// and the message isn't taken.
  void cutAfterFiles(RouteMatch match) => _switches.add((match: match, effect: _cutAfterFiles, always: false));

  /// The next request [match] takes gets the API's own answer, and nothing it did is kept: what it stored goes back as
  /// it was, and the events it would send go nowhere. A server that says it took what it never took.
  void forget(RouteMatch match) => _switches.add((match: match, effect: _forget, always: false));

  /// The next request [match] takes is refused, and does nothing: 426 and 503 in the API's words (503 with its
  /// Retry-After), any other with the [body] given. A 2xx answered so is a server that says it did what it never did.
  /// Every request [match] takes from now on is answered so when [always].
  void refuse(
    RouteMatch match,
    int status, {
    Object? body,
    Map<String, String> headers = const {},
    bool always = false,
  }) {
    final own = switch (status) {
      426 => const _Answer(426, body: {'error': 'update Duvet', 'client': null, 'minimum': null}),
      503 => const _Answer(503, body: {'error': 'encrypted conversations are paused'}, headers: {'Retry-After': '60'}),
      _ => _Answer(status, body: body),
    };
    _switches.add((
      match: match,
      effect: _Answer(status, body: body ?? own.body, headers: {...own.headers, ...headers}),
      always: always,
    ));
  }

  /// How the API serves a user's identity, by both of its routes: as it is, unless a test has it lie, as a server
  /// could; null serves none (a 404, or left out of the list).
  Map<String, Object?>? Function(Map<String, Object?> view) servedAs = (view) => view;

  /// The user's identity as the API serves it now: one a test may have it serve again later ([servedAs]).
  Map<String, Object?> identityOf(String user) => _clone(_identityView(user));

  /// The server sends an event of its own making to the user's connections (to its [device]'s, when it names one).
  void tell(String user, GatewayEvent event, {String? device}) => _send([(user: user, device: device, event: event)]);

  /// A proposal to take the device's leaf out of the conversation's group, as the groups' external sender makes one
  /// but signed with [seed]'s key (the API's own unless a test gives another): queued, and heard by the members as
  /// the API's proposals are.
  void proposeRemoval(String conversationId, String deviceId, {Uint8List? seed}) {
    final conv = _conversation(conversationId);
    final group = conv.group;
    final held = group == null ? null : _groupInfoLeaves(base64Decode(group.groupInfo));
    final leaf = held?.leaves.entries.where((leaf) => leaf.value == deviceId).firstOrNull?.key;
    if (group == null || held == null || leaf == null) throw StateError('no leaf of $deviceId in $conversationId');
    final entry = _addEntry(conv, {
      'kind': 'proposal',
      'data': _removalProposal(held.groupId, held.epoch, leaf, seed: seed),
      'generation': group.generation,
      'epoch': group.epoch,
    });
    for (final member in conv.members) {
      _emit(member['user_id']! as String, 'MLS_PROPOSAL', {
        'conversation_id': conv.id,
        'generation': group.generation,
        'epoch': group.epoch,
        'entry': _forEvent(entry),
      });
    }
    final events = [..._outbox];
    _outbox.clear();
    Timer.run(() => _send(events));
  }

  /// The API serves the message as deleted (its queue's entry `deleted`, without its bytes, and GET …/messages/deleted
  /// names it), though its author never deleted it: no tombstone is queued.
  void markDeleted(String conversationId, String messageId) {
    final conv = _conversation(conversationId);
    final message =
        conv.messages.where((m) => m['id'] == messageId).firstOrNull ??
        (throw StateError('no message $messageId in $conversationId'));
    conv.deleted.add(messageId);
    message['ciphertext'] = null;
  }

  /// Events wait from now on, until [releaseEvents].
  void holdEvents() => _held ??= [];

  /// The events held, sent: in their order or backwards, and each once or twice. Then events go at once again, unless
  /// [only] picks those that go now: the others stay held, as does what comes after, until a release without it.
  void releaseEvents({bool reverse = false, bool repeat = false, bool Function(GatewayEvent event)? only}) {
    final held = _held;
    if (held == null) return;
    final going = only == null
        ? held
        : [
            for (final one in held)
              if (only(one.event)) one,
          ];
    _held = only == null
        ? null
        : [
            for (final one in held)
              if (!only(one.event)) one,
          ];
    for (final (:connection, :event) in reverse ? going.reversed : going) {
      for (var times = repeat ? 2 : 1; times > 0; times--) {
        connection.listener((type: event.type, data: _clone(event.data)));
      }
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Requests.

  /// The API, as an http.Client: a request to any of its routes gets the API's answer.
  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (_gates.where((g) => _matches(g.match, request.method, path)).firstOrNull case final gate?) {
      final held = Completer<void>();
      gate.waiting.add(held);
      if (gate.waiting.length == gate.count) {
        _gates.remove(gate);
        for (final go in gate.waiting) {
          go.complete();
        }
      }
      await held.future;
    }
    final switched = _switches.where((s) => _matches(s.match, request.method, path)).firstOrNull;
    if (switched != null && !switched.always) _switches.remove(switched);
    final effect = switched?.effect;
    if (effect == _cut) throw http.ClientException('the request never reached the API', request.url);
    if (effect case final _Answer answer) return _respond(answer);
    if (effect == _forget) {
      final putBack = _kept();
      final (answer, _) = _answer(request);
      putBack();
      return _respond(answer);
    }
    _cuttingAfterFiles = effect == _cutAfterFiles;
    final (answer, events) = _answer(request);
    // Its events go once its answer is made, lost or not: after the code that awaited it ran on.
    Timer.run(() => _send(events));
    if (effect == _lose) throw http.ClientException('the answer was lost', request.url);
    return _respond(answer);
  }

  /// What a request can change, copied as it is now: what it gives puts it back, as [forget] does once its answer is
  /// made.
  // shortcut: the conversations, the inboxes with what they deliver, and the shares alone, which the routes the tests
  // forget write (commits, edits, deletions, an inbox's message, a share's completion); add another route's state here
  // when a test forgets it.
  void Function() _kept() {
    final conversations = {for (final MapEntry(:key, :value) in _conversations.entries) key: value.copy()};
    final inboxes = {
      for (final MapEntry(:key, :value) in _inboxes.entries) key: [...value],
    };
    final (delivered, transfers) = ([..._delivered], {..._transfers});
    final shares = {for (final MapEntry(:key, :value) in _shares.entries) key: value.copy()};
    return () {
      _conversations
        ..clear()
        ..addAll(conversations);
      _inboxes
        ..clear()
        ..addAll(inboxes);
      _delivered
        ..clear()
        ..addAll(delivered);
      _transfers
        ..clear()
        ..addAll(transfers);
      _shares
        ..clear()
        ..addAll(shares);
    };
  }

  /// A request's answer, and the events it sends: none for a refusal, as the API's rolled-back work sends none.
  (_Answer, List<_Outgoing>) _answer(http.Request request) {
    final path = request.url.path;
    final route = _routes.where((r) => r.method == request.method && r.path.hasMatch(path)).firstOrNull;
    if (route == null) return (const _Answer(404, body: {'error': 'no such route'}), const []);
    try {
      // In the API's order: the session (401), the client (426), the device (403), then the body (400).
      final session = _session(request.headers, route.needs);
      if (route.needs != _Needs.nothing && !route.anyClient) _checkClient(request.headers);
      final device = session?.device == null ? null : _devices[session!.device];
      if ((route.needs == _Needs.device || route.needs == _Needs.listed) && (device == null || device.removed)) {
        throw _fail(403, 'this session has no device');
      }
      if (route.needs == _Needs.listed && !device!.listed) throw _fail(403, "this device isn't on your device list");
      Map<String, Object?>? body;
      var files = const <FormPart>[];
      if ((request.headers['content-type'] ?? '').contains('json') && request.bodyBytes.isNotEmpty) {
        try {
          body = asMap(jsonDecode(utf8.decode(request.bodyBytes)));
        } on FormatException {
          throw _fail(400, "the body isn't JSON");
        }
      } else if (formParts(request.headers['content-type'], request.bodyBytes) case final parts?) {
        // A form, as the API's binding reads it: a value once is its text, repeated a list; a part with a file name a
        // file, and one without a name none (Go's multipart reader can't open it).
        final form = formOf(parts);
        body = {
          for (final MapEntry(:key, :value) in form.values.entries) key: value.length == 1 ? value.single : value,
        };
        files = [
          for (final file in form.files)
            if (file.filename!.isNotEmpty) file,
        ];
      }
      final match = route.path.firstMatch(path)!;
      final params = {for (final name in match.groupNames) name: match.namedGroup(name)!};
      final ctx = _Context(
        session,
        device,
        params,
        request.url.queryParameters,
        body,
        request.bodyBytes,
        request.headers,
        request.url.queryParametersAll,
        files,
      );
      final answer = route.handler(ctx);
      final events = [..._outbox];
      _outbox.clear();
      return (answer, events);
    } on _Refusal catch (refusal) {
      _outbox.clear();
      return (refusal.answer, const []);
    }
  }

  _Session? _session(Map<String, String> headers, _Needs needs) {
    if (needs == _Needs.nothing) return null;
    final token = RegExp(r'^Bearer (.+)$').firstMatch(headers['authorization'] ?? '')?[1];
    final session = token == null ? null : _sessions[token];
    if (session == null) throw _fail(401, 'unauthorized');
    return session;
  }

  /// The client gate: a client without end-to-end encryption is told to update Duvet (426), in the API's words.
  void _checkClient(Map<String, String> headers) {
    final client = _clientIn(headers['x-duvet-client']);
    final least = client == null ? null : minClients[client.platform];
    final lowest = least == null ? null : _versionIn(least);
    if (client != null && lowest != null && _atLeast(client.version, lowest)) return;
    throw _fail(426, 'update Duvet', {
      'client': client == null ? null : '${client.platform}/${client.version.join('.')}',
      'minimum': least,
    });
  }

  /// An event the request sends, as its data is now: what this request or a later one changes after doesn't reach it.
  void _emit(String user, String type, Object? data, [String? device]) =>
      _outbox.add((user: user, device: device, event: (type: type, data: _clone(data))));

  /// Events to each connection of their user (of their device, when they name one), each its own copy; or held.
  void _send(List<_Outgoing> events) {
    for (final (:user, :device, :event) in events) {
      for (final connection in [..._connections]) {
        if (connection.user != user || (device != null && connection.device != device)) continue;
        if (_held case final held?) {
          held.add((connection: connection, event: event));
        } else {
          connection.listener((type: event.type, data: _clone(event.data)));
        }
      }
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The routes (PLAN-E2E-API.md, its routes A to K): under /api, the conversations' at /api/users/@me/conversations.
  // Every route that takes a session takes only a client with end-to-end encryption, but GET /api/e2e and the
  // conversations' list (anyClient), so a client without it still starts and sees its conversations.

  List<_Route> _table() {
    const me = '/api/users/@me';
    const conv = '$me/conversations/(?<conversation>$_uuidPath)';
    _Route route(
      String method,
      String path,
      _Needs needs,
      _Answer Function(_Context ctx) handler, {
      bool any = false,
    }) => (method: method, path: RegExp('^$path\$'), needs: needs, handler: handler, anyClient: any);
    return [
      route('GET', '/api/e2e', _Needs.session, any: true, (_) {
        return _ok({
          'external_sender': externalSender,
          'cutover_at': cutoverAt,
          'paused': false,
          'min_clients': minClients,
          'limits': _limits,
        });
      }),
      // The user's files, as their attachments' list gives them: a message's sealed files, which name nothing of it.
      route('GET', '$me/attachments', _Needs.session, any: true, (ctx) {
        return _ok([
          for (final a in _attachments.values)
            if (a.owner == ctx.me.user) _attachmentView(a),
        ]);
      }),
      route('POST', '/api/e2e/decrypt-failures', _Needs.session, (ctx) {
        decryptFailures.add((kind: '${ctx['kind']}', count: ctx['count'] ?? 1));
        return _noContent;
      }),
      // A sign-out ends its session, nothing else (decision 13): the device stays as it was.
      route('POST', '/api/auth/logout', _Needs.session, any: true, (ctx) {
        _sessions.remove(ctx.me.token);
        return _noContent;
      }),
      route('POST', '$me/devices/challenge', _Needs.session, (ctx) {
        ctx.me.challenge = _randomBytes(32);
        return _ok({'device_challenge': base64Encode(ctx.me.challenge)});
      }),
      route('POST', '$me/devices', _Needs.session, _registerDevice),
      route('POST', '$me/devices/(?<device>$_uuidPath)/bind', _Needs.session, _bindDevice),
      route('GET', '$me/devices', _Needs.session, (ctx) {
        return _ok([for (final device in _devicesOf(ctx.me.user)) _deviceView(device, ctx.me)]);
      }),
      route('DELETE', '$me/devices/(?<device>$_uuidPath)', _Needs.session, (ctx) {
        final device = _devices[ctx.params['device']];
        if (device == null || device.user != ctx.me.user || device.removed) throw _fail(404, 'device not found');
        if (device.listed) throw _fail(409, 'sign a device list without it');
        _removeDevices(ctx.me.user, [device]);
        return _noContent;
      }),
      route('PUT', '$me/identity', _Needs.device, _putIdentity),
      route('PUT', '$me/device-list', _Needs.device, _putDeviceList),
      route('GET', '$me/identity/backup', _Needs.device, (ctx) {
        final identity = _identities[ctx.me.user];
        if (identity == null) throw _fail(404, 'no identity');
        return _ok({
          'identity_key': base64Encode(identity.identityKey),
          'device_list': base64Encode(identity.deviceList),
          ...identity.backup,
        });
      }),
      route('GET', '/api/users/identities', _Needs.session, (ctx) {
        final ids = [
          for (final id in (ctx.query['ids'] ?? '').split(','))
            if (id.isNotEmpty) id,
        ];
        if (ids.length > 50 || ids.any((id) => !_uuid.hasMatch(id))) throw _fail(400, 'ids are 50 user IDs at most');
        return _ok([
          for (final id in ids)
            if (_identities.containsKey(id) && _mayRead(ctx.me.user, id)) ?servedAs(_identityView(id)),
        ]);
      }),
      route('GET', '/api/users/(?<user>$_uuidPath)/identity', _Needs.session, (ctx) {
        final user = ctx.params['user']!;
        if (!_users.contains(user) || !_mayRead(ctx.me.user, user)) {
          throw _fail(403, "you can't read this user's identity");
        }
        final served = _identities.containsKey(user) ? servedAs(_identityView(user)) : null;
        if (served == null) throw _fail(404, 'no identity');
        return _ok(served);
      }),
      route('PUT', '$me/devices/@me/key-packages', _Needs.listed, _uploadKeyPackages),
      route('POST', '/api/users/(?<user>$_uuidPath)/key-packages/claim', _Needs.listed, _claimKeyPackages),
      route('POST', '/api/devices/(?<device>$_uuidPath)/inbox', _Needs.device, _sendToInbox),
      route('GET', '$me/devices/@me/inbox', _Needs.device, (ctx) {
        final after = ctx.query['after'] ?? '';
        final limit = min(_positive(ctx.query['limit']) ?? 100, 100);
        return _ok(
          [
            for (final m in _inboxes[ctx.device!.id] ?? const <Map<String, Object?>>[])
              if ((m['id']! as String).compareTo(after) > 0) m,
          ].take(limit).toList(),
        );
      }),
      route('DELETE', '$me/devices/@me/inbox', _Needs.device, (ctx) {
        final through = _uuidIn(ctx.query['through'], 'through');
        _inboxes[ctx.device!.id] = [
          for (final m in _inboxes[ctx.device!.id] ?? const <Map<String, Object?>>[])
            if ((m['id']! as String).compareTo(through) > 0) m,
        ];
        return _noContent;
      }),
      route('GET', '$me/conversations', _Needs.session, any: true, (ctx) {
        return _ok([for (final c in _conversationsOf(ctx.me.user)) _view(c, ctx.device)]);
      }),
      route('POST', '$me/conversations', _Needs.session, _createConversation),
      route('GET', '$conv/mls/group-info', _Needs.listed, (ctx) {
        final group = _memberOf(ctx).group;
        if (group == null) throw _fail(404, 'no group yet');
        return _ok({'generation': group.generation, 'epoch': group.epoch, 'group_info': group.groupInfo});
      }),
      route('POST', '$conv/mls/commits', _Needs.listed, (ctx) => _ok(_commit(_memberOf(ctx), ctx, 'commits'), 201)),
      route('GET', '$conv/mls/queue', _Needs.device, _queueOf),
      route('POST', '$conv/members', _Needs.listed, _addMember),
      route('DELETE', '$conv/members/@me', _Needs.listed, _leave),
      route('DELETE', '$conv/members/(?<user>$_uuidPath)', _Needs.listed, _removeMember),
      route('POST', '$conv/messages', _Needs.listed, _sendMessage),
      // A page of the conversation's messages as the API lists them: the newest first, `count` of them (100 at most)
      // before `before`'s, the deleted left out.
      route('GET', '$conv/messages', _Needs.session, (ctx) {
        final conv = _memberOf(ctx);
        final before = ctx.query['before'];
        final count = min(_positive(ctx.query['count']) ?? 50, 100);
        return _ok(
          [
            for (final m in conv.messages.reversed)
              if (!conv.deleted.contains(m['id']) && (before == null || (m['id']! as String).compareTo(before) < 0)) m,
          ].take(count).toList(),
        );
      }),
      route('GET', '$conv/messages/search', _Needs.session, (ctx) => _search(_memberOf(ctx), ctx)),
      route('PUT', '$conv/pins/(?<message>$_uuidPath)', _Needs.session, (ctx) {
        // shortcut: no pin notice (type 2) is posted, as the API's pin posts one: the searches' tests read none.
        final conv = _memberOf(ctx);
        final id = ctx.params['message'];
        final message = conv.messages.where((m) => m['id'] == id && !conv.deleted.contains(id)).firstOrNull;
        if (message == null) throw _fail(404, 'direct message not found');
        message['pinned_at'] ??= _now();
        return _noContent;
      }),
      // A thread: its message, then those that answer it, oldest first.
      route('GET', '$conv/messages/(?<message>$_uuidPath)/thread', _Needs.session, (ctx) {
        final conv = _memberOf(ctx);
        final root = ctx.params['message'];
        return _ok([
          for (final m in conv.messages)
            if (!conv.deleted.contains(m['id']) && (m['id'] == root || _repliesTo[m['id']] == root)) m,
        ]);
      }),
      route('GET', '$conv/messages/(?<message>$_uuidPath)', _Needs.session, (ctx) {
        final conv = _memberOf(ctx);
        final id = ctx.params['message'];
        final message = conv.messages.where((m) => m['id'] == id && !conv.deleted.contains(id)).firstOrNull;
        if (message == null) throw _fail(404, 'direct message not found');
        return _ok(message);
      }),
      route('GET', '$conv/messages/deleted', _Needs.session, (ctx) {
        final after = ctx.query['after'] ?? '';
        final limit = min(_positive(ctx.query['limit']) ?? 1000, 1000);
        return _ok({
          'ids': ([
            for (final id in _memberOf(ctx).deleted)
              if (id.compareTo(after) > 0) id,
          ]..sort()).take(limit).toList(),
        });
      }),
      route('PATCH', '$conv/messages/(?<message>$_uuidPath)', _Needs.session, (ctx) => _changeMessage(ctx, 'edit')),
      route('DELETE', '$conv/messages/(?<message>$_uuidPath)', _Needs.session, (ctx) => _changeMessage(ctx, 'delete')),
      route('PUT', '$conv/history-shares/(?<share>$_uuidPath)', _Needs.listed, _putShare),
      route('PUT', '$conv/history-shares/(?<share>$_uuidPath)/parts/(?<n>\\d+)', _Needs.listed, (ctx) {
        final share = _ownShare(ctx);
        final n = int.parse(ctx.params['n']!);
        if (n >= share.parts) throw _fail(400, 'the share has ${share.parts} parts');
        if (ctx.bytes.length > _limit('history_share_part_bytes')) {
          throw _fail(413, 'a part is 1 MiB and its tag at most');
        }
        // The same bytes again change nothing, as the API's (a part sent again); other bytes are a 409.
        if (share.uploaded[n] case final up?) {
          if (sha256.convert(_files[up]!) != sha256.convert(ctx.bytes)) {
            throw _fail(409, 'the part is up with other bytes');
          }
          return _noContent;
        }
        share.uploaded[n] = _keepFile(ctx.bytes);
        return _noContent;
      }),
      route('POST', '$conv/history-shares/(?<share>$_uuidPath)/complete', _Needs.listed, _completeShare),
      // The oldest 100 the device hasn't acknowledged, as the API's page: the next once those are.
      route('GET', '$me/history-shares', _Needs.device, (ctx) {
        final unacked = [
          for (final share in _shares.values)
            if (share.completed && share.toUser == ctx.me.user && !share.acked.contains(ctx.device!.id)) share,
        ]..sort((a, b) => a.id.compareTo(b.id));
        return _ok([for (final share in unacked.take(100)) _shareView(share)]);
      }),
      route('GET', '/api/history-shares/(?<share>$_uuidPath)/parts/(?<n>\\d+)', _Needs.session, (ctx) {
        final share = _shares[ctx.params['share']];
        final file = share?.uploaded[int.parse(ctx.params['n']!)];
        if (share == null || file == null || ![share.toUser, share.fromUser].contains(ctx.me.user)) {
          throw _fail(404, 'no such part');
        }
        return _ok({'url': _signedPath(file)});
      }),
      route('POST', '/api/history-shares/(?<share>$_uuidPath)/ack', _Needs.device, (ctx) {
        final share = _shares[ctx.params['share']];
        if (share == null || !share.completed || share.toUser != ctx.me.user) throw _fail(404, 'no such share');
        share.acked.add(ctx.device!.id);
        return _noContent;
      }),
      route('GET', '$me/backup/segments', _Needs.device, (ctx) {
        final identity = _identities[ctx.me.user];
        final after = ctx.query['after'] ?? '';
        final conversation = ctx.query['conversation_id'];
        return _ok(
          [
            for (final s in _segments.values)
              if (s.identity == identity?.id &&
                  s.id.compareTo(after) > 0 &&
                  (conversation == null || conversation.isEmpty || s.conversationId == conversation) &&
                  _shownSegment(ctx.me.user, s))
                {
                  'id': s.id,
                  'conversation_id': s.conversationId,
                  'day': s.day,
                  'complete': s.complete,
                  'key_id': s.keyId,
                  'size': s.size,
                  'created_at': s.createdAt,
                },
          ].take(1000).toList(),
        );
      }),
      route(
        'PUT',
        '$me/backup/segments/(?<conversation>$_uuidPath)/(?<day>\\d{4}-\\d{2}-\\d{2})',
        _Needs.listed,
        _putSegment,
      ),
      route('GET', '$me/backup/segments/(?<segment>$_uuidPath)', _Needs.device, (ctx) {
        final segment = _segments[ctx.params['segment']];
        final own = segment != null && segment.identity == _identities[ctx.me.user]?.id;
        if (!own || !_shownSegment(ctx.me.user, segment)) throw _fail(404, 'segment not found');
        return _ok({'url': _signedPath(segment.file)});
      }),
      // A file at the signed path the part's and the segment's routes answer, as the API serves one: with its
      // signature, before it expires, and with no session.
      route('GET', '/attachments/(?<file>$_uuidPath)', _Needs.nothing, (ctx) {
        final (sig, exp) = (ctx.query['sig'] ?? '', ctx.query['exp'] ?? '');
        if (sig.isEmpty || exp.isEmpty) throw _fail(403, 'invalid or expired signature');
        final until = int.tryParse(exp);
        if (until == null) throw _fail(400, 'invalid expiry');
        final file = ctx.params['file']!;
        if (until < _unixNow() || sig != _signature(file, until)) throw _fail(403, 'invalid or expired signature');
        final bytes = _files[file];
        if (bytes == null) throw _fail(404, 'no such file');
        return _Answer(200, body: bytes);
      }),
    ];
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Devices and sessions.

  /// A bind proof's word that the session is this device's: its fields, once its device's key signed them.
  void _checkProof(_Session session, String deviceId, Uint8List signatureKey, Uint8List hpkeKey, Uint8List proof) {
    final body = _signedBody(_bindLabel, proof, signatureKey);
    final challenge = asBytes(body?['challenge'], 32);
    final key = asBytes(body?['hpke_key'], 32);
    final fits = asUuid(body?['user']) == session.user && asUuid(body?['device']) == deviceId;
    if (!fits || challenge == null || !_equal(challenge, session.challenge) || key == null || !_equal(key, hpkeKey)) {
      throw _fail(403, "the proof doesn't verify");
    }
    // The challenge is spent.
    session.challenge = _randomBytes(32);
  }

  _Answer _registerDevice(_Context ctx) {
    final session = ctx.me;
    final id = _uuidIn(ctx['device_id'], 'device_id');
    final name = ctx['name'];
    if (name is! String || name.isEmpty || name.length > 64) {
      throw _fail(400, 'a device has a name of 64 characters at most');
    }
    final signatureKey = _bytesIn(ctx['signature_key'], 'signature_key', max: 32);
    final hpkeKey = _bytesIn(ctx['hpke_key'], 'hpke_key', max: 32);
    if (signatureKey.length != 32 || hpkeKey.length != 32) throw _fail(400, "a device's keys are 32 bytes");
    final known = _devices[id];
    final same = known != null && known.user == session.user && !known.removed;
    if (known != null && !(same && _equal(known.signatureKey, signatureKey) && _equal(known.hpkeKey, hpkeKey))) {
      throw _fail(409, 'device id in use');
    }
    _checkProof(session, id, signatureKey, hpkeKey, _bytesIn(ctx['proof'], 'proof', max: 1024));
    session.device = id;
    if (known != null) return _ok(_deviceView(known, session));
    final device = _Device(id, session.user, name, ctx.headers['x-duvet-client'], signatureKey, hpkeKey, _now());
    _devices[id] = device;
    _emit(session.user, 'DEVICE_ADD', _deviceView(device, null));
    return _ok(_deviceView(device, session), 201);
  }

  _Answer _bindDevice(_Context ctx) {
    final device = _devices[ctx.params['device']];
    if (device == null || device.user != ctx.me.user || device.removed) throw _fail(404, 'device not found');
    _checkProof(ctx.me, device.id, device.signatureKey, device.hpkeKey, _bytesIn(ctx['proof'], 'proof', max: 1024));
    ctx.me.device = device.id;
    return _noContent;
  }

  List<_Device> _devicesOf(String user) => [
    for (final device in _devices.values)
      if (device.user == user && !device.removed) device,
  ];

  Map<String, Object?> _deviceView(_Device device, _Session? session, {bool? listed}) => {
    'id': device.id,
    'name': device.name,
    'client': device.client,
    'created_at': device.createdAt,
    'last_seen_at': device.lastSeenAt,
    'listed': listed ?? device.listed,
    'current': session?.device == device.id,
  };

  /// Devices taken out: their sessions end, and their key packages and inbox go, as the API does.
  void _removeDevices(String user, List<_Device> devices) {
    for (final device in devices) {
      device.removed = true;
      device.listed = false;
      _keyPackages.remove(device.id);
      _inboxes.remove(device.id);
      _sessions.removeWhere((_, session) => session.device == device.id);
      // shortcut: no removal of its leaves is proposed (that takes the validator); a test that needs one posts it.
      _emit(user, 'DEVICE_REMOVE', {'device_id': device.id});
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Identities and device lists.

  /// Who may read a user's identity, as the API's GetIdentities: themselves, a friend, whoever shares a conversation
  /// with them, and the members of a conversation where a device of theirs has had a leaf, who may have left it.
  bool _mayRead(String viewer, String user) =>
      viewer == user ||
      _friendsWith(viewer, user) ||
      _shareConversation(viewer, user) ||
      _conversationsOf(viewer).any((conv) => conv.leaves.keys.any((id) => _devices[id]?.user == user));

  Map<String, Object?> _identityView(String user) {
    final identity = _identities[user]!;
    final list = _readDeviceList(identity.deviceList, identity.identityKey)!;
    return {
      'user_id': user,
      'identity_key': base64Encode(identity.identityKey),
      'device_list': base64Encode(identity.deviceList),
      'device_list_version': identity.version,
      // The listed devices' certificates of this identity, as the API serves them: never a removed device's, which a
      // new password's remove_devices leaves on the signed list (step 3's ruling 23).
      'certificates': [
        for (final id in list.devices)
          if (_devices[id] case final device?
              when device.listed && !device.removed && device.certifiedBy == identity.id)
            base64Encode(device.certificate!),
      ],
      // Active, as if a listed device connected lately, unless a test of deviceless members says not (setActive).
      'active': !_inactive.contains(user),
      'changed_at': identity.changedAt,
    };
  }

  /// A device list of the user's own, signed by [identityKey], naming this device, 20 devices at most.
  _DeviceList _readList(_Session session, _Device device, Uint8List identityKey, Uint8List signed) {
    final list = _readDeviceList(signed, identityKey);
    if (list == null) throw _fail(400, "the device list isn't signed by the identity key");
    if (list.user != session.user) throw _fail(400, "the device list is another user's");
    if (list.devices.length > _limit('listed_devices')) throw _fail(400, 'a device list names 20 devices at most');
    if (!list.devices.contains(device.id)) throw _fail(400, "the device list doesn't name this session's device");
    return list;
  }

  /// A certificate from [identityKey] for one of the user's devices, carrying the keys that device registered.
  void _checkCertificate(String user, String deviceId, Uint8List identityKey, Uint8List signed) {
    final device = _devices[deviceId];
    final said = _readCertificate(signed, identityKey);
    if (device == null || device.user != user || device.removed) {
      throw _fail(400, "device $deviceId isn't a registered device of yours");
    }
    if (said == null || said.user != user || said.device != deviceId) {
      throw _fail(400, "the certificate for device $deviceId doesn't verify as the identity's for it");
    }
    if (!_equal(said.signatureKey, device.signatureKey) || !_equal(said.hpkeKey, device.hpkeKey)) {
      throw _fail(400, "the certificate for device $deviceId doesn't carry the keys it registered");
    }
  }

  _Answer _putIdentity(_Context ctx) {
    final (session, device) = (ctx.me, ctx.device!);
    final identityKey = _bytesIn(ctx['identity_key'], 'identity_key', max: 32);
    final deviceList = _bytesIn(ctx['device_list'], 'device_list', max: _limit('device_list_bytes'));
    final certificate = _bytesIn(ctx['certificate'], 'certificate', max: _limit('certificate_bytes'));
    for (final field in ['encrypted_identity', 'wrapped_backup_key']) {
      _bytesIn(ctx[field], field, max: 1024);
    }
    final replaces = ctx['replaces'] == null ? null : _bytesIn(ctx['replaces'], 'replaces', max: 32);
    final transfers = _transfersIn(ctx['transfers']);
    final list = _readList(session, device, identityKey, deviceList);
    final current = _identities[session.user];
    final sameKey = current != null && _equal(identityKey, current.identityKey);
    final replacesCurrent = current != null && replaces != null && _equal(replaces, current.identityKey);
    // PUT …/identity's four cases: the first, the same one again, a rotation, or starting over (reset).
    final change = sameKey
        ? 'same'
        : current == null && replaces == null
        ? 'first'
        : replacesCurrent
        ? (ctx['reset'] == true ? 'reset' : 'rotation')
        : null;
    if (change == null) {
      throw _fail(409, 'identity changed', {
        'identity_key': current == null ? null : base64Encode(current.identityKey),
      });
    }
    if (change == 'rotation' && !device.listed) throw _fail(403, "this device isn't on your device list");
    if (change != 'same' && list.version != 1) throw _fail(400, "a new identity's device list is version 1");
    if ((change == 'first' || change == 'reset') && transfers.isNotEmpty) {
      throw _fail(
        400,
        "only a rotation brings transfers: a first identity and starting over certify this session's device alone",
      );
    }
    // Each device of the list gets its certificate: the session's own, and every other one through its transfer.
    final certificates = {device.id: certificate};
    _checkCertificate(session.user, device.id, identityKey, certificate);
    for (final transfer in transfers) {
      final id = transfer.deviceId;
      if (certificates.containsKey(id) || !list.devices.contains(id)) {
        throw _fail(400, "a transfer for device $id the list doesn't take");
      }
      final signed = base64Decode(transfer.certificate);
      _checkCertificate(session.user, id, identityKey, signed);
      certificates[id] = signed;
    }
    if (list.devices.any((id) => !certificates.containsKey(id))) {
      throw _fail(400, 'the list names a device with no transfer for it');
    }

    var identity = current;
    if (change != 'same') {
      // The backup key its encrypted identity names, in the clear as the core writes it: a new one, as the API's
      // AddBackupKey takes one. A rotation and starting over retire the user's keys now (RetireBackupKeys).
      final keyId = _backupKeyOf(ctx['encrypted_identity']);
      if (keyId == null) throw _fail(400, "the encrypted identity doesn't name the backup key it's sealed with");
      final keys = _backupKeys[session.user] ??= (retired: <String, DateTime?>{}, resets: <DateTime>[]);
      if (keys.retired.containsKey(keyId)) {
        throw _fail(400, 'the encrypted identity is sealed with a backup key you had before');
      }
      final at = DateTime.now().toUtc();
      for (final MapEntry(:key, :value) in [...keys.retired.entries]) {
        if (value == null) keys.retired[key] = at;
      }
      if (change == 'reset') keys.resets.add(at);
      keys.retired[keyId] = null;
      identity = _Identity(_id(), identityKey, deviceList, list.version, _now(), {
        'encrypted_identity': ctx['encrypted_identity'],
        'wrapped_backup_key': ctx['wrapped_backup_key'],
        'wrapped_previous_backup_keys': ctx['wrapped_previous_backup_keys'],
      });
      _identities[session.user] = identity;
      // A rotation carries the backup on, each segment under the key that sealed it (MoveBackupSegments); starting over
      // leaves it with the identity it replaced.
      if (change == 'rotation') {
        for (final segment in _segments.values) {
          if (segment.identity == current!.id) segment.identity = identity.id;
        }
      }
      final off = <_Device>[];
      for (final own in _devicesOf(session.user)) {
        if (certificates[own.id] case final signed?) {
          own
            ..certificate = signed
            ..certifiedBy = identity.id
            ..listed = true;
        } else if (own.listed && change == 'rotation') {
          off.add(own);
        } else {
          own.listed = false;
        }
      }
      _removeDevices(session.user, off);
    }
    for (final transfer in transfers) {
      _deliver(session.user, device.id, transfer.deviceId, transfer.message, transfer: true);
    }
    if (change != 'same') _announceIdentity(session.user);
    return _ok({'identity_id': identity!.id, 'device_list_version': identity.version});
  }

  _Answer _putDeviceList(_Context ctx) {
    final (session, device) = (ctx.me, ctx.device!);
    final current = _identities[session.user];
    if (current == null) throw _fail(404, 'no identity');
    final signed = _bytesIn(ctx['device_list'], 'device_list', max: _limit('device_list_bytes'));
    if (_equal(signed, current.deviceList)) return _ok({'version': current.version});
    final list = _readList(session, device, current.identityKey, signed);
    if (ctx['base_version'] != current.version || list.version <= current.version) {
      throw _fail(409, 'device list changed', {
        'device_list': base64Encode(current.deviceList),
        'version': current.version,
      });
    }
    final certificate = ctx['certificate'] == null
        ? null
        : _bytesIn(ctx['certificate'], 'certificate', max: _limit('certificate_bytes'));
    if (certificate != null) _checkCertificate(session.user, device.id, current.identityKey, certificate);
    for (final id in list.devices) {
      final listed = _devices[id];
      final ofThisIdentity = listed != null && !listed.removed && listed.certifiedBy == current.id;
      if (!ofThisIdentity && !(certificate != null && id == device.id)) {
        throw _fail(400, 'the list names device $id, which has no certificate of this identity');
      }
    }
    if (certificate != null) {
      device
        ..certificate = certificate
        ..certifiedBy = current.id;
    }
    current
      ..deviceList = signed
      ..version = list.version;
    final off = <_Device>[];
    for (final own in _devicesOf(session.user)) {
      final listed = list.devices.contains(own.id);
      if (listed && !own.listed) _emit(session.user, 'DEVICE_ADD', _deviceView(own, null, listed: true));
      if (!listed && own.listed) off.add(own);
      own.listed = listed;
    }
    _removeDevices(session.user, off);
    _announceIdentity(session.user);
    return _ok({'version': list.version});
  }

  /// IDENTITY_UPDATE, to the user and whoever shares a conversation with them.
  void _announceIdentity(String user) {
    final identity = _identities[user]!;
    final update = {
      'user_id': user,
      'identity_key': base64Encode(identity.identityKey),
      'device_list_version': identity.version,
    };
    for (final to in _peopleOf(user)) {
      _emit(to, 'IDENTITY_UPDATE', update);
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Key packages and the inbox.

  _Answer _uploadKeyPackages(_Context ctx) {
    final device = ctx.device!;
    // The whole set, as the API binds it: an empty one takes them all away, and none at all is refused.
    final uploaded = ctx['key_packages'];
    if (uploaded is! List) throw _fail(400, "key_packages is the device's whole set");
    Object? field(Object? kp, String name) => kp is Map ? kp[name] : null;
    final set = [
      for (final kp in uploaded)
        (
          id: _base64In(field(kp, 'id'), 'key_packages.id', max: 64, min: 1),
          data: _base64In(field(kp, 'data'), 'key_packages.data', max: _limit('key_package_bytes'), min: 1),
          expiresAt: _numberIn(field(kp, 'expires_at'), 'expires_at'),
          lastResort: field(kp, 'last_resort') == true,
        ),
    ];
    final lastResorts = set.where((kp) => kp.lastResort).length;
    if (set.length - lastResorts > _limit('key_packages') || lastResorts > _limit('last_resort_key_packages')) {
      throw _fail(400, 'a device keeps 100 single-use key packages and 1 of last resort at most');
    }
    if ({for (final kp in set) kp.id}.length != set.length) throw _fail(400, 'a key package is there twice');
    final kept = _keyPackages[device.id] ?? <String, _KeyPackage>{};
    // What the new set leaves out goes, but the single-use ones handed out: those are never handed out again.
    final ids = {for (final kp in set) kp.id};
    kept.removeWhere((id, kp) => !ids.contains(id) && (!kp.handedOut || kp.lastResort));
    for (final kp in set) {
      kept.putIfAbsent(kp.id, () => _KeyPackage(kp.data, kp.expiresAt, kp.lastResort));
    }
    _keyPackages[device.id] = kept;
    return _ok({
      'handed_out': [
        for (final kp in set)
          if (!kp.lastResort && kept[kp.id]!.handedOut) kp.id,
      ],
    });
  }

  _Answer _claimKeyPackages(_Context ctx) {
    final (session, device, user) = (ctx.me, ctx.device!, ctx.params['user']!);
    if (!_users.contains(user)) throw _fail(404, 'user not found');
    if (user != session.user && !_friendsWith(session.user, user) && !_shareConversation(session.user, user)) {
      throw _fail(
        403,
        "only your own key packages, a friend's, or those of someone you share a conversation with can be claimed",
      );
    }
    final notBefore = DateTime.now().millisecondsSinceEpoch + _keyPackageMargin;
    final handed = <Map<String, Object?>>[];
    final devices = [
      for (final d in _devicesOf(user))
        if (d.listed && d.id != device.id) d,
    ]..sort((a, b) => a.id.compareTo(b.id));
    for (final listed in devices) {
      final live = [
        for (final entry in (_keyPackages[listed.id] ?? const <String, _KeyPackage>{}).entries)
          if (entry.value.expiresAt > notBefore) entry,
      ];
      final single =
          [
            for (final entry in live)
              if (!entry.value.lastResort && !entry.value.handedOut) entry,
          ]..sort(
            (a, b) => a.value.expiresAt != b.value.expiresAt
                ? a.value.expiresAt.compareTo(b.value.expiresAt)
                : a.key.compareTo(b.key),
          );
      final pick =
          single.firstOrNull ??
          ([
            for (final entry in live)
              if (entry.value.lastResort) entry,
          ]..sort((a, b) => b.value.expiresAt.compareTo(a.value.expiresAt))).firstOrNull;
      // What it has left to hand out after this claim: 0 when it had none, which it hears too.
      final remaining = max(0, single.length - 1);
      if (remaining < _keyPackagesLow) {
        _emit(user, 'KEY_PACKAGES_LOW', {'device_id': listed.id, 'remaining': remaining}, listed.id);
      }
      if (pick == null) continue;
      pick.value.handedOut = true;
      handed.add({'device_id': listed.id, 'data': pick.value.data});
    }
    return _ok({'key_packages': handed});
  }

  _Answer _sendToInbox(_Context ctx) {
    final (session, device) = (ctx.me, ctx.device!);
    final message = _bytesIn(ctx['message'], 'message');
    if (message.isEmpty || message.length > _limit('inbox_message_bytes')) {
      throw _fail(400, 'a message to a device is 64 KiB at most');
    }
    final to = _devices[ctx.params['device']];
    if (to == null || to.removed) throw _fail(404, 'device not found');
    if (to.user != session.user && !_shareConversation(session.user, to.user)) {
      throw _fail(403, 'only your own devices, and those of someone you share a conversation with, take your messages');
    }
    // A rotation's transfer counts toward no cap.
    final waiting = (_inboxes[to.id] ?? const []).where((m) => !_transfers.contains(m['id']));
    if (waiting.length >= _inboxMax) throw _fail(409, 'inbox full');
    return _ok({'id': _deliver(session.user, device.id, to.id, ctx['message']! as String)}, 201);
  }

  /// A message into a device's inbox, and DEVICE_MESSAGE to it: the message's ID. A rotation's transfer takes the place
  /// of the device's earlier ones: only the newest is of use, as the API keeps it.
  String _deliver(String from, String fromDevice, String to, String message, {bool transfer = false}) {
    final device = _devices[to];
    if (device == null) return '';
    final id = _id();
    if (!transfer) _delivered.add((from: from, fromDevice: fromDevice, to: to, message: message));
    _inboxes[to] = [
      for (final m in _inboxes[to] ?? const <Map<String, Object?>>[])
        if (!transfer || !_transfers.contains(m['id'])) m,
      {'id': id, 'from_user_id': from, 'from_device_id': fromDevice, 'message': message, 'created_at': _now()},
    ];
    if (transfer) _transfers.add(id);
    _emit(device.user, 'DEVICE_MESSAGE', {'device_id': to, 'id': id}, to);
    return id;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Conversations, their groups and their queue.

  List<_Conversation> _conversationsOf(String user) => [
    for (final conv in _conversations.values)
      if (conv.members.any((m) => m['user_id'] == user)) conv,
  ];

  bool _shareConversation(String a, String b) =>
      _conversationsOf(a).any((conv) => conv.members.any((m) => m['user_id'] == b));

  /// The user and everyone they share a conversation with.
  Set<String> _peopleOf(String user) => {
    user,
    for (final conv in _conversationsOf(user))
      for (final m in conv.members) m['user_id']! as String,
  };

  _Conversation _memberOf(_Context ctx) {
    final conv = _conversations[ctx.params['conversation']];
    if (conv == null) throw _fail(404, 'conversation not found');
    if (!conv.members.any((m) => m['user_id'] == ctx.me.user)) {
      throw _fail(403, "you aren't a member of this conversation");
    }
    return conv;
  }

  /// A conversation as its object shows it: legacy, and its group (mls), with where this device joined it.
  Map<String, Object?> _view(_Conversation conv, _Device? device) {
    final group = conv.group;
    return {
      'id': conv.id,
      'type': conv.type,
      'name': null,
      'owner_id': conv.ownerId,
      'created_at': conv.createdAt,
      'updated_at': conv.createdAt,
      'deleted_at': null,
      // Each with the public profile the API's listing gives, which the app draws a member by.
      'members': [
        for (final member in conv.members)
          {
            ..._clone(member),
            'user': {'id': member['user_id'], 'username': 'u${(member['user_id']! as String).substring(0, 8)}'},
          },
      ],
      'legacy': conv.legacy,
      'mls': group == null
          ? null
          : {
              'generation': group.generation,
              'epoch': group.epoch,
              'last_seq': conv.seq,
              'floor_seq': conv.floor,
              'joined_seq': device == null ? null : conv.leaves[device.id],
            },
    };
  }

  /// An entry of the conversation's queue, under its next number.
  Map<String, Object?> _addEntry(_Conversation conv, Map<String, Object?> entry) {
    final added = {'seq': ++conv.seq, 'sent_at': DateTime.now().millisecondsSinceEpoch + sentAtOffset, ...entry};
    conv.entries.add(added);
    return added;
  }

  /// An entry as an event carries it: without its data past 16 KiB, or when the switch says so.
  Map<String, Object?> _forEvent(Map<String, Object?> entry) =>
      stripData || base64Decode(entry['data']! as String).length > _maxEventData ? ({...entry}..remove('data')) : entry;

  /// A message as the queue's entry it is: its data its ciphertext, emptied once it's deleted; whom it mentions, by
  /// their IDs in order, which its deletion takes away; and what it answers.
  Map<String, Object?> _messageEntry(Map<String, Object?> m) {
    final deleted = _conversations[m['conversation_id']]?.deleted.contains(m['id']) ?? false;
    final mentions = deleted ? <String>[] : ([...(m['mentions'] as List? ?? const []).cast<String>()]..sort());
    return {
      'seq': m['seq'],
      'kind': 'message',
      'data': m['ciphertext'] ?? '',
      'sent_at': m['sent_at'],
      'generation': m['generation'],
      'epoch': m['epoch'],
      'message_id': m['id'],
      'sender_user': m['author_id'],
      'sender_device': m['sender_device_id'],
      if (deleted) 'deleted': true,
      if (mentions.isNotEmpty) 'mentions': mentions,
      'reply_to': ?_repliesTo[m['id']],
    };
  }

  /// The queue as a member reads it, or as someone a removal took out does: up to its commit, while the queue holds
  /// that, so their devices apply their own removal (the API's MlsService.Queue).
  _Answer _queueOf(_Context ctx) {
    final viewer = ctx.me.user;
    final conv = _conversations[ctx.params['conversation']];
    final departure = conv?.departures[viewer];
    if (conv == null || departure == null || conv.members.any((m) => m['user_id'] == viewer)) {
      return _queue(_memberOf(ctx), ctx.query, viewer);
    }
    return _queue(conv, ctx.query, viewer, through: departure);
  }

  _Answer _queue(_Conversation conv, Map<String, String> query, String viewer, {int? through}) {
    // As the API binds them (its MlsQueueQuery): a number from 0, and 1 to 500 of them.
    final after = query.containsKey('after') ? int.tryParse(query['after']!) : 0;
    final limit = query.containsKey('limit') ? int.tryParse(query['limit']!) : 200;
    if (after == null || after < 0) throw _fail(400, 'after is a number from 0');
    if (limit == null || limit < 1 || limit > 500) throw _fail(400, 'limit is 1 to 500');
    final group = conv.group;
    if (group == null) throw _fail(404, 'no group yet');
    if (through != null && through < conv.floor) throw _fail(403, "you aren't a member of this conversation");
    final last = min(through ?? conv.seq, conv.seq);
    if (after + 1 < conv.floor) throw _fail(410, 'queue expired', {'floor_seq': conv.floor});
    final all = [
      ...conv.entries,
      for (final m in conv.messages)
        if (m['seq'] != null) _messageEntry(m),
    ]..sort((a, b) => (a['seq']! as int).compareTo(b['seq']! as int));
    final entries = <Map<String, Object?>>[];
    var size = 0;
    for (final entry in all.where((e) => (e['seq']! as int) > after && (e['seq']! as int) <= last)) {
      size += (entry['data']! as String).length;
      if (entries.length == limit || (entries.isNotEmpty && size > 4 << 20)) break;
      entries.add(_shownTo(viewer, entry));
    }
    return _ok({
      'entries': entries,
      'last_seq': last,
      'floor_seq': conv.floor,
      'generation': group.generation,
      'epoch': group.epoch,
    });
  }

  /// A conversation's search, as the API answers it (ConversationController.SearchMessages): never by words, which it
  /// can't read; by what it keeps in the clear, its author, whom its sender says it mentions, when, whether it's
  /// pinned, and whether it has a file or a sticker. Its encrypted messages, newest first, a page after `cursor`.
  _Answer _search(_Conversation conv, _Context ctx) {
    List<String> all(String key) => ctx.queryAll[key] ?? const [];
    if ((ctx.query['query'] ?? '').trim().isNotEmpty) throw _fail(400, 'search conversations on the device');
    if (all('room_id').isNotEmpty) throw _fail(400, "room_id doesn't apply to a conversation");
    final has = all('has');
    if (has.any((value) => value != 'file' && value != 'sticker')) {
      throw _fail(400, 'in a conversation, has takes file and sticker');
    }
    final (authors, mentions) = (all('author_id'), all('mentions'));
    final (pinned, after, before) = (ctx.query['pinned'], ctx.query['after'], ctx.query['before']);
    if (authors.isEmpty && mentions.isEmpty && has.isEmpty && pinned == null && after == null && before == null) {
      throw _fail(400, 'a search needs some text or a filter');
    }
    DateTime at(Object? time) => DateTime.parse(time! as String);
    final found = [
      for (final m in conv.messages)
        if (m['seq'] != null &&
            !conv.deleted.contains(m['id']) &&
            (authors.isEmpty || authors.contains(m['author_id'])) &&
            (mentions.isEmpty || (m['mentions'] as List? ?? const []).any(mentions.contains)) &&
            (has.isEmpty ||
                (has.contains('sticker') && m['sticker_attachment_id'] != null) ||
                (has.contains('file') && (m['attachment_ids'] as List? ?? const []).isNotEmpty)) &&
            (pinned == null || (m['pinned_at'] != null) == (pinned == 'true')) &&
            (after == null || !at(m['created_at']).isBefore(at(after))) &&
            (before == null || at(m['created_at']).isBefore(at(before))))
          m,
    ]..sort((a, b) => (b['id']! as String).compareTo(a['id']! as String));
    final cursor = ctx.query['cursor'];
    final limit = min(max(int.tryParse(ctx.query['limit'] ?? '') ?? 25, 1), 50);
    return _ok({
      'total_results': min(found.length, 1000),
      'messages': [
        for (final m in found)
          if (cursor == null || (m['id']! as String).compareTo(cursor) < 0) m,
      ].take(limit).toList(),
    });
  }

  /// A commit into the conversation's group (POST …/mls/commits, and the members routes'): its framing is what the
  /// request says, the same bytes again get the answer they got, and it's taken only on the group's generation and
  /// epoch (a creation's on the generation after, or the first). Its welcome's devices join from the welcome's entry,
  /// an external commit's device from the commit's; its entries go out as MLS_COMMIT and MLS_WELCOME.
  Map<String, Object?> _commit(_Conversation conv, _Context ctx, String route) {
    final (session, device) = (ctx.me, ctx.device!);
    final generation = _numberIn(ctx['generation'], 'generation');
    final epoch = _numberIn(ctx['epoch'], 'epoch');
    final commit = _bytesIn(ctx['commit'], 'commit', max: _limit('commit_bytes'));
    final create = ctx['initial_group_info'] != null;
    final welcome = ctx['welcome'] == null ? null : _bytesIn(ctx['welcome'], 'welcome', max: _limit('welcome_bytes'));
    final framed = _framing(commit);
    if (framed == null || framed.wire != _public || framed.conversation != conv.id) {
      throw _fail(400, "the commit isn't a public message of this conversation's group");
    }
    if (framed.generation != generation || framed.epoch != epoch) {
      throw _fail(400, "the commit's generation and epoch aren't the ones the request says");
    }
    if (create && epoch != 0) throw _fail(400, "a group's creation commits on its epoch 0");
    // Every commit brings the group info of the epoch it makes; a creation, epoch 0's too.
    for (final groupInfo in [ctx['group_info'], if (create) ctx['initial_group_info']]) {
      if (_framing(_bytesIn(groupInfo, 'group_info', max: _limit('group_info_bytes')))?.wire != _groupInfo) {
        throw _fail(400, "a group info isn't an MLS group info");
      }
    }
    final welcomed = welcome == null ? null : _framing(welcome);
    if (welcome != null && welcomed?.wire != _welcome) throw _fail(400, "the welcome isn't an MLS welcome");
    if (route == 'commits' && welcome != null && !create) {
      throw _fail(400, "a welcome only comes with a group's creation");
    }
    // An addition's welcome brings the user's devices: one with none has none (they join later).
    if (route != 'commits' && create) throw _fail(400, 'the members routes change a group that exists');
    if (route == 'remove' && welcome != null) throw _fail(400, 'a removal brings no welcome');

    if (conv.commits[ctx['commit']] case final sent?) return sent;
    final group = conv.group;
    if (group == null && (!create || generation != 0)) {
      throw _fail(409, route == 'commits' ? 'no group yet' : 'create the group first');
    }
    final taken =
        group != null &&
        (create ? generation != group.generation + 1 : generation != group.generation || epoch != group.epoch);
    if (taken) {
      throw _fail(409, 'another commit took this epoch', {'generation': group.generation, 'epoch': group.epoch});
    }

    final after = epoch + 1;
    conv.group = (generation: generation, epoch: after, groupInfo: ctx['group_info']! as String);
    final by = {'sender_user': session.user, 'sender_device': device.id};
    final entry = _addEntry(conv, {
      'kind': 'commit',
      'data': ctx['commit'],
      'generation': generation,
      'epoch': epoch,
      ...by,
    });
    final welcomeEntry = welcome == null
        ? null
        : _addEntry(conv, {'kind': 'welcome', 'data': ctx['welcome'], 'generation': generation, 'epoch': after, ...by});
    // The devices it brings in: the committer's with a creation, or with its own external commit, which takes it out
    // and in again; and those whose key packages its welcome names. A new generation's leaves are those its creation
    // brings, and a device brought in again keeps the number it has had the queue from, as the API's SetMlsLeaf does.
    final before = conv.leaves;
    if (create) {
      conv.leaves = {device.id: before[device.id] ?? entry['seq']! as int};
    } else if (framed.sender == 4) {
      conv.leaves[device.id] = entry['seq']! as int;
    }
    final brought = [
      for (final ref in welcomed?.welcomed ?? const <String>[])
        for (final MapEntry(key: id, value: kps) in _keyPackages.entries)
          if (kps.containsKey(ref)) id,
    ];
    for (final id in brought) {
      if (id != device.id) conv.leaves[id] = before[id] ?? welcomeEntry!['seq']! as int;
    }

    final answer = {
      'seq': entry['seq'],
      'generation': generation,
      'epoch': after,
      if (welcomeEntry != null) 'welcome_seq': welcomeEntry['seq'],
    };
    conv.commits[ctx['commit']! as String] = answer;
    for (final member in conv.members) {
      _emit(member['user_id']! as String, 'MLS_COMMIT', {
        'conversation_id': conv.id,
        'generation': generation,
        'epoch': after,
        'entry': _forEvent(entry),
      });
    }
    final welcomedUsers = <String, List<String>>{};
    for (final id in brought) {
      final user = _devices[id]?.user;
      if (user != null && id != device.id) (welcomedUsers[user] ??= []).add(id);
    }
    for (final MapEntry(key: user, value: devices) in welcomedUsers.entries) {
      _emit(user, 'MLS_WELCOME', {
        'conversation_id': conv.id,
        'generation': generation,
        'epoch': after,
        'devices': devices,
        'entry': _forEvent(welcomeEntry!),
      });
    }
    // The removals still pending go again in the epoch it makes, as an epoch's proposals end with it.
    _proposeRemovals(conv);
    return answer;
  }

  /// The API's proposals, as the groups' external sender, of the removal of each leaf that who left still has in the
  /// group, with their statement (PLAN-E2E-API.md, «Rutas», F): in its epoch now, once each, to its members. A leaver
  /// whose leaves are all out is forgotten.
  void _proposeRemovals(_Conversation conv) {
    final group = conv.group;
    final held = group == null ? null : _groupInfoLeaves(base64Decode(group.groupInfo));
    if (group == null || held == null) return;
    for (final MapEntry(key: user, value: statement) in [...conv.leavers.entries]) {
      final leaves = [
        for (final MapEntry(key: leaf, value: device) in held.leaves.entries)
          if (_devices[device]?.user == user) leaf,
      ];
      if (leaves.isEmpty) conv.leavers.remove(user);
      for (final leaf in leaves) {
        if (!conv.proposed.add('${group.generation}:${group.epoch}:$leaf')) continue;
        final entry = _addEntry(conv, {
          'kind': 'proposal',
          'data': _removalProposal(held.groupId, held.epoch, leaf),
          'generation': group.generation,
          'epoch': group.epoch,
          'statement': statement,
        });
        for (final member in conv.members) {
          final user = member['user_id']! as String;
          _emit(user, 'MLS_PROPOSAL', {
            'conversation_id': conv.id,
            'generation': group.generation,
            'epoch': group.epoch,
            'entry': _forEvent(_shownTo(user, entry)),
          });
        }
      }
    }
  }

  /// An external sender's proposal to remove a leaf (RFC 9420, its PublicMessage), as the API's validator makes one
  /// (OpenMLS's ExternalProposal::new_remove): from the group's first external sender, signed with its key (or
  /// [seed]'s) over the content alone, as an external sender's signature covers no group context.
  String _removalProposal(Uint8List groupId, int epoch, int leaf, {Uint8List? seed}) {
    final framed = [
      ..._tlsUint(1, 2), // the protocol's version
      ..._tlsUint(_public, 2),
      ..._tlsVector(groupId),
      ..._tlsUint(epoch, 8),
      ...[2, ..._tlsUint(0, 4)], // the sender: external, the group's first
      ..._tlsVector(const []), // no authenticated data
      ...[2, ..._tlsUint(3, 2), ..._tlsUint(leaf, 4)], // a proposal: a Remove of the leaf
    ];
    final signature = ed25519Sign(seed ?? _senderSeed, [
      ..._tlsVector(utf8.encode('MLS 1.0 FramedContentTBS')),
      ..._tlsVector(framed),
    ]);
    return base64Encode([...framed, ..._tlsVector(signature)]);
  }

  /// An addition: the owner's commit of exactly that user, which goes to the members after it, the one it adds among
  /// them, as the API sends it. It answers with the member and the commit's answer, as the API's MemberAdded.
  _Answer _addMember(_Context ctx) {
    final conv = _memberOf(ctx);
    final user = _uuidIn(ctx['user_id'], 'user_id');
    // The same addition again gets the answer it got.
    final added = conv.members.where((m) => m['user_id'] == user).firstOrNull;
    final sent = conv.commits[ctx['commit']];
    if (added != null && sent != null) return _ok({...added, 'commit': sent}, 201);
    if (conv.type != 2) throw _fail(400, "a DM's members don't change");
    if (conv.ownerId != ctx.me.user) throw _fail(403, "only the group's owner adds members");
    if (!_users.contains(user)) throw _fail(404, 'user not found');
    if (added != null) throw _fail(409, 'already a member');
    if (conv.members.length >= _limit('group_members')) throw _fail(400, 'a group can have 20 members at most');
    final at = _now();
    final member = {'id': _id(), 'conversation_id': conv.id, 'user_id': user, 'created_at': at, 'updated_at': at};
    conv.members.add(member);
    try {
      return _ok({...member, 'commit': _commit(conv, ctx, 'add')}, 201);
    } on _Refusal {
      // Refused: nothing changed, the members neither.
      conv.members.removeLast();
      rethrow;
    }
  }

  /// A removal: the owner's commit of exactly that user, which they hear too. It answers with the commit's answer
  /// (200), as the API does.
  _Answer _removeMember(_Context ctx) {
    final conv = _memberOf(ctx);
    if (conv.ownerId != ctx.me.user) throw _fail(403, "only the group's owner removes members");
    // The same removal again.
    if (conv.commits[ctx['commit']] case final sent?) return _ok(sent);
    if (!conv.members.any((m) => m['user_id'] == ctx.params['user'])) throw _fail(404, 'not a member');
    final commit = _commit(conv, ctx, 'remove');
    conv.members = [
      for (final m in conv.members)
        if (m['user_id'] != ctx.params['user']) m,
    ];
    conv.departures[ctx.params['user']!] = commit['seq']! as int;
    return _ok(commit);
  }

  /// Leaving: the user's statement, signed by the session's device, which has a leaf in the group, of this
  /// conversation's generation and an epoch it has reached; without a group, none. A DM has no leaving. The owner
  /// passes to the member who came first, and each leaf of the user's has its removal proposed, with the statement.
  /// Sent again once it went, it's refused as the user's who isn't a member (403), as the API's is.
  _Answer _leave(_Context ctx) {
    final conv = _memberOf(ctx);
    final (session, device) = (ctx.me, ctx.device!);
    if (conv.type == 1) throw _fail(400, 'cannot remove members from a DM');
    String? statement;
    if (conv.group case final group?) {
      statement = _base64In(ctx['statement'], 'statement', max: 1024);
      final said = _signedBody(_leaveLabel, base64Decode(statement), device.signatureKey);
      final epoch = said?['epoch'];
      final fits =
          asUuid(said?['user']) == session.user &&
          asUuid(said?['conversation']) == conv.id &&
          asUuid(said?['device']) == device.id &&
          said?['generation'] == group.generation &&
          epoch is int &&
          epoch <= group.epoch;
      if (!fits) throw _fail(400, "the statement doesn't verify");
      if (!conv.leaves.containsKey(device.id)) throw _fail(403, "this device isn't in the group");
    }
    final before = [for (final m in conv.members) m['user_id']! as String];
    conv.members = [
      for (final m in conv.members)
        if (m['user_id'] != session.user) m,
    ];
    final handed = conv.ownerId == session.user && conv.members.isNotEmpty;
    if (handed) conv.ownerId = conv.members.first['user_id']! as String;
    for (final user in before) {
      _emit(user, 'CONVERSATION_MEMBER_REMOVE', {'conversation_id': conv.id, 'user_id': session.user});
      if (handed) _emit(user, 'CONVERSATION_UPDATE', {'id': conv.id, 'name': null, 'owner_id': conv.ownerId});
    }
    if (statement != null) {
      conv.leavers[session.user] = statement;
      _proposeRemovals(conv);
    }
    return _noContent;
  }

  /// A new conversation, as the API's CreateConversation makes it: a DM with another user (the one they have, if they
  /// have one: 201 with its group), or a group of the session's user, its owner, and those it names, 20 at most with
  /// the owner; its members hear CONVERSATION_CREATE of a new one. It has no group yet.
  _Answer _createConversation(_Context ctx) {
    // shortcut: no friendship is asked: tests befriend users only for what claims and identities need.
    List<String> users(List<String> ids) {
      for (final id in ids) {
        if (!_users.contains(id)) throw _fail(404, 'user not found');
      }
      return ids;
    }

    final String id;
    switch (ctx['type']) {
      case 1:
        final other = users([_uuidIn(ctx['user_id'], 'user_id')]).single;
        if (other == ctx.me.user) throw _fail(400, 'cannot create a DM with yourself');
        final had = _conversationsOf(
          ctx.me.user,
        ).where((c) => c.type == 1 && c.members.any((m) => m['user_id'] == other));
        if (had.firstOrNull case final dm?) return _ok(_view(dm, ctx.device), 201);
        id = addConversation(group: false, members: [ctx.me.user, other]);
      case 2:
        final named = ctx['user_ids'];
        if (named is! List || named.isEmpty) throw _fail(400, 'user_ids is required for groups');
        final members = {
          ctx.me.user,
          ...users([for (final user in named) _uuidIn(user, 'user_ids')]),
        }.toList();
        if (members.length > _limit('group_members')) throw _fail(400, 'a group can have 20 members at most');
        id = addConversation(group: true, members: members, owner: ctx.me.user);
      default:
        throw _fail(400, 'invalid conversation type (1=DM, 2=group)');
    }
    final made = _conversations[id]!;
    for (final member in made.members) {
      _emit(member['user_id']! as String, 'CONVERSATION_CREATE', _view(made, null));
    }
    return _ok(_view(made, ctx.device), 201);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Messages.

  /// A message's MLS message, checked as the API checks it: an application message of the group, not stale.
  _Framing _checkMessage(_Conversation conv, _Device device, Uint8List ciphertext) {
    final group = conv.group;
    if (group == null) throw _fail(409, 'no group yet');
    final framed = _framing(ciphertext);
    if (framed == null || framed.wire != _private || framed.conversation != conv.id || framed.content != 1) {
      throw _fail(400, "the message isn't an application message of this conversation's group");
    }
    if (framed.generation != group.generation || framed.epoch! < group.epoch - _limit('epochs_behind')) {
      throw _fail(409, 'stale message', {'generation': group.generation, 'epoch': group.epoch});
    }
    if (framed.epoch! > group.epoch) throw _fail(400, "the message is of an epoch the group hasn't reached");
    if (!conv.leaves.containsKey(device.id)) throw _fail(403, "this device isn't in the group");
    return framed;
  }

  _Answer _sendMessage(_Context ctx) {
    final conv = _memberOf(ctx);
    final (session, device) = (ctx.me, ctx.device!);
    if (ctx['content'] != null || ctx['embeds'] != null || ctx['components'] != null) {
      throw _fail(400, 'conversations are end-to-end encrypted');
    }
    final nonce = ctx['nonce'];
    if (nonce is! String || nonce.isEmpty || nonce.length > 64) {
      throw _fail(400, 'a message has its nonce, 64 characters at most');
    }
    final ciphertext = _bytesIn(ctx['ciphertext'], 'ciphertext', max: _limit('ciphertext_bytes'), min: 1);
    // A form's list is its value repeated, one value alone a list of one; its objects are JSON in text.
    Object? listIn(Object? value) => value is String ? [value] : value ?? const [];
    Object? objectIn(Object? value) => value is String ? jsonDecode(value) : value;
    final listed = listIn(ctx['mentions']);
    if (listed is! List || listed.length > 20 || listed.any((id) => id is! String || !_uuid.hasMatch(id))) {
      throw _fail(400, 'invalid mentions');
    }
    final ids = listIn(ctx['attachment_ids']);
    if (ids is! List ||
        ids.length != ctx.files.length ||
        ids.any((id) => id is! String || !_uuid.hasMatch(id)) ||
        ids.toSet().length != ids.length) {
      throw _fail(400, 'attachment_ids names each of files, in their order, each with an ID of its own');
    }
    // A nonce it has answers with its message, before anything is checked of the group, as the API's checkSend.
    final sent = conv.messages.where((m) => m['sender_device_id'] == device.id && m['nonce'] == nonce).firstOrNull;
    if (sent != null) {
      if (conv.deleted.contains(sent['id'])) throw _fail(409, 'this message was deleted');
      if (sent['ciphertext'] != ctx['ciphertext']) throw _fail(409, 'this nonce went with another message');
      return _ok(sent, 201);
    }
    final framed = _checkMessage(conv, device, ciphertext);
    final replied = _repliedIn(conv, objectIn(ctx['message_reference']));
    // Its files go up first, each under the ID its client gave it, as the API's uploadEncryptedFiles: one up already
    // from a send that failed is taken again.
    final files = [for (final (i, file) in ctx.files.indexed) _upFile(session.user, ids[i] as String, file.bytes)];
    if (_cuttingAfterFiles) {
      _cuttingAfterFiles = false;
      _outbox.clear();
      throw http.ClientException('the connection was cut once its files went up');
    }
    // Whom it mentions, as the API has it: whom it names, then the author of what it answers (unless its
    // allowed_mentions say not to, or that's a notice), each once, of the members, never its own author.
    final members = [for (final m in conv.members) m['user_id']];
    final allowed = objectIn(ctx['allowed_mentions']);
    final mentionReplied = allowed == null || (allowed is Map && allowed['replied_user'] == true);
    final notice = replied?['type'] == 2 || replied?['type'] == 3;
    final named = [
      ...listed.cast<String>(),
      if (replied != null && mentionReplied && !notice) replied['author_id']! as String,
    ];
    final at = _now();
    final id = _id();
    final message = <String, Object?>{
      'id': id,
      'conversation_id': conv.id,
      'author_id': session.user,
      'content': null,
      'type': 0,
      'created_at': at,
      'updated_at': at,
      'nonce': nonce,
      'ciphertext': ctx['ciphertext'],
      'seq': ++conv.seq,
      'sent_at': DateTime.now().millisecondsSinceEpoch + sentAtOffset,
      'generation': framed.generation,
      'epoch': framed.epoch,
      'sender_device_id': device.id,
      'edited_at': null,
      'mentions': [
        for (final user in {...named})
          if (user != session.user && members.contains(user)) user,
      ],
      'message_reference': ctx['message_reference'],
      // What it answers, as the API's reads and events carry it: no text, which only the devices have.
      'referenced_message': replied == null
          ? null
          : {
              'type': 0,
              'message_id': replied['id'],
              'author_id': replied['author_id'],
              'created_at': replied['created_at'],
              'mention_author': mentionReplied && !notice && replied['author_id'] != session.user,
            },
      'attachment_ids': [...ids.cast<String>()],
      'attachments': [for (final file in files) _attachmentView(file..message = id)],
      'sticker_attachment_id': ctx['sticker_attachment_id'],
    };
    conv.messages.add(message);
    if (replied != null) _repliesTo[message['id']! as String] = replied['id']! as String;
    for (final member in conv.members) {
      _emit(member['user_id']! as String, 'DM_MESSAGE_CREATE', message);
    }
    return _ok(message, 201);
  }

  /// The message a message's reference answers, as the API checks it: a reply (type 0) to a message of the
  /// conversation that isn't deleted; null for no reference.
  Map<String, Object?>? _repliedIn(_Conversation conv, Object? reference) {
    final id = reference is Map ? reference['message_id'] : null;
    if (id == null || id == '') return null;
    final type = (reference! as Map)['type'];
    if (type != null && type != 0) throw _fail(400, 'invalid message reference: type must be 0 (reply)');
    if (id is! String || !_uuid.hasMatch(id)) throw _fail(400, 'invalid message reference: message_id');
    final replied = conv.messages.where((m) => m['id'] == id && !conv.deleted.contains(id)).firstOrNull;
    if (replied == null) throw _fail(404, 'referenced message not found');
    return replied;
  }

  /// An edit (PATCH) or a deletion (DELETE) of the author's message: its MLS message as the queue's entry.
  _Answer _changeMessage(_Context ctx, String kind) {
    final conv = _memberOf(ctx);
    final message = conv.messages.where((m) => m['id'] == ctx.params['message']).firstOrNull;
    if (message == null || message['seq'] == null) throw _fail(404, 'direct message not found');
    if (message['author_id'] != ctx.me.user) throw _fail(403, 'only its author changes a message');
    final device = ctx.device != null && !ctx.device!.removed ? ctx.device : null;
    if (device == null) throw _fail(403, 'this session has no device');
    final ciphertext = _bytesIn(ctx['ciphertext'], 'ciphertext', max: _limit('ciphertext_bytes'), min: 1);
    _Answer done(Map<String, Object?> entry) =>
        _ok({'id': message['id'], if (kind == 'edit') 'edited_at': message['edited_at'], 'entry': entry});
    final again = conv.entries
        .where((e) => e['kind'] == kind && e['message_id'] == message['id'] && e['data'] == ctx['ciphertext'])
        .firstOrNull;
    if (again != null) return done(again);
    if (conv.deleted.contains(message['id'])) throw _fail(404, 'direct message not found');
    final framed = _checkMessage(conv, device, ciphertext);
    final entry = _addEntry(conv, {
      'kind': kind,
      'data': ctx['ciphertext'],
      'generation': framed.generation,
      'epoch': framed.epoch,
      'sender_user': ctx.me.user,
      'sender_device': device.id,
      'message_id': message['id'],
    });
    if (kind == 'edit') {
      message['edited_at'] = _now();
      final update = {
        'id': message['id'],
        'conversation_id': conv.id,
        'edited_at': message['edited_at'],
        'entry': _forEvent(entry),
      };
      for (final member in conv.members) {
        _emit(member['user_id']! as String, 'DM_MESSAGE_UPDATE', update);
      }
    } else {
      // The deletion empties the message and its edits, whose entries say so.
      conv.deleted.add(message['id']! as String);
      message['ciphertext'] = null;
      for (final edit in conv.entries.where((e) => e['kind'] == 'edit' && e['message_id'] == message['id'])) {
        edit
          ..['data'] = ''
          ..['deleted'] = true;
      }
      final deletion = {'id': message['id'], 'conversation_id': conv.id, 'entry': _forEvent(entry)};
      for (final member in conv.members) {
        _emit(member['user_id']! as String, 'DM_MESSAGE_DELETE', deletion);
      }
    }
    return done(entry);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Shared history and backups.

  String _keepFile(Uint8List bytes) {
    final id = _id();
    _files[id] = Uint8List.fromList(bytes);
    return id;
  }

  /// A message's file up under [id], as the API takes one: 20 MiB at most (413); one up already that's [owner]'s, on
  /// no message, of these bytes' size and SHA-256, taken again; any other with its ID a 409.
  _Attachment _upFile(String owner, String id, Uint8List bytes) {
    if (bytes.length > fileLimit) throw _fail(413, 'file too large');
    final sum = '${sha256.convert(bytes)}';
    if (_attachments[id] case final had?) {
      if (had.owner == owner && had.message == null && had.size == bytes.length && had.sha256 == sum) return had;
      throw _fail(409, 'attachment id in use');
    }
    if (_files.containsKey(id)) throw _fail(409, 'attachment id in use');
    final made = _attachments[id] = _Attachment(id, owner, bytes.length, sum, _now());
    _files[id] = Uint8List.fromList(bytes);
    return made;
  }

  /// A message's file as the API's reads and events give it: sealed (named file, application/octet-stream), at its
  /// signed path, an encrypted file (kind 1).
  Map<String, Object?> _attachmentView(_Attachment a) => {
    'id': a.id,
    'message_id': a.message,
    'filename': 'file',
    'content_type': 'application/octet-stream',
    'size_bytes': a.size,
    'created_at': a.createdAt,
    'url': _signedPath(a.id),
    'kind': 1,
  };

  // What signs the files' paths, the fake's own (the API's ATTACHMENT_SIGNING_KEY).
  final _signingKey = _randomBytes(32);

  String _signature(String file, int exp) => '${Hmac(sha256, _signingKey).convert(utf8.encode('$file:$exp'))}';

  /// Where a file is downloaded from, as the API's routes answer it (storage.SignedAttachmentURL): a path on its own
  /// host, signed for a day.
  String _signedPath(String file) {
    final exp = _unixNow() + 24 * 3600;
    return '/attachments/$file?sig=${_signature(file, exp)}&exp=$exp';
  }

  Map<String, Object?> _shareView(_Share share) => {
    'id': share.id,
    'conversation_id': share.conversationId,
    'from_user_id': share.fromUser,
    'kind': share.kind,
    'range': share.range,
    'starts_at': share.startsAt.toIso8601String(),
    'size': share.size,
    'parts': share.parts,
  };

  _Answer _putShare(_Context ctx) {
    final conv = _memberOf(ctx);
    final to = _uuidIn(ctx['to_user_id'], 'to_user_id');
    if (!conv.members.any((m) => m['user_id'] == to)) throw _fail(403, "the share's recipient isn't a member");
    final kind = ctx['kind'];
    if (kind != 'share' && kind != 'catch_up') throw _fail(400, "a share's kind is share or catch_up");
    final parts = _numberIn(ctx['parts'], 'parts');
    if (parts < 1 || parts > _limit('history_share_parts')) throw _fail(400, 'a share has 1 to 64 parts');
    final share = _Share(
      ctx.params['share']!,
      conv.id,
      ctx.me.user,
      ctx.device!.id,
      to,
      kind! as String,
      ctx['range'] as String?,
      _timeIn(ctx['starts_at'], 'starts_at'),
      _numberIn(ctx['size'], 'size'),
      parts,
    );
    // The same package sent again is that package, as the API's (its sameAs); another under its ID is a 409.
    if (_shares[share.id] case final there?) {
      final same =
          there.conversationId == share.conversationId &&
          there.fromUser == share.fromUser &&
          there.toUser == share.toUser &&
          there.kind == share.kind &&
          there.range == share.range &&
          there.startsAt.isAtSameMomentAs(share.startsAt) &&
          there.size == share.size &&
          there.parts == share.parts;
      if (!same) throw _fail(409, 'share id in use');
      return _ok(_shareView(there), 201);
    }
    _limitShares(share);
    _shares[share.id] = share;
    return _ok(_shareView(share), 201);
  }

  /// A new package counted toward its sender's limits, or refused for them as the API refuses one: a 429 and its wait.
  void _limitShares(_Share share) {
    final now = DateTime.now();
    final made = [
      for (final one in _sharesMade)
        if (one.user == share.fromUser && one.kind == share.kind) one,
    ];
    int within(
      Duration window, [
      bool Function(({String user, String kind, String conversation, String to, DateTime at}))? to,
    ]) => made.where((one) => now.difference(one.at) < window && (to?.call(one) ?? true)).length;
    final over = share.kind == 'share'
        ? within(const Duration(hours: 1)) >= 10
        : within(const Duration(hours: 1)) >= 30 ||
              within(
                    const Duration(days: 1),
                    (one) => one.conversation == share.conversationId && one.to == share.toUser,
                  ) >=
                  1;
    if (over) {
      throw const _Refusal(
        _Answer(429, body: {'error': 'too many requests, try again later'}, headers: {'Retry-After': '3600'}),
      );
    }
    _sharesMade.add((
      user: share.fromUser,
      kind: share.kind,
      conversation: share.conversationId,
      to: share.toUser,
      at: now,
    ));
  }

  _Share _ownShare(_Context ctx) {
    final conv = _memberOf(ctx);
    final share = _shares[ctx.params['share']];
    if (share == null || share.conversationId != conv.id || share.fromDevice != ctx.device!.id) {
      throw _fail(404, 'no such share');
    }
    return share;
  }

  /// A share whose parts are all up reaches its recipient (HISTORY_SHARE_CREATE); a share, not a catch-up, posts its
  /// notice.
  _Answer _completeShare(_Context ctx) {
    final share = _ownShare(ctx);
    if (share.uploaded.length < share.parts) throw _fail(409, 'the share is missing parts');
    if (share.completed) return _noContent;
    share.completed = true;
    _emit(share.toUser, 'HISTORY_SHARE_CREATE', _shareView(share));
    if (share.kind == 'share') {
      final conv = _conversations[share.conversationId]!;
      final at = _now();
      final notice = <String, Object?>{
        'id': _id(),
        'conversation_id': conv.id,
        'author_id': share.fromUser,
        'content': null,
        'type': 4,
        'created_at': at,
        'updated_at': at,
        'history_share': {'to_user_id': share.toUser, 'range': share.range},
      };
      conv.messages.add(notice);
      for (final member in conv.members) {
        _emit(member['user_id']! as String, 'DM_MESSAGE_CREATE', notice);
      }
    }
    return _noContent;
  }

  /// The ID of the backup key an encrypted identity is sealed with, in the clear as the core writes it (`{v: 1, key_id,
  /// nonce, ct}`), in base64 as the API lists a segment's: null for anything else.
  static String? _backupKeyOf(Object? sealed) {
    if (sealed is! String || !_base64.hasMatch(sealed)) return null;
    final key = asBytes(asMap(cbor(base64Decode(sealed)))?['key_id'], 8);
    return key == null ? null : base64Encode(key);
  }

  /// Whether a segment is shown, as the API lists and serves one: its key seals its day, a retired one only the days
  /// before the UTC day it was retired on (e2e.KeySealsDay).
  bool _shownSegment(String user, _Segment segment) {
    final keys = _backupKeys[user];
    if (keys == null || !keys.retired.containsKey(segment.keyId)) return false;
    final retired = keys.retired[segment.keyId];
    return retired == null || segment.day.compareTo(_utcDay(retired)) < 0;
  }

  static String _utcDay(DateTime at) => at.toUtc().toIso8601String().substring(0, 10);

  /// The bytes the API keeps of a segment of a backup, by the segment's ID: those it serves, which a test may alter.
  Uint8List? segmentFile(String id) => switch (_segments[id]) {
    final segment? => _files[segment.file],
    null => null,
  };

  /// A day's segment, in place of the one it names (`replaces`: its ID, or none), as the API keeps one: its header must
  /// be this route's, and its key one of the user's that seals its day: one that isn't theirs is `unknown backup key`,
  /// and one retired on or before its day, or that starting over retired, `retired backup key` (the API's dayOf). The
  /// same bytes as the day's segment shown now are that one, sent again: its ID. Another segment shown there must be
  /// the one it names (409, with it as `current`); one no longer shown holds nothing to lose. One past the storage's
  /// limit for a file is a 413, in the API's words.
  _Answer _putSegment(_Context ctx) {
    final identity = _identities[ctx.me.user];
    if (identity == null) throw _fail(404, 'no identity');
    final header = asMap(cbor(ctx.bytes));
    final keyId = asBytes(header?['key_id'], 8);
    final fits =
        header?['v'] == 1 &&
        asUuid(header!['user']) == ctx.me.user &&
        asUuid(header['conversation']) == ctx.params['conversation'] &&
        header['day'] == ctx.params['day'] &&
        header['complete'] is bool;
    if (!fits || keyId == null) throw _fail(400, "the segment's header isn't this route's");
    final keys = _backupKeys[ctx.me.user];
    final key = base64Encode(keyId);
    if (keys == null || !keys.retired.containsKey(key)) throw _fail(400, 'unknown backup key');
    if (keys.retired[key] case final retired?) {
      final reset = keys.resets.lastOrNull;
      if ((reset != null && !retired.isAfter(reset)) || ctx.params['day']!.compareTo(_utcDay(retired)) >= 0) {
        throw _fail(400, 'retired backup key');
      }
    }
    final current = _segments.values
        .where(
          (s) =>
              s.identity == identity.id && s.conversationId == ctx.params['conversation'] && s.day == ctx.params['day'],
        )
        .firstOrNull;
    final shown = current != null && _shownSegment(ctx.me.user, current) ? current : null;
    if (shown != null && _equal(_files[shown.file]!, ctx.bytes)) return _ok({'id': shown.id}, 201);
    if (shown != null && (ctx.query['replaces'] ?? 'none') != shown.id) {
      throw _fail(409, 'another segment holds this day', {'current': shown.id});
    }
    if (ctx.bytes.length > fileLimit) {
      throw _fail(
        413,
        'uploading a backup segment: file is too large: ${ctx.bytes.length} bytes, your limit is $fileLimit',
      );
    }
    if (current != null) _segments.remove(current.id);
    final segment = _Segment(
      _id(),
      identity.id,
      ctx.params['conversation']!,
      ctx.params['day']!,
      header['complete'] == true,
      base64Encode(keyId),
      ctx.bytes.length,
      _keepFile(ctx.bytes),
    );
    _segments[segment.id] = segment;
    return _ok({'id': segment.id}, 201);
  }
}

/// A query's positive count, or null for none, as the API reads one (anything else is its default).
int? _positive(String? text) {
  final n = int.tryParse(text ?? '');
  return n == null || n <= 0 ? null : n;
}

bool _matches(RouteMatch match, String method, String path) =>
    (match.method == null || match.method == method) &&
    (match.path is String ? match.path == path : (match.path as RegExp).hasMatch(path));

http.Response _respond(_Answer answer) {
  final body = answer.body;
  // Named in lowercase, as a real client hands them over.
  final headers = {for (final MapEntry(:key, :value) in answer.headers.entries) key.toLowerCase(): value};
  if (body is Uint8List) {
    return http.Response.bytes(body, answer.status, headers: {'content-type': 'application/octet-stream', ...headers});
  }
  if (body == null) return http.Response.bytes(const [], answer.status, headers: headers);
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    answer.status,
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
  );
}
