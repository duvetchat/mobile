import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'data/links.dart';
import 'data/launchpad.dart';
import 'data/models.dart';
import 'data/repository.dart';
import 'data/scope.dart';
import 'space_admin.dart';
import 'tabs.dart' show SpaceDirectory;
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/depth.dart';
import 'widgets/glass.dart';
import 'widgets/notification_menu.dart';
import 'widgets/rows.dart';
import 'widgets/sheets.dart' show LoadingSkeleton, placeholderNames;

/// An invite's code from what was pasted: a link, or the code itself.
String? inviteCodeOf(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final withScheme = text.startsWith('duvet.chat/') ? 'https://$text' : text;
  return parseInviteCode(withScheme) ?? (RegExp(r'^[\w-]{2,64}$').hasMatch(text) ? text : null);
}

/// Join a Space: paste a link or code, see where it leads, join. Opens the
/// Space once joined.
Future<void> showJoinSheet(BuildContext context, {String? code}) async {
  final spaceId = await showGlassDialogSheet<String>(
    context,
    label: 'Join a Space',
    builder: (context) => _Join(initial: code),
  );
  if (spaceId == null || !context.mounted) return;
  final space = context.repository.spaces.value.where((s) => s.id == spaceId).firstOrNull;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => SpaceDirectory(spaceId: spaceId, name: space?.name ?? 'Space'),
    ),
  );
}

class _Join extends StatefulWidget {
  final String? initial;
  const _Join({this.initial});

  @override
  State<_Join> createState() => _JoinState();
}

class _JoinState extends State<_Join> {
  late final _link = TextEditingController(text: widget.initial);
  Timer? _debounce;
  Future<InvitePreview>? _preview;
  String? _code;
  bool _joining = false;
  String? _error;

  bool _looked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_looked && widget.initial != null) {
      _looked = true;
      _look();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _link.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _look);
  }

  void _look() {
    final code = inviteCodeOf(_link.text);
    setState(() {
      _error = null;
      _code = code;
      _preview = code == null ? null : context.repository.invite(code);
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text case final text?) {
      _link.text = text;
      _look();
    }
  }

  Future<void> _join(InvitePreview invite) async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final spaceId = invite.joined ? invite.spaceId : await context.repository.joinInvite(invite.code);
      if (mounted) Navigator.of(context).pop(spaceId);
    } catch (e) {
      // The API's reason, as the desktop shows it.
      if (mounted) setState(() => _error = e is ActionFailed ? e.message : 'Couldn’t join the Space');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text('Join a Space', style: DuvetType.title.copyWith(color: colors.foreground)),
          ),
          const SizedBox(height: 16),
          DuvetTextField(
            label: 'Invite link or code',
            controller: _link,
            hint: 'duvet.chat/invite/…',
            autofocus: widget.initial == null,
            keyboardType: TextInputType.url,
            onChanged: _changed,
            onSubmitted: (_) => _look(),
            error: _link.text.trim().isNotEmpty && _code == null ? 'That isn’t an invite link' : null,
            trailing: TextAction(label: 'Paste', onPressed: _paste),
          ),
          if (_preview != null)
            FutureBuilder(
              future: _preview,
              builder: (context, snapshot) {
                // On its way, the card as it will be, from a placeholder.
                final invite =
                    snapshot.data ??
                    InvitePreview(code: '', spaceId: '', spaceName: placeholderNames.first, memberCount: 12);
                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: ListNote(switch (snapshot.error) {
                      final ActionFailed f => f.message,
                      _ => 'This invite has expired',
                    }),
                  );
                }
                final preview = [
                  const SizedBox(height: 16),
                  // Where it leads.
                  Semantics(
                    container: true,
                    label:
                        '${invite.spaceName}, ${invite.memberCount} members${invite.description.isEmpty ? '' : '. ${invite.description}'}',
                    excludeSemantics: true,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                      decoration: BoxDecoration(
                        color: colors.card,
                        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                        boxShadow: tokens.shadowRaised,
                      ),
                      child: Column(
                        children: [
                          SpaceIcon(
                            space: Space(id: invite.spaceId, name: invite.spaceName),
                            size: 64,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            invite.spaceName,
                            textAlign: TextAlign.center,
                            style: DuvetType.title.copyWith(color: colors.foreground),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            invite.memberCount == 1 ? '1 member' : '${invite.memberCount} members',
                            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                          ),
                          if (invite.description.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(
                              invite.description,
                              textAlign: TextAlign.center,
                              style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DuvetButton(
                    label: invite.joined ? 'Open ${invite.spaceName}' : 'Join ${invite.spaceName}',
                    variant: ButtonVariant.primary,
                    expand: true,
                    busy: _joining,
                    onPressed: () => _join(invite),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: DuvetType.caption.copyWith(color: colors.destructive),
                        ),
                      ),
                    ),
                ];
                return snapshot.data == null
                    ? LoadingSkeleton(label: 'Loading the invite', children: preview)
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: preview);
              },
            ),
        ],
      ),
    );
  }
}

/// The Launchpad's "+": join with an invite, or create a Space.
class SpacesMenuButton extends StatelessWidget {
  final VoidCallback onCreate;
  const SpacesMenuButton({required this.onCreate, super.key});

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => _TitleButton(
      icon: FLucideIcons.plus,
      label: 'Join or create a Space',
      onPressed: () async {
        final picked = await showGlassMenu(
          anchor,
          label: 'Join or create',
          items: const [
            GlassMenuItem(
              icon: FLucideIcons.link,
              label: 'Join with an invite',
              hint: 'Paste a duvet.chat link',
              value: 'join',
            ),
            GlassMenuItem(
              icon: FLucideIcons.plus,
              label: 'Create a Space',
              hint: 'Start your own community',
              value: 'create',
            ),
          ],
        );
        if (!anchor.mounted) return;
        switch (picked) {
          case 'join':
            await showJoinSheet(anchor);
          case 'create':
            onCreate();
        }
      },
    ),
  );
}

/// The Launchpad's way to lay Spaces out and order them: Grid, List or
/// Cards; the gateway's order or by name. Kept on the device.
class LaunchpadOptionsButton extends StatelessWidget {
  const LaunchpadOptionsButton({super.key});

  @override
  Widget build(BuildContext context) => _TitleButton(
    icon: FLucideIcons.slidersHorizontal,
    label: 'View and sort Spaces',
    onPressed: () =>
        showGlassDialogSheet<void>(context, label: 'View and sort Spaces', builder: (_) => const _LaunchpadOptions()),
  );
}

class _LaunchpadOptions extends StatelessWidget {
  const _LaunchpadOptions();

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final prefs = LaunchpadScope.of(context);
    final choice = prefs.value;
    Widget group(String title, List<Widget> chips) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: chips),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('View and sort', style: DuvetType.title.copyWith(color: colors.foreground)),
          const SizedBox(height: 16),
          group('View', [
            for (final (view, label) in const [
              (SpaceView.grid, 'Grid'),
              (SpaceView.list, 'List'),
              (SpaceView.cards, 'Cards'),
            ])
              DuvetChip(label: label, selected: choice.view == view, onTap: () => prefs.setView(view)),
          ]),
          const SizedBox(height: 16),
          group('Order', [
            for (final (sort, label) in const [
              (SpaceSort.gateway, 'As Duvet lists them'),
              (SpaceSort.alphabetical, 'By name'),
            ])
              DuvetChip(label: label, selected: choice.sort == sort, onTap: () => prefs.setSort(sort)),
          ]),
          const SizedBox(height: 8),
          Text('Kept on this device.', style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
        ],
      ),
    );
  }
}

/// A 40pt control in the Launchpad's title: an icon on nothing, pressed in.
class _TitleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _TitleButton({required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Pressable(
        onTap: onPressed,
        builder: (context, pressed) => Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: pressed ? colors.secondary : null, borderRadius: radius),
          child: InsetShadow(
            shadows: pressed ? context.duvet.shadowPressed : const [],
            borderRadius: radius,
            child: Icon(icon, size: 24, color: colors.foreground),
          ),
        ),
      ),
    );
  }
}

/// Picks a Space's icon as it is: resized, Android's picker would make a GIF
/// a still JPEG. The cropper sizes it. Tests swap in their own.
Future<String?> Function() pickSpaceIcon = () async =>
    (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;

/// New Space: a live preview of its card, a name (up to 64 characters), what
/// it's about (up to 256), and Create.
Future<void> showCreateSpaceSheet(BuildContext context) async {
  final spaceId = await Navigator.of(
    context,
    rootNavigator: true,
  ).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CreateSpacePage()));
  if (spaceId == null || !context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => SpaceDirectory(spaceId: spaceId, name: 'New Space'),
    ),
  );
}

class CreateSpacePage extends StatefulWidget {
  const CreateSpacePage({super.key});

  @override
  State<CreateSpacePage> createState() => _CreateSpacePageState();
}

class _CreateSpacePageState extends State<CreateSpacePage> {
  // The API's columns, which count characters (an emoji is one).
  static const _maxName = 64;
  static const _maxAbout = 256;
  final _name = TextEditingController();
  final _about = TextEditingController();
  String? _icon;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _about.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || name.runes.length > _maxName || _about.text.trim().runes.length > _maxAbout) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final id = await context.repository.createSpace(
        name,
        description: _about.text.trim().isEmpty ? null : _about.text.trim(),
        iconPath: _icon,
      );
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      debugPrint('create space: $e');
      if (mounted) {
        setState(
          () => _error = switch (e) {
            // The API's reason (the 100-Space limit, say), or that no answer
            // came and the Space may have been made.
            ActionFailed(:final message) => message,
            _ => 'Couldn’t create the Space',
          },
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final padding = MediaQuery.paddingOf(context);
    final name = _name.text.trim();
    final about = _about.text.trim();
    final tooLong = name.runes.length > _maxName || about.runes.length > _maxAbout;
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, padding.top + 76, 16, padding.bottom + 96),
              children: [
                // The card it will become.
                Center(
                  child: Container(
                    width: 173,
                    height: 160,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                      boxShadow: tokens.shadowRaised,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          container: true,
                          button: true,
                          label: _icon == null ? 'Add a Space icon' : 'Change the Space icon',
                          excludeSemantics: true,
                          onTap: _pickIcon,
                          child: GestureDetector(
                            onTap: _pickIcon,
                            child: _icon == null
                                ? Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: colors.secondary,
                                      borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                                    ),
                                    child: Icon(FLucideIcons.imagePlus, color: colors.mutedForeground),
                                  )
                                : ClipRRect(
                                    borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                                    child: Image.file(File(_icon!), width: 48, height: 48, fit: BoxFit.cover),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          name.isEmpty ? 'Your Space' : name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.rowTitle.copyWith(
                            color: name.isEmpty ? colors.mutedForeground : colors.foreground,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('1 online', style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Tap the square to add an icon',
                  textAlign: TextAlign.center,
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
                const SizedBox(height: 24),
                DuvetTextField(
                  label: 'Name',
                  controller: _name,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  error: name.runes.length > _maxName ? 'Up to $_maxName characters' : null,
                  helper: '${name.runes.length} of $_maxName characters',
                ),
                const SizedBox(height: 24),
                DuvetTextField(
                  label: 'What’s it about? · optional',
                  controller: _about,
                  hint: 'Shown on invites',
                  maxLines: 4,
                  error: about.runes.length > _maxAbout ? 'Up to $_maxAbout characters' : null,
                  helper: '${about.runes.length} of $_maxAbout characters',
                ),
                const SizedBox(height: 16),
                Text(
                  'Rooms, roles and invites come next.',
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: DuvetType.caption.copyWith(color: colors.destructive)),
                  ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title: const Text('New Space'),
              actions: const [],
              leading: TextAction(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GlassChrome(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + padding.bottom),
                child: DuvetButton(
                  label: 'Create Space',
                  variant: ButtonVariant.primary,
                  expand: true,
                  busy: _creating,
                  onPressed: name.isEmpty || tooLong ? null : _create,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickIcon() async {
    final path = await chooseSpaceIcon(context);
    if (path != null && mounted) setState(() => _icon = path);
  }
}

/// Invite people: a room's link, how long it lasts, and Share.
/// Deletes [space] after its owner types its name; true once it's gone.
Future<bool> deleteSpace(BuildContext context, Space space) async {
  final sure = await showGlassDialogSheet<bool>(
    context,
    label: 'Delete ${space.name}?',
    builder: (context) => _DeleteSpace(space: space),
  );
  if (sure != true || !context.mounted) return false;
  try {
    await context.repository.deleteSpace(space.id);
    return true;
  } catch (e) {
    if (context.mounted) {
      showFToast(
        context: context,
        title: Text(e is ActionFailed ? e.message : 'Couldn’t delete the Space'),
        duration: const Duration(seconds: 4),
      );
    }
    return false;
  }
}

/// Deleting a Space asks for its name, as it's for everyone in it.
class _DeleteSpace extends StatefulWidget {
  final Space space;
  const _DeleteSpace({required this.space});

  @override
  State<_DeleteSpace> createState() => _DeleteSpaceState();
}

class _DeleteSpaceState extends State<_DeleteSpace> {
  final _name = TextEditingController();

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
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final matches = _name.text.trim() == widget.space.name.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Delete ${widget.space.name}?', style: DuvetType.title.copyWith(color: colors.foreground)),
          const SizedBox(height: 12),
          Text(
            'It goes for everyone in it, with its rooms and messages. Type its name to delete it.',
            style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
          ),
          const SizedBox(height: 16),
          DuvetTextField(label: 'Space name', hint: widget.space.name, controller: _name, autofocus: true),
          const SizedBox(height: 24),
          DuvetButton(
            label: 'Delete Space',
            variant: ButtonVariant.destructive,
            expand: true,
            onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          ),
          const SizedBox(height: 12),
          DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
        ],
      ),
    );
  }
}

/// The room an invite to [space] leads to: the first text room the user may
/// invite people to, or null when there's none.
Room? inviteRoomOf(ChatRepository repository, Space space) => space.rooms
    .where((r) => r.kind == RoomKind.text && repository.canInRoom(space.id, r.id, Perm.createInvites))
    .firstOrNull;

Future<void> showInviteSheet(BuildContext context, {required Space space, required Room room}) =>
    showGlassDialogSheet<void>(
      context,
      label: 'Invite people to ${space.name}',
      builder: (context) => _Invite(space: space, room: room),
    );

/// How long an invite link works, as the desktop offers it; null never ends.
const inviteExpiries = <(String, Duration?)>[
  ('30 minutes', Duration(minutes: 30)),
  ('1 hour', Duration(hours: 1)),
  ('6 hours', Duration(hours: 6)),
  ('12 hours', Duration(hours: 12)),
  ('1 day', Duration(days: 1)),
  ('7 days', Duration(days: 7)),
  ('Never', null),
];

/// Seven days unless the user picks otherwise, as on the desktop.
final _defaultExpiry = inviteExpiries.indexWhere((e) => e.$2 == const Duration(days: 7));

class _Invite extends StatefulWidget {
  final Space space;
  final Room room;
  const _Invite({required this.space, required this.room});

  @override
  State<_Invite> createState() => _InviteState();
}

class _InviteState extends State<_Invite> {
  int _age = _defaultExpiry;

  /// The link, with the expiry it was made with: what it says is its own,
  /// not the chip picked while the next one is on its way.
  Future<(String, int)>? _link;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _link ??= _make();
  }

  Future<(String, int)> _make() {
    final age = _age;
    return context.repository
        .createInvite(widget.space.id, widget.room.id, maxAge: inviteExpiries[age].$2)
        .then((link) => (link, age));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: FutureBuilder(
        future: _link,
        builder: (context, snapshot) {
          // Only once it's made: while the next comes, no link to copy or
          // share, and nothing said of one.
          final made = snapshot.connectionState == ConnectionState.done ? snapshot.data : null;
          final link = made?.$1;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Invite people to ${widget.space.name}',
                  style: DuvetType.title.copyWith(color: colors.foreground),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'They’ll land in #${widget.room.name}.',
                style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
              ),
              const SizedBox(height: 16),
              Text(
                'Invite link',
                style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.only(left: 16, right: 6),
                decoration: BoxDecoration(
                  color: colors.card,
                  borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                  border: Border.all(color: tokens.hairline),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        snapshot.hasError
                            ? switch (snapshot.error) {
                                final ActionFailed f => f.message,
                                _ => 'Couldn’t make a link',
                              }
                            : (link?.replaceFirst('https://', '') ?? 'Making a link…'),
                        maxLines: snapshot.hasError ? 3 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: snapshot.hasError
                            ? DuvetType.snippet.copyWith(color: colors.destructive)
                            : DuvetType.code.copyWith(fontSize: 15, color: colors.foreground),
                      ),
                    ),
                    if (snapshot.hasError)
                      TextAction(
                        label: 'Try again',
                        onPressed: () => setState(() {
                          _link = _make();
                        }),
                      )
                    else
                      TextAction(
                        label: 'Copy',
                        onPressed: link == null
                            ? null
                            : () async {
                                await Clipboard.setData(ClipboardData(text: link));
                                if (context.mounted) {
                                  showFToast(
                                    context: context,
                                    title: const Text('Link copied'),
                                    duration: const Duration(seconds: 3),
                                  );
                                }
                              },
                      ),
                  ],
                ),
              ),
              if (link != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(switch (inviteExpiries[made!.$2]) {
                    (_, null) => 'This link never expires.',
                    (final label, _) => 'This link expires in $label.',
                  }, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'Expires after',
                style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, (label, _)) in inviteExpiries.indexed)
                    DuvetChip(
                      label: label,
                      selected: i == _age,
                      onTap: () => setState(() {
                        _age = i;
                        _link = _make();
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              DuvetButton(
                label: 'Share link',
                icon: FLucideIcons.share2,
                variant: ButtonVariant.primary,
                expand: true,
                onPressed: link == null
                    ? null
                    : () => SharePlus.instance.share(ShareParams(text: link, subject: 'Join ${widget.space.name}')),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A Space's menu, from its title: who's there, Invite people, Mark all as
/// read, Leave.
Future<void> showSpaceMenu(BuildContext anchor, {required Space space}) async {
  final inviteRoom = inviteRoomOf(anchor.repository, space);
  final picked = await showGlassMenu(
    anchor,
    label: space.name,
    items: [
      GlassMenuItem(
        icon: FLucideIcons.userPlus,
        label: 'Invite people',
        value: 'invite',
        hint: inviteRoom == null ? 'Not allowed in this Space' : null,
      ),
      if (anchor.repository.spaceProfile(space.id)?.helpsRun ?? false)
        const GlassMenuItem(icon: FLucideIcons.settings, label: 'Space settings', value: 'settings')
      // Any member may see them, as on the desktop; only those who manage them change them.
      else
        const GlassMenuItem(icon: FLucideIcons.smile, label: 'Emojis and stickers', value: 'assets'),
      const GlassMenuItem(icon: FLucideIcons.checkCheck, label: 'Mark all as read', value: 'read'),
      const GlassMenuItem(icon: FLucideIcons.bell, label: 'Notifications', value: 'notifications'),
      // Its owner can't leave it: they delete it.
      if (anchor.repository.spaceProfile(space.id)?.owner ?? false)
        const GlassMenuItem(icon: FLucideIcons.trash2, label: 'Delete Space', value: 'delete', destructive: true)
      else
        const GlassMenuItem(icon: FLucideIcons.logOut, label: 'Leave Space', value: 'leave', destructive: true),
    ],
  );
  if (!anchor.mounted) return;
  final repository = anchor.repository;
  switch (picked) {
    case 'invite':
      if (inviteRoom != null) {
        await showInviteSheet(anchor, space: space, room: inviteRoom);
      } else {
        showFToast(
          context: anchor,
          title: Text('You can’t invite people to ${space.name}. Ask someone who runs it for a link.'),
          duration: const Duration(seconds: 4),
        );
      }
    case 'delete':
      if (await deleteSpace(anchor, space) && anchor.mounted) Navigator.of(anchor).maybePop();
    case 'settings':
      await Navigator.of(anchor).push(MaterialPageRoute<void>(builder: (_) => SpaceSettingsPage(spaceId: space.id)));
    case 'assets':
      await Navigator.of(anchor).push(MaterialPageRoute<void>(builder: (_) => AssetsPage(spaceId: space.id)));
    case 'read':
      repository.markSpaceRead(space.id);
    case 'notifications':
      await showNotificationMenu(anchor, targetId: space.id, target: NotificationTarget.space);
    case 'leave':
      final sure = await showGlassDialogSheet<bool>(
        anchor,
        label: 'Leave ${space.name}?',
        builder: (context) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Leave ${space.name}?', style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
              const SizedBox(height: 12),
              Text(
                'You’ll need a new invite to come back.',
                style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground),
              ),
              const SizedBox(height: 24),
              DuvetButton(
                label: 'Leave Space',
                variant: ButtonVariant.destructive,
                expand: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 12),
              DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
            ],
          ),
        ),
      );
      if (sure != true || !anchor.mounted) return;
      try {
        await repository.leaveSpace(space.id);
        if (anchor.mounted) Navigator.of(anchor).maybePop();
      } catch (_) {
        if (anchor.mounted) {
          showFToast(context: anchor, title: const Text('Couldn’t leave'), duration: const Duration(seconds: 3));
        }
      }
  }
}
