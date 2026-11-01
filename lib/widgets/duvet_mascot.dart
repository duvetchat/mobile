import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The six moods of the Duvet ghost.
enum MascotState {
  /// Welcome and sign in.
  hello('hello', 'The Duvet ghost waving hello'),

  /// Loading and "someone is typing".
  typing('typing', 'The Duvet ghost typing'),

  /// Privacy, encryption, "only you can see this".
  underDuvet('under_duvet', 'The Duvet ghost tucked in bed under a duvet'),

  /// Empty chats, rooms and search results.
  empty('empty', 'The Duvet ghost looking at an empty message'),

  /// No connection, do not disturb.
  offline('offline', 'The Duvet ghost asleep'),

  /// Failed send, something went wrong.
  oops('oops', 'The Duvet ghost looking surprised');

  const MascotState(this.file, this.label);

  /// Asset file name, without folder or extension.
  final String file;

  /// Default screen-reader description.
  final String label;
}

/// Draws the Duvet ghost in [state], picking the light or dark artwork from
/// the current [Theme]'s brightness. Pass [dark] to force one.
///
/// ```dart
/// const DuvetMascot(MascotState.empty, size: 160)
/// ```
class DuvetMascot extends StatelessWidget {
  const DuvetMascot(
    this.state, {
    super.key,
    this.size = 160,
    this.dark,
    this.semanticLabel,
    this.excludeFromSemantics = false,
  });

  final MascotState state;

  /// Width and height in logical pixels. The art is square.
  final double size;

  /// Forces the dark (`true`) or light (`false`) artwork. Null follows the theme.
  final bool? dark;

  /// Overrides [MascotState.label] for screen readers.
  final String? semanticLabel;

  /// Set when the ghost is decorative and nearby text already says the same.
  final bool excludeFromSemantics;

  static String assetPath(MascotState state, {required bool dark}) =>
      'assets/mascot/${dark ? 'dark' : 'light'}/${state.file}.svg';

  @override
  Widget build(BuildContext context) {
    final isDark = dark ?? Theme.of(context).brightness == Brightness.dark;
    return SvgPicture.asset(
      assetPath(state, dark: isDark),
      width: size,
      height: size,
      semanticsLabel: semanticLabel ?? state.label,
      excludeFromSemantics: excludeFromSemantics,
    );
  }
}
