import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

/// Duvet design-system color tokens mapped onto forui's [FColors]: the Ghost
/// theme, pastel and celestial in light, near-black (never grey) in dark.
abstract final class Duvet {
  /// Cobalt, for what has to be seen: buttons, Send, unread, the active tab.
  static const accent = Color(0xFF2F4CFF);

  /// Azure, calm enough for big surfaces: your bubbles.
  static const azure = Color(0xFF0B6FE8);

  static final light = FColors.neutralLight.copyWith(
    brightness: Brightness.light,
    systemOverlayStyle: SystemUiOverlayStyle.dark,
    barrier: const Color(0x80000000),
    background: const Color(0xFFF5F7FF), // base
    foreground: const Color(0xFF15172B), // ink
    primary: accent,
    primaryForeground: const Color(0xFFFFFFFF), // on-accent
    secondary: const Color(0xFFEAEFFF), // base-sunken
    secondaryForeground: const Color(0xFF15172B),
    muted: const Color(0xFFEAEFFF),
    mutedForeground: const Color(0xFF5E6380), // ink-secondary
    destructive: const Color(0xFFB0443B),
    destructiveForeground: const Color(0xFFFFFFFF),
    error: const Color(0xFFB0443B),
    errorForeground: const Color(0xFFFFFFFF),
    card: const Color(0xFFFFFFFF), // base-raised
    border: const Color(0x1415172B), // hairline
  );

  static final dark = FColors.neutralDark.copyWith(
    brightness: Brightness.dark,
    systemOverlayStyle: SystemUiOverlayStyle.light,
    barrier: const Color(0x80000000),
    background: const Color(0xFF07070A),
    foreground: const Color(0xFFF1F1F6),
    primary: accent,
    primaryForeground: const Color(0xFFFFFFFF),
    secondary: const Color(0xFF000000),
    secondaryForeground: const Color(0xFFF1F1F6),
    muted: const Color(0xFF000000),
    mutedForeground: const Color(0xFF9396A8),
    destructive: const Color(0xFFE07A70),
    destructiveForeground: const Color(0xFF111113),
    error: const Color(0xFFE07A70),
    errorForeground: const Color(0xFF111113),
    card: const Color(0xFF111116),
    border: const Color(0x12FFFFFF),
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
      md: DuvetType.navTitle.copyWith(color: colors.foreground),
      lg: DuvetType.title.copyWith(color: colors.foreground),
      xl3: DuvetType.largeTitle.copyWith(color: colors.foreground),
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

/// The Duvet type ramp, three faces with three jobs: Fraunces for headers,
/// Inter for the interface, Roboto for what people write. Headlines set at
/// line-height 1.1, every text style at 1.4. Colors come from the caller.
abstract final class DuvetType {
  static const family = 'Inter';
  static const content = 'Roboto';
  static const serif = 'Fraunces';
  static const mono = 'Fira Mono';

  // Fraunces is one variable font whose default instance is Black and wonky:
  // pin the soft Regular cut, at the optical size its size calls for.
  static TextStyle _headline(
    double size, {
    required double opsz,
    FontWeight weight = FontWeight.w400,
    double tracking = -0.01,
  }) => TextStyle(
    fontFamily: serif,
    fontSize: size,
    height: 1.1,
    letterSpacing: size * tracking,
    fontWeight: weight,
    fontVariations: [
      FontVariation('wght', weight.value.toDouble()),
      FontVariation('opsz', opsz),
      const FontVariation('SOFT', 50),
      const FontVariation('WONK', 0),
    ],
  );
  static const _text = TextStyle(fontFamily: family, height: 1.4, leadingDistribution: TextLeadingDistribution.even);

  /// Root tab titles: Chats, Spaces, Calls, You.
  static final largeTitle = _headline(36, opsz: 144, tracking: -0.02);

  /// Sheet titles.
  static final title = _headline(22, opsz: 72);

  /// Inline top-bar titles.
  static final navTitle = _headline(20, opsz: 36, weight: FontWeight.w500);

  /// Message text, the composer.
  static final body = _text.copyWith(fontFamily: content, fontSize: 16, fontWeight: FontWeight.w400);

  /// Row names, read.
  static final rowTitle = _text.copyWith(fontSize: 16, fontWeight: FontWeight.w500);

  /// Row names with unread messages.
  static final rowTitleUnread = _text.copyWith(fontSize: 16, fontWeight: FontWeight.w700);

  /// Button labels, filter options.
  static final label = _text.copyWith(fontSize: 16, fontWeight: FontWeight.w500);

  /// The last-message preview under a row name.
  static final snippet = _text.copyWith(fontFamily: content, fontSize: 15, fontWeight: FontWeight.w400);

  /// Timestamps, counts, sender names, reply-strip text.
  static final caption = _text.copyWith(fontSize: 13, fontWeight: FontWeight.w400);

  /// Category headers; callers set the text in uppercase.
  static final overline = _text.copyWith(fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.72);

  /// Tab bar labels.
  static final tabLabel = _text.copyWith(fontSize: 11, fontWeight: FontWeight.w500);

  /// Inline and block code.
  static const code = TextStyle(fontFamily: mono, fontSize: 14, height: 1.4);
}

/// The Duvet design-system tokens forui has no slot for: Liquid Glass, the
/// accent as text, shadows, radii and motion.
class DuvetTokens {
  /// Liquid Glass fill (78–80%), always over a backdrop blur.
  final Color glass;

  /// The 1px edge that catches the light on glass.
  final Color glassEdge;
  final Color grabber;

  /// The accent as text or outline: lifted in dark so it reads on near-black.
  final Color accentText;

  /// The pill behind an active item, the highlight behind a selected row.
  final Color accentTint;

  /// The tab bar's pill: azure, calm on the glass.
  final Color azureTint;

  /// Violet for small accents: @mentions, your reactions, selected chips.
  final Color violetText;

  /// Selected chips and toggles: a solid violet fill under [violetText], never an outline.
  final Color selectedFill;

  /// Secondary buttons and unchecked boxes: solid, so they read the same on glass.
  final Color secondaryFill;
  final Color hairline;

  /// Green for what is live: a call going on, someone online.
  final Color live;

  /// Received bubbles and other surfaces at rest.
  final List<BoxShadow> shadowRest;

  /// Glass panels: dropdowns and sheets.
  final List<BoxShadow> shadowFloat;

  /// Primary controls at rest: the outer shadow that collapses on press.
  final List<BoxShadow> shadowControl;

  /// Space Cards at rest.
  final List<BoxShadow> shadowRaised;

  /// Inset: a control pushed into the screen. Drawn by [InsetShadow].
  final List<BoxShadow> shadowPressed;

  /// Inset: the resting recess of fields.
  final List<BoxShadow> shadowWell;

  const DuvetTokens._({
    required this.glass,
    required this.glassEdge,
    required this.grabber,
    required this.accentText,
    required this.accentTint,
    required this.azureTint,
    required this.violetText,
    required this.selectedFill,
    required this.secondaryFill,
    required this.hairline,
    required this.live,
    required this.shadowRest,
    required this.shadowFloat,
    required this.shadowControl,
    required this.shadowRaised,
    required this.shadowPressed,
    required this.shadowWell,
  });

  static const light = DuvetTokens._(
    glass: Color(0xC7F5F7FF),
    glassEdge: Color(0x0F15172B),
    grabber: Color(0x2E15172B),
    accentText: Duvet.accent,
    accentTint: Color(0x1A2F4CFF),
    azureTint: Color(0x1F1C8CFF),
    violetText: Color(0xFF6A58D6),
    selectedFill: Color(0xFFF0EDFF),
    secondaryFill: Color(0xFFE3E9FF),
    hairline: Color(0x1415172B),
    live: Color(0xFF2F9E62),
    // Light shadows carry a little cobalt, so surfaces float on the pastel sky.
    shadowRest: [
      BoxShadow(color: Color(0x0A15172B), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0F2F4CFF), blurRadius: 12, offset: Offset(0, 4)),
    ],
    shadowFloat: [
      BoxShadow(color: Color(0x0A15172B), blurRadius: 8, offset: Offset(0, 4)),
      BoxShadow(color: Color(0x1F2F4CFF), blurRadius: 56, offset: Offset(0, 24)),
    ],
    shadowControl: [
      BoxShadow(color: Color(0x0F15172B), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x142F4CFF), blurRadius: 16, offset: Offset(0, 6)),
    ],
    shadowRaised: [
      BoxShadow(color: Color(0x0A15172B), blurRadius: 4, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x142F4CFF), blurRadius: 32, offset: Offset(0, 12)),
    ],
    shadowPressed: [
      BoxShadow(color: Color(0x2415172B), blurRadius: 6, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x1415172B), blurRadius: 2, offset: Offset(0, 1)),
    ],
    shadowWell: [BoxShadow(color: Color(0x0F15172B), blurRadius: 3, offset: Offset(0, 1))],
  );

  static const dark = DuvetTokens._(
    glass: Color(0xCC111116),
    glassEdge: Color(0x14FFFFFF),
    grabber: Color(0x38FFFFFF),
    accentText: Color(0xFF8C9BFF),
    accentTint: Color(0x248C9BFF),
    azureTint: Color(0x245CB2FF),
    violetText: Color(0xFFB3A6FF),
    selectedFill: Color(0xFF231E3D),
    secondaryFill: Color(0xFF1C1E2E),
    hairline: Color(0x12FFFFFF),
    live: Color(0xFF4CC38A),
    shadowRest: [
      BoxShadow(color: Color(0x4D000000), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x40000000), blurRadius: 12, offset: Offset(0, 4)),
    ],
    shadowFloat: [
      BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 4)),
      BoxShadow(color: Color(0x8C000000), blurRadius: 56, offset: Offset(0, 24)),
    ],
    shadowControl: [
      BoxShadow(color: Color(0x59000000), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x59000000), blurRadius: 16, offset: Offset(0, 6)),
    ],
    shadowRaised: [
      BoxShadow(color: Color(0x59000000), blurRadius: 4, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x66000000), blurRadius: 32, offset: Offset(0, 12)),
    ],
    shadowPressed: [
      BoxShadow(color: Color(0x73000000), blurRadius: 6, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x4D000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
    shadowWell: [BoxShadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1))],
  );

  // Backdrop blur: bars, and overlays (dropdowns, sheets).
  static const blurChrome = 20.0;
  static const blurGlass = 32.0;

  static const radiusChip = 8.0;
  static const radiusField = 12.0;
  static const radiusButton = 16.0;
  static const radiusCard = 20.0;
  static const radiusSheet = 24.0;

  static const sizeRow = 72.0;
  static const sizeRowCompact = 44.0;
  static const sizeTopBar = 52.0;
  static const sizeTabBar = 56.0;

  // Over video and photos, the same in light and dark: ink for text and icons,
  // and the play mark's scrim and its edge.
  static const mediaInk = Color(0xFFF2F1EE);
  static const mediaScrim = Color(0x8C111113);
  static const mediaScrimEdge = Color(0x1FFFFFFF);

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
