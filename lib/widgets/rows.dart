import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../theme.dart';
import 'avatar.dart';
import 'depth.dart';

/// A two-line list row (ChatRow, ChannelRow): 72pt, no divider, a 48pt
/// leading avatar or Space icon, the name over a one-line snippet (or up to
/// [snippetLines]). With
/// neither a leading nor a snippet (a room nobody wrote in yet) it is one
/// 44pt line.
///
/// What has news is puffed up and what's read lies flat: an unread row sits on
/// a cushion, its name in weight and `ink`, never blue and never a dot.
/// Pressing sinks it; the selected row (the current channel in the Channel
/// Switcher) sits on the slate pill a chosen tab does.
class ListRow extends StatelessWidget {
  final Widget? leading;
  final String title;

  /// A `# ` before the title, in `ink-secondary`: a channel.
  final bool hash;

  /// After the title, in `ink-secondary`, e.g. "· Space name".
  final String? titleSuffix;
  final String? snippet;

  /// How many lines the snippet may take: two for what's new in Chats.
  final int snippetLines;

  /// Right-aligned on the first line, e.g. the time.
  final String? trailing;
  final bool unread;
  final bool selected;

  /// Read by screen readers after the row, e.g. "2 mentions".
  final String? detail;

  /// At the end of the snippet line: the unread mentions, as "@2". Weight
  /// and count only, never a blue dot.
  final int mentions;

  /// At the end of the snippet line, before the mentions: e.g. who's in a
  /// Space's voice rooms. A look only: [detail] says it.
  final Widget? accessory;

  /// Room kept clear at the row's end, inside its cushion, for a button laid
  /// over it: a missed call's Call back.
  final double endInset;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// A member's banner, faintly behind the row: see [memberBanner].
  final String? banner;
  final bool bannerOffline;

  /// The cushion an unread row sits on, where `card` wouldn't stand up from
  /// what's under it: a sheet's popover, at night.
  final Color? cushionColor;

  /// Whether screen readers meet the row as a node of its own. False gives
  /// its name and tap to the node around it instead: a reorderable list's
  /// item, which offers the moves, so the row and its moves are one stop.
  final bool ownNode;

  const ListRow({
    required this.title,
    this.leading,
    this.hash = false,
    this.titleSuffix,
    this.snippet,
    this.snippetLines = 1,
    this.trailing,
    this.unread = false,
    this.selected = false,
    this.detail,
    this.mentions = 0,
    this.accessory,
    this.endInset = 0,
    this.onTap,
    this.onLongPress,
    this.banner,
    this.bannerOffline = false,
    this.ownNode = true,
    this.cushionColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final detail = [if (mentions > 0) mentions == 1 ? '1 mention' : '$mentions mentions', ?this.detail].join(', ');
    // On the chosen pill, everything takes its ink; the quieter parts fade.
    final name = selected ? tokens.chosenText : colors.foreground;
    final secondary = selected ? tokens.chosenText.withValues(alpha: 0.72) : colors.mutedForeground;
    final compact = leading == null && snippet == null && mentions == 0 && accessory == null;
    final label = [
      '${hash ? '# ' : ''}$title${titleSuffix == null ? '' : ' $titleSuffix'}',
      if (unread) 'unread',
      if (detail.isNotEmpty) detail,
      ?snippet,
      ?trailing,
    ].join(', ');
    return Semantics(
      container: ownNode,
      button: onTap != null,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        scale: 1,
        builder: (context, pressed) => Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: unread ? 2 : 0),
          child: AnimatedContainer(
            duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
            constraints: BoxConstraints(minHeight: compact ? DuvetTokens.sizeRowCompact : DuvetTokens.sizeRow),
            decoration: BoxDecoration(
              color: pressed
                  ? colors.secondary
                  : selected
                  ? tokens.chosen
                  : unread
                  ? cushionColor ?? colors.card
                  : Colors.transparent,
              image: memberBanner(context, banner, offline: bannerOffline),
              borderRadius: BorderRadius.circular(DuvetTokens.radiusRow),
              boxShadow: (unread || selected) && !pressed ? tokens.shadowRest : null,
            ),
            child: InsetShadow(
              shadows: pressed
                  ? tokens.shadowPressed
                  : unread || selected
                  ? tokens.cushion
                  : const [],
              borderRadius: BorderRadius.circular(DuvetTokens.radiusRow),
              child: Padding(
                padding: EdgeInsets.fromLTRB(8, compact ? 10 : 12, 8 + endInset, compact ? 10 : 12),
                child: Row(
                  children: [
                    if (leading != null) ...[leading!, const SizedBox(width: 12)],
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      if (hash)
                                        TextSpan(
                                          text: '# ',
                                          style: TextStyle(color: secondary),
                                        ),
                                      TextSpan(text: title),
                                      if (titleSuffix != null)
                                        TextSpan(
                                          text: ' $titleSuffix',
                                          style: TextStyle(color: secondary, fontWeight: FontWeight.w400),
                                        ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: (unread || selected ? DuvetType.rowTitleUnread : DuvetType.rowTitle).copyWith(
                                    color: name,
                                  ),
                                ),
                              ),
                              if (trailing != null) ...[
                                const SizedBox(width: 8),
                                Text(trailing!, style: DuvetType.caption.copyWith(color: secondary)),
                              ],
                            ],
                          ),
                          if (snippet != null || mentions > 0 || accessory != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              // Beside a longer snippet, the mentions stay on its first line.
                              crossAxisAlignment: snippetLines > 1
                                  ? CrossAxisAlignment.start
                                  : CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Text(
                                    snippet ?? '',
                                    maxLines: snippetLines,
                                    overflow: TextOverflow.ellipsis,
                                    style: DuvetType.snippet.copyWith(
                                      color: unread && !selected ? colors.foreground : secondary,
                                    ),
                                  ),
                                ),
                                if (accessory case final accessory?) ...[const SizedBox(width: 8), accessory],
                                if (mentions > 0) ...[const SizedBox(width: 8), MentionCount(mentions)],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "@2": unread mentions, the one thing in a list that takes the accent: a
/// small cushion in it.
class MentionCount extends StatelessWidget {
  final int count;
  const MentionCount(this.count, {super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(11));
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.primary, borderRadius: radius),
      child: InsetShadow(
        shadows: context.duvet.cushionAccent,
        borderRadius: radius,
        child: Text(
          '@${count > 99 ? '99+' : count}',
          style: DuvetType.caption.copyWith(color: colors.primaryForeground, fontWeight: FontWeight.w700, height: 1),
        ),
      ),
    );
  }
}

/// A group header in a list: `overline` as written, `ink-secondary`, 24pt
/// above and 8pt below. Never sticky.
class Overline extends StatelessWidget {
  final String text;
  const Overline(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Semantics(
      header: true,
      child: Text(text, style: DuvetType.overline.copyWith(color: context.theme.colors.mutedForeground)),
    ),
  );
}

/// Keeps text to [max] code points, the unit a database's length counts:
/// an edit that would pass it is turned away whole, never cut mid-emoji.
class CodePointLimit extends TextInputFormatter {
  final int max;
  CodePointLimit(this.max);

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.text.runes.length <= max || newValue.text.runes.length <= oldValue.text.runes.length
      ? newValue
      : oldValue;
}

/// A category's header in a Space's rooms: as [Overline], and a tap folds
/// its rooms away or opens them. Folded with unread rooms, its name takes the
/// unread weight and ink, as a row's does.
class CategoryHeader extends StatelessWidget {
  final String name;
  final bool collapsed;
  final bool unread;
  final VoidCallback onToggle;
  const CategoryHeader({
    required this.name,
    required this.collapsed,
    required this.onToggle,
    this.unread = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final news = collapsed && unread;
    return Semantics(
      container: true,
      header: true,
      button: true,
      expanded: !collapsed,
      label: news ? '$name, unread rooms' : name,
      onTapHint: collapsed ? 'Expand' : 'Collapse',
      onTap: onToggle,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.overline.copyWith(
                    color: news ? colors.foreground : colors.mutedForeground,
                    fontWeight: news ? FontWeight.w700 : null,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: collapsed ? -0.25 : 0,
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : DuvetTokens.dropdownIn,
                curve: DuvetTokens.decelerate,
                child: Icon(
                  FLucideIcons.chevronDown,
                  size: 14,
                  color: news ? colors.foreground : colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A banner's frame, a Space's or a profile's, as the desktop crops one.
const bannerAspect = 5 / 2;

/// "Uploading · 42%" while [progress] (0 to 1) has a value, as a message's
/// upload says it; nothing otherwise.
class UploadNote extends StatelessWidget {
  final ValueListenable<double?> progress;
  const UploadNote(this.progress, {super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: progress,
    builder: (context, p, _) => p == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                'Uploading · ${(p * 100).round()}%',
                style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground),
              ),
            ),
          ),
  );
}

/// A category's rooms under its [CategoryHeader]: they slide and fade away
/// when it folds, and back out when it opens, in step with its chevron.
class CategoryFold extends StatefulWidget {
  final bool open;
  final Widget child;
  const CategoryFold({required this.open, required this.child, super.key});

  @override
  State<CategoryFold> createState() => _CategoryFoldState();
}

class _CategoryFoldState extends State<CategoryFold> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: DuvetTokens.dropdownIn,
    reverseDuration: DuvetTokens.panelOut,
    value: widget.open ? 1 : 0,
  )..addStatusListener((_) => setState(() {}));
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: DuvetTokens.decelerate,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(CategoryFold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = widget.open ? 1 : 0;
    } else if (widget.open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isDismissed) return const SizedBox.shrink();
    return SizeTransition(
      sizeFactor: _curve,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: _curve, child: widget.child),
    );
  }
}

/// A Space's banner, 5:2 as the desktop crops it, its corners `radius-card`.
/// Nothing at all when it can't be had; base-sunken while it comes.
class SpaceBanner extends StatelessWidget {
  final String url;
  const SpaceBanner({required this.url, super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = width / bannerAspect;
      return ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
          child: Image.network(
            url,
            width: width,
            height: height,
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
            fit: BoxFit.cover,
            frameBuilder: (context, child, frame, sync) => frame == null && !sync
                ? SizedBox(
                    width: width,
                    height: height,
                    child: ColoredBox(color: context.theme.colors.secondary),
                  )
                : child,
            errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
          ),
        ),
      );
    },
  );
}

/// A Space's icon: always a rounded square (circles are for people), its
/// image or a monogram on a slate cushion, the mascot's own color.
class SpaceIcon extends StatelessWidget {
  final Space space;
  final double size;
  const SpaceIcon({required this.space, this.size = 48, super.key});

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    final monogram = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Duvet.slate, borderRadius: radius),
        child: InsetShadow(
          shadows: DuvetTokens.dark.cushion,
          borderRadius: radius,
          child: Center(
            child: Text(
              space.name.isEmpty ? '' : space.name.characters.first.toUpperCase(),
              style: DuvetType.navTitle.copyWith(color: DuvetTokens.dark.receivedText, fontSize: size * 0.4),
            ),
          ),
        ),
      ),
    );
    final url = space.iconUrl;
    if (url == null) return ExcludeSemantics(child: monogram);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: radius,
        child: Image.network(
          url,
          width: size,
          height: size,
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          fit: BoxFit.cover,
          frameBuilder: (context, child, frame, sync) => frame == null && !sync ? monogram : child,
          errorBuilder: (context, error, stackTrace) => monogram,
        ),
      ),
    );
  }
}

/// Someone's face where only their name and picture matter: in a Space's
/// voice rooms, say.
typedef PersonFace = ({String name, String? avatarUrl});

/// What a Space has going on, as its card or row says it: who's in its voice
/// rooms, its unread mentions of the user, and whether any room has news.
typedef SpaceLife = ({bool unread, int mentions, List<PersonFace> inVoice});

/// A Space's card or row as screen readers hear it: "Design Guild, unread,
/// 2 mentions, 3 in voice, 12 online".
String spaceLabel(Space space, SpaceLife life) => [
  space.name,
  if (life.unread) 'unread',
  ?_mentionsText(life.mentions),
  if (life.inVoice.isNotEmpty) '${life.inVoice.length} in voice',
  if (space.onlineCount case final n?) '$n online',
].join(', ');

String? _mentionsText(int n) => n <= 0
    ? null
    : n == 1
    ? '1 mention'
    : '$n mentions';

/// A Launchpad tile: a raised cushion, `radius-card`, 160pt tall, the Space's
/// icon and who's in its voice rooms, its name (2 lines at most), its online
/// count and its mentions. What has news has its name in weight. Pressing
/// sinks it.
class SpaceCard extends StatelessWidget {
  final Space space;
  final bool unread;

  /// Unread mentions of the user in its rooms: a pill in the accent.
  final int mentions;

  /// Who's in its voice rooms: their faces, after an ice dot.
  final List<PersonFace> inVoice;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const SpaceCard({
    required this.space,
    required this.onTap,
    this.unread = false,
    this.mentions = 0,
    this.inVoice = const [],
    this.onLongPress,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final online = space.onlineCount == null ? null : '${space.onlineCount} online';
    return Semantics(
      button: true,
      label: spaceLabel(space, (unread: unread, mentions: mentions, inVoice: inVoice)),
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        scale: 0.98,
        builder: (context, pressed) => AnimatedContainer(
          duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
          height: 160,
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
            boxShadow: pressed ? null : tokens.shadowRaised,
          ),
          child: InsetShadow(
            shadows: pressed ? tokens.shadowPressed : tokens.cushion,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SpaceIcon(space: space),
                      const Spacer(),
                      if (inVoice.isNotEmpty) InVoice(faces: inVoice),
                    ],
                  ),
                  // Two lines of name and the mentions' pill still fit.
                  const SizedBox(height: 8),
                  Flexible(
                    child: Text(
                      space.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: (unread || mentions > 0 ? DuvetType.rowTitleUnread : DuvetType.rowTitle).copyWith(
                        color: colors.foreground,
                      ),
                    ),
                  ),
                  if (online != null || mentions > 0) ...[
                    const SizedBox(height: 4),
                    _OnlineLine(online: online, mentions: mentions),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "12 online" after the ice dot of someone alive, and at the line's end the
/// mentions' pill.
class _OnlineLine extends StatelessWidget {
  final String? online;
  final int mentions;
  const _OnlineLine({required this.online, required this.mentions});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (online case final online?) ...[
        const AliveDot(),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            online,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground),
          ),
        ),
      ] else
        const Spacer(),
      if (mentions > 0) ...[const SizedBox(width: 8), MentionCount(mentions)],
    ],
  );
}

/// The ice dot of what's alive: someone online, someone in voice.
class AliveDot extends StatelessWidget {
  const AliveDot({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: context.duvet.alive, shape: BoxShape.circle),
  );
}

/// The first three faces of [faces], each overlapping the one before it,
/// ringed in [ring] (the card they sit on, by default). Decoration: what
/// holds them says who they are.
class FaceStack extends StatelessWidget {
  final List<PersonFace> faces;
  final double size;
  final Color? ring;
  const FaceStack({required this.faces, this.size = 28, this.ring, super.key});

  @override
  Widget build(BuildContext context) {
    final ring = this.ring ?? context.theme.colors.card;
    final overlap = size * 0.3;
    final shown = faces.take(3).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: SizedBox(
        width: size + (shown.length - 1) * (size - overlap) + 4,
        height: size + 4,
        child: Stack(
          children: [
            for (final (i, f) in shown.indexed)
              Positioned(
                left: i * (size - overlap),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
                  child: UserAvatar(name: f.name, url: f.avatarUrl, size: size),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Who's in a Space's voice rooms, on its card or row: the ice dot of
/// what's alive, then their first faces.
class InVoice extends StatelessWidget {
  final List<PersonFace> faces;
  const InVoice({required this.faces, super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const AliveDot(),
      const SizedBox(width: 4),
      FaceStack(faces: faces, size: 24),
    ],
  );
}

/// A room's mark, where a row needs a leading shape: a rounded square
/// (rooms are not people), sunken with a `#` for a text room or a speaker for
/// a voice room; a voice room with someone in it sits up on the slate
/// cushion, its sound waves in ice. Decoration: the row says what it is.
class RoomMark extends StatelessWidget {
  final RoomKind kind;
  final bool live;
  final double size;
  const RoomMark({required this.kind, this.live = false, this.size = 48, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final on = live && kind == RoomKind.voice;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(color: on ? tokens.chosen : colors.secondary, borderRadius: radius),
          child: InsetShadow(
            shadows: on ? tokens.cushion : tokens.shadowWell,
            borderRadius: radius,
            child: Icon(
              switch (kind) {
                RoomKind.text => FLucideIcons.hash,
                RoomKind.voice when on => FLucideIcons.audioLines,
                RoomKind.voice => FLucideIcons.volume2,
              },
              size: size * 0.46,
              color: on ? tokens.alive : colors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

/// A Space full width, the Spaces tab's Cards view: its banner over its icon,
/// name, who's online and who's in its voice rooms, and its mentions.
/// Without a banner, the rest alone.
class SpaceWideCard extends StatelessWidget {
  final Space space;
  final bool unread;
  final int mentions;
  final List<PersonFace> inVoice;
  final VoidCallback onTap;
  const SpaceWideCard({
    required this.space,
    required this.onTap,
    this.unread = false,
    this.mentions = 0,
    this.inVoice = const [],
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final online = space.onlineCount == null ? null : '${space.onlineCount} online';
    return Semantics(
      button: true,
      label: spaceLabel(space, (unread: unread, mentions: mentions, inVoice: inVoice)),
      excludeSemantics: true,
      onTap: onTap,
      child: Pressable(
        onTap: onTap,
        scale: 0.98,
        builder: (context, pressed) => AnimatedContainer(
          duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
            boxShadow: pressed ? null : tokens.shadowRaised,
          ),
          child: InsetShadow(
            shadows: pressed ? tokens.shadowPressed : tokens.cushion,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (space.bannerUrl case final banner?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: SpaceBanner(key: ValueKey(banner), url: banner),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      SpaceIcon(space: space),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    space.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: (unread || mentions > 0 ? DuvetType.rowTitleUnread : DuvetType.rowTitle)
                                        .copyWith(color: colors.foreground),
                                  ),
                                ),
                                if (inVoice.isNotEmpty) ...[const SizedBox(width: 8), InVoice(faces: inVoice)],
                              ],
                            ),
                            if (online != null || mentions > 0) ...[
                              const SizedBox(height: 4),
                              _OnlineLine(online: online, mentions: mentions),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum ButtonVariant { primary, secondary, destructive }

/// Duvet's button: a 48pt cushion, `radius-button`, `label` type. Secondary
/// (raised, its label in `accent-text`) is the default; one Primary (in the
/// accent) per screen at most. Pressing sinks it.
class DuvetButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final ButtonVariant variant;

  /// Full width: only the screen's single call to action.
  final bool expand;
  final bool busy;

  const DuvetButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = ButtonVariant.secondary,
    this.expand = false,
    this.busy = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final enabled = onPressed != null && !busy;
    final ink = switch (variant) {
      ButtonVariant.primary => colors.primaryForeground,
      ButtonVariant.secondary => tokens.accentText,
      ButtonVariant.destructive => colors.destructive,
    };
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusButton));
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: Opacity(
        opacity: onPressed == null ? 0.5 : 1,
        child: Pressable(
          onTap: enabled ? onPressed : null,
          builder: (context, pressed) => AnimatedContainer(
            duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
            height: 48,
            decoration: BoxDecoration(
              color: variant == ButtonVariant.primary ? colors.primary : colors.card,
              borderRadius: radius,
              boxShadow: pressed
                  ? null
                  : variant == ButtonVariant.primary
                  ? tokens.shadowControl
                  : tokens.shadowRest,
            ),
            child: InsetShadow(
              shadows: pressed
                  ? tokens.shadowPressed
                  : variant == ButtonVariant.primary
                  ? tokens.cushionAccent
                  : tokens.cushion,
              borderRadius: radius,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (busy)
                      SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: ink))
                    else ...[
                      if (icon != null) ...[Icon(icon, size: 24, color: ink), const SizedBox(width: 8)],
                      // Large text wraps no button off the screen.
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DuvetType.label.copyWith(color: ink, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Short time for a list: the time today, the weekday this week, else the date.
String shortTime(DateTime t, {DateTime? now}) {
  now ??= DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days == 0) return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (days == 1) return 'Yesterday';
  if (days < 7) return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1];
  return '${t.day}/${t.month}${t.year == now.year ? '' : '/${t.year % 100}'}';
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// A day separator's text: "Today", "Yesterday", "Monday, 20 October", or
/// with the year when it isn't this one. [now] defaults to [clock]'s, which
/// tests can pin with `withClock`.
String dayLabel(DateTime day, [DateTime? now]) {
  now ??= clock.now();
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(DateTime(day.year, day.month, day.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  final date = '${day.day} ${_months[day.month - 1]}';
  if (day.year != now.year) return '$date ${day.year}';
  return '${_weekdays[day.weekday - 1]}, $date';
}

/// A quiet line for a list's state: loading, empty.
class ListNote extends StatelessWidget {
  final String text;
  const ListNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Center(
      child: Text(text, style: DuvetType.body.copyWith(color: context.theme.colors.mutedForeground)),
    ),
  );
}

/// The search field: 40pt, `radius-field`, `base-raised` in a `shadow-well`
/// recess, a ⌕ glyph and placeholder in `ink-secondary`.
class SearchField extends StatelessWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool autofocus;

  const SearchField({
    this.hint = 'Search',
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onTap,
    this.autofocus = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Container(
      height: 40,
      decoration: const BoxDecoration(borderRadius: radius).copyWith(color: colors.card),
      child: InsetShadow(
        shadows: tokens.shadowWell,
        borderRadius: radius,
        child: Row(
          children: [
            const SizedBox(width: 12),
            ExcludeSemantics(child: Icon(FLucideIcons.search, size: 20, color: colors.mutedForeground)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: autofocus,
                onChanged: onChanged,
                onTap: onTap,
                textInputAction: TextInputAction.search,
                cursorColor: tokens.accentText,
                style: DuvetType.body.copyWith(color: colors.foreground),
                decoration: InputDecoration.collapsed(
                  hintText: hint,
                  hintStyle: DuvetType.body.copyWith(color: colors.mutedForeground),
                ).copyWith(semanticCounterText: ''),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// A form field: a `caption`-weight label over a 48pt `radius-field` input in
/// a `shadow-well` recess; an error turns its edge `destructive` and shows
/// under it.
class DuvetTextField extends StatelessWidget {
  final String label;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final String? error;
  final String? helper;
  final bool obscure;
  final bool autofocus;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Inside the field, at its end: e.g. Paste.
  final Widget? trailing;

  /// The most characters it takes, counted as code points (as Postgres's
  /// varchar counts them, which an emoji's parts each are); more aren't
  /// typed.
  final int? maxLength;

  const DuvetTextField({
    required this.label,
    this.controller,
    this.focusNode,
    this.hint,
    this.error,
    this.helper,
    this.obscure = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
    this.trailing,
    this.maxLength,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Text(
            label,
            style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          constraints: BoxConstraints(minHeight: maxLines == 1 ? 48 : 96),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: radius,
            border: Border.all(color: error != null ? colors.destructive : tokens.hairline),
          ),
          child: InsetShadow(
            shadows: tokens.shadowWell,
            borderRadius: radius,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, maxLines == 1 ? 0 : 12, trailing == null ? 16 : 8, 0),
              child: Row(
                crossAxisAlignment: maxLines == 1 ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: maxLines == 1 ? 13 : 0),
                      child: Semantics(
                        label: label,
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          autofocus: autofocus,
                          obscureText: obscure,
                          maxLines: obscure ? 1 : maxLines,
                          minLines: 1,
                          keyboardType: keyboardType,
                          textInputAction: textInputAction,
                          autofillHints: autofillHints,
                          onChanged: onChanged,
                          onSubmitted: onSubmitted,
                          inputFormatters: [if (maxLength case final max?) CodePointLimit(max)],
                          cursorColor: tokens.accentText,
                          style: DuvetType.body.copyWith(color: colors.foreground),
                          decoration: InputDecoration.collapsed(
                            hintText: hint,
                            hintStyle: DuvetType.body.copyWith(color: colors.mutedForeground),
                          ).copyWith(semanticCounterText: ''),
                        ),
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
        if (error != null || helper != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
              liveRegion: error != null,
              child: Text(
                error ?? helper!,
                style: DuvetType.caption.copyWith(color: error != null ? colors.destructive : colors.mutedForeground),
              ),
            ),
          ),
      ],
    );
  }
}

/// A small text button in `accent-text`, at least 40pt tall: "Paste",
/// "Resend code".
class TextAction extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  const TextAction({required this.label, required this.onPressed, this.color, super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    enabled: onPressed != null,
    label: label,
    excludeSemantics: true,
    onTap: onPressed,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: DuvetType.caption.copyWith(
                color: onPressed == null ? context.theme.colors.mutedForeground : (color ?? context.duvet.accentText),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A chip: a 32pt cushion, `radius-chip`; selected, the slate pill a chosen
/// tab sits on.
class DuvetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// A radio in a group (one of several), else a toggle.
  final bool radio;

  /// Neither: a button that does something, as Add member does.
  final bool action;

  /// Before the label: a small avatar or icon.
  final Widget? leading;
  const DuvetChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.radio = true,
    this.leading,
    this.action = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return Semantics(
      container: true,
      button: true,
      inMutuallyExclusiveGroup: radio && !action,
      checked: radio && !action ? selected : null,
      toggled: radio || action ? null : selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 32,
          decoration: BoxDecoration(
            color: selected ? tokens.chosen : colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
            boxShadow: tokens.shadowRest,
          ),
          child: InsetShadow(
            shadows: tokens.cushion,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading case final leading?) ...[leading, const SizedBox(width: 6)],
                  Text(
                    label,
                    style: DuvetType.snippet.copyWith(
                      color: selected ? tokens.chosenText : colors.foreground,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An on/off switch: a sunken track, a cushioned knob that springs across,
/// the accent when on.
class DuvetSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// What it turns on, for screen readers.
  final String label;
  const DuvetSwitch({required this.value, required this.onChanged, required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final reduce = MediaQuery.disableAnimationsOf(context);
    const radius = BorderRadius.all(Radius.circular(12));
    return Semantics(
      container: true,
      toggled: value,
      enabled: onChanged != null,
      label: label,
      excludeSemantics: true,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: reduce ? Duration.zero : const Duration(milliseconds: 200),
          width: 52,
          height: 32,
          decoration: BoxDecoration(color: value ? colors.primary : colors.secondary, borderRadius: radius),
          child: InsetShadow(
            shadows: value ? const [] : tokens.shadowWell,
            borderRadius: radius,
            child: AnimatedAlign(
              duration: reduce ? Duration.zero : const Duration(milliseconds: 250),
              curve: DuvetTokens.overshoot,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: value ? colors.primaryForeground : colors.card,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: tokens.shadowRest,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of a few choices, side by side in a recess, the chosen one on the
/// slate pill (Appearance's System, Light, Dark). Each choice's text is its
/// label.
class Segmented<T> extends StatelessWidget {
  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  const Segmented({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Semantics(
      container: true,
      label: label,
      explicitChildNodes: true,
      child: Container(
        // 44 inside the recess: each choice a full tap target.
        height: 48,
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(borderRadius: radius).copyWith(color: colors.secondary),
        child: InsetShadow(
          shadows: tokens.shadowWell,
          borderRadius: radius,
          child: Row(
            children: [
              for (final MapEntry(:key, value: text) in options.entries)
                Expanded(
                  child: Semantics(
                    container: true,
                    button: true,
                    inMutuallyExclusiveGroup: true,
                    checked: key == value,
                    label: text,
                    excludeSemantics: true,
                    onTap: () => onChanged(key),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onChanged(key);
                      },
                      child: AnimatedContainer(
                        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : DuvetTokens.pressOut,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: key == value ? tokens.chosen : null,
                          borderRadius: BorderRadius.circular(DuvetTokens.radiusField - 2),
                          boxShadow: key == value ? tokens.shadowRest : null,
                        ),
                        // One line, shrunk to fit at large text sizes rather
                        // than cut ("Do not disturb").
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              text,
                              maxLines: 1,
                              style: DuvetType.label.copyWith(
                                fontSize: 15,
                                color: key == value ? tokens.chosenText : colors.mutedForeground,
                              ),
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
