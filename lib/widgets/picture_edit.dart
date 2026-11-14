import 'dart:io';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:image_picker/image_picker.dart';

import '../data/images.dart';
import 'glass.dart';

/// Takes a picture with the camera, for an icon, an avatar or a banner.
/// Tests swap in their own.
Future<String?> Function() takePhoto = () async => (await ImagePicker().pickImage(source: ImageSource.camera))?.path;

enum PictureChoice { choose, take, remove }

/// The one sheet a Space's icon, a bot's picture, a profile photo and any
/// banner open: Choose photo, Take photo, and [remove] (its label) when there
/// is one to take away.
Future<PictureChoice?> showPictureSheet(BuildContext context, {required String title, String? remove}) =>
    showGlassDialogSheet<PictureChoice>(
      context,
      label: title,
      builder: (context) {
        Widget row(IconData icon, String label, PictureChoice choice, {bool destructive = false}) => GlassRow(
          icon: icon,
          label: label,
          destructive: destructive,
          onPressed: () => Navigator.of(context).pop(choice),
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitle(title: title),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  children: [
                    row(FLucideIcons.image, 'Choose photo', PictureChoice.choose),
                    row(FLucideIcons.camera, 'Take photo', PictureChoice.take),
                    if (remove != null) row(FLucideIcons.trash2, remove, PictureChoice.remove, destructive: true),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

/// A picture's row in an Appearance panel: its name, "Change or remove" or
/// "Not set", and [thumb] at its end, as it will be once saved.
class PictureRow extends StatelessWidget {
  final String label;
  final bool set;
  final Widget thumb;
  final VoidCallback onPressed;
  const PictureRow({required this.label, required this.set, required this.thumb, required this.onPressed, super.key});

  @override
  Widget build(BuildContext context) => GlassRow(
    label: label,
    detail: set ? 'Change or remove' : 'Not set',
    onPressed: onPressed,
    trailing: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          thumb,
          const SizedBox(width: 12),
          Icon(FLucideIcons.chevronRight, size: 24, color: context.theme.colors.mutedForeground),
        ],
      ),
    ),
  );
}

/// A picture's thumbnail: [picture] (a file just cropped, or a URL) covering
/// [width] by [height], or [empty] on `base-sunken` when there's none.
class PictureThumb extends StatelessWidget {
  final String? picture;
  final double width;
  final double height;
  final BorderRadius radius;
  final Widget empty;
  const PictureThumb({
    required this.picture,
    required this.width,
    required this.height,
    required this.radius,
    required this.empty,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final none = ColoredBox(
      color: context.theme.colors.secondary,
      child: Center(child: empty),
    );
    Widget failed(BuildContext context, Object error, StackTrace? stackTrace) => none;
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round();
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: width,
          height: height,
          child: switch (picture) {
            null => none,
            final p when p.startsWith('http') => Image(
              image: cachedImage(p, cacheWidth: cacheWidth),
              fit: BoxFit.cover,
              errorBuilder: failed,
            ),
            final p => Image.file(File(p), fit: BoxFit.cover, cacheWidth: cacheWidth, errorBuilder: failed),
          },
        ),
      ),
    );
  }
}
