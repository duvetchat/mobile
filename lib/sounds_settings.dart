import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/sounds.dart';
import 'data/voice_prefs.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/rows.dart';

/// Audio, as the desktop's section (#284): the volume of every sound and of
/// each one, 0 to 200%, 0 is off, with a button to hear it or stop it; then
/// the microphone's noise suppression, which the desktop has with its voice
/// controls.
class AudioPage extends StatefulWidget {
  final Sounds? sounds;
  final VoicePrefs? prefs;
  const AudioPage({this.sounds, this.prefs, super.key});

  @override
  State<AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends State<AudioPage> {
  // The desktop's order and names, not the enum's.
  static const _labels = [
    (Sound.mention, 'Notifications'),
    (Sound.voiceJoin, 'Join voice'),
    (Sound.voiceLeave, 'Leave voice'),
    (Sound.incomingCall, 'Incoming call'),
    (Sound.screenShareOn, 'Screen share on'),
    (Sound.screenShareOff, 'Screen share off'),
  ];

  @override
  void dispose() {
    // A preview doesn't outlive the page.
    widget.sounds?.stopPreview();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final colors = context.theme.colors;
    final sounds = widget.sounds;
    final prefs = widget.prefs;
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListenableBuilder(
              listenable: Listenable.merge([sounds, sounds?.previewing, prefs]),
              builder: (context, _) => ListView(
                padding: EdgeInsets.only(top: GlassTopBar.heightOf(context), bottom: padding.bottom + 24),
                children: [
                  if (sounds != null) ...[
                    const Overline('All sounds'),
                    _VolumeRow(label: 'Master volume', value: sounds.master, onChanged: sounds.setMaster),
                    const Overline('Each sound'),
                    for (final (sound, label) in _labels) ...[
                      if (sound != Sound.mention) const SizedBox(height: 12),
                      _VolumeRow(
                        label: label,
                        value: sounds.volume(sound),
                        onChanged: (v) => sounds.setVolume(sound, v),
                        playing: sounds.previewing.value == sound,
                        onPreview: () =>
                            sounds.previewing.value == sound ? sounds.stopPreview() : sounds.preview(sound),
                      ),
                    ],
                  ],
                  if (prefs != null) ...[
                    const Overline('Voice'),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: colors.card,
                        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                        boxShadow: context.duvet.shadowRest,
                      ),
                      child: SettingToggle(
                        label: 'Noise suppression',
                        detail: 'Filters background noise from your microphone',
                        value: prefs.noiseSuppression,
                        onChanged: prefs.setNoiseSuppression,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(title: const Text('Audio'), onBack: () => Navigator.of(context).maybePop()),
          ),
        ],
      ),
    ).readable;
  }
}

/// A card: the name and its volume over a 0–200 slider, and Play (Pause while [playing]) when there is one sound to hear.
class _VolumeRow extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final VoidCallback? onPreview;
  final bool playing;
  const _VolumeRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.onPreview,
    this.playing = false,
  });

  static const _step = 10;
  static int _stepped(int value) => value.clamp(0, 200);
  static String _spoken(int value) => _stepped(value) == 0 ? 'Off' : '${_stepped(value)}%';

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final shown = _spoken(value);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
        boxShadow: context.duvet.shadowRest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Expanded(
                    child: Text(label, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                  ),
                  Text(
                    shown,
                    style: DuvetType.caption.copyWith(
                      color: colors.mutedForeground,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                // The slider's own semantics are left out: on iOS (Flutter 3.50) they empty the whole app's
                // accessibility tree, which stays empty after the page closes. VoiceOver and TalkBack get the
                // same adjustable control from here, in steps of 10%.
                child: Semantics(
                  label: label.endsWith('volume') ? label : '$label volume',
                  value: shown,
                  increasedValue: value < 200 ? _spoken(value + _step) : null,
                  decreasedValue: value > 0 ? _spoken(value - _step) : null,
                  onIncrease: value < 200 ? () => onChanged(_stepped(value + _step)) : null,
                  onDecrease: value > 0 ? () => onChanged(_stepped(value - _step)) : null,
                  child: ExcludeSemantics(
                    child: Slider(value: value.toDouble(), max: 200, onChanged: (v) => onChanged(v.round())),
                  ),
                ),
              ),
              if (onPreview != null)
                IconAction(
                  icon: playing ? FLucideIcons.pause : FLucideIcons.play,
                  label: '${playing ? 'Pause' : 'Play'} $label',
                  onPressed: onPreview,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
