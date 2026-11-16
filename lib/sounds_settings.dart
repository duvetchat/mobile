import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'data/sounds.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/rows.dart';

/// The volume of every sound and of each one, as the desktop's Audio settings:
/// 0 to 200%, 0 is off, and a button to hear it or stop it.
class SoundsPage extends StatefulWidget {
  final Sounds sounds;
  const SoundsPage({required this.sounds, super.key});

  @override
  State<SoundsPage> createState() => _SoundsPageState();
}

class _SoundsPageState extends State<SoundsPage> {
  Sounds get sounds => widget.sounds;

  // The desktop's order and names, not the enum's.
  static const _labels = [
    (Sound.mention, 'Notifications'),
    (Sound.voiceJoin, 'Join Voice'),
    (Sound.voiceLeave, 'Leave Voice'),
    (Sound.incomingCall, 'Incoming Call'),
    (Sound.screenShareOn, 'Screen Share On'),
    (Sound.screenShareOff, 'Screen Share Off'),
  ];

  @override
  void dispose() {
    // A preview doesn't outlive the page.
    sounds.stopPreview();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: context.theme.colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListenableBuilder(
              listenable: Listenable.merge([sounds, sounds.previewing]),
              builder: (context, _) => ListView(
                padding: EdgeInsets.only(top: GlassTopBar.heightOf(context) + 16, bottom: padding.bottom + 24),
                children: [
                  _VolumeRow(label: 'Master Volume', value: sounds.master, onChanged: sounds.setMaster),
                  const Overline('Sounds'),
                  for (final (sound, label) in _labels) ...[
                    if (sound != Sound.mention) const SizedBox(height: 12),
                    _VolumeRow(
                      label: label,
                      value: sounds.volume(sound),
                      onChanged: (v) => sounds.setVolume(sound, v),
                      playing: sounds.previewing.value == sound,
                      onPreview: () => sounds.previewing.value == sound ? sounds.stopPreview() : sounds.preview(sound),
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
            child: GlassTopBar(title: const Text('Sounds'), onBack: () => Navigator.of(context).maybePop()),
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

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final shown = value == 0 ? 'Off' : '$value%';
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
                child: Semantics(
                  label: label.endsWith('Volume') ? label : '$label volume',
                  child: Slider(
                    value: value.toDouble(),
                    max: 200,
                    semanticFormatterCallback: (_) => shown,
                    onChanged: (v) => onChanged(v.round()),
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
