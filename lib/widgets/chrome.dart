import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../theme.dart';
import 'depth.dart';
import 'duvet_mascot.dart';
import 'ghost_art.dart';
import 'glass.dart';

/// Liquid Glass chrome: the bars (top, tab, composer). The lighter
/// `blur-chrome` over the saturated backdrop, and a 1px hairline on the edge
/// facing the content, shown once content scrolls beneath it.
class GlassChrome extends StatelessWidget {
  final Widget child;

  /// Where the hairline goes: the bottom edge for a top bar, the top for a
  /// bottom bar.
  final bool top;
  final bool hairline;

  const GlassChrome({required this.child, this.top = true, this.hairline = true, super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.duvet;
    final colors = context.theme.colors;
    final opaque = MediaQuery.highContrastOf(context);
    final edge = BorderSide(color: hairline ? tokens.hairline : Colors.transparent);
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        color: opaque ? colors.background : tokens.glass,
        border: top ? Border(bottom: edge) : Border(top: edge),
      ),
      child: child,
    );
    if (opaque) return fill;
    return ClipRect(
      child: BackdropFilter(filter: glassBackdrop(DuvetTokens.blurChrome), child: fill),
    );
  }
}

/// A 40×40 icon button: a 24px line icon in `ink`; pressing sinks it into a
/// `radius-field` well.
class IconAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  /// A count on its corner, as on the desktop's Friends button: none at 0,
  /// 9+ past 9. [label] says it for screen readers.
  final int badge;

  const IconAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.badge = 0,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Pressable(
        onTap: onPressed,
        builder: (context, pressed) {
          final button = SizedBox.square(
            dimension: 40,
            child: AnimatedContainer(
              duration: pressed ? DuvetTokens.pressIn : DuvetTokens.pressOut,
              decoration: BoxDecoration(color: pressed ? colors.secondary : Colors.transparent, borderRadius: radius),
              child: InsetShadow(
                shadows: pressed ? tokens.shadowPressed : const [],
                borderRadius: radius,
                child: Center(
                  child: Icon(
                    icon,
                    size: 24,
                    color: onPressed == null ? colors.mutedForeground : (color ?? colors.foreground),
                  ),
                ),
              ),
            ),
          );
          if (badge <= 0) return button;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              button,
              Positioned(
                top: 1,
                right: 1,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.destructive,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: colors.background, width: 1.5),
                  ),
                  child: Text(
                    badge > 9 ? '9+' : '$badge',
                    style: DuvetType.tabLabel.copyWith(
                      color: colors.destructiveForeground,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
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

/// The inline top bar of a pushed screen: glass, 52pt below the status bar, a
/// back chevron at x8, the title centered in `nav-title`, actions on the right.
class GlassTopBar extends StatelessWidget {
  final Widget? title;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final bool hairline;

  /// Under the bar, inside its glass: e.g. a [ConnectionBanner].
  final Widget? bottom;

  /// Tapping the title, e.g. the Channel Switcher: it gets a ⌄ and presses.
  final VoidCallback? onTitle;

  /// What screen readers call the tappable title.
  final String? titleLabel;

  /// In place of Back, e.g. Cancel.
  final Widget? leading;

  const GlassTopBar({
    this.title,
    this.onBack,
    this.actions = const [],
    this.hairline = true,
    this.bottom,
    this.onTitle,
    this.titleLabel,
    this.leading,
    super.key,
  });

  /// The bar's height with the status bar above it.
  static double heightOf(BuildContext context) => MediaQuery.paddingOf(context).top + DuvetTokens.sizeTopBar;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    // Both sides as wide, so the title stays centered.
    // Text actions (Cancel, Save) take a wider slot than icons.
    final text = leading != null || actions.any((a) => a is! IconAction && a is! Builder);
    final side = text ? 88.0 : 8 + 40.0 * (actions.length > 1 ? actions.length : 1);
    return GlassChrome(
      hairline: hairline,
      child: Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: DuvetTokens.sizeTopBar,
              child: Row(
                children: [
                  SizedBox(
                    width: side,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: leading != null
                          ? Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: FittedBox(fit: BoxFit.scaleDown, child: leading),
                            )
                          : onBack == null
                          ? null
                          : Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: IconAction(icon: FLucideIcons.chevronLeft, label: 'Back', onPressed: onBack),
                            ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: DefaultTextStyle.merge(
                        style: DuvetType.navTitle.copyWith(color: colors.foreground),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: onTitle == null
                            ? Semantics(header: true, child: title ?? const SizedBox.shrink())
                            : Semantics(
                                container: true,
                                header: true,
                                button: true,
                                label: titleLabel,
                                excludeSemantics: titleLabel != null,
                                onTap: onTitle,
                                child: Pressable(
                                  onTap: onTitle,
                                  builder: (context, _) => Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(child: title ?? const SizedBox.shrink()),
                                      const SizedBox(width: 4),
                                      Icon(FLucideIcons.chevronDown, size: 14, color: colors.mutedForeground),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: side,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (bottom case final bottom?) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: bottom),
          ],
        ),
      ),
    );
  }
}

/// The connection's state, in the chrome and never over content: a 36pt
/// `base-sunken` strip, e.g. "Reconnecting… messages will send when you're
/// back". Screen readers hear it change.
class ConnectionBanner extends StatelessWidget {
  final String text;
  final String? detail;
  final IconData icon;
  const ConnectionBanner({required this.text, this.detail, this.icon = FLucideIcons.wifiOff, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
        child: InsetShadow(
          shadows: context.duvet.shadowWell,
          borderRadius: radius,
          child: Row(
            children: [
              ExcludeSemantics(child: Icon(icon, size: 16, color: colors.foreground)),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: text),
                      if (detail != null)
                        TextSpan(
                          text: ' $detail',
                          style: TextStyle(color: colors.mutedForeground),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DuvetType.caption.copyWith(color: colors.foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tab root: the `large-title` scrolls away with the content, and a 52pt
/// glass bar with the `nav-title` fades in over it. The bar is laid over the
/// list, never inside it: no blur in a scrolling list.
class LargeTitlePage extends StatefulWidget {
  final String title;

  /// Before the title: the app icon on Chats, the screen the app opens on.
  final Widget? titleLeading;

  /// Beside the title, e.g. the connecting spinner.
  final Widget? titleTrailing;

  /// Under the title, scrolling with it, e.g. the search field.
  final Widget? header;
  final List<Widget> slivers;
  final Future<void> Function()? onRefresh;

  const LargeTitlePage({
    required this.title,
    required this.slivers,
    this.titleLeading,
    this.titleTrailing,
    this.header,
    this.onRefresh,
    super.key,
  });

  @override
  State<LargeTitlePage> createState() => _LargeTitlePageState();
}

class _LargeTitlePageState extends State<LargeTitlePage> {
  final _scroll = ScrollController();
  bool _collapsed = false;

  // The large title's height (8 above, then size × line height): past it, the bar shows.
  static final _titleExtent = 8 + DuvetType.largeTitle.fontSize! * DuvetType.largeTitle.height!;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final collapsed = _scroll.offset > _titleExtent;
      if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final padding = MediaQuery.paddingOf(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    Widget list = CustomScrollView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, padding.top + 8, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The night sky beside the title, clear of its buttons (the tab
                // roots' titles are all one short word); it scrolls away with it.
                Positioned(
                  left: widget.titleLeading == null ? 128 : 172,
                  top: -6,
                  child: const NightSky.title(width: 120),
                ),
                Row(
                  children: [
                    if (widget.titleLeading case final leading?) ...[leading, const SizedBox(width: 12)],
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(widget.title, style: DuvetType.largeTitle.copyWith(color: colors.foreground)),
                      ),
                    ),
                    ?widget.titleTrailing,
                  ],
                ),
              ],
            ),
          ),
        ),
        if (widget.header case final header?) SliverToBoxAdapter(child: header),
        ...widget.slivers,
        SliverPadding(padding: EdgeInsets.only(bottom: padding.bottom + 16)),
      ],
    );
    if (widget.onRefresh case final refresh?) {
      list = RefreshIndicator(edgeOffset: padding.top, onRefresh: refresh, child: list);
    }
    return Stack(
      children: [
        Positioned.fill(child: list),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !_collapsed,
            child: ExcludeSemantics(
              excluding: !_collapsed,
              child: AnimatedOpacity(
                opacity: _collapsed ? 1 : 0,
                duration: reduce ? Duration.zero : const Duration(milliseconds: 200),
                curve: DuvetTokens.decelerate,
                // The tab's title, collapsed: Inter like the large one.
                child: GlassTopBar(
                  title: Text(
                    widget.title,
                    style: DuvetType.largeTitle.copyWith(
                      fontSize: 20,
                      letterSpacing: 20 * -0.02,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One tab of the [DuvetTabBar].
typedef TabItem = ({IconData icon, String label});

/// The bottom tab bar: glass, 56pt above the safe area, four equal columns.
/// The active tab is `accent-text` with a 56×32 `accent-tint` pill behind its
/// icon, which springs between tabs.
class DuvetTabBar extends StatelessWidget {
  final int index;
  final List<TabItem> items;
  final ValueChanged<int> onChange;

  const DuvetTabBar({required this.index, required this.items, required this.onChange, super.key});

  static double heightOf(BuildContext context) => DuvetTokens.sizeTabBar + MediaQuery.paddingOf(context).bottom;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return GlassChrome(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: SizedBox(
          height: DuvetTokens.sizeTabBar,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final column = constraints.maxWidth / items.length;
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: reduce ? Duration.zero : DuvetTokens.tabPill,
                    curve: DuvetTokens.pillSpring,
                    left: column * index + column / 2 - 28,
                    top: 4,
                    width: 56,
                    height: 32,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: tokens.azureTint, borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                  Row(
                    children: [
                      for (final (i, item) in items.indexed)
                        Expanded(
                          child: Semantics(
                            button: true,
                            selected: i == index,
                            inMutuallyExclusiveGroup: true,
                            label: item.label,
                            hint: 'Tab ${i + 1} of ${items.length}',
                            excludeSemantics: true,
                            onTap: () => onChange(i),
                            child: Pressable(
                              onTap: () => onChange(i),
                              scale: 0.94,
                              builder: (context, _) {
                                final color = i == index ? tokens.accentText : colors.mutedForeground;
                                return Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Column(
                                    children: [
                                      Icon(item.icon, size: 24, color: color),
                                      const SizedBox(height: 4),
                                      Text(item.label, style: DuvetType.tabLabel.copyWith(color: color)),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A screen title-less placeholder: an icon and a line, centered; or the ghost
/// over a `title`-type heading.
class EmptyState extends StatelessWidget {
  final IconData? icon;
  final MascotState? mascot;
  final String text;
  final Widget? action;
  const EmptyState({this.icon, this.mascot, required this.text, this.action, super.key})
    : assert((icon == null) != (mascot == null), 'Give an icon or a mascot');

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mascot case final mascot?)
              // Shrinks rather than overflows when the keyboard leaves little room.
              Flexible(
                child: FittedBox(fit: BoxFit.scaleDown, child: DuvetMascot(mascot, excludeFromSemantics: true)),
              )
            else
              Icon(icon, size: 32, color: colors.mutedForeground),
            SizedBox(height: mascot == null ? 12 : 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: mascot == null
                  ? DuvetType.body.copyWith(color: colors.mutedForeground)
                  : DuvetType.title.copyWith(color: colors.foreground),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
