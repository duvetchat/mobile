import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../theme.dart';
import 'avatar.dart';
import 'depth.dart';

/// A floating surface: menus, sheets, the bars over a picture. A cushion one
/// step above the ground, with a 1px edge where it meets what's under it and
/// a large, weak float shadow. Only for overlays and floating chrome, never
/// inside a scrolling list.
///
/// With high contrast on, its edge turns to ink.
class GlassSurface extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;

  const GlassSurface({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(DuvetTokens.radiusCard)),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.duvet;
    final contrast = MediaQuery.highContrastOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.popover,
        borderRadius: borderRadius,
        border: Border.all(color: contrast ? context.theme.colors.foreground : tokens.popoverEdge),
        boxShadow: tokens.shadowFloat,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: InsetShadow(shadows: tokens.cushion, borderRadius: borderRadius, child: child),
      ),
    );
  }
}

/// A frosted backdrop: [blur], then the colors underneath saturated 1.8× so
/// they stay alive through it. Only over a picture, as the image viewer's
/// bars are.
ImageFilter glassBackdrop(double blur) => ImageFilter.compose(
  outer: const ColorFilter.matrix(_saturate18),
  inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
);

// CSS `saturate(1.8)`: each channel pulled away from the pixel's luminance
// (Rec. 709 weights 0.213, 0.715, 0.072) by the factor s.
const _s = 1.8;
const _saturate18 = <double>[
  0.213 + 0.787 * _s, 0.715 - 0.715 * _s, 0.072 - 0.072 * _s, 0, 0, //
  0.213 - 0.213 * _s, 0.715 + 0.285 * _s, 0.072 - 0.072 * _s, 0, 0, //
  0.213 - 0.213 * _s, 0.715 - 0.715 * _s, 0.072 + 0.928 * _s, 0, 0, //
  0, 0, 0, 1, 0,
];

/// A row of a [showGlassMenu].
class GlassMenuItem<T> {
  final IconData icon;
  final String label;
  final T value;

  /// Read by screen readers after the label, e.g. what the action affects.
  final String? hint;
  final bool destructive;

  const GlassMenuItem({
    required this.icon,
    required this.label,
    required this.value,
    this.hint,
    this.destructive = false,
  });
}

/// Opens a menu of actions from the bottom, as every other sheet: [label] as
/// its title, a row for each item, and what can't be undone apart under a
/// rule. Answers the picked item's value, or null when dismissed: back, a tap
/// outside, dragging it down and a screen reader's dismiss gesture all close
/// it.
Future<T?> showGlassMenu<T>(BuildContext anchor, {required List<GlassMenuItem<T>> items, String label = 'Menu'}) =>
    showGlassDialogSheet<T>(
      anchor,
      label: label,
      builder: (context) {
        Widget row(GlassMenuItem<T> item) => GlassRow(
          icon: item.icon,
          label: item.label,
          hint: item.hint,
          destructive: item.destructive,
          onPressed: () => Navigator.of(context).pop(item.value),
        );
        final kept = [
          for (final item in items)
            if (!item.destructive) item,
        ];
        final apart = [
          for (final item in items)
            if (item.destructive) item,
        ];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitle(title: label),
              for (final item in kept) row(item),
              if (kept.isNotEmpty && apart.isNotEmpty) const SheetRule(),
              for (final item in apart) row(item),
            ],
          ),
        );
      },
    );

/// A hairline across a sheet, setting what follows apart: what can't be undone.
class SheetRule extends StatelessWidget {
  const SheetRule({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, margin: const EdgeInsets.fromLTRB(16, 4, 16, 4), color: context.duvet.hairline);
}

/// A pressable row in a menu or sheet: a 24px line icon and a label, at least 48px tall.
/// Pressing sinks it (0.97 and a sunken highlight), Duvet's one press language.
class GlassRow extends StatefulWidget {
  final IconData? icon;
  final Widget? leading;
  final String label;
  final String? detail;
  final String? hint;
  final bool destructive;
  final bool selected;
  final VoidCallback onPressed;

  /// The label's color in place of `ink`: a member's role color.
  final Color? labelColor;

  /// A member's banner, faintly behind the row: see [memberBanner].
  final String? banner;
  final bool bannerOffline;

  const GlassRow({
    required this.label,
    required this.onPressed,
    this.icon,
    this.leading,
    this.detail,
    this.hint,
    this.destructive = false,
    this.selected = false,
    this.labelColor,
    this.banner,
    this.bannerOffline = false,
    super.key,
  });

  @override
  State<GlassRow> createState() => _GlassRowState();
}

class _GlassRowState extends State<GlassRow> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final ink = widget.destructive
        ? colors.destructive
        : widget.selected
        ? tokens.accentText
        : colors.foreground;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.detail == null ? widget.label : '${widget.label}, ${widget.detail}',
      hint: widget.hint,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed && !reduce ? 0.97 : 1,
          duration: Duration(milliseconds: _pressed ? 120 : 150),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _pressed
                  ? colors.foreground.withValues(alpha: 0.08)
                  : widget.selected
                  ? tokens.accentTint
                  : Colors.transparent,
              image: memberBanner(context, widget.banner, offline: widget.bannerOffline),
              borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            ),
            child: Row(
              children: [
                if (widget.leading != null)
                  Padding(padding: const EdgeInsets.only(right: 12), child: widget.leading)
                else if (widget.icon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Icon(widget.icon, size: 24, color: ink),
                  ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DuvetType.label.copyWith(color: widget.labelColor ?? ink),
                      ),
                      if (widget.detail != null)
                        Text(
                          widget.detail!,
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
      ),
    );
  }
}

/// Opens a bottom sheet: a cushion with `radius-sheet` top corners and a
/// grabber, over a dimmed screen. It springs in and decelerates out; drag it down, tap outside
/// or use back to close.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required String label,
  required Widget Function(BuildContext context, ScrollController scroll) builder,
  double initialSize = 0.6,
  double maxSize = 0.92,
}) {
  final reduce = MediaQuery.disableAnimationsOf(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: context.theme.colors.barrier,
    barrierLabel: 'Close ${label.toLowerCase()}',
    sheetAnimationStyle: reduce
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: DuvetTokens.panelIn,
            curve: DuvetTokens.overshoot,
            reverseDuration: DuvetTokens.panelOut,
            reverseCurve: DuvetTokens.decelerate,
          ),
    // Above the keyboard when a search field in it takes focus.
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: initialSize,
        minChildSize: math.min(0.3, initialSize),
        maxChildSize: maxSize,
        builder: (context, scroll) => Semantics(
          label: label,
          explicitChildNodes: true,
          scopesRoute: true,
          namesRoute: true,
          child: GlassSurface(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(DuvetTokens.radiusSheet)),
            child: Column(
              children: [
                const _Grabber(),
                Expanded(child: builder(context, scroll)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A short sheet that fits its content: a confirmation, a form.
/// It's an alert dialog to screen readers, named [label].
Future<T?> showGlassDialogSheet<T>(BuildContext context, {required String label, required WidgetBuilder builder}) {
  final reduce = MediaQuery.disableAnimationsOf(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: context.theme.colors.barrier,
    barrierLabel: 'Close ${label.toLowerCase()}',
    sheetAnimationStyle: reduce
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: DuvetTokens.panelIn,
            curve: DuvetTokens.overshoot,
            reverseDuration: DuvetTokens.panelOut,
            reverseCurve: DuvetTokens.decelerate,
          ),
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Semantics(
        label: label,
        explicitChildNodes: true,
        scopesRoute: true,
        namesRoute: true,
        child: GlassSurface(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(DuvetTokens.radiusSheet)),
          child: SafeArea(
            top: false,
            // The padding above already lifts it over the keyboard; it
            // scrolls when that leaves too little room.
            child: MediaQuery.removeViewInsets(
              context: context,
              removeBottom: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Grabber(),
                  Flexible(
                    child: SingleChildScrollView(child: Builder(builder: builder)),
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

/// The sheet's handle. Screen readers get it as a close button, since they
/// can't drag.
class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Close',
    onTap: () => Navigator.of(context).maybePop(),
    excludeSemantics: true,
    child: SizedBox(
      height: 24,
      child: Center(
        child: Container(
          width: 36,
          height: 5,
          decoration: BoxDecoration(color: context.duvet.grabber, borderRadius: BorderRadius.circular(3)),
        ),
      ),
    ),
  );
}

/// A sheet's title row: the `title` style, with an optional caption.
class SheetTitle extends StatelessWidget {
  final String title;
  final String? caption;
  const SheetTitle({required this.title, this.caption, super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Semantics(header: true, child: Text(title, style: DuvetType.title)),
        if (caption != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DuvetType.caption.copyWith(color: context.theme.colors.mutedForeground),
            ),
          ),
        ],
      ],
    ),
  );
}
