import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

/// Duvet's colors, taken from its mascot: a pillow with a cat's ears. Its
/// slate body, the ice blue inside its ears, and the periwinkle of
/// duvet.chat's wordmark. Night is the ground the brand sits on.
abstract final class Duvet {
  /// The mascot's body.
  static const slate = Color(0xFF3A3D52);

  /// The tips of its ears.
  static const slateDeep = Color(0xFF4E5270);

  /// The inside of its ears.
  static const ice = Color(0xFFA8DFF0);

  /// ".chat" in the wordmark.
  static const periwinkle = Color(0xFF7B83F5);
  static const night = Color(0xFF14151D);

  /// Ink on night, where a surface stays dark in either theme (the image
  /// viewer, the crop).
  static const moon = Color(0xFFECEDF5);

  /// Under pictures and video: a step darker than night.
  static const nightDeep = Color(0xFF0B0C11);

  static final light = FColors.neutralLight.copyWith(
    brightness: Brightness.light,
    systemOverlayStyle: SystemUiOverlayStyle.dark,
    barrier: const Color(0x6622243A),
    background: const Color(0xFFF3F4F9), // cloud
    foreground: const Color(0xFF22243A), // ink
    primary: const Color(0xFF5A62DE), // periwinkle, deepened to carry white
    primaryForeground: const Color(0xFFFFFFFF),
    secondary: const Color(0xFFE6E7EF), // sunken
    secondaryForeground: const Color(0xFF22243A),
    muted: const Color(0xFFE6E7EF),
    mutedForeground: const Color(0xFF62657C), // ink-secondary
    destructive: const Color(0xFFC2413B),
    destructiveForeground: const Color(0xFFFFFFFF),
    error: const Color(0xFFC2413B),
    errorForeground: const Color(0xFFFFFFFF),
    card: const Color(0xFFFFFFFF), // raised
    border: const Color(0x1722243A), // hairline
  );

  static final dark = FColors.neutralDark.copyWith(
    brightness: Brightness.dark,
    systemOverlayStyle: SystemUiOverlayStyle.light,
    barrier: const Color(0x99000000),
    background: night,
    foreground: moon,
    primary: periwinkle,
    primaryForeground: night,
    secondary: const Color(0xFF0F1017), // sunken
    secondaryForeground: const Color(0xFFECEDF5),
    muted: const Color(0xFF0F1017),
    mutedForeground: const Color(0xFF9B9EB5),
    destructive: const Color(0xFFF08C84),
    destructiveForeground: night,
    error: const Color(0xFFF08C84),
    errorForeground: night,
    card: const Color(0xFF1E2030), // raised
    border: const Color(0x1AFFFFFF),
  );

  static DuvetTokens tokens(Brightness brightness) =>
      brightness == Brightness.dark ? DuvetTokens.dark : DuvetTokens.light;

  static FThemeData theme(Brightness brightness) {
    final colors = brightness == Brightness.dark ? dark : light;
    final face = FTypeface.inherit(colors: colors, touch: true, fontFamily: DuvetType.family);
    // forui's own widgets read these slots; Duvet code uses [DuvetType] by name.
    final ramp = face.copyWith(
      xs3: DuvetType.tabLabel.copyWith(color: colors.foreground),
      xs2: DuvetType.overline.copyWith(color: colors.foreground),
      xs: DuvetType.caption.copyWith(color: colors.foreground),
      sm: DuvetType.body.copyWith(color: colors.foreground),
      md: DuvetType.navTitle.copyWith(color: colors.foreground, fontWeight: FontWeight.w400),
      lg: DuvetType.title.copyWith(color: colors.foreground, fontWeight: FontWeight.w400),
      xl3: DuvetType.largeTitle.copyWith(color: colors.foreground, fontWeight: FontWeight.w400),
    );
    return FThemeData(
      colors: colors,
      touch: true,
      typography: FTypography(display: ramp, body: ramp),
    );
  }

  /// Material theme with the same colors, so route transitions and other Material
  /// surfaces don't paint the default light palette behind forui screens (the flash).
  static ThemeData material(Brightness brightness) {
    final c = brightness == Brightness.dark ? dark : light;
    return ThemeData(
      brightness: brightness,
      fontFamily: DuvetType.family,
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: c.primary,
        onPrimary: c.primaryForeground,
        secondary: c.secondary,
        onSecondary: c.secondaryForeground,
        error: c.error,
        onError: c.errorForeground,
        surface: c.background,
        onSurface: c.foreground,
      ),
    );
  }
}

/// The Duvet type ramp: one humanist sans in three weights. Headlines set at
/// line-height 1.1, every text style at 1.4. Colors come from the caller.
abstract final class DuvetType {
  static const family = 'Fira Sans';
  static const mono = 'Fira Mono';

  static const _headline = TextStyle(fontFamily: family, height: 1.1, fontWeight: FontWeight.w700);
  static const _text = TextStyle(fontFamily: family, height: 1.4, leadingDistribution: TextLeadingDistribution.even);

  /// Root tab titles: Chats, Spaces, Calls, You.
  static final largeTitle = _headline.copyWith(fontSize: 34, letterSpacing: -0.5);

  /// Sheet titles.
  static final title = _headline.copyWith(fontSize: 20);

  /// Inline top-bar titles.
  static final navTitle = _headline.copyWith(fontSize: 17);

  /// Message text, the composer.
  static final body = _text.copyWith(fontSize: 16, fontWeight: FontWeight.w400);

  /// Row names, read.
  static final rowTitle = _text.copyWith(fontSize: 16, fontWeight: FontWeight.w500);

  /// Row names with unread messages.
  static final rowTitleUnread = _text.copyWith(fontSize: 16, fontWeight: FontWeight.w700);

  /// Button labels, filter options.
  static final label = _text.copyWith(fontSize: 16, fontWeight: FontWeight.w500);

  /// The last-message preview under a row name.
  static final snippet = _text.copyWith(fontSize: 15, fontWeight: FontWeight.w400);

  /// Timestamps, counts, sender names, reply-strip text.
  static final caption = _text.copyWith(fontSize: 13, fontWeight: FontWeight.w400);

  /// Group and category headers, as written: never set in capitals.
  static final overline = _text.copyWith(fontSize: 14, fontWeight: FontWeight.w700);

  /// Tab bar labels.
  static final tabLabel = _text.copyWith(fontSize: 11, fontWeight: FontWeight.w500);

  /// Inline and block code.
  static const code = TextStyle(fontFamily: mono, fontSize: 14, height: 1.4);
}

/// The Duvet tokens forui has no slot for. Its surfaces are made of what its
/// mascot is: a pillow. A raised surface is cushioned (lit along its top
/// edge, resting on a short contact shadow) rather than floated on a long
/// one, and pressing one sinks it into the screen. Each maps 1:1 to a CSS
/// box-shadow, so the web app draws the same material.
class DuvetTokens {
  /// Menus and sheets: one step above the ground.
  final Color popover;

  /// The 1px edge of a popover, where it meets what's under it.
  final Color popoverEdge;
  final Color grabber;

  /// The accent as text or outline: lifted in dark so it reads on night.
  final Color accentText;

  /// The pill behind an active item, the highlight behind a selected row.
  final Color accentTint;
  final Color hairline;

  /// Someone else's message: the mascot's slate at night, a cushion by day.
  final Color received;
  final Color receivedText;

  /// What's alive: someone online, someone speaking. The ice inside the
  /// mascot's ears.
  final Color alive;

  /// The chosen tab, the chosen choice: a slate pill.
  final Color chosen;
  final Color chosenText;

  /// Inset: a raised surface's cushion, a 1px highlight along its top edge.
  /// Drawn by [InsetShadow].
  final List<BoxShadow> cushion;

  /// Inset: the cushion of a surface in the accent, its highlight brighter.
  final List<BoxShadow> cushionAccent;

  /// Under a cushion at rest: where it touches the ground.
  final List<BoxShadow> shadowRest;

  /// Menus and sheets.
  final List<BoxShadow> shadowFloat;

  /// Primary controls at rest: the outer shadow that collapses on press.
  final List<BoxShadow> shadowControl;

  /// Space Cards and other cushions that stand off the ground.
  final List<BoxShadow> shadowRaised;

  /// Inset: a control pushed into the screen. Drawn by [InsetShadow].
  final List<BoxShadow> shadowPressed;

  /// Inset: the resting recess of fields.
  final List<BoxShadow> shadowWell;

  const DuvetTokens._({
    required this.popover,
    required this.popoverEdge,
    required this.grabber,
    required this.accentText,
    required this.accentTint,
    required this.hairline,
    required this.received,
    required this.receivedText,
    required this.alive,
    required this.chosen,
    required this.chosenText,
    required this.cushion,
    required this.cushionAccent,
    required this.shadowRest,
    required this.shadowFloat,
    required this.shadowControl,
    required this.shadowRaised,
    required this.shadowPressed,
    required this.shadowWell,
  });

  static const light = DuvetTokens._(
    popover: Color(0xFFFFFFFF),
    popoverEdge: Color(0x1422243A),
    grabber: Color(0x3322243A),
    accentText: Color(0xFF4C54D2),
    accentTint: Color(0x1A5A62DE),
    hairline: Color(0x1722243A),
    received: Color(0xFFFFFFFF),
    receivedText: Color(0xFF22243A),
    alive: Color(0xFF2A86AB),
    chosen: Color(0xFF22243A),
    chosenText: Color(0xFFFFFFFF),
    cushion: [BoxShadow(color: Color(0xFFFFFFFF), offset: Offset(0, 1))],
    cushionAccent: [BoxShadow(color: Color(0x4DFFFFFF), offset: Offset(0, 1))],
    shadowRest: [BoxShadow(color: Color(0x1F22243A), blurRadius: 2, offset: Offset(0, 1))],
    shadowFloat: [
      BoxShadow(color: Color(0x0F22243A), blurRadius: 8, offset: Offset(0, 4)),
      BoxShadow(color: Color(0x2422243A), blurRadius: 40, offset: Offset(0, 16)),
    ],
    shadowControl: [BoxShadow(color: Color(0x2E3A3FA8), blurRadius: 10, offset: Offset(0, 4))],
    shadowRaised: [
      BoxShadow(color: Color(0x1422243A), blurRadius: 3, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0F22243A), blurRadius: 18, offset: Offset(0, 8)),
    ],
    shadowPressed: [
      BoxShadow(color: Color(0x2E22243A), blurRadius: 6, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x1A22243A), blurRadius: 2, offset: Offset(0, 1)),
    ],
    shadowWell: [BoxShadow(color: Color(0x1422243A), blurRadius: 3, offset: Offset(0, 1))],
  );

  static const dark = DuvetTokens._(
    popover: Color(0xFF262839),
    popoverEdge: Color(0x1FFFFFFF),
    grabber: Color(0x40FFFFFF),
    accentText: Color(0xFFA6ABFF),
    accentTint: Color(0x2E7B83F5),
    hairline: Color(0x1AFFFFFF),
    received: Duvet.slate,
    receivedText: Color(0xFFF2F3F9),
    alive: Duvet.ice,
    chosen: Duvet.slate,
    chosenText: Color(0xFFF2F3F9),
    cushion: [BoxShadow(color: Color(0x0FFFFFFF), offset: Offset(0, 1))],
    cushionAccent: [BoxShadow(color: Color(0x4DFFFFFF), offset: Offset(0, 1))],
    shadowRest: [BoxShadow(color: Color(0x73000000), blurRadius: 2, offset: Offset(0, 1))],
    shadowFloat: [
      BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 4)),
      BoxShadow(color: Color(0x8C000000), blurRadius: 48, offset: Offset(0, 20)),
    ],
    shadowControl: [BoxShadow(color: Color(0x59000000), blurRadius: 10, offset: Offset(0, 4))],
    shadowRaised: [
      BoxShadow(color: Color(0x73000000), blurRadius: 3, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x4D000000), blurRadius: 18, offset: Offset(0, 8)),
    ],
    shadowPressed: [
      BoxShadow(color: Color(0x8C000000), blurRadius: 6, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x59000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
    shadowWell: [BoxShadow(color: Color(0x80000000), blurRadius: 3, offset: Offset(0, 1))],
  );

  static const radiusChip = 10.0;
  static const radiusRow = 12.0;
  static const radiusField = 12.0;
  static const radiusButton = 14.0;
  static const radiusCard = 16.0;
  static const radiusSheet = 24.0;

  /// The bars that float over a screen: the tab bar, the voice bar, the
  /// voice controls' dock.
  static const radiusBar = 20.0;

  /// A message bubble's corners; the one nearest its sender is [radiusBubbleTail].
  static const radiusBubble = 18.0;
  static const radiusBubbleTail = 6.0;

  static const sizeRow = 72.0;
  static const sizeRowCompact = 44.0;
  static const sizeTopBar = 52.0;
  static const sizeTabBar = 60.0;

  /// The tab bar floats this far off the screen's edges.
  static const tabBarInset = 12.0;

  // Motion: presses settle in 120ms and release in 150ms; panels spring in
  // with a ~2% overshoot and decelerate out.
  static const pressIn = Duration(milliseconds: 120);
  static const pressOut = Duration(milliseconds: 150);
  static const tabPill = Duration(milliseconds: 250);
  static const replyStrip = Duration(milliseconds: 250);

  /// The tab pill's spring, damping ≈ 0.9.
  static const pillSpring = Cubic(0.3, 1.18, 0.5, 1);
  static const panelIn = Duration(milliseconds: 320);
  static const dropdownIn = Duration(milliseconds: 280);
  static const panelOut = Duration(milliseconds: 250);
  static const overshoot = Cubic(0.34, 1.12, 0.64, 1);
  static const decelerate = Cubic(0.2, 0.9, 0.3, 1);
}

extension DuvetTokensContext on BuildContext {
  DuvetTokens get duvet => Duvet.tokens(Theme.of(this).brightness);
}
