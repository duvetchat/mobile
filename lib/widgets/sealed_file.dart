import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../e2e/conventions.dart' show sniffType, waveformSamples;
import '../e2e/decrypted_files.dart';
import '../e2e/files.dart';
import '../e2e/notices.dart';
import '../theme.dart';
import 'media.dart';
import 'media_actions.dart';
import 'message_content.dart' show openImageViewer;

/// A file of an encrypted conversation's message (PLAN-E2E-CLIENTES.md, «Adjuntos»), drawn from its decrypted copy
/// (lib/e2e/decrypted_files.dart) by its bytes' own type, never its sender's: a picture in an Image, a video in the
/// player once it came down whole after the tap that asked for it, an audio file and a voice note in today's players.
/// Anything else is a card that saves its copy as bytes or shares it, and nothing opens it (Review Focus 6); so is a
/// picture or a video the phone doesn't draw (task 18's review, rule 10). Its thumbnail shows while it comes. What its
/// sender said of it (its type, its size) only lays it out.
class SealedFileView extends StatefulWidget {
  const SealedFileView({
    required this.attachment,
    required this.messageId,
    this.width = 260,
    this.voice = false,
    this.mine = false,
    this.authorName = '',
    this.authorAvatarUrl,
    super.key,
  });

  /// A file whose [MessageAttachment.sealed] is set.
  final MessageAttachment attachment;
  final String messageId;
  final double width;

  /// Its message is a voice note: it plays as one.
  final bool voice;
  final bool mine;
  final String authorName;
  final String? authorAvatarUrl;

  @override
  State<SealedFileView> createState() => _SealedFileViewState();
}

class _SealedFileViewState extends State<SealedFileView> {
  /// The tap that asked for a video: it plays once it's here, and only then (task 18's review, M2).
  var _asked = false;
  var _revealed = false;

  ShownFile get _file => widget.attachment.sealed!;
  String get _url => widget.attachment.url;
  DecryptedFiles get _files => DecryptedFiles.instance;

  /// Laid out as its sender says; drawn as its bytes say.
  String get _said => _file.said;
  bool get _picture => !widget.voice && _said.startsWith('image/');
  bool get _video => !widget.voice && _said.startsWith('video/');
  bool get _spoiler => widget.attachment.isSpoiler && !_revealed;

  @override
  void initState() {
    super.initState();
    _files.addListener(_changed);
    // Pictures, audio and voice notes come as they show (a lazy list builds them as they near the screen); a video
    // and a file to save on a tap.
    if (widget.voice || _picture || _said.startsWith('audio/')) _open(auto: true);
    if (_file.thumbnailRef case final ref?) {
      final url = widget.attachment.thumbnailUrl;
      if (url != null) unawaited(_files.open(ref, url, widget.messageId, auto: true));
    }
  }

  @override
  void dispose() {
    _files.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final state = _files.state(_file, _url);
    // The video asked for is here: it plays, once.
    if (_asked && state is FileReady && drawnBy(state.type) == DrawnIn.video) {
      _asked = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _play(state);
      });
    }
  }

  void _open({required bool auto}) => unawaited(_files.open(_file, _url, widget.messageId, auto: auto));

  void _play(FileReady ready) => openVideo(
    context,
    MessageAttachment(
      id: widget.attachment.id,
      filename: _file.name,
      contentType: ready.type,
      url: Uri.file(ready.path).toString(),
      width: _file.width,
      height: _file.height,
      local: true,
    ),
    onSave: () => _save(ready),
  );

  /// The type a copy goes out with: its own when the app draws it, bytes otherwise, so nothing opens it as what it
  /// says it is.
  String _typeOut(FileReady ready) => drawnBy(ready.type) == DrawnIn.save ? 'application/octet-stream' : ready.type;

  Future<void> _save(FileReady ready) async {
    try {
      final saved = await MediaActions.instance.saveFile(ready.path, _file.name, _typeOut(ready));
      if (saved) _toast('Saved ${_file.name}');
    } catch (_) {
      _toast('Couldn’t save the file');
    }
  }

  Future<void> _share(FileReady ready) async {
    try {
      await MediaActions.instance.shareFile(ready.path, _file.name, _typeOut(ready));
    } catch (_) {
      _toast('Couldn’t share the file');
    }
  }

  void _toast(String text) {
    if (mounted) showFToast(context: context, title: Text(text), duration: const Duration(seconds: 3));
  }

  /// Its thumbnail while it comes, when its message has one that reads as a JPEG or a PNG: inside the message, or a
  /// file of its own, opened as any file is.
  Widget? _thumbnail() {
    if (_file.thumbnail case final inside?) {
      final bytes = base64Decode(inside);
      if (!const {'image/jpeg', 'image/png'}.contains(sniffType(bytes))) return null;
      return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, excludeFromSemantics: true);
    }
    final (ref, url) = (_file.thumbnailRef, widget.attachment.thumbnailUrl);
    if (ref == null || url == null) return null;
    return switch (_files.state(ref, url)) {
      final FileReady ready when const {'image/jpeg', 'image/png'}.contains(ready.type) => Image.file(
        File(ready.path),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        excludeFromSemantics: true,
      ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = _files.state(_file, _url);
    final ready = state is FileReady ? state : null;
    final drawn = ready == null ? null : drawnBy(ready.type);
    if (widget.voice && ready != null && drawn == DrawnIn.audio) {
      return VoiceNotePlayer(
        attachment: _local(ready),
        mine: widget.mine,
        authorName: widget.authorName,
        authorAvatarUrl: widget.authorAvatarUrl,
        bars: _bars(),
      );
    }
    if (!widget.voice && _said.startsWith('audio/') && ready != null && drawn == DrawnIn.audio) {
      return AudioFileTile(attachment: _local(ready));
    }
    if (_picture && ready != null && drawn == DrawnIn.image) return _pictureOf(ready);
    if (_video && state is! FileFailed && (ready == null || drawn == DrawnIn.video)) return _videoTile(state);
    return _card(state);
  }

  /// Its copy, as a player takes a file of this device's.
  MessageAttachment _local(FileReady ready) => MessageAttachment(
    id: widget.attachment.id,
    filename: _file.name,
    contentType: ready.type,
    url: Uri.file(ready.path).toString(),
    sizeBytes: ready.size,
    local: true,
  );

  /// A voice note's bars from the waveform its message carries, 30 of them as today's player draws.
  List<double>? _bars() {
    final peaks = _file.waveform == null ? null : base64Decode(_file.waveform!);
    if (peaks == null || peaks.length != waveformSamples) return null;
    return [
      for (var i = 0; i < 30; i++)
        math.max(0.08, peaks.sublist(i * peaks.length ~/ 30, (i + 1) * peaks.length ~/ 30).fold(0, math.max) / 255),
    ];
  }

  ({double width, double height}) _box() {
    final (w, h) = (_file.width ?? 0, _file.height ?? 0);
    final ratio = w <= 0 || h <= 0 ? 248 / 168 : w / h;
    final height = math.min(widget.width / ratio, 320.0);
    return (width: math.min(widget.width, height * ratio), height: height);
  }

  Widget _pictureOf(FileReady ready) {
    final box = _box();
    final colors = context.theme.colors;
    final copy = MessageAttachment(
      id: widget.attachment.id,
      filename: _file.name,
      contentType: ready.type,
      url: ready.path,
      width: _file.width,
      height: _file.height,
      sizeBytes: ready.size,
      local: true,
    );
    return Semantics(
      container: true,
      image: true,
      button: true,
      label: _spoiler ? 'Spoiler, Photo, ${_file.name}' : 'Photo, ${_file.name}',
      excludeSemantics: true,
      onTap: _spoiler ? () => setState(() => _revealed = true) : () => openImageViewer(context, [copy]),
      child: GestureDetector(
        onTap: _spoiler ? () => setState(() => _revealed = true) : () => openImageViewer(context, [copy]),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
          child: Container(
            width: box.width,
            height: box.height,
            color: colors.secondary,
            child: ImageFiltered(
              enabled: _spoiler,
              imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24, tileMode: TileMode.decal),
              child: Image.file(
                File(ready.path),
                fit: BoxFit.cover,
                cacheWidth: math.max(1, (box.width * MediaQuery.devicePixelRatioOf(context)).round()),
                // A picture this phone doesn't decode (an AVIF before Android 12, say) is a file to save.
                errorBuilder: (_, _, _) => _card(ready),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _videoTile(FileState? state) {
    final box = _box();
    final loading = state is FileLoading ? state : null;
    final ready = state is FileReady ? state : null;
    final label = loading != null
        ? '${Notice.fileProgress.fill({'percent': '${(loading.progress * 100).floor()}'})}, ${_file.name}'
        : 'Video, ${_file.name}. ${Notice.filePlay.text}';
    void tap() {
      if (_spoiler) return setState(() => _revealed = true);
      if (ready != null) return _play(ready);
      setState(() => _asked = true);
      _open(auto: false);
    }

    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: tap,
      child: GestureDetector(
        onTap: tap,
        child: Container(
          width: box.width,
          height: box.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: videoBackdrop,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                enabled: _spoiler,
                imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24, tileMode: TileMode.decal),
                child: _thumbnail() ?? const SizedBox.shrink(),
              ),
              const Center(child: PlayMark()),
              if (loading != null)
                Positioned(left: 12, right: 12, bottom: 12, child: _Progress(share: loading.progress, onMedia: true)),
            ],
          ),
        ),
      ),
    );
  }

  /// A file as a card: its name and size, how far it came, why it isn't shown, or Save and Share once it's here.
  Widget _card(FileState? state) {
    final colors = context.theme.colors;
    final ready = state is FileReady ? state : null;
    final failed = state is FileFailed ? state : null;
    // Only a download that failed asks again: other bytes, too many, or none the core opens are final.
    final again = failed?.reason == FileFailure.download;
    final status = switch (state) {
      FileFailed(reason: FileFailure.hash) => Notice.fileAltered.text,
      FileFailed(reason: FileFailure.download) => Notice.fileDownloadFailed.text,
      FileFailed() => Notice.fileUnavailable.text,
      FileLoading(:final progress) => Notice.fileProgress.fill({'percent': '${(progress * 100).floor()}'}),
      FileReady() => _size(ready!.size),
      _ => _size(_file.size),
    };
    void tap() {
      if (ready != null || (failed != null && !again)) return;
      _open(auto: false);
    }

    return Semantics(
      container: true,
      button: ready == null && (failed == null || again),
      label: Notice.fileNamed.fill({'name': _file.name, 'status': status}),
      onTap: ready == null && (failed == null || again) ? tap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap,
        child: Container(
          width: widget.width,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
            boxShadow: context.duvet.shadowRest,
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  failed != null ? FLucideIcons.fileX : FLucideIcons.fileLock,
                  size: 24,
                  color: failed != null ? colors.destructive : colors.foreground,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DuvetType.rowTitle.copyWith(fontSize: 15, color: colors.foreground),
                      ),
                      const SizedBox(height: 2),
                      if (state is FileLoading)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _Progress(share: state.progress, onMedia: false),
                        )
                      else
                        Text(status, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                    ],
                  ),
                ),
              ),
              if (ready != null) ...[
                _Action(
                  icon: FLucideIcons.download,
                  label: Notice.fileSaveNamed.fill({'name': _file.name}),
                  onTap: () => _save(ready),
                ),
                _Action(icon: FLucideIcons.share2, label: 'Share ${_file.name}', onTap: () => _share(ready)),
              ] else if (state == null || state is FileGone || again)
                ExcludeSemantics(child: Icon(FLucideIcons.download, size: 20, color: colors.mutedForeground)),
            ],
          ),
        ),
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// How far a file came: «Downloading · N%» over its bar.
class _Progress extends StatelessWidget {
  const _Progress({required this.share, required this.onMedia});
  final double share;

  /// Over a video's poster: the media's ink.
  final bool onMedia;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final ink = onMedia ? DuvetTokens.mediaInk : colors.mutedForeground;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          Notice.fileProgress.fill({'percent': '${(share * 100).floor()}'}),
          style: DuvetType.caption.copyWith(color: ink, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: share.clamp(0, 1),
            minHeight: 4,
            color: onMedia ? DuvetTokens.mediaInk : colors.foreground,
            backgroundColor: onMedia ? const Color(0x3DFFFFFF) : colors.secondary,
          ),
        ),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox.square(dimension: 40, child: Icon(icon, size: 20, color: context.theme.colors.foreground)),
    ),
  );
}
