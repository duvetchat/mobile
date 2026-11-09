import 'package:flex_color_picker/flex_color_picker.dart' show ColorWheelPicker;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../theme.dart';
import 'rows.dart' show DuvetTextField;

/// [text] as an RGB when it's exactly `#RRGGBB`, else null.
int? parseHex(String text) {
  final m = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(text);
  return m == null ? null : int.parse(m[1]!, radix: 16);
}

/// [rgb] as `#30A46C`.
String hexOf(int rgb) => '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// A color: one of [presets], or any other under the Custom swatch, on a hue
/// wheel or typed as `#RRGGBB`. Custom stays open while the pick isn't a preset.
class ColorPick extends StatefulWidget {
  /// An RGB, or null for a null preset.
  final int? value;

  /// The swatches; null for the default or for none.
  final List<int?> presets;

  /// A swatch read aloud.
  final String Function(int? rgb) label;

  /// A swatch's fill, as the color will be seen.
  final Color Function(int? rgb) fill;

  /// On the null swatch.
  final IconData? noneIcon;

  /// Every change, the wheel's as it's dragged too.
  final ValueChanged<int?> onChanged;

  /// A change made: a swatch, a hex code, the wheel let go.
  final ValueChanged<int?>? onChangeEnd;

  const ColorPick({
    required this.value,
    required this.presets,
    required this.label,
    required this.fill,
    required this.onChanged,
    this.noneIcon,
    this.onChangeEnd,
    super.key,
  });

  @override
  State<ColorPick> createState() => _ColorPickState();
}

class _ColorPickState extends State<ColorPick> {
  late final _hex = TextEditingController(text: _text);
  bool _open = false;
  String? _error;
  // The wheel's last color, and whether the value since came from elsewhere:
  // only then is it pushed into the wheel, as its own, sent back, would lose
  // the hue of a grey.
  int? _fromWheel;
  bool _outside = false;

  String get _text => widget.value == null ? '' : hexOf(widget.value!);

  bool get _custom => widget.value != null && !widget.presets.contains(widget.value);

  @override
  void didUpdateWidget(ColorPick oldWidget) {
    super.didUpdateWidget(oldWidget);
    _outside = widget.value != oldWidget.value && widget.value != _fromWheel;
    if (_outside) _fromWheel = null;
    // Unless it's the code being typed.
    if (widget.value != oldWidget.value && parseHex(_hex.text) != widget.value) {
      _hex.text = _text;
      _error = null;
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _pick(int? rgb) {
    widget.onChanged(rgb);
    widget.onChangeEnd?.call(rgb);
  }

  void _typed(String text, {bool done = false}) {
    final rgb = parseHex(text);
    setState(() => _error = rgb == null && (done || text.length >= 7) ? 'Use #RRGGBB, as #30A46C' : null);
    if (rgb != null && rgb != widget.value) _pick(rgb);
  }

  Widget _swatch(String label, bool selected, VoidCallback onTap, Color fill, IconData? icon) {
    final colors = context.theme.colors;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : DuvetTokens.pressOut,
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            border: selected ? Border.all(color: colors.foreground, width: 3) : null,
          ),
          child: icon == null ? null : Icon(icon, size: 18, color: colors.mutedForeground),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final value = widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final rgb in widget.presets)
              _swatch(
                widget.label(rgb),
                value == rgb,
                () {
                  HapticFeedback.selectionClick();
                  _pick(rgb);
                },
                widget.fill(rgb),
                rgb == null ? widget.noneIcon : null,
              ),
            _swatch(
              _custom ? 'Custom color, ${hexOf(value!)}' : 'Custom color',
              _custom,
              () => setState(() => _open = !_open),
              _custom ? widget.fill(value) : colors.secondary,
              _custom ? null : FLucideIcons.pipette,
            ),
          ],
        ),
        if (_open || _custom) ...[
          const SizedBox(height: 16),
          // The hex field is the screen reader's way in.
          ExcludeSemantics(
            child: Center(
              child: SizedBox.square(
                dimension: 200,
                child: ColorWheelPicker(
                  color: value == null ? widget.fill(null) : Color(0xFF000000 | value),
                  shouldUpdate: _outside,
                  onChanged: (c) => widget.onChanged(_fromWheel = c.toARGB32() & 0xFFFFFF),
                  onChangeEnd: (c) => widget.onChangeEnd?.call(c.toARGB32() & 0xFFFFFF),
                  onWheel: (_) {},
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          DuvetTextField(
            label: 'Hex code',
            hint: '#30A46C',
            controller: _hex,
            error: _error,
            maxLength: 7,
            textInputAction: TextInputAction.done,
            onChanged: _typed,
            onSubmitted: (text) => _typed(text, done: true),
          ),
        ],
      ],
    );
  }
}
