import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:image_picker/image_picker.dart';

import 'account.dart' show formatBytes;
import 'data/models.dart';
import 'data/scope.dart';
import 'people.dart' show SquareCheck;
import 'spaces.dart' show deleteSpace, inviteRoomOf, pickSpaceIcon, showInviteSheet;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/glass.dart';
import 'widgets/rows.dart';

/// Picks a Space's banner, an emoji or a sticker; tests swap in their own.
Future<String?> Function() pickSpaceImage = () async =>
    (await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 90))?.path;

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
              if (profile.can(Perm.manageChannels))
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

/// A settings page: the glass bar over a list.
class AdminPage extends StatelessWidget {
  final String title;
  final String? backLabel;
  final List<Widget> actions;
  final List<Widget> children;
  const AdminPage({required this.title, required this.children, this.backLabel, this.actions = const [], super.key});

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: context.theme.colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, GlassTopBar.heightOf(context) + 8, 16, padding.bottom + 24),
              children: children,
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
    padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
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

  Future<void> _create() async {
    final categories = _all.where((r) => r.kind == AdminRoomKind.category).toList();
    final kinds = {AdminRoomKind.text: 'Text', AdminRoomKind.voice: 'Voice', AdminRoomKind.category: 'Category'};
    final got = await askName<AdminRoomKind>(
      context,
      title: 'New room',
      action: 'Create',
      choices: kinds,
      choice: AdminRoomKind.text,
    );
    if (got == null || !mounted) return;
    final (name, kind) = got;
    String? parent;
    if (kind != AdminRoomKind.category && categories.isNotEmpty) {
      parent = await showGlassSheet<String>(
        context,
        label: 'Put #$name in',
        builder: (context, scroll) => ListView(
          controller: scroll,
          children: [
            SheetTitle(title: 'Put #$name in'),
            GlassRow(label: 'No category', onPressed: () => Navigator.of(context).pop('')),
            for (final c in categories) GlassRow(label: c.name, onPressed: () => Navigator.of(context).pop(c.id)),
          ],
        ),
      );
      if (parent == null || !mounted) return;
    }
    await _try(
      context,
      'Couldn’t create #$name',
      () => context.repository.createRoom(
        widget.spaceId,
        name,
        kind ?? AdminRoomKind.text,
        parentId: parent == null || parent.isEmpty ? null : parent,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _options(AdminRoom room, List<AdminRoom> siblings) async {
    final i = siblings.indexOf(room);
    final label = room.kind == AdminRoomKind.category ? room.name : '#${room.name}';
    final categories = _all.where((r) => r.kind == AdminRoomKind.category).toList();
    final category = categories.where((c) => c.id == room.parentId).firstOrNull;
    final picked = await showGlassSheet<String>(
      context,
      label: label,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          SheetTitle(title: label),
          GlassRow(icon: FLucideIcons.pencil, label: 'Rename', onPressed: () => Navigator.of(context).pop('rename')),
          if (i > 0)
            GlassRow(icon: FLucideIcons.arrowUp, label: 'Move up', onPressed: () => Navigator.of(context).pop('up')),
          if (i < siblings.length - 1)
            GlassRow(
              icon: FLucideIcons.arrowDown,
              label: 'Move down',
              onPressed: () => Navigator.of(context).pop('down'),
            ),
          // Categories don't nest.
          if (room.kind != AdminRoomKind.category && categories.isNotEmpty)
            GlassRow(
              icon: FLucideIcons.folder,
              label: 'Category',
              detail: category?.name ?? 'No category',
              onPressed: () => Navigator.of(context).pop('category'),
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
      // Where the API inserts it, counted before it leaves its place: the
      // room above's, or one past the room below's.
      case 'up':
        await _try(context, 'Couldn’t move $label', () => repository.moveRoom(id, room.id, siblings[i - 1].position));
      case 'down':
        await _try(
          context,
          'Couldn’t move $label',
          () => repository.moveRoom(id, room.id, siblings[i + 1].position + 1),
        );
      case 'category':
        final into = await showGlassSheet<String>(
          context,
          label: 'Put $label in',
          builder: (context, scroll) => ListView(
            controller: scroll,
            children: [
              SheetTitle(title: 'Put $label in'),
              GlassRow(
                label: 'No category',
                selected: category == null,
                onPressed: () => Navigator.of(context).pop(''),
              ),
              for (final c in categories)
                GlassRow(
                  label: c.name,
                  selected: c.id == category?.id,
                  onPressed: () => Navigator.of(context).pop(c.id),
                ),
            ],
          ),
        );
        if (into == null || into == (category?.id ?? '') || !mounted) return;
        await _try(
          context,
          'Couldn’t move $label',
          () => repository.setRoomCategory(id, room.id, into.isEmpty ? null : into),
        );
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

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    // Moves and deletions elsewhere (ROOM_REORDER) show as they come.
    valueListenable: context.repository.spaces,
    builder: (context, _, _) {
      final colors = context.theme.colors;
      final all = _all;
      final categories = all.where((r) => r.kind == AdminRoomKind.category).toList();
      final categoryIds = {for (final c in categories) c.id};
      // As the Space's list has them: a room whose category isn't listed is
      // outside any.
      final loose = all.where((r) => r.kind != AdminRoomKind.category && !categoryIds.contains(r.parentId)).toList();
      Widget roomRow(AdminRoom r, List<AdminRoom> siblings) => ListRow(
        title: r.name,
        hash: r.kind == AdminRoomKind.text,
        leading: r.kind == AdminRoomKind.voice
            ? ExcludeSemantics(child: Icon(FLucideIcons.volume2, size: 20, color: colors.mutedForeground))
            : null,
        detail: r.kind == AdminRoomKind.voice ? 'Voice room. Double tap for options' : 'Double tap for options',
        onTap: () => _options(r, siblings),
      );
      return AdminPage(
        title: 'Rooms',
        actions: [IconAction(icon: FLucideIcons.plus, label: 'New room', onPressed: _create)],
        children: [
          for (final r in loose) roomRow(r, loose),
          for (final c in categories) ...[
            Semantics(
              container: true,
              button: true,
              label: 'Category ${c.name}',
              hint: 'Double tap for options',
              excludeSemantics: true,
              onTap: () => _options(c, categories),
              child: GestureDetector(onTap: () => _options(c, categories), child: Overline(c.name)),
            ),
            for (final r in all.where((r) => r.parentId == c.id && r.kind != AdminRoomKind.category).toList())
              roomRow(r, all.where((o) => o.parentId == c.id && o.kind != AdminRoomKind.category).toList()),
          ],
          if (all.isEmpty) const ListNote('No rooms yet'),
        ],
      );
    },
  );
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
    } catch (_) {
      if (mounted) _toast(context, 'Couldn’t create the role');
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
  AssetKind _kind = AssetKind.emoji;
  late Future<List<SpaceAsset>> _list;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list = context.repository.assets(widget.spaceId, _kind);
  }

  void _reload() => setState(() {
    _list = context.repository.assets(widget.spaceId, _kind);
  });

  String get _noun => _kind == AssetKind.emoji ? 'emoji' : 'sticker';

  // Emoji names are `:like_this:`.
  static String _clean(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');

  Future<void> _add() async {
    final path = await pickSpaceImage();
    if (path == null || !mounted) return;
    final got = await askName<void>(context, title: 'Name the $_noun', action: 'Add');
    if (got == null || !mounted) return;
    final name = _kind == AssetKind.emoji ? _clean(got.$1) : got.$1;
    await _try(
      context,
      'Couldn’t add the $_noun',
      () => context.repository.addAsset(widget.spaceId, _kind, name, path),
    );
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
        final name = _kind == AssetKind.emoji ? _clean(got.$1) : got.$1;
        await _try(context, 'Couldn’t rename it', () => repository.renameAsset(widget.spaceId, _kind, a.id, name));
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
    return FutureBuilder(
      future: _list,
      builder: (context, snapshot) {
        final list = snapshot.data;
        return AdminPage(
          title: 'Emojis and stickers',
          actions: [IconAction(icon: FLucideIcons.plus, label: 'Add $_noun', onPressed: _add)],
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
                      button: true,
                      label: _kind == AssetKind.emoji ? ':${a.name}:' : a.name,
                      hint: 'Double tap for options',
                      excludeSemantics: true,
                      onTap: () => _options(a),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _options(a),
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
    } catch (_) {
      if (mounted) _toast(context, 'Couldn’t create the webhook');
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
        } catch (_) {
          if (mounted) _toast(context, 'Couldn’t make a new URL');
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
