import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import '../data/images.dart';
import '../data/models.dart';
import '../theme.dart';
import 'avatar.dart';
import 'depth.dart';

/// A two-line list row (ChatRow, ChannelRow): 72pt, no divider, a 48pt
/// leading avatar or Space icon, the name over a one-line snippet. With
/// neither a leading nor a snippet (a room nobody wrote in yet) it is one
/// 44pt line.
///
/// Unread is weight and `ink` alone, never blue and never a dot. Pressing
/// shows a `base-sunken` highlight inset 8pt; the selected row (the current
/// channel in the Channel Switcher) an `accent-tint` one.
class ListRow extends StatelessWidget {
  final Widget? leading;
  final String title;

  /// A `# ` before the title, in `ink-secondary`: a channel.
  final bool hash;

  /// After the title, in `ink-secondary`, e.g. "· Space name".
  final String? titleSuffix;

  /// Right after the title, a small glyph kept when a long title is cut: [OwnerCrown], the pin.
  final Widget? titleIcon;
  final String? snippet;

  /// Right-aligned on the first line, e.g. the time.
  final String? trailing;
  final bool unread;
  final bool selected;

  /// Read by screen readers after the row, e.g. "2 mentions".
  final String? detail;

  /// At the end of the snippet line: the unread mentions, as "@2". Weight
  /// and count only, never a blue dot.
  final int mentions;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// A member's banner, faintly behind the row: see [memberBanner].
  final String? banner;
  final bool bannerOffline;

  /// Whether screen readers meet the row as a node of its own. False gives
  /// its name and tap to the node around it instead: a reorderable list's
  /// item, which offers the moves, so the row and its moves are one stop.
  final bool ownNode;

  const ListRow({
    required this.title,
    this.leading,
    this.hash = false,
    this.titleSuffix,
    this.titleIcon,
    this.snippet,
    this.trailing,
    this.unread = false,
    this.selected = false,
    this.detail,
    this.mentions = 0,
    this.onTap,
    this.onLongPress,
    this.banner,
    this.bannerOffline = false,
    this.ownNode = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final secondary = colors.mutedForeground;
    final detail = [if (mentions > 0) mentions == 1 ? '1 mention' : '$mentions mentions', ?this.detail].join(', ');
    final name = selected ? tokens.accentText : colors.foreground;
    final compact = leading == null && snippet == null && mentions == 0;
    final label = [
      '${hash ? '# ' : ''}$title${titleSuffix == null ? '' : ' $titleSuffix'}',
      if (unread) 'unread',
      if (detail.isNotEmpty) detail,
      ?snippet,
      ?trailing,
    ].join(', ');
    final titleText = Text.rich(
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
      style: (unread ? DuvetType.rowTitleUnread : DuvetType.rowTitle).copyWith(color: name),
    );
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
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: AnimatedContainer(
            duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
            constraints: BoxConstraints(minHeight: compact ? DuvetTokens.sizeRowCompact : DuvetTokens.sizeRow),
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: compact ? 10 : 12),
            decoration: BoxDecoration(
              color: pressed
                  ? colors.secondary
                  : selected
                  ? tokens.accentTint
                  : Colors.transparent,
              image: memberBanner(context, banner, offline: bannerOffline),
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            ),
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
                            child: titleIcon == null
                                ? titleText
                                : Row(
                                    children: [
                                      Flexible(child: titleText),
                                      const SizedBox(width: 4),
                                      titleIcon!,
                                    ],
                                  ),
                          ),
                          if (trailing != null) ...[
                            const SizedBox(width: 8),
                            Text(trailing!, style: DuvetType.caption.copyWith(color: secondary)),
                          ],
                        ],
                      ),
                      if (snippet != null || mentions > 0) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                snippet ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.snippet.copyWith(color: unread ? colors.foreground : secondary),
                              ),
                            ),
                            if (mentions > 0) ...[const SizedBox(width: 8), _MentionCount(mentions)],
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
    );
  }
}

/// "@2": unread mentions, in a small `base-sunken` recess, bold `ink`.
class _MentionCount extends StatelessWidget {
  final int count;
  const _MentionCount(this.count);

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusChip));
    return Container(
      height: 20,
      decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
      child: InsetShadow(
        shadows: context.duvet.shadowWell,
        borderRadius: radius,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Center(
          widthFactor: 1,
          child: Text(
            '@${count > 99 ? '99+' : count}',
            style: DuvetType.overline.copyWith(color: colors.foreground, fontWeight: FontWeight.w700, letterSpacing: 0),
          ),
        ),
      ),
    );
  }
}

/// A group header in a list: `overline`, uppercase, `ink-secondary`, 24pt
/// above and 8pt below. Never sticky, never blurred.
class Overline extends StatelessWidget {
  final String text;
  const Overline(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Semantics(
      header: true,
      child: Text(text.toUpperCase(), style: DuvetType.overline.copyWith(color: context.theme.colors.mutedForeground)),
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
                  name.toUpperCase(),
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
          child: Image(
            image: cachedImage(url, cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round()),
            width: width,
            height: height,
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
/// image or a monogram on `base-sunken`.
class SpaceIcon extends StatelessWidget {
  final Space space;
  final double size;
  const SpaceIcon({required this.space, this.size = 48, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    final monogram = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
        child: InsetShadow(
          shadows: tokens.shadowWell,
          borderRadius: radius,
          child: Center(
            child: Text(
              space.name.isEmpty ? '' : space.name.characters.first.toUpperCase(),
              style: DuvetType.navTitle.copyWith(color: colors.foreground, fontSize: size * 0.4),
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
        child: Image(
          image: cachedImage(url, cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round()),
          width: size,
          height: size,
          fit: BoxFit.cover,
          frameBuilder: (context, child, frame, sync) => frame == null && !sync ? monogram : child,
          errorBuilder: (context, error, stackTrace) => monogram,
        ),
      ),
    );
  }
}

/// A Launchpad tile: `base-raised`, `radius-card`, `shadow-raised`, 160pt
/// tall, the Space's icon, name (2 lines at most) and online count. Pressing
/// settles it toward the surface: 0.98, `shadow-raised` to `shadow-rest`.
class SpaceCard extends StatelessWidget {
  final Space space;
  final bool unread;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const SpaceCard({required this.space, required this.onTap, this.unread = false, this.onLongPress, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final online = space.onlineCount == null ? null : '${space.onlineCount} online';
    return Semantics(
      button: true,
      label: [space.name, if (unread) 'unread', ?online].join(', '),
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
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
            boxShadow: pressed ? tokens.shadowRest : tokens.shadowRaised,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SpaceIcon(space: space),
              const SizedBox(height: 12),
              Flexible(
                child: Text(
                  space.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: (unread ? DuvetType.rowTitleUnread : DuvetType.rowTitle).copyWith(color: colors.foreground),
                ),
              ),
              if (online != null) ...[
                const SizedBox(height: 4),
                Text(online, maxLines: 1, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A Space full width, the Spaces tab's Cards view: its banner over its icon,
/// name and who's online. Without a banner, the rest alone.
class SpaceWideCard extends StatelessWidget {
  final Space space;
  final bool unread;
  final VoidCallback onTap;
  const SpaceWideCard({required this.space, required this.onTap, this.unread = false, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final online = space.onlineCount == null ? null : '${space.onlineCount} online';
    return Semantics(
      button: true,
      label: [space.name, if (unread) 'unread', ?online].join(', '),
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
            boxShadow: pressed ? tokens.shadowRest : tokens.shadowRaised,
          ),
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
                          Text(
                            space.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: (unread ? DuvetType.rowTitleUnread : DuvetType.rowTitle).copyWith(
                              color: colors.foreground,
                            ),
                          ),
                          if (online != null) ...[
                            const SizedBox(height: 4),
                            Text(online, maxLines: 1, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
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
    );
  }
}

enum ButtonVariant { primary, secondary, destructive }

/// Duvet's button: 48pt, `radius-button`, `label` type, always a solid fill.
/// Secondary (cobalt on a pale fill) is the default; one Primary (cobalt) per
/// screen at most.
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
      ButtonVariant.destructive => colors.destructiveForeground,
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
              color: switch (variant) {
                ButtonVariant.primary => Duvet.accent,
                ButtonVariant.secondary => tokens.secondaryFill,
                ButtonVariant.destructive => colors.destructive,
              },
              borderRadius: radius,
              boxShadow: pressed ? null : tokens.shadowControl,
            ),
            child: InsetShadow(
              shadows: pressed ? tokens.shadowPressed : const [],
              borderRadius: radius,
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
                        style: DuvetType.label.copyWith(color: ink),
                      ),
                    ),
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

/// A chip: 32pt, `radius-chip`, raised; selected, a solid violet fill.
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
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? tokens.selectedFill : colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
            boxShadow: selected ? null : tokens.shadowRest,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading case final leading?) ...[leading, const SizedBox(width: 6)],
              Text(
                label,
                style: DuvetType.snippet.copyWith(
                  color: selected ? tokens.violetText : colors.foreground,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An on/off switch: a sunken track, a raised knob that springs across, the
/// accent when on.
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
          decoration: BoxDecoration(color: value ? Duvet.accent : colors.secondary, borderRadius: radius),
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
                  color: value ? const Color(0xFFFFFFFF) : colors.card,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: tokens.shadowControl,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of a few choices, side by side in a recess, the chosen one raised
/// (Appearance's System, Light, Dark). Each choice's text is its label.
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
        decoration: const BoxDecoration(borderRadius: radius).copyWith(color: colors.secondary),
        child: InsetShadow(
          shadows: tokens.shadowWell,
          borderRadius: radius,
          padding: const EdgeInsets.all(2),
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
                          color: key == value ? colors.card : null,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: key == value ? tokens.shadowControl : null,
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
                                color: key == value ? colors.foreground : colors.mutedForeground,
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

/// A Space owner's crown, after their name: gold, dimmed while they're offline.
class OwnerCrown extends StatelessWidget {
  final bool offline;
  const OwnerCrown({this.offline = false, super.key});

  @override
  Widget build(BuildContext context) => Icon(
    FLucideIcons.crown,
    size: 14,
    color: context.duvet.crown.withValues(alpha: offline ? 0.6 : 1),
    semanticLabel: 'Owner',
  );
}
