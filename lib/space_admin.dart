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

import 'account.dart' show CropPage, formatBytes;
import 'data/models.dart';
import 'data/scope.dart';
import 'people.dart' show PersonRow;
import 'spaces.dart' show deleteSpace, inviteRoomOf, pickSpaceIcon, showInviteSheet;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/depth.dart' show Cushion, InsetShadow, Pressable;
import 'widgets/glass.dart';
import 'widgets/rows.dart';
import 'widgets/scrolling.dart' show CarouselPhysics;

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

/// Picks a Space's icon and crops it square, as the desktop does; answers the
/// cropped picture's path, or null when the user backs out.
Future<String?> chooseSpaceIcon(BuildContext context) async {
  final path = await pickSpaceIcon();
  if (path == null || !context.mounted) return null;
  final crop = await Navigator.of(context).push<CropRect>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => CropPage(path: path, aspect: 1, round: false)),
  );
  if (crop == null || !context.mounted) return null;
  try {
    return await saveSquareImage(path, crop, avatarSide);
  } catch (e) {
    debugPrint('icon: $e');
    if (context.mounted) _toast(context, 'Couldn’t read this picture');
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
    return ValueListenableBuilder(
      valueListenable: repository.spaces,
      builder: (context, spaces, _) {
        final space = spaces.where((s) => s.id == widget.spaceId).firstOrNull;
        final profile = repository.spaceProfile(widget.spaceId);
        if (space == null || profile == null) {
          return const AdminPage(
            title: 'Space settings',
            placeholder: EmptyState(icon: FLucideIcons.layoutGrid, text: 'This Space is gone'),
          );
        }
        final id = space.id;
        final rooms = repository.adminRooms(id).where((r) => r.kind != AdminRoomKind.category).length;
        final roles = repository.roles(id).length;
        Widget row(IconData icon, String label, String? detail, Widget page) =>
            GlassRow(leading: AdminMark(icon), label: label, detail: detail, onPressed: () => _open(page));
        final groups = <(String, List<Widget>)>[
          (
            'Space',
            [
              if (profile.can(Perm.administrator))
                row(FLucideIcons.squarePen, 'Overview', 'Name, icon, banner', SpaceOverviewPage(spaceId: id)),
              // ManageChannels in the Space makes rooms; in a room, runs it.
              if (profile.can(Perm.manageChannels) || profile.managesRooms)
                row(FLucideIcons.hash, 'Rooms', '$rooms', RoomsAdminPage(spaceId: id)),
              // Any member's to see; changed by those who manage them.
              row(
                FLucideIcons.smile,
                'Emojis and stickers',
                _assets == null ? null : '${_assets!.$1} · ${_assets!.$2}',
                AssetsPage(spaceId: id),
              ),
            ],
          ),
          (
            'People',
            [
              if (profile.can(Perm.manageRoles)) row(FLucideIcons.shield, 'Roles', '$roles', RolesPage(spaceId: id)),
              if (profile.can(Perm.manageInvites))
                row(
                  FLucideIcons.link,
                  'Invites',
                  _invites == null ? null : '$_invites active',
                  InvitesAdminPage(spaceId: id),
                ),
            ],
          ),
          (
            'Integrations',
            [
              if (profile.can(Perm.manageWebhooks))
                row(
                  FLucideIcons.webhook,
                  'Webhooks',
                  _webhooks == null ? null : '$_webhooks',
                  WebhooksPage(spaceId: id),
                ),
              if (profile.can(Perm.manageAttachments) || profile.can(Perm.manageBuckets))
                row(
                  FLucideIcons.database,
                  'Storage',
                  _storage == null ? null : '${formatBytes(_storage!)} used',
                  SpaceStoragePage(spaceId: id),
                ),
            ],
          ),
        ];
        return AdminPage(
          title: 'Space settings',
          backLabel: 'Back to ${space.name}',
          children: [
            // The Space as it opens: its banner, its icon and name.
            SpaceFace(
              space: space,
              bannerUrl: space.bannerUrl,
              caption:
                  '${profile.memberCount} ${profile.memberCount == 1 ? 'member' : 'members'} · ${profile.standing}',
            ),
            for (final (name, rows) in groups)
              if (rows.isNotEmpty) ...[Overline(name), AdminPanel(children: rows)],
            if (profile.owner)
              AdminApart(
                icon: FLucideIcons.trash2,
                label: 'Delete Space',
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  if (await deleteSpace(context, space)) navigator.popUntil((r) => r.isFirst);
                },
              ),
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

  /// In place of any list: what the page says when it has nothing to list
  /// or couldn't load it, centered between the bars ([EmptyState]).
  final Widget? placeholder;
  final Widget? bottom;
  const AdminPage({
    required this.title,
    this.children = const [],
    this.list,
    this.placeholder,
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
            child: placeholder != null
                ? Padding(padding: clear, child: placeholder)
                : list?.call(clear) ?? ListView(padding: clear, children: children),
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

/// Rows on one cushion, a group of settings as the You tab has them.
class AdminPanel extends StatelessWidget {
  final List<Widget> children;
  const AdminPanel({required this.children, super.key});

  @override
  Widget build(BuildContext context) => Cushion(
    padding: const EdgeInsets.all(4),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

/// A settings row's mark: its glyph on a small square sunk into the
/// cushion, as a room's is (only people are round), in [color] when it isn't
/// ink. At night it sinks to the ground's own shade rather than a hole.
/// Decoration: the row says what it is.
class AdminMark extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final double size;
  const AdminMark(this.icon, {this.color, this.size = 36, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusChip));
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark ? colors.background : colors.secondary,
            borderRadius: radius,
          ),
          child: InsetShadow(
            shadows: context.duvet.shadowWell,
            borderRadius: radius,
            child: Icon(icon, size: size * 0.5, color: color ?? colors.foreground),
          ),
        ),
      ),
    );
  }
}

/// What can't be undone, set apart under the rest: on a cushion of its own,
/// in the danger color, as a message's Delete is under its other actions.
class AdminApart extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback onPressed;
  const AdminApart({required this.icon, required this.label, required this.onPressed, this.detail, super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32),
    child: AdminPanel(
      children: [
        GlassRow(
          leading: AdminMark(icon, color: context.theme.colors.destructive),
          label: label,
          detail: detail,
          destructive: true,
          onPressed: onPressed,
        ),
      ],
    ),
  );
}

/// A Space's face, as the Space opens on it and its card shows it: its
/// banner ([bannerUrl], none without) over its icon, name and [caption].
/// [iconFile] and [bannerFile] show pictures chosen and not saved yet.
/// Screen readers get the name and caption; the pictures are decoration.
class SpaceFace extends StatelessWidget {
  final Space space;
  final String? name;
  final String? caption;
  final String? iconFile;
  final String? bannerFile;
  final String? bannerUrl;
  const SpaceFace({
    required this.space,
    required this.bannerUrl,
    this.name,
    this.caption,
    this.iconFile,
    this.bannerFile,
    super.key,
  });

  static const _icon = 64.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const banner = BorderRadius.all(Radius.circular(DuvetTokens.radiusRow));
    const square = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    // Under the picture while it loads, or where it can't: the mascot's slate.
    Widget framed(Widget picture) => AspectRatio(
      aspectRatio: bannerAspect,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Duvet.slate, borderRadius: banner),
        child: ClipRRect(borderRadius: banner, child: picture),
      ),
    );
    return Cushion(
      shadows: context.duvet.shadowRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (bannerFile case final path?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: ExcludeSemantics(
                child: framed(
                  Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                ),
              ),
            )
          else if (bannerUrl case final url?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: framed(SpaceBanner(key: ValueKey(url), url: url)),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (iconFile case final path?)
                  ExcludeSemantics(
                    child: ClipRRect(
                      borderRadius: square,
                      child: Image.file(
                        File(path),
                        width: _icon,
                        height: _icon,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => SpaceIcon(space: space, size: _icon),
                      ),
                    ),
                  )
                else
                  SpaceIcon(space: space, size: _icon),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name ?? space.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: DuvetType.title.copyWith(color: colors.foreground),
                      ),
                      if (caption case final caption?) ...[
                        const SizedBox(height: 4),
                        Text(caption, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
            _SheetHeading(title),
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
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetHeading(widget.title),
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
          const SizedBox(height: 24),
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
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetHeading(widget.title),
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
        const SizedBox(height: 24),
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

/// A dialog sheet's title, as the app's other dialog sheets set theirs.
class _SheetHeading extends StatelessWidget {
  final String text;
  const _SheetHeading(this.text);

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
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

  /// The new banner, cropped; or [_removeBanner] to take the one there away.
  String? _banner;
  bool _removeBanner = false;
  bool _saving = false;
  final _upload = ValueNotifier<double?>(null);

  Future<void> _pickBanner() async {
    final path = await pickSpaceImage();
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
      if (mounted) _toast(context, 'Couldn’t read this picture');
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
    _upload.dispose();
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
        removeBanner: _removeBanner,
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
    // Its face from the Space list; from what settings know of it otherwise.
    final space =
        context.repository.spaces.value.where((s) => s.id == widget.spaceId).firstOrNull ??
        (p == null ? null : Space(id: p.id, name: p.name, iconUrl: p.iconUrl, bannerUrl: p.bannerUrl));
    Widget picked(IconData icon, String label, String? path, VoidCallback onTap, {bool has = false}) => GlassRow(
      leading: AdminMark(icon),
      label: label,
      detail: path != null
          ? 'New one chosen'
          : has
          ? 'Change'
          : 'Choose',
      onPressed: onTap,
    );
    // What the banner will be once saved: the new one, none, or as it is.
    final bannerNow = _removeBanner ? null : p?.bannerUrl;
    final hasBanner = _banner != null || bannerNow != null;
    return AdminPage(
      title: 'Overview',
      actions: [TextAction(label: 'Save', onPressed: _saving || p == null ? null : _save)],
      placeholder: p == null ? const EmptyState(icon: FLucideIcons.layoutGrid, text: 'This Space is gone') : null,
      children: [
        if (p != null && space != null) ...[
          // The Space as everyone will see it once saved, its name as typed.
          ListenableBuilder(
            listenable: _name,
            builder: (context, _) => SpaceFace(
              space: space,
              name: _name.text.trim().isEmpty ? p.name : _name.text.trim(),
              caption: '${p.memberCount} ${p.memberCount == 1 ? 'member' : 'members'} · ${p.standing}',
              iconFile: _icon,
              bannerFile: _banner,
              bannerUrl: bannerNow,
            ),
          ),
          const SizedBox(height: 24),
          DuvetTextField(label: 'Name', controller: _name),
          const SizedBox(height: 16),
          DuvetTextField(label: 'What it’s about', controller: _about, maxLines: 3),
          const Overline('Pictures'),
          AdminPanel(
            children: [
              picked(FLucideIcons.squareDashed, 'Icon', _icon, () async {
                final path = await chooseSpaceIcon(context);
                if (path != null && mounted) setState(() => _icon = path);
              }),
              picked(FLucideIcons.image, 'Banner', _banner, _pickBanner, has: hasBanner),
              if (hasBanner)
                GlassRow(
                  leading: AdminMark(FLucideIcons.trash2, color: colors.destructive),
                  label: 'Remove banner',
                  destructive: true,
                  onPressed: () => setState(() {
                    _banner = null;
                    _removeBanner = p.bannerUrl != null;
                  }),
                ),
            ],
          ),
          UploadNote(_upload),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Everyone in the Space sees the change.',
              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
            ),
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
          // What can't be undone, apart under the rest.
          const SheetRule(),
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
      case 'describe':
        final got = await askDescription(context, title: 'What $label is for', initial: room.description ?? '');
        if (got == null || !mounted) return;
        await _try(
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
    // The grip at the row's end: drag it to move the row, in the list it's
    // nearest to.
    Widget grip(int index) => DragEdge(index: index);
    // A plain row on its panel, with its grip to drag by when it may move.
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
    Widget panel(Widget child, {Key? key}) => Cushion(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shadows: tokens.shadowRaised,
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
                    c.name,
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
      placeholder: all.isEmpty ? const EmptyState(text: 'No rooms yet') : null,
      list: (padding) => Listener(
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
    await _try(
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
        !await _try(
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
          if (t.type == 1) ...[
            UserAvatar(name: t.name, url: t.avatarUrl, size: 24),
            const SizedBox(width: 8),
          ] else ...[
            RoleDot(colors: t.colors!),
            const SizedBox(width: 10),
          ],
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
            for (final (i, (group, perms)) in _groups.indexed) ...[
              if (i > 0)
                Container(height: 1, margin: const EdgeInsets.fromLTRB(12, 10, 12, 0), color: context.duvet.hairline),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                child: Semantics(
                  header: true,
                  child: Text(group, style: DuvetType.overline.copyWith(color: colors.mutedForeground)),
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
                      PermissionChoice(
                        label: p.label,
                        value: overwrite.stateOf(p.bit),
                        neutral: t.type == 1 ? 'Their roles' : 'Role default',
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
                        leading: t.type == 1
                            ? UserAvatar(name: t.name, url: t.avatarUrl, size: 18)
                            : t.colors!.from == null
                            ? null
                            : RoleDot(colors: t.colors!, size: 10),
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

/// A room permission's three states side by side in a recess: denied, as
/// the roles say ([neutral]), or allowed. The one chosen stands out: a deny
/// in the danger color, an allow in the accent (tinted and outlined, as a
/// selection is), the roles' say raised plain. Deny and Allow carry a mark,
/// so the state never rests on color alone. Each choice's text is its label.
class PermissionChoice extends StatelessWidget {
  final String label;
  final bool? value;
  final String neutral;
  final ValueChanged<bool?> onChanged;
  const PermissionChoice({
    required this.label,
    required this.value,
    required this.neutral,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final reduce = MediaQuery.disableAnimationsOf(context);
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    const inner = BorderRadius.all(Radius.circular(DuvetTokens.radiusField - 2));
    // The chosen one, raised from the recess: at night a step lighter than
    // the card it's on, or it would barely stand up.
    final raised = Theme.of(context).brightness == Brightness.dark
        ? Color.alphaBlend(colors.foreground.withValues(alpha: 0.06), colors.card)
        : colors.card;
    final options = <(bool?, String, IconData?, Color)>[
      (false, 'Deny', FLucideIcons.x, colors.destructive),
      (null, neutral, null, colors.foreground),
      (true, 'Allow', FLucideIcons.check, tokens.accentText),
    ];
    return Semantics(
      container: true,
      label: label,
      explicitChildNodes: true,
      child: Container(
        // 44 inside the recess: each choice a full tap target.
        height: 48,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
        child: InsetShadow(
          shadows: tokens.shadowWell,
          borderRadius: radius,
          child: Row(
            children: [
              for (final (state, text, icon, ink) in options)
                Expanded(
                  child: Semantics(
                    container: true,
                    button: true,
                    inMutuallyExclusiveGroup: true,
                    checked: state == value,
                    label: text,
                    excludeSemantics: true,
                    onTap: () => onChanged(state),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onChanged(state);
                      },
                      child: AnimatedContainer(
                        duration: reduce ? Duration.zero : DuvetTokens.pressOut,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: state != value
                              ? null
                              : state == null
                              ? raised
                              : Color.alphaBlend(ink.withValues(alpha: 0.14), raised),
                          borderRadius: inner,
                          border: state == value && state != null
                              ? Border.all(color: ink.withValues(alpha: 0.7), width: 1.5)
                              : null,
                          boxShadow: state == value ? tokens.shadowRest : null,
                        ),
                        // One line, shrunk to fit at large text sizes rather than cut.
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (icon != null) ...[
                                  Icon(icon, size: 16, color: state == value ? ink : colors.mutedForeground),
                                  const SizedBox(width: 4),
                                ],
                                Text(
                                  text,
                                  maxLines: 1,
                                  style: DuvetType.label.copyWith(
                                    fontSize: 15,
                                    fontWeight: state == value ? FontWeight.w700 : FontWeight.w500,
                                    color: state == value ? ink : colors.mutedForeground,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
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
            const EmptyState(asleep: true, text: 'Couldn’t load the members. Close this and try again.')
          else if (!snapshot.hasData)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: FCircularProgress()),
            )
          else if (offered.isEmpty)
            // Nothing to search for is the pillow's to say; a search that
            // finds no one, a line.
            query.isEmpty
                ? const EmptyState(text: 'Everyone has theirs already')
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No one by that name',
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

/// A role's name color, readable on this theme's background.
Color? roleColorOn(BuildContext context, int? rgb) =>
    rgb == null ? null : readableOn(Color(0xFF000000 | rgb), context.theme.colors.background);

/// A reorderable row's grip at its end, on the row's own ground: drag it to
/// move the row. Dots, not lines, so it doesn't read as a menu.
class DragEdge extends StatelessWidget {
  final int index;
  const DragEdge({required this.index, super.key});

  @override
  Widget build(BuildContext context) => ReorderableDragStartListener(
    index: index,
    child: ExcludeSemantics(
      child: SizedBox(
        width: 44,
        child: Icon(FLucideIcons.gripVertical, size: 18, color: context.theme.colors.mutedForeground),
      ),
    ),
  );
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

/// A role's name as members see it: in its color, or across its gradient
/// left to right, each stop made readable on this theme's background; the
/// default ink without one. Sized to the name, so a gradient spans the name.
class RoleName extends StatelessWidget {
  final String name;
  final RoleColors colors;
  final TextStyle style;
  const RoleName(this.name, {required this.colors, required this.style, super.key});

  @override
  Widget build(BuildContext context) {
    final ink = context.theme.colors.foreground;
    // A gradient only with both ends, as the desktop reads one; the text is
    // white only under the mask that colors it.
    final gradient = colors.from != null && colors.to != null;
    final stops = [colors.from, colors.via, colors.to].nonNulls.map((c) => roleColorOn(context, c)!).toList();
    final text = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(
        color: gradient ? const Color(0xFFFFFFFF) : (colors.from == null ? ink : roleColorOn(context, colors.from)),
      ),
    );
    if (!gradient) return text;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(colors: stops).createShader(bounds),
      child: text,
    );
  }
}

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
  String hex(int rgb) => '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  if (c.from == null) return 'default';
  if (c.to == null) return hex(c.from!);
  return 'gradient, ${[c.from, c.via, c.to].nonNulls.map(hex).join(' to ')}';
}

/// A role's colors on a small rounded swatch, left to right: the picker's
/// own preview, and [RoleDot]'s mark beside a role's name; never a fill
/// behind it. The default ink without one.
class RoleSwatch extends StatelessWidget {
  final RoleColors colors;
  final double width;
  final double height;
  final double radius;
  const RoleSwatch({required this.colors, this.width = 20, this.height = 20, this.radius = 6, super.key});

  @override
  Widget build(BuildContext context) {
    final stops = [colors.from, colors.via, colors.to].nonNulls.map((c) => roleColorOn(context, c)!).toList();
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: stops.isEmpty ? context.theme.colors.foreground : stops.first,
        gradient: colors.from != null && colors.to != null ? LinearGradient(colors: stops) : null,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// A role's color beside its name, where roles are listed: a small rounded
/// square, solid or across its gradient; a faint ink one for the default
/// ink, so a role without a color still lines up with the rest. A mark,
/// never a fill behind the name. Decoration: the name says whose it is.
class RoleDot extends StatelessWidget {
  final RoleColors colors;
  final double size;
  const RoleDot({required this.colors, this.size = 14, super.key});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.3);
    if (colors.from == null) {
      return SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(color: context.duvet.grabber, borderRadius: radius),
        ),
      );
    }
    return ExcludeSemantics(
      child: RoleSwatch(colors: colors, width: size, height: size, radius: size * 0.3),
    );
  }
}

enum _ColorKind { none, solid, gradient }

enum _Stop { start, middle, end }

/// The name's color: none, one of the swatches, or a gradient across two or
/// three of them, previewed on the name as members will see it. A color set
/// on the desktop outside the swatches stays offered. Answers on Done.
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

  // The swatches, and any color the role has beyond them.
  late final _swatches = [
    ...roleSwatches,
    for (final c in [widget.initial.from, widget.initial.via, widget.initial.to].nonNulls)
      if (!roleSwatches.contains(c)) c,
  ];

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
    HapticFeedback.selectionClick();
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
    final accent = context.duvet.accentText;
    // The middle stop alone may be left out.
    final none = _kind == _ColorKind.gradient && _stop == _Stop.middle;
    return ListView(
      controller: widget.scroll,
      padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        const SheetTitle(title: 'Name color', caption: 'Names only, never fills'),
        // The name as members will see it, sunk into the sheet as the
        // screen's ground is.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            ),
            child: InsetShadow(
              shadows: context.duvet.shadowWell,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                alignment: Alignment.center,
                child: Semantics(
                  label: 'Preview: ${widget.name}, ${describeRoleColors(_c)}',
                  excludeSemantics: true,
                  child: RoleName(widget.name, colors: _c, style: DuvetType.title),
                ),
              ),
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
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final rgb in [if (none) null, ..._swatches])
                  Semantics(
                    container: true,
                    button: true,
                    selected: _current == rgb,
                    label: rgb == null ? 'No middle' : describeRoleColors((from: rgb, via: null, to: null)),
                    excludeSemantics: true,
                    onTap: () => _pick(rgb),
                    child: GestureDetector(
                      onTap: () => _pick(rgb),
                      child: AnimatedContainer(
                        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : DuvetTokens.pressOut,
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: rgb == null ? colors.secondary : roleColorOn(context, rgb),
                          borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                          border: _current == rgb ? Border.all(color: accent, width: 3) : null,
                        ),
                        child: rgb == null
                            ? Icon(FLucideIcons.ban, size: 18, color: colors.mutedForeground)
                            : _current == rgb
                            // Chosen: a check too, in what reads on the swatch.
                            ? Icon(
                                FLucideIcons.check,
                                size: 20,
                                color: roleColorOn(context, rgb)!.computeLuminance() > 0.4 ? Duvet.night : Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
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
      if (mounted) _toast(context, e is ActionFailed ? e.message : 'Couldn’t create the role');
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
  bool _below(int position) {
    final repository = context.repository;
    final profile = repository.spaceProfile(widget.spaceId);
    if (profile == null) return false;
    if (profile.owner) return true;
    if (!profile.can(Perm.manageRoles)) return false;
    final me = repository.profile.value?.id;
    final highest = me == null ? 0 : repository.rolesOf(widget.spaceId, me).firstOrNull?.position ?? 0;
    return position < highest;
  }

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
      _toast(context, 'Roles can only go below your highest role');
      return;
    }
    HapticFeedback.selectionClick();
    // The API clamps a position to the number of roles less one: one in a
    // gap past that can't be sent, so the user's roles are laid out again.
    if (position > context.repository.roles(widget.spaceId).length - 1) {
      return _arrange(([...others]..insert(to, moved)).where(_manages).toList());
    }
    setState(() => _sorting = true);
    await _try(
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
      final ok = await _try(
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
      body:
          'Roles with Administrator go to the top, then those that manage part of the Space. The rest keep their order below them. Everyone sees the new order.',
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

    // The grip at the row's end, as the rooms' is.
    Widget grip(int index) => DragEdge(index: index);
    // Above the user's highest role: theirs to see, not to move or change.
    Widget locked() => ExcludeSemantics(
      child: SizedBox(width: 32, child: Icon(FLucideIcons.lock, size: 14, color: colors.mutedForeground)),
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
            child: Row(
              children: [
                RoleDot(colors: r.colors),
                const SizedBox(width: 14),
                Expanded(
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
              ],
            ),
          ),
        ),
      );
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: body),
            if (moves) grip(index) else if (!r.everyone) locked(),
          ],
        ),
      );
    }

    Widget panel(Widget child) => Cushion(clipBehavior: Clip.antiAlias, shadows: tokens.shadowRaised, child: child);

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
              _sorting ? 'Reordering…' : 'Higher roles outrank those below them. Drag a role by its dots to move it.',
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
  late final _name = TextEditingController(text: widget.role.name);
  late RoleColors _colors = widget.role.colors;
  late int _perms = widget.role.perms;
  late bool _hoisted = widget.role.hoisted;
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
        colors: _colors != r.colors ? _colors : null,
        perms: _perms != r.perms ? _perms : null,
        hoisted: _hoisted != r.hoisted ? _hoisted : null,
      ),
    );
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
          final holders = repository.roleMembers(widget.spaceId, widget.role.id).toSet();
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
                  onTap: () => _toggle(m, !holders.contains(m.userId), setSheet),
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
    final tokens = context.duvet;
    // A setting with its switch: its mark, what it does, then the switch.
    Widget toggle(String label, String description, bool value, ValueChanged<bool>? onChanged, {IconData? icon}) =>
        Semantics(
          container: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (icon != null) ...[AdminMark(icon), const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                      Text(description, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                DuvetSwitch(label: label, value: value, onChanged: onChanged),
              ],
            ),
          ),
        );
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
          // The name's color, on a cushion that sinks when pressed.
          Semantics(
            container: true,
            button: true,
            label: 'Name color: ${describeRoleColors(_colors)}',
            excludeSemantics: true,
            onTap: _pickColor,
            child: Pressable(
              onTap: _pickColor,
              builder: (context, pressed) => AnimatedContainer(
                duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
                width: 96,
                height: 48,
                decoration: BoxDecoration(
                  color: colors.card,
                  borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                  boxShadow: pressed ? null : tokens.shadowRest,
                ),
                child: InsetShadow(
                  shadows: pressed ? tokens.shadowPressed : tokens.cushion,
                  borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
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
            ),
          ),
        ],
      ),
      if (!r.everyone) ...[
        const SizedBox(height: 16),
        AdminPanel(
          children: [
            // A node of its own beside the switch's, or it would take the
            // whole panel's.
            Semantics(
              container: true,
              child: GlassRow(
                leading: const AdminMark(FLucideIcons.users),
                label: '${holders.length} ${holders.length == 1 ? 'member' : 'members'}',
                detail: 'Manage',
                onPressed: _members,
              ),
            ),
            // As the desktop's "Display role members separately".
            toggle(
              'Show members separately',
              'In the member list, those online show under this role’s name',
              _hoisted,
              (on) => setState(() => _hoisted = on),
              icon: FLucideIcons.layers,
            ),
          ],
        ),
      ],
      for (final (group, perms) in permissionGroups) ...[
        Overline(group),
        AdminPanel(
          children: [
            for (final p in perms)
              toggle(
                p.label,
                p.description,
                _perms & p.bit != 0 || (admin && p.bit != Perm.administrator),
                admin && p.bit != Perm.administrator
                    ? null
                    : (on) => setState(() => _perms = on ? _perms | p.bit : _perms & ~p.bit),
              ),
          ],
        ),
      ],
      if (!r.everyone && !widget.readOnly)
        AdminApart(icon: FLucideIcons.trash2, label: 'Delete role', onPressed: _delete),
    ];
    if (!widget.readOnly) {
      return AdminPage(
        title: 'Edit role',
        actions: [TextAction(label: 'Save', onPressed: _saving ? null : _save)],
        children: children,
      );
    }
    return AdminPage(
      title: r.name,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(FLucideIcons.lock, size: 14, color: colors.mutedForeground),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'It’s at or above your highest role, so only those above it change it.',
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ),
            ],
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
        placeholder: snapshot.hasError
            ? const EmptyState(asleep: true, text: 'Couldn’t load the invites')
            : invites == null
            ? const Center(child: FCircularProgress())
            : invites.isEmpty
            ? const EmptyState(text: 'No invite links')
            : null,
        children: [
          if (invites != null && invites.isNotEmpty)
            AdminPanel(
              children: [
                for (final i in invites)
                  ListRow(
                    leading: AdminMark(
                      FLucideIcons.link,
                      color: _until(i.expiresAt) == 'expired' ? context.theme.colors.mutedForeground : null,
                    ),
                    title: i.code,
                    snippet: '#${i.roomName} · ${i.createdBy} · ${_until(i.expiresAt)}',
                    detail: 'Double tap to revoke',
                    onTap: () => _revoke(i),
                  ),
              ],
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

    await _try(context, 'Couldn’t add the $_noun', () async {
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
          // What can't be undone, apart under the rest.
          const SheetRule(),
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
            Segmented<AssetKind>(
              label: 'Show',
              value: _kind,
              options: const {AssetKind.emoji: 'Emojis', AssetKind.sticker: 'Stickers'},
              onChanged: (k) {
                _kind = k;
                _reload();
              },
            ),
            UploadNote(_upload),
            if (!may)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Anyone here may use them. Those who manage ${_noun}s add and change them.',
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ),
            const SizedBox(height: 16),
            if (snapshot.hasError)
              const SizedBox(height: 320, child: EmptyState(asleep: true, text: 'Couldn’t load them'))
            else if (list == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: FCircularProgress()),
              )
            else if (list.isEmpty)
              SizedBox(height: 320, child: EmptyState(text: 'No ${_noun}s yet'))
            else
              // A cushion each, four emojis or two stickers a row.
              LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 12.0;
                  final across = _kind == AssetKind.emoji ? 4 : 2;
                  final width = (constraints.maxWidth - gap * (across - 1)) / across;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final a in list)
                        Semantics(
                          container: true,
                          button: may,
                          label: _kind == AssetKind.emoji ? ':${a.name}:' : a.name,
                          hint: may ? 'Double tap for options' : null,
                          excludeSemantics: true,
                          onTap: may ? () => _options(a) : null,
                          child: _AssetTile(
                            url: a.url,
                            name: a.name,
                            size: size,
                            width: width,
                            onTap: may ? () => _options(a) : null,
                          ),
                        ),
                    ],
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

/// An emoji or a sticker on a cushion of its own, its name under it;
/// pressing sinks it, where it may be changed.
class _AssetTile extends StatelessWidget {
  final String url;
  final String name;
  final double size;
  final double width;
  final VoidCallback? onTap;
  const _AssetTile({required this.url, required this.name, required this.size, required this.width, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusRow));
    return Pressable(
      onTap: onTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
        width: width,
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: radius,
          boxShadow: pressed ? null : tokens.shadowRest,
        ),
        child: InsetShadow(
          shadows: pressed ? tokens.shadowPressed : tokens.cushion,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
            child: Column(
              children: [
                Image.network(
                  url,
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => SizedBox.square(dimension: size),
                ),
                const SizedBox(height: 6),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ],
            ),
          ),
        ),
      ),
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
          _SheetHeading('$name’s URL'),
          const SizedBox(height: 12),
          Text(
            'Copy it now: it won’t be shown again. Anyone with it can post as $name.',
            style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground),
          ),
          const SizedBox(height: 16),
          // The secret, sunk in a recess.
          DecoratedBox(
            decoration: BoxDecoration(
              color: context.theme.colors.secondary,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            ),
            child: InsetShadow(
              shadows: context.duvet.shadowWell,
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(url, style: DuvetType.code.copyWith(color: context.theme.colors.foreground)),
              ),
            ),
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
      maxLength: 64,
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

  /// A picture for [w], cropped round as it shows by its messages.
  Future<void> _avatar(SpaceWebhook w) async {
    final path = await pickSpaceIcon();
    if (path == null || !mounted) return;
    final crop = await Navigator.of(
      context,
    ).push<CropRect>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => CropPage(path: path, aspect: 1)));
    if (crop == null || !mounted) return;
    final repository = context.repository;
    await _try(context, 'Couldn’t change its picture', () async {
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
          // What can't be undone, apart under the rest.
          const SheetRule(),
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
        await _try(
          context,
          'Couldn’t rename it',
          () => repository.updateWebhook(widget.spaceId, w, name: got.$1.trim()),
        );
      case 'avatar':
        await _avatar(w);
      case 'noavatar':
        await _try(
          context,
          'Couldn’t remove its picture',
          () => repository.updateWebhook(widget.spaceId, w, removeAvatar: true),
        );
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
        placeholder: snapshot.hasError
            ? const EmptyState(asleep: true, text: 'Couldn’t load the webhooks')
            : list == null
            ? const Center(child: FCircularProgress())
            : list.isEmpty
            ? const EmptyState(text: 'No webhooks. Make one to let another app post in a room.')
            : null,
        children: [
          if (list != null && list.isNotEmpty)
            AdminPanel(
              children: [
                for (final w in list)
                  ListRow(
                    // It posts as someone would: a face, round.
                    leading: ExcludeSemantics(
                      child: UserAvatar(name: w.name, url: w.avatarUrl, size: 48),
                    ),
                    title: w.name,
                    snippet: 'Posts in #${w.roomName}',
                    detail: 'Double tap for options',
                    onTap: () => _options(w),
                  ),
              ],
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
          placeholder: snapshot.hasError
              ? const EmptyState(asleep: true, text: 'Couldn’t load the storage')
              : s == null
              ? const Center(child: FCircularProgress())
              : null,
          children: [
            if (s != null) ...[
              Cushion(
                padding: const EdgeInsets.all(16),
                shadows: tokens.shadowRaised,
                child: Semantics(
                  label: '${formatBytes(s.used)} used by ${s.files.length} files',
                  excludeSemantics: true,
                  child: Row(
                    children: [
                      const AdminMark(FLucideIcons.database, size: 48),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(formatBytes(s.used), style: DuvetType.title.copyWith(color: colors.foreground)),
                            const SizedBox(height: 2),
                            Text(
                              '${s.files.length} ${s.files.length == 1 ? 'file' : 'files'}',
                              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (s.buckets.isNotEmpty) ...[
                const Overline('Kept in'),
                AdminPanel(children: [for (final b in s.buckets) _BucketRow(bucket: b)]),
              ],
              const Overline('Largest files'),
              if (s.files.isEmpty)
                const SizedBox(height: 240, child: EmptyState(text: 'No files yet'))
              else
                AdminPanel(
                  children: [
                    for (final f in s.files.take(20))
                      ListRow(
                        leading: AdminMark(switch (f.contentType.split('/').first) {
                          'image' => FLucideIcons.fileImage,
                          'audio' => FLucideIcons.fileAudio,
                          'video' => FLucideIcons.fileVideo,
                          _ => FLucideIcons.file,
                        }),
                        title: f.name,
                        snippet: '${formatBytes(f.size)} · ${shortTime(f.createdAt)}',
                      ),
                  ],
                ),
            ],
          ],
        );
      },
    );
  }
}

/// A bucket the Space's files are kept in: its name, what it holds (of how
/// much, and whether it's off), and with a size, a bar of it filled in ink,
/// as the You tab's storage is: never hues.
class _BucketRow extends StatelessWidget {
  final ({String name, int used, int? max, bool active}) bucket;
  const _BucketRow({required this.bucket});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final b = bucket;
    final max = b.max;
    final detail = [
      max == null ? '${formatBytes(b.used)} used' : '${formatBytes(b.used)} of ${formatBytes(max)}',
      if (!b.active) 'off',
    ].join(' · ');
    return Semantics(
      container: true,
      label: '${b.name}, $detail',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Row(
          children: [
            AdminMark(FLucideIcons.hardDrive, color: b.active ? null : colors.mutedForeground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    b.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DuvetType.rowTitle.copyWith(color: b.active ? colors.foreground : colors.mutedForeground),
                  ),
                  Text(detail, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                  if (max != null && max > 0) ...[
                    const SizedBox(height: 8),
                    Container(
                      height: 6,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: colors.secondary,
                        borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                      ),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: (b.used / max).clamp(0.0, 1.0),
                        heightFactor: 1,
                        child: ColoredBox(color: b.active ? colors.foreground : colors.mutedForeground),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
