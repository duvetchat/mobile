import 'dart:async';

import 'package:clock/clock.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/repository.dart' show ChatRepository;
import '../data/scope.dart';
import '../e2e/engine.dart';
import '../e2e/host.dart' show CoreError;
import '../e2e/notices.dart';
import '../space_admin.dart' show AdminPage, AdminPanel, confirmDestructive;
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/rows.dart';
import 'approval.dart' show ScanDevicePage, approvalWaits, deviceUnfinished, scanTitle;

/// Whether this device has a database of its own to delete: none while its engine starts, nor where another engine
/// has it (locked) or there's no core (unsupported).
bool hasDeviceData(EngineState state) =>
    !const {EngineStage.starting, EngineStage.locked, EngineStage.unsupported}.contains(state.stage);

/// What deleting this device's data asks, as the desktop asks it: a device not set up; one on the list, which stays
/// there until another of the user's devices removes it, as the API takes no list without the session's own device
/// (decision 13); and the only one, whose history goes without the recovery key.
const deleteDeviceQuestion = "Delete this device's encrypted conversations and their keys, and sign out?";
// Every listed device's names the recovery key, beside others too: one whose data went stays listed, and the client
// can't tell such a phantom from a device that holds the history (review 24's I2).
const deleteListedDeviceQuestion =
    "Delete this device's encrypted conversations and their keys, and sign out? Without your recovery key, their "
    'history is lost unless another of your devices still holds it. This device stays on your device list until you '
    'remove it on another device.';

/// A change of keys that can't finish (review 24's I1), and its two ways out: another device's change of keys, whose
/// transfer the core takes over the change that waits (duvetchat/e2e#49), or this device's data deleted and set up
/// again.
const rotationStuck =
    "This change of your security keys can't finish: another of your devices changed your devices or keys meanwhile, "
    "and the recovery key it showed won't work. Change your security keys on another of your devices, or delete this "
    "device's data and set it up again.";

/// A change of keys that can't finish with the devices another device took off meanwhile ([gone], by the start of
/// their IDs, as their names went with them), which it finishes without on the person's yes (duvetchat/e2e#49): its
/// recovery key stays the same.
String rotationGone(List<String> gone) =>
    "This change of your security keys can't finish with ${_listed([for (final id in gone) _idStart(id)])}, which "
    'another of your devices took off your account meanwhile. Finish it without them: the recovery key it showed still '
    'works.';

/// Its action.
const finishWithout = 'Finish without them';

/// A change of keys another device's made impossible for good: that one kept a device this one takes off, and the
/// core refuses its keys (`removed_device_listed`, duvetchat/e2e#49).
const rotationRelisted =
    "Another of your devices changed your security keys and kept a device you removed here, so this device can't "
    "take them. To use encrypted conversations here again, delete this device's data and set it up again.";

/// After a change of keys that left devices out ([finishWithout]): one of them may still hold the keys, if the API
/// worked with whoever has it (duvetchat/e2e#49).
const keysAgainText =
    "A device that left your account may still hold your security keys: change them once more, so it can't read "
    "what's sent from now on.";

String _idStart(String id) => id.length > 8 ? id.substring(0, 8) : id;

/// A device the API's list doesn't name, by what this device knows of it (N-M7 of step 4's closing re-review): its
/// name, with its client and when it was added; the start of its ID only when nothing is known.
String knownName(String id, KnownDevice? known) {
  final about = [?known?.client, if (known?.added case final at?) 'added ${fullDate(at.toLocal())}'];
  return switch ((known?.name, about)) {
    (null, []) => _idStart(id),
    (final String name, []) => name,
    (final name, _) => '${name ?? 'a device'} (${about.join(', ')})',
  };
}

String _listed(List<String> names) =>
    names.length < 2 ? names.join() : '${names.take(names.length - 1).join(', ')} and ${names.last}';
const deleteOnlyDeviceQuestion =
    'This is your only device with your encrypted conversations: without your recovery key, their history is lost. '
    'Delete them and their keys, and sign out?';

/// What a removal or a change of keys that failed says: while a device this one approved sets up, why it waits (Task
/// 27); the API's refusal of a list naming a device this one approved that never finished (task 26's I1), and the
/// core's of a change of keys keeping such a device, with no certificate the API serves (review 27's M4), in words;
/// anything else, to try again.
String devicesRefusal(Object error) => switch (error) {
  CoreError(code: 'approval_waits') => approvalWaits,
  // More devices would leave the list than the confirmation named: nothing went, and the next one names them.
  CoreError(code: 'devices_changed') => 'Your devices changed meanwhile. Try again.',
  duvet.DuvetApiException(statusCode: 400, :final body?) when body.contains('has no certificate of this identity') =>
    deviceUnfinished,
  CoreError(code: 'bad_command', field: 'certificates') => deviceUnfinished,
  _ => "Couldn't change your devices. Check your connection, then try again.",
};

/// What Settings says of the encrypted backup (Task 33), in the desktop's words: how far a new device's restore went, a
/// pause and why, that it's up to date, or else days going up.
String backupLine(BackupShown backup) => switch (backup.stage) {
  BackupStage.restoring => Notice.backupRestoring.fill({'done': '${backup.done}', 'total': '${backup.total}'}),
  BackupStage.paused => (backup.pause == BackupPause.full ? Notice.backupPaused : Notice.backupTooLarge).text,
  BackupStage.upToDate => Notice.backupUpToDate.text,
  BackupStage.uploading => Notice.backupUploading.text,
};

/// What a change of keys that can't finish says, by why (duvetchat/e2e#49).
String stuckText(EngineState state) => state.relisted
    ? rotationRelisted
    : state.gone.isNotEmpty
    ? rotationGone(state.gone)
    : rotationStuck;

/// «Remove this device and delete its data» (decision 13), from Devices or from the sign-out dialog: it asks first, as
/// the user's [devices] make it (read here when not given; the most careful way when they can't be read), then deletes
/// the data and signs out, no page of the account left over the welcome screen.
Future<void> deleteThisDevice(BuildContext context, [List<duvet.Device>? devices]) async {
  final repository = context.repository;
  final navigator = Navigator.of(context, rootNavigator: true);
  final known = devices ?? await repository.devices().then<List<duvet.Device>?>((d) => d, onError: (Object _) => null);
  if (!context.mounted) return;
  final sure = await confirmDestructive(
    context,
    title: Notice.deleteDevice.text,
    body: known == null || onlyDevice(known)
        ? deleteOnlyDeviceQuestion
        : known.any((d) => d.current && d.listed)
        ? deleteListedDeviceQuestion
        : deleteDeviceQuestion,
    action: 'Delete',
  );
  if (!sure) return;
  try {
    await repository.removeThisDevice();
    navigator.popUntil((route) => route.isFirst);
  } catch (error) {
    debugPrint("e2e: this device's data wasn't deleted: ${error.runtimeType}");
    if (context.mounted) _toast(context, "Couldn't delete this device's data. Try again.");
  }
}

/// What a removal of [asked] (none: a change of keys) takes along, in the desktop's words, and their IDs, which go
/// with the yes: the devices an earlier removal of this device's took off that the API didn't take, which the next list
/// or key change takes off too (review 24's M3), and those the list names that the API no longer lists, as the first
/// list names them (I2 of step 4's closing review); each by its name in [devices], the user's devices as the API lists
/// them, or by what's known of one the API's list doesn't have ([knownName]). Of those the API no longer lists it says
/// what's known, never why the server says they went (N-M7).
Future<({String text, List<String> named})> devicesAlongWith(
  ChatRepository repository,
  String? asked,
  List<duvet.Device>? devices,
) async {
  final along = await repository
      .devicesAlong(asked)
      .catchError((Object _) => (unsent: const <String>[], unregistered: const <String>[]));
  String nameOf(String id) =>
      devices?.where((d) => d.id == id).firstOrNull?.name ?? knownName(id, repository.knownDevice(id));
  String listed(List<String> ids) => switch ([for (final id in ids) nameOf(id)]) {
    [final one] => one,
    final names => '${names.take(names.length - 1).join(', ')} and ${names.last}',
  };
  final (:unsent, :unregistered) = along;
  return (
    text: [
      if (unsent.isNotEmpty) " This also removes ${listed(unsent)}, whose earlier removal didn't finish.",
      if (unregistered.isNotEmpty)
        " Duvet no longer lists ${listed(unregistered)}. If you didn't remove "
            "${unregistered.length == 1 ? 'it' : 'them'} or change your password, cancel.",
    ].join(),
    named: [...unsent, ...unregistered],
  );
}

/// Change security keys (Task 25), asked first wherever it's offered, Settings or the strip after a change that left
/// devices out (N-M6 of step 4's closing re-review): one question naming each device it takes off beside it, as the
/// user's [devices] name them (read here when not given). The devices that go with the yes, or null when cancelled.
Future<List<String>?> confirmChangeKeys(BuildContext context, [List<duvet.Device>? devices]) async {
  final repository = context.repository;
  final listed = devices ?? await repository.devices().then<List<duvet.Device>?>((d) => d, onError: (Object _) => null);
  final along = await devicesAlongWith(repository, null, listed);
  if (!context.mounted) return null;
  final sure = await confirmDestructive(
    context,
    title: 'Change security keys?',
    body:
        'Make new security keys and a new recovery key for your account? Your contacts will see that your keys '
        'changed.${along.text}',
    action: 'Change keys',
    destructive: false,
  );
  return sure ? along.named : null;
}

/// Sign out (decision 13): it only ends the session, the device and its data staying, unless the person picks
/// «Remove this device and delete its data» beside it, offered where this device has data of its own.
Future<void> signOut(BuildContext context) async {
  final repository = context.repository;
  final data = hasDeviceData(repository.encryption.value);
  final choice = await _choose(
    context,
    title: 'Sign out?',
    body: data ? 'Your encrypted conversations stay on this device for when you sign in again.' : null,
    choices: [
      ('Sign out', _SignOut.only, ButtonVariant.primary),
      if (data) (Notice.deleteDevice.text, _SignOut.deleteData, ButtonVariant.destructive),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case _SignOut.only:
      await repository.logOut();
    case _SignOut.deleteData:
      await deleteThisDevice(context);
    case null:
  }
}

enum _SignOut { only, deleteData }

enum _Removal { remove, changeKeys }

/// A question with its choices, each a button, and Cancel under them: null when cancelled.
Future<T?> _choose<T>(
  BuildContext context, {
  required String title,
  required String? body,
  required List<(String, T, ButtonVariant)> choices,
}) => showGlassDialogSheet<T>(
  context,
  label: title,
  builder: (context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
        if (body != null) ...[
          const SizedBox(height: 12),
          Text(body, style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground)),
        ],
        const SizedBox(height: 24),
        for (final (label, value, variant) in choices) ...[
          DuvetButton(label: label, variant: variant, expand: true, onPressed: () => Navigator.of(context).pop(value)),
          const SizedBox(height: 12),
        ],
        DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop()),
      ],
    ),
  ),
);

void _toast(BuildContext context, String text) =>
    showFToast(context: context, title: Text(text), duration: const Duration(seconds: 3));

/// When a device was last seen, by day: «Last seen today», «Last seen Monday, 20 October».
String lastSeen(DateTime at, [DateTime? now]) {
  final day = dayLabel(at.toLocal(), now ?? clock.now());
  return 'Last seen ${day == 'Today' || day == 'Yesterday' ? day.toLowerCase() : day}';
}

/// Settings → Devices (PLAN-E2E-CLIENTES.md, Task 25; decisions 13 and 52), the desktop's DevicesSettings: the user's
/// devices, each with its client and when it was last seen, this one, one not seen in 45 days and one never set up
/// marked; on a ready device, how its encrypted backup is (Task 33); removing another and changing the security keys
/// while this device is ready; and deleting this device's data where it has some.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<duvet.Device>? _devices;
  var _failed = false;
  var _busy = false;
  var _loaded = false;
  ValueListenable<EngineState>? _encryption;
  // The newest read's number: an older read whose answer comes after it is dropped.
  var _reads = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    // Read again at each change of the encryption's state, as the desktop's page is: a change of keys that went up
    // takes its lost device off the list (review 25's M2).
    _encryption = context.repository.encryption..addListener(_reload);
    unawaited(_load());
  }

  @override
  void dispose() {
    _encryption?.removeListener(_reload);
    super.dispose();
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    final read = ++_reads;
    setState(() => _failed = false);
    try {
      final devices = await context.repository.devices();
      if (mounted && read == _reads) setState(() => _devices = devices);
    } catch (error) {
      debugPrint("e2e: the user's devices: ${error.runtimeType}");
      if (mounted && read == _reads) setState(() => _failed = true);
    }
  }

  Future<void> _act(Future<void> Function() act) async {
    setState(() => _busy = true);
    try {
      await act();
    } catch (error) {
      debugPrint('e2e: what the person asked of their devices failed: ${error.runtimeType}');
      if (mounted) _toast(context, devicesRefusal(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<({String text, List<String> named})> _alongWith(String? asked) =>
      devicesAlongWith(context.repository, asked, _devices);

  // Removing another device, in the desktop's words; for one on the list, what changing the keys too does, for one
  // that was lost or stolen.
  Future<void> _remove(duvet.Device device) async {
    final repository = context.repository;
    final along = await _alongWith(device.id);
    if (!mounted) return;
    final choice = await _choose(
      context,
      title: 'Remove ${device.name}?',
      body:
          (device.listed
              ? "It's signed out, and reads none of your encrypted conversations from now on. If it was lost or "
                    "stolen, change your security keys too: with new keys, whoever has it can't add devices to your "
                    "account or read what's sent from now on. You'll save a new recovery key, and your contacts see "
                    'that your keys changed.'
              : "It's signed out, and reads none of your encrypted conversations from now on.") +
          along.text,
      choices: [
        ('Remove', _Removal.remove, ButtonVariant.destructive),
        if (device.listed) ('Remove and change keys', _Removal.changeKeys, ButtonVariant.destructive),
      ],
    );
    if (choice == null || !mounted) return;
    await _act(() async {
      await repository.removeDevice(device.id, changeKeys: choice == _Removal.changeKeys, named: along.named);
      await _load();
    });
  }

  Future<void> _changeKeys() async {
    final repository = context.repository;
    final named = await confirmChangeKeys(context, _devices);
    if (named == null || !mounted) return;
    await _act(() => repository.changeKeys(named: named));
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: context.repository.encryption,
    builder: (context, state, _) {
      final devices = _devices;
      // Removing and changing keys only while this device is set up and no change of keys waits.
      // A device this one approved, until its own list is up: a list or new keys meanwhile would leave it out.
      final holding = state.approval?.phase == ApprovalPhase.confirmed;
      final ready = state.stage == EngineStage.ready && !state.rotating && !_busy && !holding;
      // A change of keys that waits, its key put off or cut by the app's close: the banner's strip may be hidden.
      final finish = state.rotating && state.recoveryKey == null && !state.stuck && !_busy;
      final data = hasDeviceData(state);
      final without = state.stuck && state.gone.isNotEmpty && !_busy;
      return AdminPage(
        title: 'Devices',
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              "Each place you're signed in to Duvet. Those on your device list read your encrypted conversations.",
              style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground),
            ),
          ),
          if (devices == null)
            _failed
                ? Column(
                    children: [
                      const ListNote("Couldn't load your devices."),
                      TextAction(label: 'Try again', onPressed: _load),
                    ],
                  )
                : const ListNote('Loading your devices…')
          else
            AdminPanel(
              children: [
                for (final device in [...devices.where((d) => d.current), ...devices.where((d) => !d.current)])
                  _DeviceRow(device: device, onRemove: ready && !device.current ? () => _remove(device) : null),
              ],
            ),
          if (state.stuck)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
              child: Semantics(
                liveRegion: true,
                child: Text(stuckText(state), style: DuvetType.caption.copyWith(color: context.theme.colors.error)),
              ),
            ),
          if (holding)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  approvalWaits,
                  style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground),
                ),
              ),
            ),
          // A ready device's encrypted backup (Task 33): up to date, going up, restoring, or paused and why.
          if (state.stage == EngineStage.ready) ...[
            const SizedBox(height: 16),
            AdminPanel(
              children: [
                ValueListenableBuilder(
                  valueListenable: context.repository.backup,
                  builder: (context, backup, _) => _BackupRow(backup),
                ),
              ],
            ),
          ],
          if (ready || finish || without || data) ...[
            const SizedBox(height: 16),
            AdminPanel(
              children: [
                if (ready)
                  GlassRow(
                    icon: FLucideIcons.scanQrCode,
                    label: scanTitle,
                    onPressed: () => unawaited(
                      Navigator.of(
                        context,
                      ).push(MaterialPageRoute<void>(builder: (_) => ScanDevicePage(context.repository))),
                    ),
                  ),
                if (ready) GlassRow(icon: FLucideIcons.keyRound, label: 'Change security keys', onPressed: _changeKeys),
                if (finish)
                  GlassRow(
                    icon: FLucideIcons.keyRound,
                    label: 'Finish changing your security keys',
                    onPressed: () => _act(context.repository.changeKeys),
                  ),
                if (state.stuck && state.gone.isNotEmpty && !_busy)
                  GlassRow(
                    icon: FLucideIcons.keyRound,
                    label: finishWithout,
                    onPressed: () => _act(context.repository.finishKeysWithout),
                  ),
                if (data)
                  GlassRow(
                    label: Notice.deleteDevice.text,
                    destructive: true,
                    onPressed: () {
                      if (!_busy) unawaited(deleteThisDevice(context, devices));
                    },
                  ),
              ],
            ),
          ],
        ],
      );
    },
  );
}

/// A device: its name, its client and when it was last seen, then what marks it (this one, not seen in 45 days, never
/// set up), and Remove for one that may go.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.onRemove});

  final duvet.Device device;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final phone = device.client.startsWith('android/') || device.client.startsWith('ios/');
    final marks = [
      if (device.current) (text: 'This device', color: context.duvet.accentText),
      if (inactiveDevice(device)) (text: Notice.inactiveDevice.text, color: colors.error),
      if (!device.listed) (text: 'Not set up', color: colors.mutedForeground),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ExcludeSemantics(
              child: Icon(phone ? FLucideIcons.smartphone : FLucideIcons.monitor, size: 22, color: colors.foreground),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name, style: DuvetType.rowTitle.copyWith(fontSize: 15, color: colors.foreground)),
                Text(
                  '${device.client} · ${lastSeen(device.lastSeenAt)}',
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
                for (final mark in marks) Text(mark.text, style: DuvetType.caption.copyWith(color: mark.color)),
              ],
            ),
          ),
          if (onRemove case final remove?)
            Semantics(
              label: 'Remove ${device.name}',
              button: true,
              excludeSemantics: true,
              onTap: remove,
              child: TextAction(label: 'Remove', onPressed: remove, color: colors.error),
            ),
        ],
      ),
    );
  }
}

/// The encrypted backup's row: its name, and how it is.
class _BackupRow extends StatelessWidget {
  const _BackupRow(this.backup);

  final BackupShown backup;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ExcludeSemantics(child: Icon(FLucideIcons.archiveRestore, size: 22, color: colors.foreground)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(Notice.backup.text, style: DuvetType.rowTitle.copyWith(fontSize: 15, color: colors.foreground)),
                  Text(
                    backupLine(backup),
                    style: DuvetType.caption.copyWith(
                      color: backup.stage == BackupStage.paused ? colors.error : colors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tells the person, wherever they are in the app, what the engine tells of their other devices: one added, one not
/// seen in 45 days (Task 25), in the notices' words. Under the app's [FToaster], over every screen.
class DeviceNotices extends StatefulWidget {
  const DeviceNotices({required this.notices, required this.child, super.key});

  final Stream<String> notices;
  final Widget child;

  @override
  State<DeviceNotices> createState() => _DeviceNoticesState();
}

class _DeviceNoticesState extends State<DeviceNotices> {
  late StreamSubscription<String> _heard;

  @override
  void initState() {
    super.initState();
    _heard = widget.notices.listen(_tell);
  }

  @override
  void didUpdateWidget(DeviceNotices old) {
    super.didUpdateWidget(old);
    if (identical(old.notices, widget.notices)) return;
    unawaited(_heard.cancel());
    _heard = widget.notices.listen(_tell);
  }

  void _tell(String notice) {
    if (mounted) showFToast(context: context, title: Text(notice), duration: const Duration(seconds: 10));
  }

  @override
  void dispose() {
    unawaited(_heard.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
