import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport, ViewportOffset;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'account.dart' show BucketMeter, CropPage, FileRow, confirmFileDelete, formatBytes, placeholderFiles;
import 'data/images.dart';
import 'data/models.dart';
import 'data/repository.dart' show ChatRepository;
import 'data/scope.dart';
import 'people.dart' show PersonRow, removeBotAsking, removeMemberButtons;
import 'spaces.dart' show deleteSpace, inviteRoomOf, pickSpaceIcon, showInviteSheet;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/depth.dart' show Pressable;
import 'widgets/color_picker.dart';
import 'widgets/glass.dart';
import 'widgets/picture_edit.dart';
import 'widgets/role_name.dart';
import 'widgets/rows.dart';
import 'widgets/scrolling.dart' show CarouselPhysics;
import 'widgets/sheets.dart' show LoadingSkeleton, placeholderNames, placeholderRows;
import 'widgets/skeleton.dart' show Bone;
import 'widgets/unsaved_changes.dart';

/// Picks a Space's banner as it is: resized, Android's picker would make a GIF
/// a still image. Tests swap in their own.
Future<String?> Function() pickSpaceImage = () async =>
    (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;

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
Future<Uint8List> squarePng(String path, CropRect crop, int side) => framedPng(path, crop, side, side);

/// The part of the picture at [path] that [crop] frames, drawn [width] by
/// [height] pixels, as a PNG.
Future<Uint8List> framedPng(String path, CropRect crop, int width, int height) async {
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
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..filterQuality = FilterQuality.high,
  );
  final drawing = recorder.endRecording();
  final square = await drawing.toImage(width, height);
  try {
    return (await square.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  } finally {
    picture.dispose();
    drawing.dispose();
    square.dispose();
  }
}

/// [squarePng] in a file to upload, or [framedGif] for a moving GIF, named
/// after the picture, as the desktop names it; answers its path. Each crop
/// has a folder of its own: a picture shows by its path, so one saved where
/// the last crop was would show as the last crop. Tests swap in their own.
Future<String> Function(String path, CropRect crop, int side) saveSquareImage = (path, crop, side) async {
  final moving = (await gifAt(path))?.animated ?? false;
  // Off the UI thread: every frame is decoded and encoded again.
  final bytes = moving
      ? await Isolate.run(() async => framedGif(await File(path).readAsBytes(), crop, side, side))
      : await squarePng(path, crop, side);
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  final squares = await Directory('${(await getTemporaryDirectory()).path}/square').create(recursive: true);
  final dir = await squares.createTemp();
  final file = File('${dir.path}/${dot > 0 ? name.substring(0, dot) : 'image'}.${moving ? 'gif' : 'png'}');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
};

/// Picks a Space's icon (or, [camera], takes one) and crops it square, as the
/// desktop does; answers the cropped picture's path, or null when the user
/// backs out.
Future<String?> chooseSpaceIcon(BuildContext context, {bool camera = false}) async {
  final path = await (camera ? takePhoto() : pickSpaceIcon());
  if (path == null || !context.mounted) return null;
  final crop = await Navigator.of(context).push<CropRect>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => CropPage(path: path, aspect: 1, round: false)),
  );
  if (crop == null || !context.mounted) return null;
  try {
    return await saveSquareImage(path, crop, avatarSide);
  } catch (e) {
    debugPrint('icon: $e');
    if (context.mounted) adminToast(context, 'Couldn’t read this picture');
    return null;
  }
}

/// A banner's pixels, a Space's or a profile's, as the desktop crops one: 5:2
/// ([bannerAspect]).
const bannerSize = (width: 600, height: 240);

/// An avatar's or a Space icon's side, as the desktop crops one.
const avatarSide = 256;

/// The part of the moving GIF [gif] that [crop] frames, every frame of it,
/// drawn [width] by [height] pixels, as a GIF: it stays moving, as the
/// desktop keeps it.
Uint8List framedGif(Uint8List gif, CropRect crop, int width, int height) {
  img.Image? moving;
  // Frame by frame: cropped whole, the animation would give every frame the
  // first's palette and time. The first frame holds the others, hence a copy
  // of it alone.
  for (final frame in img.decodeGif(gif)!.frames) {
    final framed = img.copyResize(
      img.copyCrop(
        img.Image.from(frame, noAnimation: true),
        x: crop.x.round(),
        y: crop.y.round(),
        width: crop.w.round(),
        height: crop.h.round(),
      ),
      width: width,
      height: height,
      interpolation: img.Interpolation.average,
    );
    moving?.addFrame(framed);
    moving ??= framed;
  }
  return img.encodeGif(moving!);
}

/// The banner [crop] frames in the picture at [path], in a file to upload;
/// answers its path. Tests swap in their own.
Future<String> Function(String path, CropRect crop) saveBannerImage = (path, crop) async {
  final moving = (await gifAt(path))?.animated ?? false;
  // Off the UI thread: every frame is decoded and encoded again.
  final bytes = moving
      ? await Isolate.run(
          () async => framedGif(await File(path).readAsBytes(), crop, bannerSize.width, bannerSize.height),
        )
      : await framedPng(path, crop, bannerSize.width, bannerSize.height);
  final dir = Directory('${(await getTemporaryDirectory()).path}/banner');
  await dir.create(recursive: true);
  final file = File('${dir.path}/banner-${DateTime.now().microsecondsSinceEpoch}.${moving ? 'gif' : 'png'}');
  await file.writeAsBytes(bytes, flush: true);
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
  int? _banned;
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
    if (profile.can(Perm.banMembers)) {
      repository.bans(id).then((l) => mounted ? setState(() => _banned = l.length) : null, onError: ignore);
    }
    // Any member's to see.
    (
      repository.assets(id, AssetKind.emoji),
      repository.assets(id, AssetKind.sticker),
    ).wait.then((l) => mounted ? setState(() => _assets = (l.$1.length, l.$2.length)) : null, onError: ignore);
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
              // Any member's to see; changed by those who manage them.
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
              if (profile.can(Perm.manageRoles) ||
                  profile.can(Perm.manageBots) ||
                  profile.can(Perm.kickMembers) ||
                  profile.can(Perm.banMembers))
                GlassRow(
                  icon: FLucideIcons.users,
                  label: 'Members',
                  detail: '${profile.memberCount}',
                  onPressed: () => _open(MembersAdminPage(spaceId: id)),
                ),
              if (profile.can(Perm.manageInvites))
                GlassRow(
                  icon: FLucideIcons.link,
                  label: 'Invites',
                  detail: _invites == null ? null : '$_invites active',
                  onPressed: () => _open(InvitesAdminPage(spaceId: id)),
                ),
              if (profile.can(Perm.banMembers))
                GlassRow(
                  icon: FLucideIcons.ban,
                  label: 'Bans',
                  detail: _banned == null ? null : '$_banned banned',
                  onPressed: () => _open(BansAdminPage(spaceId: id)),
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

/// Asks before something that can't be undone, or ([destructive] false)
/// that changes things for everyone.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool destructive = true,
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
              variant: destructive ? ButtonVariant.destructive : ButtonVariant.primary,
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
  int? maxLength,
}) => showGlassDialogSheet<(String, T?)>(
  context,
  label: title,
  builder: (context) => _NameSheet<T>(
    title: title,
    initial: initial,
    label: label,
    action: action,
    choices: choices,
    choice: choice,
    maxLength: maxLength,
  ),
);

/// The most a room's description takes, as the API stores it.
const roomDescriptionLimit = 256;

/// Asks what a room is for; empty clears it. Null when cancelled.
Future<String?> askDescription(BuildContext context, {required String title, String initial = ''}) =>
    showGlassDialogSheet<String>(
      context,
      label: title,
      builder: (context) => _DescriptionSheet(title: title, initial: initial),
    );

class _DescriptionSheet extends StatefulWidget {
  final String title;
  final String initial;
  const _DescriptionSheet({required this.title, required this.initial});

  @override
  State<_DescriptionSheet> createState() => _DescriptionSheetState();
}

class _DescriptionSheetState extends State<_DescriptionSheet> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    // As the field and the API's column count them: code points.
    final left = roomDescriptionLimit - _text.text.runes.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: DuvetType.title.copyWith(color: colors.foreground)),
          const SizedBox(height: 16),
          DuvetTextField(
            label: 'Description',
            hint: 'What this room is for',
            controller: _text,
            autofocus: true,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            maxLength: roomDescriptionLimit,
          ),
          const SizedBox(height: 8),
          Text(
            _text.text.trim().isEmpty
                ? 'Leave it empty to clear it.'
                : left == 1
                ? '1 character left'
                : '$left characters left',
            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
          ),
          const SizedBox(height: 16),
          DuvetButton(
            label: 'Save',
            variant: ButtonVariant.primary,
            expand: true,
            // Unchanged, there's nothing to save.
            onPressed: _text.text.trim() == widget.initial.trim()
                ? null
                : () => Navigator.of(context).pop(_text.text.trim()),
          ),
        ],
      ),
    );
  }
}

class _NameSheet<T> extends StatefulWidget {
  final String title;
  final String initial;
  final String label;
  final String action;
  final Map<T, String> choices;
  final T? choice;
  final int? maxLength;
  const _NameSheet({
    required this.title,
    required this.initial,
    required this.label,
    required this.action,
    required this.choices,
    required this.choice,
    this.maxLength,
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
        DuvetTextField(label: widget.label, controller: _name, autofocus: true, maxLength: widget.maxLength),
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

void adminToast(BuildContext context, String message) {
  if (!context.mounted) return;
  showFToast(context: context, title: Text(message), duration: const Duration(seconds: 3));
}

/// A secret the server shows once, a webhook's URL or a bot's token, to copy.
Future<void> showSecretOnce(
  BuildContext context, {
  required String title,
  required String body,
  required String secret,
  required String copyLabel,
  ({String label, String secret, String note})? also,
}) => showGlassDialogSheet<void>(
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
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.theme.colors.secondary,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
          ),
          child: SelectableText(secret, style: DuvetType.code.copyWith(color: context.theme.colors.foreground)),
        ),
        const SizedBox(height: 24),
        DuvetButton(
          label: copyLabel,
          variant: ButtonVariant.primary,
          expand: true,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: secret));
            Navigator.of(context).pop();
          },
        ),
        if (also != null) ...[
          const SizedBox(height: 12),
          DuvetButton(
            label: also.label,
            expand: true,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: also.secret));
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(height: 8),
          Text(also.note, style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground)),
        ],
      ],
    ),
  ),
);

/// Runs a change, saying so if it fails; true when it worked.
Future<bool> adminTry(BuildContext context, String failure, Future<void> Function() change) async {
  try {
    await change();
    return true;
  } catch (e) {
    debugPrint('space admin: $e');
    if (context.mounted) adminToast(context, e is ActionFailed ? e.message : failure);
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
  late final _name = TextEditingController(text: _profile?.name)..addListener(_changed);
  late final _about = TextEditingController(text: _profile?.description)..addListener(_changed);
  late final _locale = TextEditingController(text: _profile?.locale)..addListener(_changed);
  void _changed() => setState(() {});

  // What its members are notified of until they choose: every message or only mentions.
  late final NotificationLevel _defaultWas = context.repository.spaceDefault(widget.spaceId);
  late NotificationLevel _default = _defaultWas;

  /// The new icon and banner, cropped; or [_removeIcon] and [_removeBanner]
  /// to take the ones there away.
  String? _icon;
  String? _banner;
  bool _removeIcon = false;
  bool _removeBanner = false;
  bool _saving = false;
  final _upload = ValueNotifier<double?>(null);

  Future<void> _editIcon({required bool has}) async {
    final choice = await showPictureSheet(context, title: 'Icon', remove: has ? 'Remove icon' : null);
    if (choice == null || !mounted) return;
    if (choice == PictureChoice.remove) {
      setState(() {
        _icon = null;
        _removeIcon = _profile?.iconUrl != null;
      });
      return;
    }
    final path = await chooseSpaceIcon(context, camera: choice == PictureChoice.take);
    if (path != null && mounted) {
      setState(() {
        _icon = path;
        _removeIcon = false;
      });
    }
  }

  Future<void> _editBanner({required bool has}) async {
    final choice = await showPictureSheet(context, title: 'Banner', remove: has ? 'Remove banner' : null);
    if (choice == null || !mounted) return;
    if (choice == PictureChoice.remove) {
      setState(() {
        _banner = null;
        _removeBanner = _profile?.bannerUrl != null;
      });
      return;
    }
    final path = await (choice == PictureChoice.take ? takePhoto() : pickSpaceImage());
    if (path == null || !mounted) return;
    final crop = await Navigator.of(context).push<CropRect>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CropPage(path: path, aspect: bannerAspect, round: false),
      ),
    );
    if (crop == null || !mounted) return;
    final String cropped;
    try {
      cropped = await saveBannerImage(path, crop);
    } catch (e) {
      debugPrint('banner: $e');
      if (mounted) adminToast(context, 'Couldn’t read this picture');
      return;
    }
    if (mounted) {
      setState(() {
        _banner = cropped;
        _removeBanner = false;
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _locale.dispose();
    _upload.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = _profile;
    final name = _name.text.trim();
    if (p == null || name.isEmpty) return;
    final about = _about.text.trim();
    final locale = _locale.text.trim();
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await adminTry(
      context,
      'Couldn’t save the Space',
      () => context.repository.updateSpace(
        p.id,
        name: name == p.name ? null : name,
        description: about == (p.description ?? '') ? null : about,
        locale: locale == (p.locale ?? '') ? null : locale,
        iconPath: _icon,
        bannerPath: _banner,
        removeBanner: _removeBanner,
        removeIcon: _removeIcon,
        defaultNotifications: _default == _defaultWas ? null : _default,
        onProgress: (p) {
          // Left mid-upload, the page is gone, and its note with it.
          if (mounted) _upload.value = p;
        },
      ),
    );
    if (!mounted) return;
    _upload.value = null;
    setState(() => _saving = false);
    if (ok) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final p = _profile;
    // What the pictures will be once saved: the new ones, none, or as they are.
    final iconNow = _icon ?? (_removeIcon ? null : p?.iconUrl);
    final bannerNow = _banner ?? (_removeBanner ? null : p?.bannerUrl);
    final dirty =
        p != null &&
        (_icon != null ||
            _banner != null ||
            _removeIcon ||
            _removeBanner ||
            _name.text.trim() != p.name ||
            _about.text.trim() != (p.description ?? '').trim() ||
            _locale.text.trim() != (p.locale ?? '').trim() ||
            _default != _defaultWas);
    return UnsavedChanges(
      dirty: dirty,
      child: AdminPage(
        title: 'Overview',
        actions: [TextAction(label: 'Save', onPressed: _saving || !dirty ? null : _save)],
        children: [
          if (p == null)
            const ListNote('This Space is gone')
          else ...[
            const Overline('Appearance'),
            AdminPanel(
              children: [
                PictureRow(
                  label: 'Icon',
                  set: iconNow != null,
                  onPressed: () => _editIcon(has: iconNow != null),
                  thumb: PictureThumb(
                    picture: iconNow,
                    width: 48,
                    height: 48,
                    radius: BorderRadius.circular(DuvetTokens.radiusField),
                    empty: Text(
                      _name.text.trim().isEmpty ? '' : _name.text.trim().characters.first.toUpperCase(),
                      style: DuvetType.navTitle.copyWith(color: colors.foreground, fontSize: 20),
                    ),
                  ),
                ),
                PictureRow(
                  label: 'Banner',
                  set: bannerNow != null,
                  onPressed: () => _editBanner(has: bannerNow != null),
                  thumb: PictureThumb(
                    picture: bannerNow,
                    width: 144,
                    height: 48,
                    radius: BorderRadius.circular(8),
                    empty: Icon(FLucideIcons.image, size: 24, color: colors.mutedForeground),
                  ),
                ),
              ],
            ),
            UploadNote(_upload),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Everyone in the Space sees the change.',
                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
              ),
            ),
            const Overline('Details'),
            DuvetTextField(label: 'Name', controller: _name),
            const SizedBox(height: 16),
            DuvetTextField(label: 'What it’s about', controller: _about, maxLines: 3),
            const SizedBox(height: 16),
            // Free text, as the desktop takes it.
            DuvetTextField(label: 'Locale', controller: _locale, hint: 'en', maxLength: 4),
            const Overline('Default notifications'),
            Segmented<NotificationLevel>(
              label: 'Default notifications',
              value: _default,
              options: const {NotificationLevel.all: 'All messages', NotificationLevel.mentions: 'Only mentions'},
              onChanged: (level) => setState(() => _default = level),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Members are notified of this until they choose for themselves.',
                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
              ),
            ),
          ],
        ],
      ),
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

  /// The room a drag holds, by ID from the drag's start: the page rebuilds
  /// on every room event, so by the drop another room may be at its index.
  String? _held;
  int? _heldFrom;

  /// The rooms a held room is among, by category ('' for those in none),
  /// until the finger lifts: the page scrolls no further than shows them
  /// ([_HeldRoomsPhysics]). Null while no room is held.
  String? _heldAmong;
  final _roomLists = <String, GlobalKey>{};

  void _hold(List<AdminRoom> list, int i) {
    _held = list[i].id;
    _heldFrom = i;
  }

  /// How far the page may scroll while a room is held: from where the start
  /// of its rooms shows to where their end does.
  (double, double)? _heldRange() {
    final box = _roomLists[_heldAmong]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    final start = viewport.getOffsetToReveal(box, 0).offset;
    final end = viewport.getOffsetToReveal(box, 1).offset;
    return (min(start, end), max(start, end));
  }

  /// The room to move in [list] as it is now: the held one, null when it
  /// went meanwhile, or else the one at [from]. A drop names the index its
  /// drag began at; a screen reader's move names its own room's. So a room
  /// held by a drag that was cancelled (a system gesture, the list changing),
  /// which ends with no drop, only counts at that index, where it still is
  /// unless the list changed.
  AdminRoom? _heldIn(List<AdminRoom> list, int from) {
    final held = from == _heldFrom ? _held : null;
    _held = _heldFrom = null;
    return held == null ? list[from] : list.where((r) => r.id == held).firstOrNull;
  }

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
    await adminTry(
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
          // Categories have none: the API ignores theirs.
          if (room.kind != AdminRoomKind.category)
            GlassRow(
              icon: FLucideIcons.text,
              label: 'Edit description',
              detail: room.description ?? 'None',
              onPressed: () => Navigator.of(context).pop('describe'),
            ),
          if (room.kind != AdminRoomKind.category &&
              context.repository.canInRoom(widget.spaceId, room.id, Perm.createInvites))
            GlassRow(
              icon: FLucideIcons.userPlus,
              label: 'Invite people',
              detail: 'A link to $label',
              onPressed: () => Navigator.of(context).pop('invite'),
            ),
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
        await adminTry(context, 'Couldn’t rename $label', () => repository.renameRoom(id, room.id, got.$1));
      case 'describe':
        final got = await askDescription(context, title: 'What $label is for', initial: room.description ?? '');
        if (got == null || !mounted) return;
        await adminTry(
          context,
          'Couldn’t change what $label is for',
          () => repository.setRoomDescription(id, room.id, got),
        );
      case 'invite':
        final space = repository.spaces.value.where((s) => s.id == id).firstOrNull;
        final inviteTo = space?.rooms.where((r) => r.id == room.id).firstOrNull;
        if (space == null || inviteTo == null) return;
        await showInviteSheet(context, space: space, room: inviteTo);
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
        await adminTry(context, 'Couldn’t delete $label', () => repository.deleteRoom(id, room.id));
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

  // A screen reader's move of what the user may not move: the list offers
  // moves on every item, so this says why nothing moved.
  void _cantMove(AdminRoom r) {
    if (!mounted) return;
    SemanticsService.sendAnnouncement(
      View.of(context),
      'You can’t move ${r.kind == AdminRoomKind.category ? r.name : '#${r.name}'}',
      Directionality.of(context),
    );
  }

  /// Sends [moved] to [position] in [parent], as the API takes it.
  Future<void> _place(AdminRoom moved, String? parent, int position) async {
    final label = moved.kind == AdminRoomKind.category ? moved.name : '#${moved.name}';
    final change = context.repository.moveRoom(widget.spaceId, moved.id, parentId: parent, position: position);
    setState(() {});
    await adminTry(context, 'Couldn’t move $label', () => change);
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
    Widget grip(int index) => DragEdge(index: index);
    // A plain row on its panel, with its edge to drag by when it may move.
    Widget row(Widget body, int index, {double indent = 0, bool moves = true}) => EdgedRow(
      edge: moves ? grip(index) : null,
      child: Padding(
        padding: EdgeInsets.only(left: indent),
        child: body,
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
    const liftRow = liftedRow;
    // A category's panel is its own surface: only lifted a little.
    Widget liftPanel(Widget child, int _, Animation<double> _) => Material(
      type: MaterialType.transparency,
      child: Transform.scale(scale: 1.02, child: child),
    );

    Widget roomList(List<AdminRoom> list, String? parent) => SliverReorderableList(
      itemCount: list.length,
      onReorderStart: (i) {
        _hold(list, i);
        _heldAmong = parent ?? '';
      },
      onReorderItem: (from, to) {
        final held = _heldIn(list, from);
        if (held == null) return;
        if (!manages(held)) return _cantMove(held);
        if (list.indexOf(held) != to) _move(held, [...list]..remove(held), to, parent: parent);
      },
      proxyDecorator: liftRow,
      itemBuilder: (context, i) {
        final r = list[i];
        final mine = manages(r);
        final body = row(
          ListRow(
            // One stop with the moves the list offers on it.
            ownNode: false,
            title: r.name,
            hash: r.kind == AdminRoomKind.text,
            leading: r.kind == AdminRoomKind.voice
                ? ExcludeSemantics(child: Icon(FLucideIcons.volume2, size: 20, color: colors.mutedForeground))
                : null,
            detail: switch ([
              if (r.kind == AdminRoomKind.voice) 'Voice room',
              if (mine)
                list.length > 1 ? 'Double tap for options, or use actions to move it' : 'Double tap for options',
            ]) {
              [] => null,
              final parts => parts.join('. '),
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

    // One place's rooms, to reorder there. In a viewport that doesn't
    // scroll, not a list of its own: a drag scrolls the nearest Scrollable,
    // the page's, so a room goes past the screen's edge in one drag. A node
    // of their own, as a list's is: else a category's moves would be offered
    // again around each of its rooms.
    Widget rooms(List<AdminRoom> list, String? parent) => Semantics(
      key: _roomLists.putIfAbsent(parent ?? '', GlobalKey.new),
      container: true,
      child: ShrinkWrappingViewport(offset: ViewportOffset.zero(), slivers: [roomList(list, parent)]),
    );

    // A category and its rooms, on one panel: they move together.
    Widget block(int i) {
      final c = categories[i];
      final inside = _roomsIn(all, c.id);
      final mine = manages(c);
      // Not a node of its own: the panel's, with the moves the list offers
      // on it, so a category and its moves are one stop.
      final header = Semantics(
        button: mine,
        label: 'Category ${c.name}',
        hint: !mine
            ? null
            : categories.length > 1
            ? 'Double tap for options, or use actions to move it with its rooms'
            : 'Double tap for options',
        excludeSemantics: true,
        onTap: mine ? () => _options(c) : null,
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
                  // Its own node, or it would name the panel.
                  child: Semantics(
                    container: true,
                    child: Text(
                      'No rooms. Move one here from its options.',
                      style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                    ),
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
          : Listener(
              // The finger lifted or taken: no room held any more.
              onPointerUp: (_) => _heldAmong = null,
              onPointerCancel: (_) => _heldAmong = null,
              child: ReorderableListView.builder(
                physics: _HeldRoomsPhysics(() => _heldAmong == null ? null : _heldRange()),
                padding: padding,
                buildDefaultDragHandles: false,
                header: loose.isEmpty ? null : panel(rooms(loose, null)),
                itemCount: categories.length,
                itemBuilder: (context, i) => block(i),
                onReorderStart: (i) => _hold(categories, i),
                onReorderItem: (from, to) {
                  final held = _heldIn(categories, from);
                  if (held == null) return;
                  if (!manages(held)) return _cantMove(held);
                  if (categories.indexOf(held) != to) _move(held, [...categories]..remove(held), to);
                },
                proxyDecorator: liftPanel,
              ),
            ),
    );
  }
}

/// While a room is held, the page scrolls no further than shows the rooms
/// it's among ([range]): the drag's autoscroll would carry it on, and their
/// list, once scrolled off and dropped, would take the drag with it.
class _HeldRoomsPhysics extends ScrollPhysics {
  final (double, double)? Function() range;
  const _HeldRoomsPhysics(this.range, {super.parent});

  @override
  _HeldRoomsPhysics applyTo(ScrollPhysics? ancestor) => _HeldRoomsPhysics(range, parent: buildParent(ancestor));

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (range() case (final start, final end)?) {
      // Not past it, nor further away when it's already off.
      final last = max(end, position.pixels);
      final first = min(start, position.pixels);
      if (value > last) return value - last;
      if (value < first) return value - first;
    }
    return super.applyBoundaryConditions(position, value);
  }
}

/// What each role, and each member given their own, may do in one room:
/// allowed, denied, or as their roles say. A card each, swiped between.
class RoomPermissionsPage extends StatefulWidget {
  final String spaceId;
  final AdminRoom room;
  const RoomPermissionsPage({required this.spaceId, required this.room, super.key});

  @override
  State<RoomPermissionsPage> createState() => _RoomPermissionsPageState();
}

/// Whose permissions a card sets: a role (type 0) or a member (type 1).
typedef _Target = ({String id, int type, String name, RoleColors? colors, String? avatarUrl});

class _RoomPermissionsPageState extends State<RoomPermissionsPage> {
  // Every room permission, as the desktop groups them; ManageRoles has no
  // say in a room. An overwrite keeps any bit not shown: an edit changes
  // only the bit it sets.
  static const _groups = <(String, List<PermissionInfo>)>[
    (
      'General',
      [
        (bit: Perm.viewChannels, label: 'See the room', description: 'And read its messages'),
        (bit: Perm.manageChannels, label: 'Manage the room', description: 'Its name, what it’s for, and these'),
        (bit: Perm.createInvites, label: 'Invite people', description: 'Links to this room'),
      ],
    ),
    (
      'Messages',
      [
        (bit: Perm.sendMessages, label: 'Send messages', description: 'Write here'),
        (bit: Perm.manageMessages, label: 'Delete others’ messages', description: 'Here'),
        (bit: Perm.pinMessages, label: 'Pin messages', description: 'Here'),
      ],
    ),
    (
      'Voice',
      [
        (bit: Perm.joinVoice, label: 'Join voice', description: 'If it’s a voice room'),
        (bit: Perm.speakInVoice, label: 'Speak', description: 'If it’s a voice room'),
        (bit: Perm.video, label: 'Video', description: 'Camera and screen, if it’s a voice room'),
      ],
    ),
  ];

  // Members given a card on this visit; they keep it once something is set.
  final _added = <String>[];
  List<Member>? _members;
  Future<List<Member>>? _loadingMembers;

  // A chip's page on its way: the pages passed on the way neither click nor
  // move the selection.
  bool _jumping = false;

  // The card shown, by whose it is: @everyone's at first.
  late String _shown = widget.spaceId;
  late final _pages = PageController(initialPage: _targets.indexWhere((t) => t.id == _shown), viewportFraction: 0.86);
  final _chips = <String, GlobalKey>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadingMembers != null) return;
    _loadMembers();
    // @everyone's chip is the last role's: in view from the start.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bringChip(Duration.zero));
  }

  // The Space's members, to name and picture members' cards and to add one;
  // asked again when the picker opens after a failure.
  void _loadMembers() {
    final repository = context.repository;
    final text = repository.adminRooms(widget.spaceId).where((r) => r.kind == AdminRoomKind.text).firstOrNull?.id;
    final load = repository.members(RoomTarget(spaceId: widget.spaceId, roomId: text ?? widget.room.id));
    _loadingMembers = load;
    load.then(
      (m) {
        if (mounted) setState(() => _members = m);
      },
      onError: (Object e) {
        debugPrint('room permissions: members: $e');
        if (mounted && _loadingMembers == load) _loadingMembers = null;
      },
    );
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Duration get _motion => MediaQuery.disableAnimationsOf(context) ? Duration.zero : DuvetTokens.dropdownIn;

  List<RoomOverwrite> get _overwrites => context.repository.overwrites(widget.spaceId, widget.room.id);

  /// The roles, highest first, then the members with their own.
  List<_Target> get _targets {
    final repository = context.repository;
    final known = {for (final m in _members ?? const <Member>[]) m.userId: m};
    final memberIds = {
      for (final o in _overwrites)
        if (o.targetType == 1) o.targetId,
      ..._added,
    };
    return [
      for (final r in repository.roles(widget.spaceId))
        (id: r.id, type: 0, name: r.name, colors: r.colors, avatarUrl: null),
      for (final id in memberIds)
        (
          id: id,
          type: 1,
          name: known[id]?.displayName ?? repository.nameOf(id) ?? 'Member',
          colors: null,
          avatarUrl: known[id]?.avatarUrl,
        ),
    ];
  }

  RoomOverwrite _overwrite(_Target t) =>
      _overwrites.where((o) => o.targetId == t.id).firstOrNull ?? RoomOverwrite(targetId: t.id, targetType: t.type);

  Future<void> _set(_Target t, int bit, bool? state) async {
    final next = _overwrite(t).withState(bit, state);
    await adminTry(
      context,
      'Couldn’t change the permission',
      () => context.repository.setOverwrite(widget.spaceId, widget.room.id, next),
    );
    if (mounted) setState(() {});
  }

  /// Turns to [index]'s card from a chip or a peeking card: one click, the
  /// selection there at once.
  Future<void> _pick(int index) async {
    final targets = _targets;
    HapticFeedback.selectionClick();
    setState(() => _shown = targets[index].id);
    _bringChip(_motion);
    if (_motion == Duration.zero) return _pages.jumpToPage(index);
    _jumping = true;
    await _pages.animateToPage(index, duration: _motion, curve: DuvetTokens.decelerate);
    _jumping = false;
  }

  void _bringChip(Duration duration) {
    if (_chips[_shown]?.currentContext case final chip? when mounted) {
      Scrollable.ensureVisible(chip, alignment: 0.5, duration: duration, curve: DuvetTokens.decelerate);
    }
  }

  void _turned(List<_Target> targets, int index) {
    if (_jumping) return;
    HapticFeedback.selectionClick();
    setState(() => _shown = targets[index].id);
    _bringChip(_motion);
  }

  /// A member to give their own permissions here: theirs and no one's else.
  Future<void> _addMember(List<_Target> targets) async {
    final taken = {for (final t in targets) t.id};
    if (_loadingMembers == null) _loadMembers();
    final picked = await showGlassSheet<Member>(
      context,
      label: 'Add a member',
      initialSize: 0.75,
      builder: (context, scroll) => _MemberPicker(
        spaceId: widget.spaceId,
        members: _loadingMembers!,
        loaded: _members,
        taken: taken,
        scroll: scroll,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _added.add(picked.userId);
      _shown = picked.userId;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pick(_targets.indexWhere((t) => t.id == picked.userId));
    });
  }

  /// A member's own permissions here, gone: their roles say again.
  Future<void> _removeMember(_Target t) async {
    // Its place now: the card before it is shown after.
    final before = _targets.indexWhere((x) => x.id == t.id);
    final had = _overwrites.any((o) => o.targetId == t.id);
    if (had &&
        !await adminTry(
          context,
          'Couldn’t remove ${t.name}’s permissions',
          () => context.repository.setOverwrite(
            widget.spaceId,
            widget.room.id,
            RoomOverwrite(targetId: t.id, targetType: 1),
          ),
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _added.remove(t.id);
      final left = _targets;
      _shown = left[(before - 1).clamp(0, left.length - 1)].id;
    });
  }

  Widget _header(BuildContext context, _Target t) {
    final colors = context.theme.colors;
    final title = DuvetType.rowTitleUnread.copyWith(color: colors.foreground);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 8, 4),
      child: Row(
        children: [
          if (t.type == 1) ...[UserAvatar(name: t.name, url: t.avatarUrl, size: 24), const SizedBox(width: 8)],
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: t.type == 0
                  ? RoleName(t.name, colors: t.colors!, style: title)
                  : Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: title),
            ),
          ),
          if (t.type == 1)
            Semantics(
              container: true,
              button: true,
              label: 'Remove ${t.name}’s own permissions',
              excludeSemantics: true,
              onTap: () => _removeMember(t),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _removeMember(t),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Center(
                      widthFactor: 1,
                      child: Text('Remove', style: DuvetType.label.copyWith(fontSize: 15, color: colors.destructive)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _page(BuildContext context, List<_Target> targets, int index, EdgeInsets padding) {
    final colors = context.theme.colors;
    final t = targets[index];
    final overwrite = _overwrite(t);
    final card = ListView(
      // A card scrolls on its own, and bounces even when it fits.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(6, 0, 6, padding.bottom),
      children: [
        AdminPanel(
          children: [
            _header(context, t),
            if (t.type == 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(
                  'Theirs alone, over what their roles say',
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ),
            for (final (group, perms) in _groups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                child: Semantics(
                  header: true,
                  child: Text(group.toUpperCase(), style: DuvetType.overline.copyWith(color: colors.mutedForeground)),
                ),
              ),
              for (final p in perms)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(p.label, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                      Text(p.description, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                      const SizedBox(height: 8),
                      Segmented<bool?>(
                        label: p.label,
                        value: overwrite.stateOf(p.bit),
                        options: {false: 'Deny', null: t.type == 1 ? 'Their roles' : 'Role default', true: 'Allow'},
                        onChanged: (state) => _set(t, p.bit, state),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 6),
          ],
        ),
      ],
    );
    // The cards beside the one shown sit back a little and dim, following the
    // finger; tapped, one turns to the front. Screen readers have the chips.
    // The tree stays the same whichever card is shown, so turning the page
    // mid-swipe doesn't build both cards again; and the card is veiled, not
    // faded, so a swipe moves its drawing instead of redrawing it each frame.
    final shown = t.id == _shown;
    final veil = colors.background;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: shown ? null : () => _pick(index),
      child: ExcludeSemantics(
        excluding: !shown,
        child: IgnorePointer(
          ignoring: !shown,
          child: AnimatedBuilder(
            animation: _pages,
            child: RepaintBoundary(child: card),
            builder: (context, child) {
              final page = _pages.hasClients && _pages.position.haveDimensions ? _pages.page! : index.toDouble();
              final away = (page - index).abs().clamp(0.0, 1.0);
              return Transform.scale(
                scale: 1 - 0.05 * away,
                alignment: Alignment.topCenter,
                child: Stack(
                  children: [
                    child!,
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(color: veil.withValues(alpha: 0.45 * away)),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // Where the cards are: a dot each, the one shown long; past ten, a count.
  Widget _dots(BuildContext context, List<_Target> targets) {
    final colors = context.theme.colors;
    final accent = context.duvet.accentText;
    final index = targets.indexWhere((t) => t.id == _shown);
    if (targets.length > 10) {
      return Text(
        '${index + 1} of ${targets.length}',
        style: DuvetType.caption.copyWith(color: colors.mutedForeground),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < targets.length; i++)
          AnimatedContainer(
            duration: _motion == Duration.zero ? Duration.zero : DuvetTokens.pressOut,
            curve: DuvetTokens.decelerate,
            margin: const EdgeInsets.only(left: 4),
            width: i == index ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? accent : colors.mutedForeground.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder(valueListenable: context.repository.spaces, builder: (context, _, _) => _build(context));

  Widget _build(BuildContext context) {
    final colors = context.theme.colors;
    final targets = _targets;
    // A role or member gone while here: the card next to where it was.
    if (!targets.any((t) => t.id == _shown)) _shown = targets.last.id;
    // Roles come and go and move as others change them: the page follows the
    // card shown, or the one on screen would be another's, and inert.
    final at = targets.indexWhere((t) => t.id == _shown);
    if (!_jumping && _pages.hasClients && _pages.position.haveDimensions && _pages.page?.round() != at) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_jumping && _pages.hasClients) _pages.jumpToPage(at);
      });
    }
    return AdminPage(
      title: '#${widget.room.name}',
      list: (padding) {
        // Headers, chips and cards line up: the cards' edge is where the overlines' text starts.
        final inset = padding.left + 16;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: padding.top),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: padding.left),
              child: const Overline('For'),
            ),
            // One row of roles and members however many, edge to edge, the
            // one shown brought to the middle; adding a member at its end.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: Row(
                children: [
                  for (final (i, t) in targets.indexed)
                    Padding(
                      key: _chips.putIfAbsent(t.id, GlobalKey.new),
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: DuvetChip(
                        label: t.name,
                        selected: t.id == _shown,
                        leading: t.type == 1 ? UserAvatar(name: t.name, url: t.avatarUrl, size: 18) : null,
                        onTap: () => _pick(i),
                      ),
                    ),
                  DuvetChip(
                    label: 'Add member',
                    selected: false,
                    action: true,
                    leading: Icon(FLucideIcons.userPlus, size: 16, color: colors.foreground),
                    onTap: () => _addMember(targets),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.only(left: padding.left),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Expanded(child: Overline('In this room')),
                  ExcludeSemantics(
                    child: Padding(padding: EdgeInsets.fromLTRB(0, 0, inset, 10), child: _dots(context, targets)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                physics: const CarouselPhysics(),
                itemCount: targets.length,
                onPageChanged: (i) => _turned(targets, i),
                itemBuilder: (context, i) => _page(context, targets, i, padding),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The Space's members, searched by name, to give one their own permissions
/// in a room; those with theirs already aren't offered. Answers the one picked.
class _MemberPicker extends StatefulWidget {
  /// Whose members they are: a bot's status here comes first.
  final String spaceId;
  final Future<List<Member>> members;

  /// The members already had: shown at once, no spinner first.
  final List<Member>? loaded;
  final Set<String> taken;
  final ScrollController scroll;
  const _MemberPicker({
    required this.spaceId,
    required this.members,
    required this.loaded,
    required this.taken,
    required this.scroll,
  });

  @override
  State<_MemberPicker> createState() => _MemberPickerState();
}

class _MemberPickerState extends State<_MemberPicker> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: widget.members,
    initialData: widget.loaded,
    builder: (context, snapshot) {
      final colors = context.theme.colors;
      final repository = context.repository;
      final query = _search.text.trim().toLowerCase();
      final offered = [
        for (final m in snapshot.data ?? const <Member>[])
          if (!widget.taken.contains(m.userId) &&
              (query.isEmpty ||
                  m.displayName.toLowerCase().contains(query) ||
                  m.username.toLowerCase().contains(query)))
            m,
      ];
      return ListView(
        controller: widget.scroll,
        // Scrolling the members puts the search's keyboard away.
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          const SheetTitle(title: 'Add a member', caption: 'Their own permissions here, over their roles'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: DuvetTextField(label: 'Search', controller: _search, onChanged: (_) => setState(() {})),
          ),
          if (snapshot.hasError)
            const ListNote('Couldn’t load the members. Close this and try again.')
          else if (!snapshot.hasData)
            LoadingSkeleton(
              label: 'Loading members',
              children: [
                // As a PersonRow without the handle.
                for (final name in placeholderNames)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Bone.circle(size: 40),
                        const SizedBox(width: 12),
                        Text(name, style: DuvetType.rowTitle),
                      ],
                    ),
                  ),
              ],
            )
          else if (offered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                query.isEmpty ? 'Everyone has theirs already' : 'No one by that name',
                textAlign: TextAlign.center,
                style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
              ),
            )
          else
            for (final m in offered)
              PersonRow(
                member: m,
                presence: presenceIn(repository.presence.value, m.userId, spaceId: widget.spaceId),
                username: false,
                onTap: () => Navigator.of(context).pop(m),
              ),
        ],
      );
    },
  );
}

// -----------------------------------------------------------------------------
// Roles
// -----------------------------------------------------------------------------

/// A reorderable row's trailing edge, ridged like a grip: drag it to move
/// the row. Down a panel the edges make one ridge.
class DragEdge extends StatelessWidget {
  final int index;
  const DragEdge({required this.index, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return ReorderableDragStartListener(
      index: index,
      child: ExcludeSemantics(
        child: Container(
          width: EdgedRow.edgeWidth,
          decoration: BoxDecoration(
            color: colors.secondary,
            border: BorderDirectional(start: BorderSide(color: context.duvet.hairline)),
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
  }
}

/// A row with [edge] down its trailing side, as tall as the row: a
/// [DragEdge], or what stands where one would. The row's height is [child]'s
/// alone and the edge is stretched to it afterwards, so each row is laid out
/// once: an `IntrinsicHeight` around a stretched `Row` costs a second pass
/// over every row (#65) for the same pixels, as long as [child] is at least
/// as tall as what [edge] holds. An edge is never what makes a row taller: a
/// [child] shorter than a [DragEdge]'s ridges (18) would overflow it.
class EdgedRow extends StatelessWidget {
  /// How wide an edge is.
  static const edgeWidth = 32.0;

  final Widget child;
  final Widget? edge;
  const EdgedRow({required this.child, this.edge, super.key});

  @override
  Widget build(BuildContext context) {
    final edge = this.edge;
    if (edge == null) return child;
    return Stack(
      // The list's width, not up to it.
      fit: StackFit.passthrough,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: edgeWidth),
          child: child,
        ),
        PositionedDirectional(top: 0, bottom: 0, end: 0, width: edgeWidth, child: edge),
      ],
    );
  }
}

/// A reorderable row off its panel while held: raised on its own.
Widget liftedRow(Widget child, int _, Animation<double> _) => Builder(
  builder: (context) => Transform.scale(
    scale: 1.02,
    child: Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.theme.colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
        boxShadow: context.duvet.shadowRaised,
      ),
      child: Material(type: MaterialType.transparency, child: child),
    ),
  ),
);

/// What a role may do, in a few words: its strongest permissions first.
String rolePowers(SpaceRole r) {
  if (Perm.has(r.perms, Perm.administrator)) return 'Administrator';
  final names = [
    for (final (_, perms) in permissionGroups)
      for (final p in perms)
        if (r.perms & p.bit == p.bit) p.label,
  ];
  return switch (names.length) {
    0 => 'No permissions',
    1 || 2 => names.join(', '),
    final n => '${names.take(2).join(', ')} and ${n - 2} more',
  };
}

/// How much a role manages, for Admins first: Administrator, then any part
/// of the Space, then nothing.
int _adminRank(SpaceRole r) => Perm.has(r.perms, Perm.administrator)
    ? 0
    : r.perms & Perm.anyAdmin != 0
    ? 1
    : 2;

/// A role's colors read aloud: "default", "#30A46C", or a gradient's stops.
String describeRoleColors(RoleColors c) {
  if (c.from == null) return 'default';
  if (c.to == null) return hexOf(c.from!);
  return 'gradient, ${[c.from, c.via, c.to].nonNulls.map(hexOf).join(' to ')}';
}

/// A role's colors on a small rounded swatch, left to right: the picker's
/// own preview, never a role's fill elsewhere. The default ink without one.
class RoleSwatch extends StatelessWidget {
  final RoleColors colors;
  final double width;
  final double height;
  const RoleSwatch({required this.colors, this.width = 20, this.height = 20, super.key});

  @override
  Widget build(BuildContext context) {
    final stops = [colors.from, colors.via, colors.to].nonNulls.map((c) => roleColorOn(context, c)!).toList();
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: stops.isEmpty ? context.theme.colors.foreground : stops.first,
        gradient: colors.from != null && colors.to != null ? LinearGradient(colors: stops) : null,
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}

enum _ColorKind { none, solid, gradient }

enum _Stop { start, middle, end }

/// The name's color: none, a swatch or any custom color, or a gradient across
/// two or three of those, previewed on the name as members will see it.
/// Answers on Done.
class _RoleColorSheet extends StatefulWidget {
  final String name;
  final RoleColors initial;
  final ScrollController scroll;
  const _RoleColorSheet({required this.name, required this.initial, required this.scroll});

  @override
  State<_RoleColorSheet> createState() => _RoleColorSheetState();
}

class _RoleColorSheetState extends State<_RoleColorSheet> {
  late RoleColors _c = widget.initial;
  late _ColorKind _kind = _c.from == null
      ? _ColorKind.none
      : _c.to == null
      ? _ColorKind.solid
      : _ColorKind.gradient;
  _Stop _stop = _Stop.start;

  void _kindTo(_ColorKind kind) => setState(() {
    _kind = kind;
    _stop = _Stop.start;
    final first = _c.from ?? roleSwatches[3];
    _c = switch (kind) {
      _ColorKind.none => (from: null, via: null, to: null),
      _ColorKind.solid => (from: first, via: null, to: null),
      // A gradient starts from the color there was, to the next swatch along.
      _ColorKind.gradient => (
        from: first,
        via: _c.via,
        to: _c.to ?? roleSwatches[(roleSwatches.indexOf(first) + 2) % roleSwatches.length],
      ),
    };
  });

  void _pick(int? rgb) => setState(() {
    _c = switch ((_kind, _stop)) {
      (_ColorKind.gradient, _Stop.middle) => (from: _c.from, via: rgb, to: _c.to),
      (_ColorKind.gradient, _Stop.end) => (from: _c.from, via: _c.via, to: rgb),
      (_ColorKind.gradient, _) => (from: rgb, via: _c.via, to: _c.to),
      _ => (from: rgb, via: null, to: null),
    };
  });

  int? get _current => switch ((_kind, _stop)) {
    (_ColorKind.gradient, _Stop.middle) => _c.via,
    (_ColorKind.gradient, _Stop.end) => _c.to,
    _ => _c.from,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    // The middle stop alone may be left out.
    final none = _kind == _ColorKind.gradient && _stop == _Stop.middle;
    return ListView(
      controller: widget.scroll,
      padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        const SheetTitle(title: 'Name color', caption: 'Names only, never fills'),
        // The name as members will see it.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            ),
            alignment: Alignment.center,
            child: Semantics(
              label: 'Preview: ${widget.name}, ${describeRoleColors(_c)}',
              excludeSemantics: true,
              child: RoleName(widget.name, colors: _c, style: DuvetType.title),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Segmented<_ColorKind>(
            label: 'Color',
            value: _kind,
            options: const {_ColorKind.none: 'Default', _ColorKind.solid: 'Solid', _ColorKind.gradient: 'Gradient'},
            onChanged: _kindTo,
          ),
        ),
        if (_kind == _ColorKind.gradient) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Segmented<_Stop>(
              label: 'Which stop',
              value: _stop,
              options: const {_Stop.start: 'Start', _Stop.middle: 'Middle', _Stop.end: 'End'},
              onChanged: (stop) => setState(() => _stop = stop),
            ),
          ),
        ],
        if (_kind != _ColorKind.none)
          Padding(
            // Kept by key as the stops' row comes and goes: Custom stays open.
            key: const ValueKey('color'),
            padding: const EdgeInsets.all(16),
            child: ColorPick(
              value: _current,
              presets: [if (none) null, ...roleSwatches],
              label: (rgb) => rgb == null ? 'No middle' : hexOf(rgb),
              fill: (rgb) => rgb == null ? colors.secondary : roleColorOn(context, rgb)!,
              noneIcon: FLucideIcons.ban,
              onChanged: _pick,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: DuvetButton(
            label: 'Done',
            variant: ButtonVariant.primary,
            expand: true,
            onPressed: () => Navigator.of(context).pop(_c),
          ),
        ),
      ],
    );
  }
}

/// The Space's roles, highest first, to reorder by dragging their edge as
/// rooms are; @everyone last, where it stays.
class RolesPage extends StatefulWidget {
  final String spaceId;
  const RolesPage({required this.spaceId, super.key});

  @override
  State<RolesPage> createState() => _RolesPageState();
}

class _RolesPageState extends State<RolesPage> {
  bool _sorting = false;

  Future<void> _create() async {
    // The API takes 64 and fails past it.
    final got = await askName<void>(context, title: 'New role', action: 'Create', maxLength: 64);
    if (got == null || !mounted) return;
    final repository = context.repository;
    try {
      final role = await repository.createRole(widget.spaceId, got.$1);
      if (mounted) await _edit(role);
    } catch (e) {
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t create the role');
    }
  }

  Future<void> _edit(SpaceRole role) async {
    // @everyone too, at 0: below the user's highest role, or theirs to look at.
    final readOnly = !_below(role.position);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoleEditorPage(spaceId: widget.spaceId, role: role, readOnly: readOnly),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Whether the user may move or change [r]: as the API checks it, a role
  /// below their highest one, unless they own the Space (Administrator
  /// doesn't get past it).
  bool _manages(SpaceRole r) => !r.everyone && _below(r.position);

  /// Whether a role may sit at [position]: below the user's highest role,
  /// with ManageRoles; anywhere for the Space's owner.
  bool _below(int position) => managesRoleAt(context.repository, widget.spaceId, position);

  // A screen reader's move of a role the user may not move.
  void _cantMove(SpaceRole r) =>
      SemanticsService.sendAnnouncement(View.of(context), 'You can’t move ${r.name}', Directionality.of(context));

  /// Moves [moved] to [to] among the others above @everyone (0 at the top):
  /// to the position of the role it lands above, going up, or of the one it
  /// lands below, going down, as the API shifts those between. Positions can
  /// have gaps (a deleted role's stays empty), so never counted from indexes.
  Future<void> _move(List<SpaceRole> ranked, SpaceRole moved, int to) async {
    final others = [...ranked]..remove(moved);
    final up = to < ranked.indexOf(moved);
    final position = up ? others[to].position : others[to - 1].position;
    if (!_below(position)) {
      adminToast(context, 'Roles can only go below your highest role');
      return;
    }
    HapticFeedback.selectionClick();
    // The API clamps a position to the number of roles less one: one in a
    // gap past that can't be sent, so the user's roles are laid out again.
    if (position > context.repository.roles(widget.spaceId).length - 1) {
      return _arrange(([...others]..insert(to, moved)).where(_manages).toList());
    }
    setState(() => _sorting = true);
    await adminTry(
      context,
      'Couldn’t move ${moved.name}',
      () => context.repository.moveRole(widget.spaceId, moved.id, position),
    );
    if (mounted) setState(() => _sorting = false);
  }

  /// Lays the user's roles out in [order], top first: each sent to the
  /// bottom (position 1, always the user's to send), so those sent before
  /// rise one place each time. Right whatever gaps the positions have, which
  /// it closes; one request a role, one after another.
  Future<void> _arrange(List<SpaceRole> order) async {
    final repository = context.repository;
    setState(() => _sorting = true);
    for (final role in order) {
      final ok = await adminTry(
        context,
        'Couldn’t move ${role.name}',
        () => repository.moveRole(widget.spaceId, role.id, 1),
      );
      if (!ok || !mounted) break;
    }
    if (mounted) setState(() => _sorting = false);
  }

  /// The roles the user manages, admins first, each tier in its order.
  Future<void> _adminsFirst() async {
    final sure = await confirmDestructive(
      context,
      title: 'Put admin roles first?',
      body: 'Roles with Administrator go to the top, then those that manage part of the Space. The rest keep their order below them. Everyone sees the new order.',
      action: 'Reorder',
      destructive: false,
    );
    if (!sure || !mounted) return;
    // A stable sort: each tier keeps its order.
    final mine = context.repository.roles(widget.spaceId).where(_manages).toList();
    await _arrange([...mine]..sort((a, b) => _adminRank(a).compareTo(_adminRank(b))));
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder(valueListenable: context.repository.spaces, builder: (context, _, _) => _build(context));

  Widget _build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final repository = context.repository;
    final roles = repository.roles(widget.spaceId);
    final ranked = roles.where((r) => !r.everyone).toList();
    final everyone = roles.where((r) => r.everyone).firstOrNull;
    final mine = ranked.where(_manages).toList();
    final unsorted = [
      for (var i = 1; i < mine.length; i++)
        if (_adminRank(mine[i]) < _adminRank(mine[i - 1])) i,
    ].isNotEmpty;

    // The trailing edge, ridged like a grip, as the rooms' is.
    Widget grip(int index) => DragEdge(index: index);
    // Above the user's highest role: theirs to see, not to move or change.
    Widget locked() => ExcludeSemantics(
      child: SizedBox(
        width: EdgedRow.edgeWidth,
        child: Icon(FLucideIcons.lock, size: 14, color: colors.mutedForeground),
      ),
    );

    Widget row(SpaceRole r, {int? index}) {
      final moves = index != null && _manages(r);
      final members = r.everyone
          ? 'Everyone in the Space'
          : '${r.memberCount} ${r.memberCount == 1 ? 'member' : 'members'}';
      final body = Semantics(
        button: true,
        label: [
          r.name,
          if (r.hoisted) 'shown separately',
          members,
          rolePowers(r),
          if (moves && ranked.length > 1) 'Double tap to edit, or use actions to move it',
        ].join(', '),
        excludeSemantics: true,
        onTap: () => _edit(r),
        // Pressed, the row's `base-sunken` highlight, as every row's.
        child: Pressable(
          onTap: () => _edit(r),
          scale: 1,
          builder: (context, pressed) => AnimatedContainer(
            duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
            color: pressed ? colors.secondary : colors.card,
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: RoleName(r.name, colors: r.colors, style: DuvetType.rowTitleUnread),
                    ),
                    if (r.hoisted) ...[
                      const SizedBox(width: 8),
                      Icon(FLucideIcons.layers, size: 14, color: colors.mutedForeground),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$members · ${rolePowers(r)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ],
            ),
          ),
        ),
      );
      return EdgedRow(
        edge: moves
            ? grip(index)
            : r.everyone
            ? null
            : locked(),
        child: body,
      );
    }

    Widget panel(Widget child) => Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
        boxShadow: tokens.shadowRaised,
      ),
      child: child,
    );

    return AdminPage(
      title: 'Roles',
      actions: [
        if (unsorted)
          IconAction(
            icon: FLucideIcons.arrowUpWideNarrow,
            label: 'Admins first',
            onPressed: _sorting ? null : _adminsFirst,
          ),
        IconAction(icon: FLucideIcons.plus, label: 'New role', onPressed: _create),
      ],
      children: [
        if (ranked.isNotEmpty) ...[
          panel(
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              buildDefaultDragHandles: false,
              itemCount: ranked.length,
              onReorderItem: (from, to) {
                // One change at a time: a move made from a list still moving would land wrong.
                if (_sorting) return;
                if (!_manages(ranked[from])) return _cantMove(ranked[from]);
                if (from != to) _move(ranked, ranked[from], to);
              },
              // A role off its panel while held: raised on its own.
              proxyDecorator: liftedRow,
              itemBuilder: (context, i) {
                final r = ranked[i];
                return _manages(r)
                    ? ReorderableDelayedDragStartListener(
                        key: ValueKey(r.id),
                        index: i,
                        child: row(r, index: i),
                      )
                    : KeyedSubtree(key: ValueKey(r.id), child: row(r));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _sorting ? 'Reordering…' : 'Higher roles outrank those below them. Drag a role by its edge to move it.',
              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
            ),
          ),
        ],
        if (everyone != null) ...[const SizedBox(height: 16), panel(row(everyone))],
      ],
    );
  }
}

/// A role: its name and color, who has it, and what it may do.
class RoleEditorPage extends StatefulWidget {
  final String spaceId;
  final SpaceRole role;

  /// At or above the user's highest role: shown, not changed, as the API
  /// refuses it.
  final bool readOnly;
  const RoleEditorPage({required this.spaceId, required this.role, this.readOnly = false, super.key});

  @override
  State<RoleEditorPage> createState() => _RoleEditorPageState();
}

class _RoleEditorPageState extends State<RoleEditorPage> {
  late final _name = TextEditingController(text: widget.role.name)..addListener(() => setState(() {}));
  late RoleColors _colors = widget.role.colors;
  late int _perms = widget.role.perms;
  late bool _hoisted = widget.role.hoisted;
  // Members to give (true) or take (false) the role on Save.
  final _memberChanges = <String, bool>{};
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
    final repository = context.repository;
    final fields = _fieldsDirty;
    setState(() => _saving = true);
    final ok = await adminTry(context, 'Couldn’t save ${r.name}', () async {
      if (fields) {
        await repository.updateRole(
          widget.spaceId,
          r.id,
          name: r.everyone || name.isEmpty || name == r.name ? null : name,
          colors: _colors != r.colors ? _colors : null,
          perms: _perms != r.perms ? _perms : null,
          hoisted: _hoisted != r.hoisted ? _hoisted : null,
        );
      }
      for (final MapEntry(key: userId, value: has) in [..._memberChanges.entries]) {
        await repository.setRole(widget.spaceId, r.id, userId, has: has);
        _memberChanges.remove(userId);
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) navigator.pop();
  }

  Future<void> _pickColor() async {
    final picked = await showGlassSheet<RoleColors>(
      context,
      label: 'Name color',
      initialSize: 0.7,
      builder: (context, scroll) => _RoleColorSheet(
        name: _name.text.trim().isEmpty ? widget.role.name : _name.text.trim(),
        initial: _colors,
        scroll: scroll,
      ),
    );
    if (picked != null && mounted) setState(() => _colors = picked);
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
          final holders = _holders;
          return ListView(
            controller: scroll,
            children: [
              SheetTitle(title: 'Who has ${widget.role.name}'),
              for (final m in members)
                PersonRow(
                  member: m,
                  presence: presenceIn(repository.presence.value, m.userId, spaceId: widget.spaceId),
                  checked: holders.contains(m.userId),
                  username: false,
                  onTap: () => setSheet(() => _toggle(m.userId, !holders.contains(m.userId))),
                ),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  /// Who has the role once Save applies the staged member changes.
  Set<String> get _holders {
    final holders = context.repository.roleMembers(widget.spaceId, widget.role.id).toSet();
    _memberChanges.forEach((userId, has) => has ? holders.add(userId) : holders.remove(userId));
    return holders;
  }

  // Stages it for Save; back to how it was, nothing is staged.
  void _toggle(String userId, bool has) => setState(() {
    if (context.repository.roleMembers(widget.spaceId, widget.role.id).contains(userId) == has) {
      _memberChanges.remove(userId);
    } else {
      _memberChanges[userId] = has;
    }
  });

  bool get _fieldsDirty {
    final r = widget.role;
    final name = _name.text.trim();
    return (!r.everyone && name.isNotEmpty && name != r.name) ||
        _colors != r.colors ||
        _perms != r.perms ||
        _hoisted != r.hoisted;
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
    if (await adminTry(
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
    final holders = _holders;
    final admin = Perm.has(_perms, Perm.administrator);
    final children = <Widget>[
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: r.everyone
                ? Text(r.name, style: DuvetType.title.copyWith(color: colors.foreground))
                // The API takes 64 and fails past it.
                : DuvetTextField(label: 'Role name', controller: _name, maxLength: 64),
          ),
          const SizedBox(width: 12),
          Semantics(
            container: true,
            button: true,
            label: 'Name color: ${describeRoleColors(_colors)}',
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
                    RoleSwatch(colors: _colors, width: 28, height: 20),
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
        const SizedBox(height: 12),
        AdminPanel(
          children: [
            // As the desktop's "Display role members separately".
            Semantics(
              container: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Show members separately', style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                          Text(
                            'In the member list, those online show under this role’s name',
                            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    DuvetSwitch(
                      label: 'Show members separately',
                      value: _hoisted,
                      onChanged: (on) => setState(() => _hoisted = on),
                    ),
                  ],
                ),
              ),
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
      if (!r.everyone && !widget.readOnly) ...[
        const SizedBox(height: 24),
        DuvetButton(label: 'Delete role', variant: ButtonVariant.destructive, expand: true, onPressed: _delete),
      ],
    ];
    if (!widget.readOnly) {
      final dirty = _fieldsDirty || _memberChanges.isNotEmpty;
      return UnsavedChanges(
        dirty: dirty,
        child: AdminPage(
          title: 'Edit role',
          actions: [TextAction(label: 'Save', onPressed: _saving || !dirty ? null : _save)],
          children: children,
        ),
      );
    }
    return AdminPage(
      title: r.name,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'It’s at or above your highest role, so only those above it change it.',
            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
          ),
        ),
        IgnorePointer(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
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

  /// As the desktop: "Expires 11/15/2026, 3:04 PM", or "Never expires".
  String _until(DateTime? t) {
    if (t == null) return 'Never expires';
    final l = MaterialLocalizations.of(context);
    final time = l.formatTimeOfDay(
      TimeOfDay.fromDateTime(t),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return 'Expires ${l.formatCompactDate(t)}, $time';
  }

  Future<void> _revoke(SpaceInvite i) async {
    final sure = await confirmDestructive(
      context,
      title: 'Revoke ${i.code}?',
      body: 'The link stops working. People who joined with it stay.',
      action: 'Revoke link',
    );
    if (!sure || !mounted) return;
    await adminTry(context, 'Couldn’t revoke the link', () => context.repository.revokeInvite(widget.spaceId, i.id));
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
            LoadingSkeleton(label: 'Loading invites', children: placeholderRows())
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
// Bans
// -----------------------------------------------------------------------------

/// Who's banned from the Space, newest first: searchable by name, ID or
/// reason, each with why, by whom and since when. One opens to unban. Bans
/// made or lifted elsewhere show as they happen.
class BansAdminPage extends StatefulWidget {
  final String spaceId;
  const BansAdminPage({required this.spaceId, super.key});

  @override
  State<BansAdminPage> createState() => _BansAdminPageState();
}

class _BansAdminPageState extends State<BansAdminPage> {
  late Future<List<SpaceBan>> _bans;
  final _search = TextEditingController();
  StreamSubscription<String>? _changes;

  // Unbanned here: gone from the list at once, until the list comes again.
  final _lifting = <String>{};

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = context.repository;
    _bans = repository.bans(widget.spaceId);
    _changes ??= repository.bansChanged.where((id) => id == widget.spaceId).listen((_) => _reload());
  }

  @override
  void dispose() {
    _changes?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    final lifted = {..._lifting};
    setState(() {
      _bans = context.repository.bans(widget.spaceId).then((l) {
        if (mounted) setState(() => _lifting.removeAll(lifted));
        return l;
      });
    });
  }

  String _date(DateTime t) => MaterialLocalizations.of(context).formatMediumDate(t);

  Future<void> _open(SpaceBan b) async {
    final name = b.user.displayName;
    if (!await _askUnban(context, b, _date(b.at)) || !mounted) return;
    final id = b.user.userId;
    setState(() => _lifting.add(id));
    final lifted = await adminTry(context, 'Couldn’t unban $name', () => context.repository.unban(widget.spaceId, id));
    if (!mounted) return;
    if (lifted) {
      adminToast(context, '$name can join again');
      _reload();
    } else {
      setState(() => _lifting.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _bans,
    builder: (context, snapshot) {
      final all = snapshot.data;
      final q = _search.text.trim().toLowerCase();
      bool matches(SpaceBan b) =>
          q.isEmpty ||
          b.user.displayName.toLowerCase().contains(q) ||
          b.user.username.toLowerCase().contains(q) ||
          b.user.userId.contains(q) ||
          (b.reason?.toLowerCase().contains(q) ?? false);
      final shown = [
        for (final b in all ?? const <SpaceBan>[])
          if (!_lifting.contains(b.user.userId) && matches(b)) b,
      ];
      return AdminPage(
        title: 'Bans',
        children: [
          SearchField(controller: _search, hint: 'Search by name, ID or reason'),
          const SizedBox(height: 8),
          if (snapshot.hasError)
            const ListNote('Couldn’t load the bans')
          else if (all == null)
            LoadingSkeleton(label: 'Loading bans', children: placeholderRows(avatar: 40))
          else if (shown.isEmpty)
            ListNote(q.isEmpty ? 'No one is banned' : 'No one matches')
          else
            for (final b in shown)
              ListRow(
                leading: ExcludeSemantics(
                  child: UserAvatar(name: b.user.displayName, url: b.user.avatarUrl, size: 40),
                ),
                title: b.user.displayName,
                snippet: [
                  if (b.user.username.isNotEmpty) '@${b.user.username}',
                  b.reason ?? 'No reason given',
                ].join(' · '),
                trailing: MaterialLocalizations.of(context).formatCompactDate(b.at),
                detail: 'Double tap to unban',
                onTap: () => _open(b),
              ),
        ],
      );
    },
  );
}

/// A ban up close: who, by whom, when and why, in full. True to unban.
Future<bool> _askUnban(BuildContext context, SpaceBan b, String date) async =>
    await showGlassDialogSheet<bool>(
      context,
      label: '${b.user.displayName}’s ban',
      builder: (context) {
        final colors = context.theme.colors;
        final m = b.user;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ExcludeSemantics(
                    child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 48),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.displayName, style: DuvetType.title.copyWith(color: colors.foreground)),
                        Text(
                          [if (m.username.isNotEmpty) '@${m.username}', 'banned by ${b.bannedBy}', date].join(' · '),
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.secondary,
                  borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                ),
                child: Text(
                  b.reason ?? 'No reason given',
                  style: DuvetType.body.copyWith(
                    color: b.reason == null ? colors.mutedForeground : colors.foreground,
                    fontStyle: b.reason == null ? FontStyle.italic : null,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Unbanned, they can join again with an invite.',
                style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
              ),
              const SizedBox(height: 24),
              DuvetButton(
                label: 'Unban',
                icon: FLucideIcons.userCheck,
                variant: ButtonVariant.primary,
                expand: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 12),
              DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
            ],
          ),
        );
      },
    ) ==
    true;

// -----------------------------------------------------------------------------
// Members
// -----------------------------------------------------------------------------

/// Whether the user may give, take, move or change a role at [position]:
/// as the API checks it, one below their highest role, with ManageRoles;
/// any for the Space's owner (Administrator doesn't get past it).
bool managesRoleAt(ChatRepository repository, String spaceId, int position) {
  final profile = repository.spaceProfile(spaceId);
  if (profile == null) return false;
  if (profile.owner) return true;
  if (!profile.can(Perm.manageRoles)) return false;
  final me = repository.profile.value?.id;
  final highest = me == null ? 0 : repository.rolesOf(spaceId, me).firstOrNull?.position ?? 0;
  return position < highest;
}

/// May kick or ban [userId] ([bit]: Kick or Ban Members), as the API rules:
/// never the owner or themselves and, but for the owner, only someone whose
/// highest role is below the user's own.
bool mayRemove(ChatRepository repository, String spaceId, String userId, int bit) {
  final profile = repository.spaceProfile(spaceId);
  final me = repository.profile.value?.id;
  if (profile == null || me == null || userId == me || !profile.can(bit)) return false;
  if (repository.spaces.value.where((s) => s.id == spaceId).firstOrNull?.ownerId == userId) return false;
  if (profile.owner) return true;
  int highest(String id) => repository.rolesOf(spaceId, id).firstOrNull?.position ?? 0;
  return highest(userId) < highest(me);
}

/// A Space's members, as the desktop's Members tab lists them: searchable by
/// name, username or ID, each with their roles. One opens to change their
/// roles, and to remove a bot or kick or ban a person.
class MembersAdminPage extends StatefulWidget {
  final String spaceId;
  const MembersAdminPage({required this.spaceId, super.key});

  @override
  State<MembersAdminPage> createState() => _MembersAdminPageState();
}

class _MembersAdminPageState extends State<MembersAdminPage> {
  late Future<List<Member>> _members;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = context.repository;
    _members = repository.members(
      RoomTarget(
        spaceId: widget.spaceId,
        roomId: repository.adminRooms(widget.spaceId).where((r) => r.kind == AdminRoomKind.text).firstOrNull?.id ?? '',
      ),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    return FutureBuilder(
      future: _members,
      builder: (context, snapshot) => ValueListenableBuilder(
        // Roles given or taken, and members leaving (a bot removed).
        valueListenable: repository.spaces,
        builder: (context, _, _) {
          final all = snapshot.data;
          final ownerId = repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull?.ownerId;
          final q = _search.text.trim().toLowerCase();
          final shown = [
            for (final m in all ?? const <Member>[])
              if (repository.isMember(widget.spaceId, m.userId) &&
                  (q.isEmpty ||
                      m.displayName.toLowerCase().contains(q) ||
                      m.username.toLowerCase().contains(q) ||
                      m.userId.contains(q)))
                m,
          ]..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
          return AdminPage(
            title: 'Members',
            children: [
              SearchField(controller: _search, hint: 'Search by name or ID'),
              const SizedBox(height: 8),
              if (snapshot.hasError)
                const ListNote('Couldn’t load the members')
              else if (all == null)
                LoadingSkeleton(label: 'Loading members', children: placeholderRows(avatar: 40))
              else if (shown.isEmpty)
                ListNote(q.isEmpty ? 'No members' : 'No one matches')
              else
                for (final m in shown)
                  ListRow(
                    leading: ExcludeSemantics(
                      child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 40),
                    ),
                    title: m.displayName,
                    titleIcon: m.userId == ownerId ? const OwnerCrown() : null,
                    snippet: [
                      if (m.username.isNotEmpty) '@${m.username}',
                      if (m.userId == ownerId) 'owner',
                      if (m.isBot) 'bot',
                      switch (repository.rolesOf(widget.spaceId, m.userId)) {
                        [] => 'No roles',
                        final roles => roles.map((r) => r.name).join(', '),
                      },
                    ].join(' · '),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MemberAdminPage(spaceId: widget.spaceId, member: m),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// A member's roles as switches; those the user manages change at once.
/// The caller rebuilds it when repository.spaces changes.
class MemberRoleSwitches extends StatelessWidget {
  final String spaceId;
  final Member member;
  const MemberRoleSwitches({required this.spaceId, required this.member, super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final m = member;
    final has = {for (final r in repository.rolesOf(spaceId, m.userId)) r.id};
    final roles = repository.roles(spaceId).where((r) => !r.everyone).toList();
    return AdminPanel(
      children: [
        if (roles.isEmpty) const ListNote('This Space has no roles yet'),
        for (final r in roles)
          Builder(
            builder: (context) {
              final on = has.contains(r.id);
              final change = managesRoleAt(repository, spaceId, r.position)
                  ? (bool on) => adminTry(
                      context,
                      'Couldn’t change ${m.displayName}’s roles',
                      () => repository.setRole(spaceId, r.id, m.userId, has: on),
                    )
                  : null;
              // The whole row toggles, for a target past 44pt.
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: change == null ? null : () => change(!on),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: RoleName(r.name, colors: r.colors, style: DuvetType.rowTitle),
                      ),
                      const SizedBox(width: 12),
                      DuvetSwitch(label: r.name, value: on, onChanged: change),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// One member, in Space settings: their ID, their roles (those the user
/// manages can be given and taken) and Remove from Space for a bot, or Kick
/// and Ban for a person.
class MemberAdminPage extends StatelessWidget {
  final String spaceId;
  final Member member;
  const MemberAdminPage({required this.spaceId, required this.member, super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final colors = context.theme.colors;
    final m = member;
    return ValueListenableBuilder(
      valueListenable: repository.spaces,
      builder: (context, spaces, _) {
        final profile = repository.spaceProfile(spaceId);
        final spaceName = spaces.where((s) => s.id == spaceId).firstOrNull?.name ?? 'this Space';
        return AdminPage(
          title: m.displayName,
          backLabel: 'Back to Members',
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 56),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.displayName, style: DuvetType.title.copyWith(color: colors.foreground)),
                      if (m.username.isNotEmpty || m.isBot)
                        Text(
                          [if (m.username.isNotEmpty) '@${m.username}', if (m.isBot) 'bot'].join(' · '),
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const Overline('User ID'),
            AdminPanel(
              children: [
                ListRow(
                  title: m.userId,
                  detail: 'Double tap to copy',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: m.userId));
                    adminToast(context, 'ID copied');
                  },
                ),
              ],
            ),
            const Overline('Roles'),
            MemberRoleSwitches(spaceId: spaceId, member: m),
            if (m.isBot && (profile?.can(Perm.manageBots) ?? false)) ...[
              const SizedBox(height: 32),
              DuvetButton(
                label: 'Remove from Space',
                icon: FLucideIcons.userMinus,
                variant: ButtonVariant.destructive,
                expand: true,
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  if (await removeBotAsking(context, spaceId: spaceId, bot: m, spaceName: spaceName)) navigator.pop();
                },
              ),
            ],
            ...removeMemberButtons(
              context,
              spaceId: spaceId,
              member: m,
              spaceName: spaceName,
              gap: 32,
              onGone: Navigator.of(context).pop,
            ),
          ],
        );
      },
    );
  }
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

  // The picture going up: its sheet is gone, and the list waits for it.
  final _upload = ValueNotifier<double?>(null);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list = context.repository.assets(widget.spaceId, _kind);
  }

  @override
  void dispose() {
    _upload.dispose();
    super.dispose();
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
    // A moving GIF the API takes as it is goes up unchanged; a larger one is
    // cropped, every frame. A still GIF is cropped as any picture is.
    final gif = await gifAt(path);
    if (!mounted) return;
    // The cropper would close on it without a word.
    if (gif != null && !gif.readable) {
      adminToast(context, 'Couldn’t read this GIF');
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
                ? 'This GIF is over ${cap.bytes ~/ 1024} KiB or ${cap.side} px, so it goes up cropped and resized'
                : null,
          ),
        ),
      );
      if (crop == null || !mounted) return;
    }
    final got = await askName<void>(context, title: 'Name the $_noun', action: 'Add');
    if (got == null || !mounted) return;
    final repository = context.repository;
    void progress(double p) {
      if (mounted) _upload.value = p;
    }

    await adminTry(context, 'Couldn’t add the $_noun', () async {
      if (crop == null) return repository.addAsset(widget.spaceId, kind, got.$1, path, onProgress: progress);
      final square = await saveSquareImage(path, crop, kind == AssetKind.emoji ? emojiSide : stickerSide);
      try {
        await repository.addAsset(widget.spaceId, kind, got.$1, square, onProgress: progress);
      } finally {
        // Best effort: the list needn't wait for it.
        unawaited(File(square).delete().then((_) {}, onError: (Object e) => debugPrint('square image: $e')));
      }
    });
    if (mounted) {
      _upload.value = null;
      _reload();
    }
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
        await adminTry(
          context,
          'Couldn’t rename it',
          () => repository.renameAsset(widget.spaceId, _kind, a.id, got.$1),
        );
      case 'delete':
        final sure = await confirmDestructive(
          context,
          title: 'Delete ${a.name}?',
          body: 'Messages that used it show its name instead.',
          action: 'Delete $_noun',
        );
        if (!sure || !mounted) return;
        await adminTry(context, 'Couldn’t delete it', () => repository.deleteAsset(widget.spaceId, _kind, a.id));
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
            UploadNote(_upload),
            if (!may)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(
                  'Anyone here may use them. Those who manage ${_noun}s add and change them.',
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ),
            const SizedBox(height: 16),
            if (snapshot.hasError)
              const ListNote('Couldn’t load them')
            else if (list == null)
              LoadingSkeleton(
                label: 'Loading ${_noun}s',
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final name in placeholderNames)
                        SizedBox(
                          width: size + 24,
                          child: Column(
                            children: [
                              Bone.square(size: size),
                              const SizedBox(height: 4),
                              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DuvetType.caption),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
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
                              Image(
                                image: cachedImage(a.url),
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

  Future<void> _showOnce(String name, String url) => showSecretOnce(
    context,
    title: '$name’s URL',
    body: 'Copy it now: it won’t be shown again. Anyone with it can post as $name.',
    secret: url,
    copyLabel: 'Copy URL',
    also: (
      label: 'Copy GitHub URL',
      secret: '$url/github',
      note: 'Paste it as a GitHub repository’s webhook: its pushes, issues and pull requests post here.',
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
      maxLength: 64,
      choices: {for (final r in rooms) r.id: '#${r.name}'},
      choice: rooms.first.id,
    );
    if (got == null || !mounted) return;
    try {
      final url = await repository.createWebhook(widget.spaceId, got.$2 ?? rooms.first.id, got.$1);
      if (mounted) await _showOnce(got.$1, url);
    } catch (e) {
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t create the webhook');
    }
    if (mounted) _reload();
  }

  /// A picture for [w], cropped round as it shows by its messages.
  Future<void> _avatar(SpaceWebhook w) async {
    final path = await pickSpaceIcon();
    if (path == null || !mounted) return;
    final crop = await Navigator.of(context)
        .push<CropRect>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => CropPage(path: path, aspect: 1)));
    if (crop == null || !mounted) return;
    final repository = context.repository;
    await adminTry(context, 'Couldn’t change its picture', () async {
      final square = await saveSquareImage(path, crop, 256);
      try {
        await repository.updateWebhook(widget.spaceId, w, avatarPath: square);
      } finally {
        // Best effort: the list needn't wait for it.
        unawaited(File(square).delete().then((_) {}, onError: (Object e) => debugPrint('square image: $e')));
      }
    });
  }

  Future<void> _options(SpaceWebhook w) async {
    final picked = await showGlassSheet<String>(
      context,
      label: w.name,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          SheetTitle(title: w.name, caption: '#${w.roomName}'),
          GlassRow(icon: FLucideIcons.pencil, label: 'Rename', onPressed: () => Navigator.of(context).pop('rename')),
          GlassRow(
            icon: FLucideIcons.image,
            label: w.avatarUrl == null ? 'Add a picture' : 'Change picture',
            detail: 'Its past messages keep theirs',
            onPressed: () => Navigator.of(context).pop('avatar'),
          ),
          if (w.avatarUrl != null)
            GlassRow(
              icon: FLucideIcons.imageOff,
              label: 'Remove picture',
              onPressed: () => Navigator.of(context).pop('noavatar'),
            ),
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
      case 'rename':
        // The API takes 64 and fails past it.
        final got = await askName<void>(context, title: 'Rename ${w.name}', initial: w.name, maxLength: 64);
        if (got == null || got.$1.trim().isEmpty || !mounted) return;
        await adminTry(
          context,
          'Couldn’t rename it',
          () => repository.updateWebhook(widget.spaceId, w, name: got.$1.trim()),
        );
      case 'avatar':
        await _avatar(w);
      case 'noavatar':
        await adminTry(
          context,
          'Couldn’t remove its picture',
          () => repository.updateWebhook(widget.spaceId, w, removeAvatar: true),
        );
      case 'reset':
        try {
          final url = await repository.resetWebhook(widget.spaceId, w);
          if (mounted) await _showOnce(w.name, url);
        } catch (e) {
          if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t make a new URL');
        }
      case 'delete':
        final sure = await confirmDestructive(
          context,
          title: 'Delete ${w.name}?',
          body: 'Apps using it can’t post any more. Its messages stay.',
          action: 'Delete webhook',
        );
        if (!sure || !mounted) return;
        await adminTry(context, 'Couldn’t delete it', () => repository.deleteWebhook(widget.spaceId, w));
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
            LoadingSkeleton(label: 'Loading webhooks', children: placeholderRows(avatar: 48))
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

/// What the Space's files take and where they're kept: its buckets to add,
/// change and delete (ManageSpaceBuckets), and its files to delete
/// (ManageSpaceAttachments).
class SpaceStoragePage extends StatefulWidget {
  final String spaceId;
  const SpaceStoragePage({required this.spaceId, super.key});

  @override
  State<SpaceStoragePage> createState() => _SpaceStoragePageState();
}

class _SpaceStoragePageState extends State<SpaceStoragePage> {
  late Future<SpaceStorage> _storage = context.repository.spaceStorage(widget.spaceId);

  void _reload() => setState(() {
    _storage = context.repository.spaceStorage(widget.spaceId);
  });

  Future<void> _editBucket(Bucket? b) async {
    final repository = context.repository;
    final id = widget.spaceId;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BucketFormPage(
          bucket: b,
          onSave: (draft) =>
              b == null ? repository.createSpaceBucket(id, draft) : repository.updateSpaceBucket(id, b.id, draft),
        ),
      ),
    );
    if (saved == true && mounted) _reload();
  }

  Future<void> _bucketOptions(BuildContext anchor, Bucket b) async {
    final picked = await showGlassMenu<String>(
      anchor,
      label: b.name,
      items: [
        const GlassMenuItem(icon: FLucideIcons.pencil, label: 'Edit', value: 'edit'),
        b.active
            ? const GlassMenuItem(
                icon: FLucideIcons.pause,
                label: 'Deactivate',
                value: 'off',
                hint: 'Uploads go back to Duvet’s storage',
              )
            : const GlassMenuItem(
                icon: FLucideIcons.play,
                label: 'Activate',
                value: 'on',
                hint: 'The Space’s uploads go to it',
              ),
        const GlassMenuItem(icon: FLucideIcons.trash2, label: 'Delete', value: 'delete', destructive: true),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == 'edit') return _editBucket(b);
    final repository = context.repository;
    if (picked == 'delete') {
      final sure = await confirmDestructive(
        context,
        title: 'Delete ${b.name}?',
        body: 'Duvet forgets its keys. The bucket and what’s in it stay with its owner.',
        action: 'Delete bucket',
      );
      if (!sure || !mounted) return;
      // Refused while it holds files: the repository says how many.
      await adminTry(context, 'Couldn’t delete the bucket', () => repository.deleteSpaceBucket(widget.spaceId, b.id));
    } else {
      await adminTry(
        context,
        'Couldn’t change the bucket',
        () => repository.setSpaceBucketActive(widget.spaceId, b.id, picked == 'on'),
      );
    }
    if (mounted) _reload();
  }

  Future<void> _deleteFile(MyFile f) async {
    final sure = await confirmFileDelete(context, 'Delete ${f.name}?', body: 'This can’t be undone.');
    if (!sure || !mounted) return;
    await adminTry(context, 'Couldn’t delete the file', () => context.repository.deleteSpaceFile(widget.spaceId, f.id));
    if (mounted) _reload();
  }

  Future<void> _deleteAll(int n) async {
    // The API deletes every file, those posted in messages too: the confirm says so.
    final sure = await confirmFileDelete(
      context,
      'Delete all files?',
      body:
          'Delete all $n ${n == 1 ? 'file' : 'files'} in this Space, including ones posted in messages? '
          'This can’t be undone.',
      action: 'Delete all files',
    );
    if (!sure || !mounted) return;
    await adminTry(context, 'Couldn’t delete the files', () => context.repository.deleteAllSpaceFiles(widget.spaceId));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final profile = context.repository.spaceProfile(widget.spaceId);
    final manageBuckets = profile?.can(Perm.manageBuckets) ?? false;
    final manageFiles = profile?.can(Perm.manageAttachments) ?? false;
    return FutureBuilder(
      future: _storage,
      builder: (context, snapshot) {
        final s = snapshot.data;
        Widget usage(SpaceStorage s) => Container(
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
                Text(formatBytes(s.used), style: DuvetType.titleSans.copyWith(color: colors.foreground)),
                Text(
                  '${s.files.length} ${s.files.length == 1 ? 'file' : 'files'}',
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ],
            ),
          ),
        );
        return AdminPage(
          title: 'Storage',
          children: [
            if (snapshot.hasError)
              const ListNote('Couldn’t load the storage')
            else if (s == null)
              LoadingSkeleton(
                label: 'Loading the storage',
                children: [
                  usage(const SpaceStorage(used: 0)),
                  const Overline('Files'),
                  for (final f in placeholderFiles) FileRow(file: f),
                ],
              )
            else ...[
              usage(s),
              if (manageBuckets) ...[
                const Overline('Buckets'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(
                    'Connect an S3-compatible bucket. While one is active, the Space’s uploads go to it.',
                    style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                  ),
                ),
                for (final b in s.buckets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    // The menu opens under the meter it's for.
                    child: Builder(
                      builder: (anchor) => Semantics(
                        container: true,
                        button: true,
                        label: 'Options for ${b.name}',
                        onTap: () => _bucketOptions(anchor, b),
                        child: GestureDetector(
                          onTap: () => _bucketOptions(anchor, b),
                          child: BucketMeter(bucket: b.usage, title: b.active ? 'Active' : 'Off'),
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DuvetButton(
                    label: 'Add a bucket',
                    icon: FLucideIcons.plus,
                    onPressed: () => _editBucket(null),
                  ),
                ),
              ],
              // Largest first: those worth deleting.
              const Overline('Files'),
              if (s.files.isEmpty)
                const ListNote('No files yet')
              else ...[
                for (final f in s.files)
                  FileRow(
                    file: f,
                    // The API deletes a file in a message only with all of them.
                    note: f.inMessage ? 'In a message' : null,
                    onDelete: manageFiles && !f.inMessage ? () => _deleteFile(f) : null,
                  ),
                if (manageFiles) ...[
                  const SizedBox(height: 24),
                  DuvetButton(
                    label: 'Delete all files',
                    variant: ButtonVariant.destructive,
                    expand: true,
                    onPressed: () => _deleteAll(s.files.length),
                  ),
                ],
              ],
            ],
          ],
        );
      },
    );
  }
}

/// A bucket's settings, to add one or change it. [onSave] does the saving, so
/// the user's own buckets can use the form too.
class BucketFormPage extends StatefulWidget {
  /// The one to change, or null to add one.
  final Bucket? bucket;
  final Future<void> Function(BucketDraft draft) onSave;
  const BucketFormPage({required this.onSave, this.bucket, super.key});

  @override
  State<BucketFormPage> createState() => _BucketFormPageState();
}

class _BucketFormPageState extends State<BucketFormPage> {
  // Every field but the secret starts as the bucket has it: the API takes
  // them all on an edit, and a blank limit would remove it.
  late final Bucket? _b = widget.bucket;
  late final _name = TextEditingController(text: _b?.name);
  late final _region = TextEditingController(text: _b?.region);
  late final _endpoint = TextEditingController(text: _b?.endpoint);
  late final _bucketName = TextEditingController(text: _b?.bucketName);
  late final _accessKey = TextEditingController(text: _b?.accessKey);
  final _secret = TextEditingController();
  late final _max = TextEditingController(text: _mb(_b?.max));
  late final _uploadLimit = TextEditingController(text: _mb(_b?.uploadLimit));
  late bool _pathStyle = _b?.pathStyle ?? false;
  late final List<TextEditingController> _fields = [
    _name,
    _region,
    _endpoint,
    _bucketName,
    _accessKey,
    _secret,
    _max,
    _uploadLimit,
  ];
  late final Map<TextEditingController, String> _initial = {for (final c in _fields) c: c.text};
  bool _saving = false;

  static const _mib = 1024 * 1024;

  /// Whole MB when it is, so an unchanged limit saves the same bytes.
  static String _mb(int? bytes) => bytes == null ? '' : (bytes % _mib == 0 ? '${bytes ~/ _mib}' : '${bytes / _mib}');

  /// What a limit field means: none when empty, else its bytes; not [ok]
  /// when it isn't a number above 0.
  static ({bool ok, int? bytes}) _limit(String text, int? was) {
    final t = text.trim();
    if (t.isEmpty) return (ok: true, bytes: null);
    if (t == _mb(was)) return (ok: true, bytes: was);
    final mb = double.tryParse(t);
    return mb == null || mb <= 0 ? (ok: false, bytes: null) : (ok: true, bytes: (mb * _mib).round());
  }

  @override
  void initState() {
    super.initState();
    // Reading [_initial] here keeps the texts the page opened with.
    for (final c in _initial.keys) {
      c.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(BucketDraft draft) async {
    if (_b == null) {
      final sure = await confirmDestructive(
        context,
        title: 'Add this bucket?',
        body:
            'Only use keys you own and control. Whoever owns the bucket can read, change or delete every file '
            'kept in it, and cut off access at any time.',
        action: 'Yes, add bucket',
        destructive: false,
      );
      if (!sure || !mounted) return;
    }
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await adminTry(context, 'Couldn’t save the bucket', () => widget.onSave(draft));
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final max = _limit(_max.text, _b?.max);
    final uploadLimit = _limit(_uploadLimit.text, _b?.uploadLimit);
    final draft = (
      name: _name.text.trim(),
      region: _region.text.trim(),
      endpoint: _endpoint.text.trim(),
      bucketName: _bucketName.text.trim(),
      accessKey: _accessKey.text.trim(),
      secret: _secret.text,
      pathStyle: _pathStyle,
      max: max.bytes,
      uploadLimit: uploadLimit.bytes,
    );
    final dirty = _pathStyle != (_b?.pathStyle ?? false) || _initial.entries.any((e) => e.key.text != e.value);
    final complete =
        draft.name.isNotEmpty &&
        draft.endpoint.isNotEmpty &&
        draft.bucketName.isNotEmpty &&
        draft.accessKey.isNotEmpty &&
        // A new bucket needs its secret; an edit keeps the stored one when it's empty.
        (_b != null || draft.secret.trim().isNotEmpty) &&
        max.ok &&
        uploadLimit.ok;
    const gap = SizedBox(height: 16);
    return UnsavedChanges(
      dirty: dirty,
      child: AdminPage(
        title: _b == null ? 'Add a bucket' : 'Edit bucket',
        actions: [TextAction(label: 'Save', onPressed: _saving || !dirty || !complete ? null : () => _save(draft))],
        children: [
          const Overline('Bucket'),
          DuvetTextField(label: 'Name', controller: _name, hint: 'My R2', textInputAction: TextInputAction.next),
          gap,
          DuvetTextField(label: 'Region', controller: _region, hint: 'auto', textInputAction: TextInputAction.next),
          gap,
          DuvetTextField(
            label: 'Endpoint',
            controller: _endpoint,
            hint: 'https://account-id.r2.cloudflarestorage.com',
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
          ),
          gap,
          DuvetTextField(
            label: 'Bucket name',
            controller: _bucketName,
            hint: 'my-bucket',
            textInputAction: TextInputAction.next,
          ),
          const Overline('Keys'),
          DuvetTextField(label: 'Access key ID', controller: _accessKey, textInputAction: TextInputAction.next),
          gap,
          DuvetTextField(
            label: 'Secret access key',
            controller: _secret,
            obscure: true,
            helper: _b == null ? null : 'Leave it empty to keep the current one',
          ),
          gap,
          AdminPanel(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Path-style addressing', style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                          Text(
                            'Needed for MinIO, RustFS and the like',
                            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    DuvetSwitch(
                      label: 'Path-style addressing',
                      value: _pathStyle,
                      onChanged: (on) => setState(() => _pathStyle = on),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Overline('Limits'),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DuvetTextField(
                  label: 'Total (MB)',
                  controller: _max,
                  hint: 'No limit',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  error: max.ok ? null : 'A number above 0',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DuvetTextField(
                  label: 'Per file (MB)',
                  controller: _uploadLimit,
                  hint: 'No limit',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  error: uploadLimit.ok ? null : 'A number above 0',
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              'Leave them empty for no limit. With a total limit, the oldest files make room when it’s full.',
              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
            ),
          ),
        ],
      ),
    );
  }
}
