import 'dart:async';

import 'package:clock/clock.dart';
import 'package:duvet_client/duvet.dart' as duvet;
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/scope.dart';
import '../e2e/engine.dart';
import '../e2e/notices.dart';
import '../space_admin.dart' show AdminPage, AdminPanel, confirmDestructive;
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/rows.dart';

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
    'If no other device of yours holds your encrypted conversations, their history is lost without your recovery key. '
    "Delete this device's encrypted conversations and their keys, and sign out? Your other devices keep it on your "
    'device list until you remove it on one of them.';

/// A change of keys that can never finish (review 24's I1), and the two ways left: another device's change of keys,
/// whose transfer ends this one, or this device's data deleted.
const rotationStuck =
    "This device can't finish changing your security keys: another of your devices removed a device or changed the "
    "keys meanwhile. Change your security keys on another device, or delete this device's data.";
const deleteOnlyDeviceQuestion =
    'This is your only device with your encrypted conversations: without your recovery key, their history is lost. '
    'Delete them and their keys, and sign out?';

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
/// marked; removing another and changing the security keys while this device is ready; and deleting this device's
/// data where it has some.
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final devices = await context.repository.devices();
      if (mounted) setState(() => _devices = devices);
    } catch (error) {
      debugPrint("e2e: the user's devices: ${error.runtimeType}");
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _act(Future<void> Function() act) async {
    setState(() => _busy = true);
    try {
      await act();
    } catch (error) {
      debugPrint('e2e: what the person asked of their devices failed: ${error.runtimeType}');
      if (mounted) _toast(context, "Couldn't change your devices. Check your connection, then try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Removing another device, in the desktop's words; for one on the list, what changing the keys too does, for one
  // that was lost or stolen.
  /// What a removal or a change of keys takes along, said by name: the devices an earlier removal of this device's took
  /// off that the API didn't take, which the next list or key change takes off too (review 24's M3). Empty for none.
  Future<String> _alongWith(String? asked) async {
    final ids = await context.repository.unsentRemovals().catchError((Object _) => const <String>[]);
    final names = [
      for (final device in _devices ?? const <duvet.Device>[])
        if (ids.contains(device.id) && device.id != asked) device.name,
    ];
    return names.isEmpty
        ? ''
        : " This also takes off ${names.join(', ')}: an earlier removal of yours didn't go through.";
  }

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
          along,
      choices: [
        ('Remove', _Removal.remove, ButtonVariant.destructive),
        if (device.listed) ('Remove and change keys', _Removal.changeKeys, ButtonVariant.destructive),
      ],
    );
    if (choice == null || !mounted) return;
    await _act(() async {
      await repository.removeDevice(device.id, changeKeys: choice == _Removal.changeKeys);
      await _load();
    });
  }

  Future<void> _changeKeys() async {
    final repository = context.repository;
    final along = await _alongWith(null);
    if (!mounted) return;
    final sure = await confirmDestructive(
      context,
      title: 'Change security keys?',
      body:
          'Make new security keys and a new recovery key for your account? Your contacts will see that your keys '
          'changed.$along',
      action: 'Change keys',
      destructive: false,
    );
    if (!sure || !mounted) return;
    await _act(repository.changeKeys);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: context.repository.encryption,
    builder: (context, state, _) {
      final devices = _devices;
      // Removing and changing keys only while this device is set up and no change of keys waits.
      final ready = state.stage == EngineStage.ready && !state.rotating && !_busy;
      // A change of keys that waits, its key put off or cut by the app's close: the banner's strip may be hidden.
      final finish = state.rotating && state.recoveryKey == null && !state.stuck && !_busy;
      final data = hasDeviceData(state);
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
                child: Text(rotationStuck, style: DuvetType.caption.copyWith(color: context.theme.colors.error)),
              ),
            ),
          if (ready || finish || data) ...[
            const SizedBox(height: 16),
            AdminPanel(
              children: [
                if (ready) GlassRow(icon: FLucideIcons.keyRound, label: 'Change security keys', onPressed: _changeKeys),
                if (finish)
                  GlassRow(
                    icon: FLucideIcons.keyRound,
                    label: 'Finish changing your security keys',
                    onPressed: () => _act(context.repository.changeKeys),
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
