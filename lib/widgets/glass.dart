import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../theme.dart';
import 'avatar.dart';

/// Duvet's Liquid Glass: a 78% glass fill over a backdrop blur, a 1px edge that
/// catches the light, and a large, weak float shadow. Only for overlays and
/// floating chrome, never inside a scrolling list.
///
/// With high contrast on, the glass turns opaque: blur under text costs
/// legibility some people can't spare.
class GlassSurface extends StatelessWidget {
  final BorderRadius borderRadius;
  final double blur;
  final Widget child;

  const GlassSurface({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(DuvetTokens.radiusCard)),
    this.blur = DuvetTokens.blurGlass,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.duvet;
    final opaque = MediaQuery.highContrastOf(context);
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        color: opaque ? context.theme.colors.card : tokens.glass,
        borderRadius: borderRadius,
        border: Border.all(color: opaque ? context.theme.colors.foreground : tokens.glassEdge),
      ),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: tokens.shadowFloat),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: opaque ? fill : BackdropFilter(filter: glassBackdrop(blur), child: fill),
      ),
    );
  }
}

/// The backdrop of Liquid Glass: [blur], then the colors underneath saturated
/// 1.8× so they stay alive through the fill.
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

/// Opens a Liquid Glass dropdown under (or, without room, over) the widget of
/// [anchor]'s context, and answers the picked item's value, or null when
/// dismissed. It's a route: back, a tap outside and a screen reader's
/// dismiss gesture all close it, and focus stays inside while it's open.
Future<T?> showGlassMenu<T>(BuildContext anchor, {required List<GlassMenuItem<T>> items, String label = 'Menu'}) {
  return Navigator.of(anchor).push(_GlassMenuRoute<T>(anchor: anchor, items: items, label: label));
}

/// Where [anchor]'s widget is on screen now, or null once it's gone.
Rect? _rectOf(BuildContext anchor) {
  if (!anchor.mounted) return null;
  final box = anchor.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _GlassMenuRoute<T> extends PopupRoute<T> {
  /// The trigger, measured again as the screen changes: opening the menu
  /// takes focus from a text field, the keyboard closes, and a trigger above
  /// it (the composer's +) moves down. The menu follows.
  final BuildContext anchor;
  final List<GlassMenuItem<T>> items;
  final String label;
  _GlassMenuRoute({required this.anchor, required this.items, required this.label}) : _last = _rectOf(anchor)!;

  Rect _last;

  static const _width = 248.0;
  static const _rowHeight = 52.0;
  static const _gap = 8.0; // space-8 below the trigger
  static const _margin = 16.0;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Close ${label.toLowerCase()}';

  @override
  Duration get transitionDuration => DuvetTokens.dropdownIn;

  @override
  Duration get reverseTransitionDuration => DuvetTokens.panelOut;

  // Where it opens: under the anchor when it fits, else over it.
  ({Offset offset, bool below}) _place(Rect anchor, Size screen, EdgeInsets padding) {
    final height = items.length * _rowHeight + 16;
    final below =
        anchor.bottom + _gap + height <= screen.height - padding.bottom - _margin ||
        anchor.top - _gap - height < padding.top + _margin;
    final top = below ? anchor.bottom + _gap : anchor.top - _gap - height;
    // Aligned to the anchor's nearer edge, kept on screen.
    final left = anchor.center.dx > screen.width / 2 ? anchor.right - _width : anchor.left;
    return (offset: Offset(left.clamp(_margin, math.max(_margin, screen.width - _width - _margin)), top), below: below);
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _Following(route: this, builder: (context) => _menu(context, animation));

  Widget _menu(BuildContext context, Animation<double> animation) {
    final media = MediaQuery.of(context);
    // The keyboard's space isn't room for it.
    final (:offset, :below) = _place(
      _last,
      media.size,
      media.padding + EdgeInsets.only(bottom: media.viewInsets.bottom),
    );
    return Stack(
      children: [
        Positioned(
          left: offset.dx,
          top: offset.dy,
          width: _width,
          child: _GlassMenuTransition(
            animation: animation,
            below: below,
            child: Semantics(
              label: label,
              explicitChildNodes: true,
              scopesRoute: true,
              namesRoute: true,
              child: GlassSurface(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in items)
                        GlassRow(
                          icon: item.icon,
                          label: item.label,
                          hint: item.hint,
                          destructive: item.destructive,
                          onPressed: () => Navigator.of(context).pop(item.value),
                        ),
                    ],
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

/// Rebuilds a [_GlassMenuRoute]'s menu where its trigger is now: after each
/// frame the screen's size or insets change in (the keyboard animating), it
/// measures the trigger again, once laid out.
class _Following extends StatefulWidget {
  final _GlassMenuRoute<dynamic> route;
  final WidgetBuilder builder;
  const _Following({required this.route, required this.builder});

  @override
  State<_Following> createState() => _FollowingState();
}

class _FollowingState extends State<_Following> {
  void _measure(Duration _) {
    if (!mounted) return;
    final now = _rectOf(widget.route.anchor);
    if (now != null && now != widget.route._last) setState(() => widget.route._last = now);
  }

  @override
  Widget build(BuildContext context) {
    // Depends on the screen's size and insets: a change rebuilds, then measures.
    MediaQuery.sizeOf(context);
    MediaQuery.viewInsetsOf(context);
    WidgetsBinding.instance.addPostFrameCallback(_measure);
    return widget.builder(context);
  }
}

/// In: drops 8px and fades in on a spring with a ~2% overshoot. Out: fades on
/// a deceleration. With animations off: a plain fade.
class _GlassMenuTransition extends AnimatedWidget {
  final bool below;
  final Widget child;
  const _GlassMenuTransition({required Animation<double> animation, required this.below, required this.child})
    : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    final animation = listenable as Animation<double>;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final forward = animation.status != AnimationStatus.reverse;
    final fade = (forward ? DuvetTokens.decelerate : Curves.easeOut).transform(animation.value);
    if (reduce) return Opacity(opacity: fade, child: child);
    final travel = forward ? DuvetTokens.overshoot.transform(animation.value) : 1.0;
    return Opacity(
      opacity: fade,
      child: Transform.translate(
        offset: Offset(0, (1 - travel) * (below ? -8 : 8)),
        child: Transform.scale(
          scale: 0.96 + 0.04 * travel,
          alignment: below ? Alignment.topCenter : Alignment.bottomCenter,
          child: child,
        ),
      ),
    );
  }
}

/// A pressable row on glass: a 24px line icon and a label, at least 48px tall.
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

/// Opens a Liquid Glass bottom sheet: 24px top corners, a grabber, the heavier
/// overlay blur. It springs in and decelerates out; drag it down, tap outside
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
    barrierColor: const Color(0x52000000),
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

/// A short Liquid Glass sheet that fits its content: a confirmation, a form.
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
    barrierColor: const Color(0x52000000),
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
