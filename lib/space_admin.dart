import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'account.dart' show CropPage, formatBytes;
import 'data/models.dart';
import 'data/scope.dart';
import 'people.dart' show SquareCheck;
import 'spaces.dart' show deleteSpace, inviteRoomOf, pickSpaceIcon, showInviteSheet;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';

/// Picks a Space's banner; tests swap in their own.
Future<String?> Function() pickSpaceImage = () async =>
    (await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 90))?.path;

/// Picks an emoji's or a sticker's picture as it is: resized, Android's picker
/// would make a GIF a still image. Tests swap in their own.
Future<String?> Function() pickAssetImage = () async =>
    (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;

/// The sides of what the desktop's image editor makes of an emoji and a
/// sticker: a PNG this size is always under the API's caps.
const emojiSide = 128;
const stickerSide = 320;

/// The API's caps on an emoji's and a sticker's file: its bytes, and the
/// pixels of each side.
const emojiCap = (bytes: 256 * 1024, side: 512);
const stickerCap = (bytes: 512 * 1024, side: 1024);

/// A GIF's size as the API reads it (its header's screen, and its bytes),
/// whether it moves, and whether it can be read at all; null for any other
/// picture, of which only the header is read.
Future<({int width, int height, int bytes, bool animated, bool readable})?> gifAt(String path) async {
  final file = File(path);
  final opened = await file.open();
  final Uint8List header;
  try {
    header = await opened.read(10);
  } finally {
    await opened.close();
  }
  if (header.length < 10 || !const ['GIF87a', 'GIF89a'].contains(String.fromCharCodes(header, 0, 6))) return null;
  // Its frames tell whether it moves.
  final data = await file.readAsBytes();
  var animated = false;
  var readable = true;
  try {
    final codec = await ui.instantiateImageCodec(data);
    animated = codec.frameCount > 1;
    codec.dispose();
  } catch (e) {
    // The cropper couldn't show it either: the caller says so.
    debugPrint('gif: $e');
    readable = false;
  }
  return (
    width: header[6] | header[7] << 8,
    height: header[8] | header[9] << 8,
    bytes: data.length,
    animated: animated,
    readable: readable,
  );
}

/// The part of the picture at [path] that [crop] frames, drawn [side] pixels
/// square, as a PNG.
Future<Uint8List> squarePng(String path, CropRect crop, int side) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  final ui.Image picture;
  try {
    picture = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    picture,
    Rect.fromLTWH(crop.x, crop.y, crop.w, crop.h),
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..filterQuality = FilterQuality.high,
  );
  final drawing = recorder.endRecording();
  final square = await drawing.toImage(side, side);
  try {
    return (await square.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  } finally {
    picture.dispose();
    drawing.dispose();
    square.dispose();
  }
}

/// [squarePng] in a file to upload, named after the picture, as the desktop
/// names it; answers its path. Tests swap in their own.
Future<String> Function(String path, CropRect crop, int side) saveSquareImage = (path, crop, side) async {
  final png = await squarePng(path, crop, side);
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  final dir = Directory('${(await getTemporaryDirectory()).path}/square');
  await dir.create(recursive: true);
  final file = File('${dir.path}/${dot > 0 ? name.substring(0, dot) : 'image'}.png');
  await file.writeAsBytes(png, flush: true);
  return file.path;
};

/// Space settings: the Space, then its rooms, emojis and stickers; its
/// roles and invites; its webhooks and storage. Each row shows only to those
/// who may change what it opens.
class SpaceSettingsPage extends StatefulWidget {
  final String spaceId;
  const SpaceSettingsPage({required this.spaceId, super.key});

  @override
  State<SpaceSettingsPage> createState() => _SpaceSettingsPageState();
}

class _SpaceSettingsPageState extends State<SpaceSettingsPage> {
  int? _invites;
  (int, int)? _assets;
  int? _webhooks;
  int? _storage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _count();
  }

  // The counts beside the rows: best effort.
  void _count() {
    final repository = context.repository;
    final id = widget.spaceId;
    final profile = repository.spaceProfile(id);
    if (profile == null) return;
    void ignore(Object e) => debugPrint('space settings: $e');
    if (profile.can(Perm.manageInvites)) {
      repository.spaceInvites(id).then((l) => mounted ? setState(() => _invites = l.length) : null, onError: ignore);
    }
    if (profile.can(Perm.manageEmojis) || profile.can(Perm.manageStickers)) {
      (
        repository.assets(id, AssetKind.emoji),
        repository.assets(id, AssetKind.sticker),
      ).wait.then((l) => mounted ? setState(() => _assets = (l.$1.length, l.$2.length)) : null, onError: ignore);
    }
    if (profile.can(Perm.manageWebhooks)) {
      repository.webhooks(id).then((l) => mounted ? setState(() => _webhooks = l.length) : null, onError: ignore);
    }
    if (profile.can(Perm.manageAttachments) || profile.can(Perm.manageBuckets)) {
      repository.spaceStorage(id).then((s) => mounted ? setState(() => _storage = s.used) : null, onError: ignore);
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) setState(_count);
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return ValueListenableBuilder(
      valueListenable: repository.spaces,
      builder: (context, spaces, _) {
        final space = spaces.where((s) => s.id == widget.spaceId).firstOrNull;
        final profile = repository.spaceProfile(widget.spaceId);
        if (space == null || profile == null) {
          return const AdminPage(title: 'Space settings', children: [ListNote('This Space is gone')]);
        }
        final id = space.id;
        final rooms = repository.adminRooms(id).where((r) => r.kind != AdminRoomKind.category).length;
        final roles = repository.roles(id).length;
        final groups = <(String, List<Widget>)>[
          (
            'Space',
            [
              if (profile.can(Perm.administrator))
                GlassRow(
                  icon: FLucideIcons.squarePen,
                  label: 'Overview',
                  detail: 'Name, icon, banner',
                  onPressed: () => _open(SpaceOverviewPage(spaceId: id)),
                ),
              // ManageChannels in the Space makes rooms; in a room, runs it.
              if (profile.can(Perm.manageChannels) || profile.managesRooms)
                GlassRow(
                  icon: FLucideIcons.hash,
                  label: 'Rooms',
                  detail: '$rooms',
                  onPressed: () => _open(RoomsAdminPage(spaceId: id)),
                ),
              if (profile.can(Perm.manageEmojis) || profile.can(Perm.manageStickers))
                GlassRow(
                  icon: FLucideIcons.smile,
                  label: 'Emojis and stickers',
                  detail: _assets == null ? null : '${_assets!.$1} · ${_assets!.$2}',
                  onPressed: () => _open(AssetsPage(spaceId: id)),
                ),
            ],
          ),
          (
            'People',
            [
              if (profile.can(Perm.manageRoles))
                GlassRow(
                  icon: FLucideIcons.shield,
                  label: 'Roles',
                  detail: '$roles',
                  onPressed: () => _open(RolesPage(spaceId: id)),
                ),
              if (profile.can(Perm.manageInvites))
                GlassRow(
                  icon: FLucideIcons.link,
                  label: 'Invites',
                  detail: _invites == null ? null : '$_invites active',
                  onPressed: () => _open(InvitesAdminPage(spaceId: id)),
                ),
            ],
          ),
          (
            'Integrations',
            [
              if (profile.can(Perm.manageWebhooks))
                GlassRow(
                  icon: FLucideIcons.webhook,
                  label: 'Webhooks',
                  detail: _webhooks == null ? null : '$_webhooks',
                  onPressed: () => _open(WebhooksPage(spaceId: id)),
                ),
              if (profile.can(Perm.manageAttachments) || profile.can(Perm.manageBuckets))
                GlassRow(
                  icon: FLucideIcons.database,
                  label: 'Storage',
                  detail: _storage == null ? null : '${formatBytes(_storage!)} used',
                  onPressed: () => _open(SpaceStoragePage(spaceId: id)),
                ),
            ],
          ),
        ];
        return AdminPage(
          title: 'Space settings',
          backLabel: 'Back to ${space.name}',
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                boxShadow: tokens.shadowRaised,
              ),
              child: Row(
                children: [
                  ExcludeSemantics(child: SpaceIcon(space: space, size: 64)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(space.name, style: DuvetType.title.copyWith(color: colors.foreground)),
                        const SizedBox(height: 4),
                        Text(
                          '${profile.memberCount} ${profile.memberCount == 1 ? 'member' : 'members'} · ${profile.standing}',
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            for (final (name, rows) in groups)
              if (rows.isNotEmpty) ...[Overline(name), AdminPanel(children: rows)],
            if (profile.owner) ...[
              const SizedBox(height: 32),
              DuvetButton(
                label: 'Delete Space',
                variant: ButtonVariant.destructive,
                expand: true,
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  if (await deleteSpace(context, space)) navigator.popUntil((r) => r.isFirst);
                },
              ),
            ],
          ],
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Shared pieces
// -----------------------------------------------------------------------------

/// A settings page: the glass bar over a list, and [bottom]'s button, if
/// any, pinned under it.
class AdminPage extends StatelessWidget {
  final String title;
  final String? backLabel;
  final List<Widget> actions;
  final List<Widget> children;

  /// In place of [children]: a list of its own, given the padding that
  /// clears the bars.
  final Widget Function(EdgeInsets padding)? list;
  final Widget? bottom;
  const AdminPage({
    required this.title,
    this.children = const [],
    this.list,
    this.bottom,
    this.backLabel,
    this.actions = const [],
    super.key,
  });

  /// The bottom area: 16 around a 48 button.
  static const _bottomBar = 16 + 48 + 16.0;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final clear = EdgeInsets.fromLTRB(
      16,
      GlassTopBar.heightOf(context) + 8,
      16,
      padding.bottom + 24 + (bottom == null ? 0 : _bottomBar),
    );
    return Scaffold(
      backgroundColor: context.theme.colors.background,
      // A sheet's keyboard mustn't lift the bottom button over the page.
      resizeToAvoidBottomInset: bottom == null,
      body: Stack(
        children: [
          Positioned.fill(
            child: list?.call(clear) ?? ListView(padding: clear, children: children),
          ),
          if (bottom case final bottom?)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Stack(
                children: [
                  // The list fades out under the button rather than ending at
                  // a bar's edge; rows show through, and take taps, beside it.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              context.theme.colors.background.withValues(alpha: 0),
                              context.theme.colors.background,
                            ],
                            stops: const [0, 0.45],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 24, 16, 16 + padding.bottom),
                    child: Center(child: bottom),
                  ),
                ],
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title: Semantics(header: true, child: Text(title)),
              onBack: () => Navigator.of(context).maybePop(),
              actions: actions,
            ),
          ),
        ],
      ),
    );
  }
}

/// Rows on one raised panel.
class AdminPanel extends StatelessWidget {
  final List<Widget> children;
  const AdminPanel({required this.children, super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: context.theme.colors.card,
      borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
      boxShadow: context.duvet.shadowRest,
    ),
    child: Column(children: children),
  );
}

/// Asks before something that can't be undone.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showGlassDialogSheet<bool>(
      context,
      label: title,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
            const SizedBox(height: 12),
            Text(body, style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground)),
            const SizedBox(height: 24),
            DuvetButton(
              label: action,
              variant: ButtonVariant.destructive,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 12),
            DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
          ],
        ),
      ),
    ) ==
    true;

/// Asks for a name (and, with [choices], one of them); null when cancelled.
Future<(String, T?)?> askName<T>(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = 'Name',
  String action = 'Save',
  Map<T, String> choices = const {},
  T? choice,
}) => showGlassDialogSheet<(String, T?)>(
  context,
  label: title,
  builder: (context) =>
      _NameSheet<T>(title: title, initial: initial, label: label, action: action, choices: choices, choice: choice),
);

class _NameSheet<T> extends StatefulWidget {
  final String title;
  final String initial;
  final String label;
  final String action;
  final Map<T, String> choices;
  final T? choice;
  const _NameSheet({
    required this.title,
    required this.initial,
    required this.label,
    required this.action,
    required this.choices,
    required this.choice,
  });

  @override
  State<_NameSheet<T>> createState() => _NameSheetState<T>();
}

class _NameSheetState<T> extends State<_NameSheet<T>> {
  late final _name = TextEditingController(text: widget.initial);
  late T? _choice = widget.choice;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
        const SizedBox(height: 16),
        DuvetTextField(label: widget.label, controller: _name, autofocus: true),
        if (widget.choices.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final MapEntry(:key, :value) in widget.choices.entries)
                DuvetChip(label: value, selected: _choice == key, onTap: () => setState(() => _choice = key)),
            ],
          ),
        ],
        const SizedBox(height: 16),
        DuvetButton(
          label: widget.action,
          variant: ButtonVariant.primary,
          expand: true,
          onPressed: _name.text.trim().isEmpty ? null : () => Navigator.of(context).pop((_name.text.trim(), _choice)),
        ),
      ],
    ),
  );
}

void _toast(BuildContext context, String message) {
  if (!context.mounted) return;
  showFToast(context: context, title: Text(message), duration: const Duration(seconds: 3));
}

/// Runs a change, saying so if it fails; true when it worked.
Future<bool> _try(BuildContext context, String failure, Future<void> Function() change) async {
  try {
    await change();
    return true;
  } catch (e) {
    debugPrint('space admin: $e');
    if (context.mounted) _toast(context, e is ActionFailed ? e.message : failure);
    return false;
  }
}

// -----------------------------------------------------------------------------
// Overview
// -----------------------------------------------------------------------------

/// The Space's name, what it's about, its icon and banner.
class SpaceOverviewPage extends StatefulWidget {
  final String spaceId;
  const SpaceOverviewPage({required this.spaceId, super.key});

  @override
  State<SpaceOverviewPage> createState() => _SpaceOverviewPageState();
}

class _SpaceOverviewPageState extends State<SpaceOverviewPage> {
  late final SpaceProfile? _profile = context.repository.spaceProfile(widget.spaceId);
  late final _name = TextEditingController(text: _profile?.name);
  late final _about = TextEditingController(text: _profile?.description);
  String? _icon;
  String? _banner;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = _profile;
    final name = _name.text.trim();
    if (p == null || name.isEmpty) return;
    final about = _about.text.trim();
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await _try(
      context,
      'Couldn’t save the Space',
      () => context.repository.updateSpace(
        p.id,
        name: name == p.name ? null : name,
        description: about == (p.description ?? '') ? null : about,
        iconPath: _icon,
        bannerPath: _banner,
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final p = _profile;
    Widget picked(String label, String? path, VoidCallback onTap) => GlassRow(
      icon: FLucideIcons.image,
      label: label,
      detail: path == null ? 'Choose' : 'New one chosen',
      onPressed: onTap,
    );
    return AdminPage(
      title: 'Overview',
      actions: [TextAction(label: 'Save', onPressed: _saving || p == null ? null : _save)],
      children: [
        if (p == null)
          const ListNote('This Space is gone')
        else ...[
          const SizedBox(height: 8),
          DuvetTextField(label: 'Name', controller: _name),
          const SizedBox(height: 16),
          DuvetTextField(label: 'What it’s about', controller: _about, maxLines: 3),
          const Overline('Pictures'),
          AdminPanel(
            children: [
              picked('Icon', _icon, () async {
                final path = await pickSpaceIcon();
                if (path != null && mounted) setState(() => _icon = path);
              }),
              picked('Banner', _banner, () async {
                final path = await pickSpaceImage();
                if (path != null && mounted) setState(() => _banner = path);
              }),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Everyone in the Space sees the change.',
            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
          ),
        ],
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Rooms
// -----------------------------------------------------------------------------

/// The Space's rooms by category: add, rename, move, delete, and who may do
/// what in each.
class RoomsAdminPage extends StatefulWidget {
  final String spaceId;
  const RoomsAdminPage({required this.spaceId, super.key});

  @override
  State<RoomsAdminPage> createState() => _RoomsAdminPageState();
}

class _RoomsAdminPageState extends State<RoomsAdminPage> {
  List<AdminRoom> get _all => context.repository.adminRooms(widget.spaceId);

  /// What to make, then its name and, for a room, its category.
  Future<void> _create() async {
    final kind = await showGlassDialogSheet<AdminRoomKind>(
      context,
      label: 'Create room',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetTitle(title: 'Create room'),
          for (final (kind, icon, label, hint) in [
            (AdminRoomKind.text, FLucideIcons.hash, 'Text room', 'Messages, pictures and files'),
            (AdminRoomKind.voice, FLucideIcons.volume2, 'Voice room', 'Talk, and share a screen'),
            (AdminRoomKind.category, FLucideIcons.folder, 'Category', 'A heading to group rooms under'),
          ])
            GlassRow(icon: icon, label: label, detail: hint, onPressed: () => Navigator.of(context).pop(kind)),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (kind == null || !mounted) return;
    final categories = kind == AdminRoomKind.category
        ? const <AdminRoom>[]
        : _all.where((r) => r.kind == AdminRoomKind.category).toList();
    final got = await askName<String>(
      context,
      title: switch (kind) {
        AdminRoomKind.text => 'New text room',
        AdminRoomKind.voice => 'New voice room',
        AdminRoomKind.category => 'New category',
      },
      action: 'Create',
      choices: categories.isEmpty ? const {} : {'': 'No category', for (final c in categories) c.id: c.name},
      choice: '',
    );
    if (got == null || !mounted) return;
    final (name, parent) = got;
    await _try(
      context,
      'Couldn’t create ${kind == AdminRoomKind.category ? name : '#$name'}',
      () => context.repository.createRoom(
        widget.spaceId,
        name,
        kind,
        parentId: parent == null || parent.isEmpty ? null : parent,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _options(AdminRoom room) async {
    final label = room.kind == AdminRoomKind.category ? room.name : '#${room.name}';
    final picked = await showGlassSheet<String>(
      context,
      label: label,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          SheetTitle(title: label),
          GlassRow(icon: FLucideIcons.pencil, label: 'Rename', onPressed: () => Navigator.of(context).pop('rename')),
          if (room.kind != AdminRoomKind.category &&
              (room.parentId != null || _all.any((c) => c.kind == AdminRoomKind.category)))
            GlassRow(
              icon: FLucideIcons.folderInput,
              label: 'Move to…',
              onPressed: () => Navigator.of(context).pop('move'),
            ),
          if (room.kind != AdminRoomKind.category)
            GlassRow(
              icon: FLucideIcons.shield,
              label: 'Permissions',
              onPressed: () => Navigator.of(context).pop('perms'),
            ),
          GlassRow(
            icon: FLucideIcons.trash2,
            label: 'Delete',
            destructive: true,
            onPressed: () => Navigator.of(context).pop('delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final repository = context.repository;
    final id = widget.spaceId;
    switch (picked) {
      case 'rename':
        final got = await askName<void>(context, title: 'Rename $label', initial: room.name);
        if (got == null || !mounted) return;
        await _try(context, 'Couldn’t rename $label', () => repository.renameRoom(id, room.id, got.$1));
      case 'move':
        await _moveTo(room);
      case 'perms':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RoomPermissionsPage(spaceId: id, room: room),
          ),
        );
      case 'delete':
        final sure = await confirmDestructive(
          context,
          title: 'Delete $label?',
          body: room.kind == AdminRoomKind.category
              ? 'Its rooms stay, without a category.'
              : 'Its messages go with it, for everyone. This can’t be undone.',
          action: 'Delete',
        );
        if (!sure || !mounted) return;
        await _try(context, 'Couldn’t delete $label', () => repository.deleteRoom(id, room.id));
    }
    if (mounted) setState(() {});
  }

  /// The rooms in [parent], or with none outside any category, by position.
  List<AdminRoom> _roomsIn(List<AdminRoom> all, String? parent) {
    final categories = {
      for (final r in all)
        if (r.kind == AdminRoomKind.category) r.id,
    };
    return [
      for (final r in all)
        if (r.kind != AdminRoomKind.category &&
            (parent == null ? !categories.contains(r.parentId) : r.parentId == parent))
          r,
    ];
  }

  /// Moves [moved] into [parent] (a category stays out of any), to [to]
  /// among [others] there: before the one now at [to], or last.
  Future<void> _move(AdminRoom moved, List<AdminRoom> others, int to, {String? parent}) => _place(
    moved,
    parent,
    to < others.length
        ? others[to].position
        : _all
                  .where((r) => r.id != moved.id && r.parentId == parent)
                  .fold(-1, (p, r) => r.position > p ? r.position : p) +
              1,
  );

  /// Sends [moved] to [position] in [parent], as the API takes it.
  Future<void> _place(AdminRoom moved, String? parent, int position) async {
    final label = moved.kind == AdminRoomKind.category ? moved.name : '#${moved.name}';
    final change = context.repository.moveRoom(widget.spaceId, moved.id, parentId: parent, position: position);
    setState(() {});
    await _try(context, 'Couldn’t move $label', () => change);
    if (mounted) setState(() {});
  }

  /// Another category for a room, or none: first in a category, as the
  /// desktop drops one in, or after the rooms outside any (the categories,
  /// which share their positions, are listed apart).
  Future<void> _moveTo(AdminRoom room) async {
    final options = [
      if (room.parentId != null) (id: '', name: 'No category'),
      for (final c in _all)
        if (c.kind == AdminRoomKind.category && c.id != room.parentId) (id: c.id, name: c.name),
    ];
    final picked = await showGlassSheet<String>(
      context,
      label: 'Move #${room.name} to',
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          SheetTitle(title: 'Move #${room.name} to'),
          for (final o in options)
            GlassRow(
              icon: o.id.isEmpty ? null : FLucideIcons.folder,
              label: o.name,
              onPressed: () => Navigator.of(context).pop(o.id),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.isNotEmpty) return _place(room, picked, 0);
    final loose = _roomsIn(_all, null).where((r) => r.id != room.id);
    await _place(room, null, loose.fold(-1, (p, r) => r.position > p ? r.position : p) + 1);
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder(valueListenable: context.repository.spaces, builder: (context, _, _) => _build(context));

  Widget _build(BuildContext context) {
    final colors = context.theme.colors;
    final all = _all;
    final categories = all.where((r) => r.kind == AdminRoomKind.category).toList();
    final loose = _roomsIn(all, null);
    final tokens = context.duvet;
    final repository = context.repository;
    // The API checks ManageChannels in the room itself, overwrites included,
    // to change, move or delete it, and in the Space to make one.
    bool manages(AdminRoom r) => repository.canInRoom(widget.spaceId, r.id, Perm.manageChannels);
    final makes = repository.spaceProfile(widget.spaceId)?.can(Perm.manageChannels) ?? false;
    // The trailing edge, ridged like a grip: drag it to move the row, in the
    // list it's nearest to. Down a panel the edges make one ridge.
    Widget grip(int index) => ReorderableDragStartListener(
      index: index,
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('grip'),
          width: 32,
          decoration: BoxDecoration(
            color: colors.secondary,
            border: Border(left: BorderSide(color: tokens.hairline)),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                  width: 14,
                  height: 2,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(color: colors.mutedForeground, borderRadius: BorderRadius.circular(1)),
                ),
            ],
          ),
        ),
      ),
    );
    // A plain row on its panel, with its edge to drag by when it may move.
    Widget row(Widget body, int index, {double indent = 0, bool moves = true}) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: indent),
              child: body,
            ),
          ),
          if (moves) grip(index),
        ],
      ),
    );
    // One raised panel: the rooms outside any category, or a category's.
    Widget panel(Widget child, {Key? key}) => Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
        boxShadow: tokens.shadowRaised,
      ),
      child: child,
    );
    // A room off its panel while held: raised on its own.
    Widget liftRow(Widget child, int _, Animation<double> _) => Transform.scale(
      scale: 1.02,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
          boxShadow: tokens.shadowRaised,
        ),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
    // A category's panel is its own surface: only lifted a little.
    Widget liftPanel(Widget child, int _, Animation<double> _) => Material(
      type: MaterialType.transparency,
      child: Transform.scale(scale: 1.02, child: child),
    );

    // One place's rooms, to reorder there.
    Widget rooms(List<AdminRoom> list, String? parent) => ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: list.length,
      onReorderItem: (from, to) {
        if (from != to && manages(list[from])) _move(list[from], [...list]..removeAt(from), to, parent: parent);
      },
      proxyDecorator: liftRow,
      itemBuilder: (context, i) {
        final r = list[i];
        final mine = manages(r);
        final body = row(
          ListRow(
            title: r.name,
            hash: r.kind == AdminRoomKind.text,
            leading: r.kind == AdminRoomKind.voice
                ? ExcludeSemantics(child: Icon(FLucideIcons.volume2, size: 20, color: colors.mutedForeground))
                : null,
            detail: switch ((r.kind == AdminRoomKind.voice, mine)) {
              (true, true) => 'Voice room. Double tap for options',
              (true, false) => 'Voice room',
              (false, true) => 'Double tap for options',
              (false, false) => null,
            },
            onTap: mine ? () => _options(r) : null,
          ),
          i,
          indent: parent == null ? 0 : 12,
          moves: mine,
        );
        return mine
            ? ReorderableDelayedDragStartListener(key: ValueKey(r.id), index: i, child: body)
            : KeyedSubtree(key: ValueKey(r.id), child: body);
      },
    );

    // A category and its rooms, on one panel: they move together.
    Widget block(int i) {
      final c = categories[i];
      final inside = _roomsIn(all, c.id);
      final mine = manages(c);
      void moveBy(int step) => _move(c, [...categories]..removeAt(i), i + step);
      final header = Semantics(
        container: true,
        button: mine,
        label: 'Category ${c.name}',
        hint: mine ? 'Double tap for options' : null,
        excludeSemantics: true,
        onTap: mine ? () => _options(c) : null,
        customSemanticsActions: {
          if (mine && i > 0) const CustomSemanticsAction(label: 'Move up'): () => moveBy(-1),
          if (mine && i < categories.length - 1) const CustomSemanticsAction(label: 'Move down'): () => moveBy(1),
        },
        // All of the row takes the tap, not only the name.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: mine ? () => _options(c) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                Icon(FLucideIcons.folder, size: 16, color: colors.mutedForeground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.name.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DuvetType.overline.copyWith(color: colors.mutedForeground),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return panel(
        key: ValueKey(c.id),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (mine)
              ReorderableDelayedDragStartListener(index: i, child: row(header, i))
            else
              row(header, i, moves: false),
            if (inside.isEmpty)
              row(
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 4, 16, 16),
                  child: Text(
                    'No rooms. Move one here from its options.',
                    style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                  ),
                ),
                i,
                moves: mine,
              )
            else
              rooms(inside, c.id),
          ],
        ),
      );
    }

    return AdminPage(
      title: 'Rooms',
      bottom: makes
          ? DuvetButton(
              label: 'Create room',
              icon: FLucideIcons.plus,
              variant: ButtonVariant.primary,
              onPressed: _create,
            )
          : null,
      list: (padding) => all.isEmpty
          ? ListView(padding: padding, children: const [ListNote('No rooms yet')])
          : ReorderableListView.builder(
              padding: padding,
              buildDefaultDragHandles: false,
              header: loose.isEmpty ? null : panel(rooms(loose, null)),
              itemCount: categories.length,
              itemBuilder: (context, i) => block(i),
              onReorderItem: (from, to) {
                if (from != to && manages(categories[from])) {
                  _move(categories[from], [...categories]..removeAt(from), to);
                }
              },
              proxyDecorator: liftPanel,
            ),
    );
  }
}

/// What each role may do in one room: allowed, denied, or as the role says.
class RoomPermissionsPage extends StatefulWidget {
  final String spaceId;
  final AdminRoom room;
  const RoomPermissionsPage({required this.spaceId, required this.room, super.key});

  @override
  State<RoomPermissionsPage> createState() => _RoomPermissionsPageState();
}

class _RoomPermissionsPageState extends State<RoomPermissionsPage> {
  late final List<SpaceRole> _roles = context.repository.roles(widget.spaceId);
  late String _role = _roles.last.id;

  // What can differ by room.
  static const _bits = <PermissionInfo>[
    (bit: Perm.viewChannels, label: 'See the room', description: 'And read its messages'),
    (bit: Perm.sendMessages, label: 'Send messages', description: 'Write here'),
    (bit: Perm.manageMessages, label: 'Delete others’ messages', description: 'Here'),
    (bit: Perm.pinMessages, label: 'Pin messages', description: 'Here'),
    (bit: Perm.createInvites, label: 'Invite people', description: 'Links to this room'),
    (bit: Perm.joinVoice, label: 'Join voice', description: 'If it’s a voice room'),
    (bit: Perm.speakInVoice, label: 'Speak', description: 'If it’s a voice room'),
  ];

  RoomOverwrite get _overwrite =>
      context.repository.overwrites(widget.spaceId, widget.room.id).where((o) => o.targetId == _role).firstOrNull ??
      RoomOverwrite(targetId: _role);

  Future<void> _set(int bit, bool? state) async {
    final next = _overwrite.withState(bit, state);
    await _try(
      context,
      'Couldn’t change the permission',
      () => context.repository.setOverwrite(widget.spaceId, widget.room.id, next),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final overwrite = _overwrite;
    return AdminPage(
      title: '#${widget.room.name}',
      children: [
        const Overline('For'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in _roles)
              DuvetChip(label: r.name, selected: r.id == _role, onTap: () => setState(() => _role = r.id)),
          ],
        ),
        const Overline('In this room'),
        AdminPanel(
          children: [
            for (final p in _bits)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.label, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                    Text(p.description, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                    const SizedBox(height: 8),
                    Semantics(
                      container: true,
                      label: p.label,
                      explicitChildNodes: true,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (final (state, label) in [(false, 'Deny'), (null, 'As the role says'), (true, 'Allow')])
                            DuvetChip(
                              label: label,
                              selected: overwrite.stateOf(p.bit) == state,
                              onTap: () => _set(p.bit, state),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Roles
// -----------------------------------------------------------------------------

/// A role's name color, readable on this theme's background.
Color? roleColorOn(BuildContext context, int? rgb) =>
    rgb == null ? null : readableOn(Color(0xFF000000 | rgb), context.theme.colors.background);

/// The Space's roles, highest first; @everyone last.
class RolesPage extends StatefulWidget {
  final String spaceId;
  const RolesPage({required this.spaceId, super.key});

  @override
  State<RolesPage> createState() => _RolesPageState();
}

class _RolesPageState extends State<RolesPage> {
  Future<void> _create() async {
    final got = await askName<void>(context, title: 'New role', action: 'Create');
    if (got == null || !mounted) return;
    final repository = context.repository;
    try {
      final role = await repository.createRole(widget.spaceId, got.$1);
      if (mounted) await _edit(role);
    } catch (e) {
      if (mounted) _toast(context, e is ActionFailed ? e.message : 'Couldn’t create the role');
    }
  }

  Future<void> _edit(SpaceRole role) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoleEditorPage(spaceId: widget.spaceId, role: role),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final roles = context.repository.roles(widget.spaceId);
    return AdminPage(
      title: 'Roles',
      actions: [IconAction(icon: FLucideIcons.plus, label: 'New role', onPressed: _create)],
      children: [
        for (final r in roles)
          ListRow(
            leading: ExcludeSemantics(
              child: Icon(
                FLucideIcons.shield,
                size: 24,
                color: roleColorOn(context, r.color) ?? colors.mutedForeground,
              ),
            ),
            title: r.name,
            snippet: r.everyone
                ? 'Everyone in the Space'
                : '${r.memberCount} ${r.memberCount == 1 ? 'member' : 'members'}',
            onTap: () => _edit(r),
          ),
      ],
    );
  }
}

/// A role: its name and color, who has it, and what it may do.
class RoleEditorPage extends StatefulWidget {
  final String spaceId;
  final SpaceRole role;
  const RoleEditorPage({required this.spaceId, required this.role, super.key});

  @override
  State<RoleEditorPage> createState() => _RoleEditorPageState();
}

class _RoleEditorPageState extends State<RoleEditorPage> {
  late final _name = TextEditingController(text: widget.role.name);
  late int? _color = widget.role.color;
  late int _perms = widget.role.perms;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final r = widget.role;
    final name = _name.text.trim();
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await _try(
      context,
      'Couldn’t save ${r.name}',
      () => context.repository.updateRole(
        widget.spaceId,
        r.id,
        name: r.everyone || name.isEmpty || name == r.name ? null : name,
        color: _color != r.color ? _color : null,
        clearColor: _color == null && r.color != null,
        perms: _perms != r.perms ? _perms : null,
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) navigator.pop();
  }

  Future<void> _pickColor() async {
    final colors = context.theme.colors;
    final picked = await showGlassSheet<int>(
      context,
      label: 'Name color',
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          const SheetTitle(title: 'Name color', caption: 'Names only, never fills'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final rgb in [-1, ...roleSwatches])
                  Semantics(
                    container: true,
                    button: true,
                    selected: (_color ?? -1) == rgb,
                    label: rgb == -1 ? 'Default' : '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}',
                    excludeSemantics: true,
                    onTap: () => Navigator.of(context).pop(rgb),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(rgb),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: rgb == -1 ? colors.foreground : roleColorOn(context, rgb),
                          borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                          border: (_color ?? -1) == rgb ? Border.all(color: context.duvet.accentText, width: 3) : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _color = picked == -1 ? null : picked);
  }

  Future<void> _members() async {
    final repository = context.repository;
    final members = await repository.members(
      RoomTarget(
        spaceId: widget.spaceId,
        roomId: repository.adminRooms(widget.spaceId).where((r) => r.kind == AdminRoomKind.text).firstOrNull?.id ?? '',
      ),
    );
    if (!mounted) return;
    await showGlassSheet<void>(
      context,
      label: 'Who has ${widget.role.name}',
      initialSize: 0.75,
      builder: (context, scroll) => StatefulBuilder(
        builder: (context, setSheet) {
          final holders = repository.roleMembers(widget.spaceId, widget.role.id).toSet();
          return ListView(
            controller: scroll,
            children: [
              SheetTitle(title: 'Who has ${widget.role.name}'),
              for (final m in members)
                Semantics(
                  container: true,
                  checked: holders.contains(m.userId),
                  label: m.displayName,
                  excludeSemantics: true,
                  onTap: () => _toggle(m, !holders.contains(m.userId), setSheet),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _toggle(m, !holders.contains(m.userId), setSheet),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          UserAvatar(name: m.displayName, url: m.avatarUrl, size: 40),
                          const SizedBox(width: 12),
                          Expanded(child: Text(m.displayName, style: DuvetType.rowTitle)),
                          SquareCheck(checked: holders.contains(m.userId)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggle(Member m, bool has, StateSetter setSheet) async {
    await _try(
      context,
      'Couldn’t change ${m.displayName}’s roles',
      () => context.repository.setRole(widget.spaceId, widget.role.id, m.userId, has: has),
    );
    setSheet(() {});
  }

  Future<void> _delete() async {
    final sure = await confirmDestructive(
      context,
      title: 'Delete ${widget.role.name}?',
      body: 'Everyone who has it loses it. This can’t be undone.',
      action: 'Delete role',
    );
    if (!sure || !mounted) return;
    final navigator = Navigator.of(context);
    if (await _try(
      context,
      'Couldn’t delete the role',
      () => context.repository.deleteRole(widget.spaceId, widget.role.id),
    )) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final r = widget.role;
    final holders = context.repository.roleMembers(widget.spaceId, r.id);
    final admin = Perm.has(_perms, Perm.administrator);
    return AdminPage(
      title: 'Edit role',
      actions: [TextAction(label: 'Save', onPressed: _saving ? null : _save)],
      children: [
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: r.everyone
                  ? Text(r.name, style: DuvetType.title.copyWith(color: colors.foreground))
                  : DuvetTextField(label: 'Role name', controller: _name),
            ),
            const SizedBox(width: 12),
            Semantics(
              container: true,
              button: true,
              label:
                  'Name color: ${_color == null ? 'default' : '#${_color!.toRadixString(16).padLeft(6, '0').toUpperCase()}'}',
              excludeSemantics: true,
              onTap: _pickColor,
              child: GestureDetector(
                onTap: _pickColor,
                child: Container(
                  width: 96,
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: colors.card,
                    borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                    border: Border.all(color: context.duvet.hairline),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: roleColorOn(context, _color) ?? colors.foreground,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      Icon(FLucideIcons.chevronDown, size: 16, color: colors.mutedForeground),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (!r.everyone) ...[
          const SizedBox(height: 16),
          AdminPanel(
            children: [
              GlassRow(
                icon: FLucideIcons.users,
                label: '${holders.length} ${holders.length == 1 ? 'member' : 'members'}',
                detail: 'Manage',
                onPressed: _members,
              ),
            ],
          ),
        ],
        for (final (group, perms) in permissionGroups) ...[
          Overline(group),
          AdminPanel(
            children: [
              for (final p in perms)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.label, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                            Text(p.description, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      DuvetSwitch(
                        label: p.label,
                        value: _perms & p.bit != 0 || (admin && p.bit != Perm.administrator),
                        onChanged: admin && p.bit != Perm.administrator
                            ? null
                            : (on) => setState(() => _perms = on ? _perms | p.bit : _perms & ~p.bit),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
        if (!r.everyone) ...[
          const SizedBox(height: 24),
          DuvetButton(label: 'Delete role', variant: ButtonVariant.destructive, expand: true, onPressed: _delete),
        ],
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Invites
// -----------------------------------------------------------------------------

/// Every invite link to the Space: who made it, where it leads, until when;
/// revoke any.
class InvitesAdminPage extends StatefulWidget {
  final String spaceId;
  const InvitesAdminPage({required this.spaceId, super.key});

  @override
  State<InvitesAdminPage> createState() => _InvitesAdminPageState();
}

class _InvitesAdminPageState extends State<InvitesAdminPage> {
  late Future<List<SpaceInvite>> _invites;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _invites = context.repository.spaceInvites(widget.spaceId);
  }

  void _reload() => setState(() {
    _invites = context.repository.spaceInvites(widget.spaceId);
  });

  static String _until(DateTime? t) {
    if (t == null) return 'never expires';
    final left = t.difference(DateTime.now());
    if (left.isNegative) return 'expired';
    if (left.inDays >= 1) return 'expires in ${left.inDays} ${left.inDays == 1 ? 'day' : 'days'}';
    if (left.inHours >= 1) return 'expires in ${left.inHours} h';
    return 'expires in ${left.inMinutes} min';
  }

  Future<void> _revoke(SpaceInvite i) async {
    final sure = await confirmDestructive(
      context,
      title: 'Revoke ${i.code}?',
      body: 'The link stops working. People who joined with it stay.',
      action: 'Revoke link',
    );
    if (!sure || !mounted) return;
    await _try(context, 'Couldn’t revoke the link', () => context.repository.revokeInvite(widget.spaceId, i.id));
    if (mounted) _reload();
  }

  Future<void> _new() async {
    final repository = context.repository;
    final space = repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull;
    final room = space == null ? null : inviteRoomOf(repository, space);
    if (space == null || room == null) return;
    await showInviteSheet(context, space: space, room: room);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _invites,
    builder: (context, snapshot) {
      final invites = snapshot.data;
      return AdminPage(
        title: 'Invites',
        actions: [IconAction(icon: FLucideIcons.plus, label: 'New invite', onPressed: _new)],
        children: [
          if (snapshot.hasError)
            const ListNote('Couldn’t load the invites')
          else if (invites == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: FCircularProgress()),
            )
          else if (invites.isEmpty)
            const ListNote('No invite links')
          else
            for (final i in invites)
              ListRow(
                title: i.code,
                snippet: '#${i.roomName} · ${i.createdBy} · ${_until(i.expiresAt)}',
                detail: 'Double tap to revoke',
                onTap: () => _revoke(i),
              ),
        ],
      );
    },
  );
}

// -----------------------------------------------------------------------------
// Emojis and stickers
// -----------------------------------------------------------------------------

/// The Space's emojis or stickers: add, rename, delete.
class AssetsPage extends StatefulWidget {
  final String spaceId;
  const AssetsPage({required this.spaceId, super.key});

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  // The kind the user may change first.
  late AssetKind _kind = _may(AssetKind.emoji) || !_may(AssetKind.sticker) ? AssetKind.emoji : AssetKind.sticker;
  late Future<List<SpaceAsset>> _list;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list = context.repository.assets(widget.spaceId, _kind);
  }

  /// Each kind takes its own permission, as in the API and the desktop's
  /// tabs: both lists show, the controls only where it's held.
  bool _may(AssetKind kind) =>
      context.repository
          .spaceProfile(widget.spaceId)
          ?.can(kind == AssetKind.emoji ? Perm.manageEmojis : Perm.manageStickers) ??
      false;

  void _reload() => setState(() {
    _list = context.repository.assets(widget.spaceId, _kind);
  });

  String get _noun => _kind == AssetKind.emoji ? 'emoji' : 'sticker';

  // Cropped square and sized as the desktop's image editor does (but a moving
  // GIF the API takes as it is), then named as typed (trimmed), as the
  // desktop sends it: the API takes any text.
  Future<void> _add() async {
    final path = await pickAssetImage();
    if (path == null || !mounted) return;
    final kind = _kind;
    final cap = kind == AssetKind.emoji ? emojiCap : stickerCap;
    // A moving GIF the API takes as it is goes up unchanged, still moving:
    // cropping makes a still image of it. A still GIF is cropped as any
    // picture is.
    final gif = await gifAt(path);
    if (!mounted) return;
    // The cropper would close on it without a word.
    if (gif != null && !gif.readable) {
      _toast(context, 'Couldn’t read this GIF');
      return;
    }
    final CropRect? crop;
    if (gif != null && gif.animated && gif.bytes <= cap.bytes && gif.width <= cap.side && gif.height <= cap.side) {
      crop = null;
    } else {
      crop = await Navigator.of(context).push<CropRect>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CropPage(
            path: path,
            aspect: 1,
            round: false,
            note: gif?.animated ?? false
                ? 'This GIF is over ${cap.bytes ~/ 1024} KiB or ${cap.side} px, so it goes up still: its animation is lost'
                : null,
          ),
        ),
      );
      if (crop == null || !mounted) return;
    }
    final got = await askName<void>(context, title: 'Name the $_noun', action: 'Add');
    if (got == null || !mounted) return;
    final repository = context.repository;
    await _try(context, 'Couldn’t add the $_noun', () async {
      if (crop == null) return repository.addAsset(widget.spaceId, kind, got.$1, path);
      final square = await saveSquareImage(path, crop, kind == AssetKind.emoji ? emojiSide : stickerSide);
      try {
        await repository.addAsset(widget.spaceId, kind, got.$1, square);
      } finally {
        // Best effort: the list needn't wait for it.
        unawaited(File(square).delete().then((_) {}, onError: (Object e) => debugPrint('square image: $e')));
      }
    });
    if (mounted) _reload();
  }

  Future<void> _options(SpaceAsset a) async {
    final picked = await showGlassSheet<String>(
      context,
      label: a.name,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          SheetTitle(title: _kind == AssetKind.emoji ? ':${a.name}:' : a.name),
          GlassRow(icon: FLucideIcons.pencil, label: 'Rename', onPressed: () => Navigator.of(context).pop('rename')),
          GlassRow(
            icon: FLucideIcons.trash2,
            label: 'Delete',
            destructive: true,
            onPressed: () => Navigator.of(context).pop('delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final repository = context.repository;
    switch (picked) {
      case 'rename':
        final got = await askName<void>(context, title: 'Rename ${a.name}', initial: a.name);
        if (got == null || !mounted) return;
        await _try(context, 'Couldn’t rename it', () => repository.renameAsset(widget.spaceId, _kind, a.id, got.$1));
      case 'delete':
        final sure = await confirmDestructive(
          context,
          title: 'Delete ${a.name}?',
          body: 'Messages that used it show its name instead.',
          action: 'Delete $_noun',
        );
        if (!sure || !mounted) return;
        await _try(context, 'Couldn’t delete it', () => repository.deleteAsset(widget.spaceId, _kind, a.id));
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final size = _kind == AssetKind.emoji ? 48.0 : 96.0;
    final may = _may(_kind);
    return FutureBuilder(
      future: _list,
      builder: (context, snapshot) {
        final list = snapshot.data;
        return AdminPage(
          title: 'Emojis and stickers',
          actions: [if (may) IconAction(icon: FLucideIcons.plus, label: 'Add $_noun', onPressed: _add)],
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final k in AssetKind.values)
                  DuvetChip(
                    label: k == AssetKind.emoji ? 'Emojis' : 'Stickers',
                    selected: _kind == k,
                    onTap: () {
                      _kind = k;
                      _reload();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (snapshot.hasError)
              const ListNote('Couldn’t load them')
            else if (list == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: FCircularProgress()),
              )
            else if (list.isEmpty)
              ListNote('No ${_noun}s yet')
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final a in list)
                    Semantics(
                      container: true,
                      button: may,
                      label: _kind == AssetKind.emoji ? ':${a.name}:' : a.name,
                      hint: may ? 'Double tap for options' : null,
                      excludeSemantics: true,
                      onTap: may ? () => _options(a) : null,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: may ? () => _options(a) : null,
                        child: SizedBox(
                          width: size + 24,
                          child: Column(
                            children: [
                              Image.network(
                                a.url,
                                width: size,
                                height: size,
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => SizedBox.square(dimension: size),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                a.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Webhooks
// -----------------------------------------------------------------------------

/// Webhooks let other apps post in a room. Their URL is a secret: shown once,
/// when made or reset.
class WebhooksPage extends StatefulWidget {
  final String spaceId;
  const WebhooksPage({required this.spaceId, super.key});

  @override
  State<WebhooksPage> createState() => _WebhooksPageState();
}

class _WebhooksPageState extends State<WebhooksPage> {
  late Future<List<SpaceWebhook>> _list;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list = context.repository.webhooks(widget.spaceId);
  }

  void _reload() => setState(() {
    _list = context.repository.webhooks(widget.spaceId);
  });

  Future<void> _showOnce(String name, String url) => showGlassDialogSheet<void>(
    context,
    label: '$name’s URL',
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$name’s URL', style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
          const SizedBox(height: 12),
          Text(
            'Copy it now: it won’t be shown again. Anyone with it can post as $name.',
            style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.theme.colors.secondary,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            ),
            child: SelectableText(url, style: DuvetType.code.copyWith(color: context.theme.colors.foreground)),
          ),
          const SizedBox(height: 24),
          DuvetButton(
            label: 'Copy URL',
            variant: ButtonVariant.primary,
            expand: true,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    ),
  );

  Future<void> _new() async {
    final repository = context.repository;
    final rooms = repository.adminRooms(widget.spaceId).where((r) => r.kind == AdminRoomKind.text).toList();
    if (rooms.isEmpty) return;
    final got = await askName<String>(
      context,
      title: 'New webhook',
      action: 'Create',
      choices: {for (final r in rooms) r.id: '#${r.name}'},
      choice: rooms.first.id,
    );
    if (got == null || !mounted) return;
    try {
      final url = await repository.createWebhook(widget.spaceId, got.$2 ?? rooms.first.id, got.$1);
      if (mounted) await _showOnce(got.$1, url);
    } catch (e) {
      if (mounted) _toast(context, e is ActionFailed ? e.message : 'Couldn’t create the webhook');
    }
    if (mounted) _reload();
  }

  Future<void> _options(SpaceWebhook w) async {
    final picked = await showGlassSheet<String>(
      context,
      label: w.name,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          SheetTitle(title: w.name, caption: '#${w.roomName}'),
          GlassRow(
            icon: FLucideIcons.refreshCw,
            label: 'New URL',
            detail: 'The old one stops working',
            onPressed: () => Navigator.of(context).pop('reset'),
          ),
          GlassRow(
            icon: FLucideIcons.trash2,
            label: 'Delete',
            destructive: true,
            onPressed: () => Navigator.of(context).pop('delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final repository = context.repository;
    switch (picked) {
      case 'reset':
        try {
          final url = await repository.resetWebhook(widget.spaceId, w);
          if (mounted) await _showOnce(w.name, url);
        } catch (e) {
          if (mounted) _toast(context, e is ActionFailed ? e.message : 'Couldn’t make a new URL');
        }
      case 'delete':
        final sure = await confirmDestructive(
          context,
          title: 'Delete ${w.name}?',
          body: 'Apps using it can’t post any more. Its messages stay.',
          action: 'Delete webhook',
        );
        if (!sure || !mounted) return;
        await _try(context, 'Couldn’t delete it', () => repository.deleteWebhook(widget.spaceId, w));
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _list,
    builder: (context, snapshot) {
      final list = snapshot.data;
      return AdminPage(
        title: 'Webhooks',
        actions: [IconAction(icon: FLucideIcons.plus, label: 'New webhook', onPressed: _new)],
        children: [
          if (snapshot.hasError)
            const ListNote('Couldn’t load the webhooks')
          else if (list == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: FCircularProgress()),
            )
          else if (list.isEmpty)
            const ListNote('No webhooks. Make one to let another app post in a room.')
          else
            for (final w in list)
              ListRow(
                leading: ExcludeSemantics(
                  child: UserAvatar(name: w.name, url: w.avatarUrl, size: 48),
                ),
                title: w.name,
                snippet: 'Posts in #${w.roomName}',
                detail: 'Double tap for options',
                onTap: () => _options(w),
              ),
        ],
      );
    },
  );
}

// -----------------------------------------------------------------------------
// Storage
// -----------------------------------------------------------------------------

/// What the Space's files take, where they're kept, and the largest.
class SpaceStoragePage extends StatefulWidget {
  final String spaceId;
  const SpaceStoragePage({required this.spaceId, super.key});

  @override
  State<SpaceStoragePage> createState() => _SpaceStoragePageState();
}

class _SpaceStoragePageState extends State<SpaceStoragePage> {
  late final Future<SpaceStorage> _storage = context.repository.spaceStorage(widget.spaceId);

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return FutureBuilder(
      future: _storage,
      builder: (context, snapshot) {
        final s = snapshot.data;
        return AdminPage(
          title: 'Storage',
          children: [
            if (snapshot.hasError)
              const ListNote('Couldn’t load the storage')
            else if (s == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: FCircularProgress()),
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.card,
                  borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                  boxShadow: tokens.shadowRaised,
                ),
                child: Semantics(
                  label: '${formatBytes(s.used)} used by ${s.files.length} files',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(formatBytes(s.used), style: DuvetType.title.copyWith(color: colors.foreground)),
                      Text(
                        '${s.files.length} ${s.files.length == 1 ? 'file' : 'files'}',
                        style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                      ),
                    ],
                  ),
                ),
              ),
              if (s.buckets.isNotEmpty) ...[
                const Overline('Kept in'),
                AdminPanel(
                  children: [
                    for (final b in s.buckets)
                      ListRow(
                        title: b.name,
                        snippet: [
                          b.max == null
                              ? '${formatBytes(b.used)} used'
                              : '${formatBytes(b.used)} of ${formatBytes(b.max!)}',
                          if (!b.active) 'off',
                        ].join(' · '),
                      ),
                  ],
                ),
              ],
              const Overline('Largest files'),
              if (s.files.isEmpty)
                const ListNote('No files yet')
              else
                for (final f in s.files.take(20))
                  ListRow(title: f.name, snippet: '${formatBytes(f.size)} · ${shortTime(f.createdAt)}'),
            ],
          ],
        );
      },
    );
  }
}
