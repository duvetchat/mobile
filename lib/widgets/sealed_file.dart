import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../e2e/conventions.dart' show sniffPrefix, thumbnailDrawn, waveformSamples;
import '../e2e/decrypted_files.dart';
import '../e2e/files.dart';
import '../e2e/notices.dart';
import '../theme.dart';
import 'media.dart';
import 'media_actions.dart';
import 'message_content.dart' show openImageViewer;

/// The least side of a picture's or a video's box: a tap's room, as the desktop's (48 px).
const _leastSide = 48.0;

/// A file of an encrypted conversation's message (PLAN-E2E-CLIENTES.md, «Adjuntos»), drawn from its decrypted copy
/// (lib/e2e/decrypted_files.dart) by its bytes' own type, never its sender's: a picture in an Image, a video in the
/// player once it came down whole after the tap that asked for it, an audio file and a voice note in today's players.
/// Anything else is a card that saves its copy as bytes or shares it, and nothing opens it (Review Focus 6); so is a
/// picture, a video or a sound the phone doesn't draw or play (task 18's review, rule 10). A picture's box shows its
/// thumbnail while it comes. What its sender said of it (its type, its size) only lays it out.
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

  /// The player, which says what the phone couldn't play.
  final _playback = AudioPlayback.instance;

  /// Laid out as its sender says; drawn as its bytes say.
  String get _said => _file.said;
  bool get _picture => !widget.voice && _said.startsWith('image/');
  bool get _video => !widget.voice && _said.startsWith('video/');
  bool get _spoiler => widget.attachment.isSpoiler && !_revealed;

  @override
  void initState() {
    super.initState();
    _files.addListener(_changed);
    _playback.failed.addListener(_changed);
    // Pictures, audio and voice notes come as they show (a lazy list builds them as they near the screen); a video
    // and a file to save on a tap.
    if (widget.voice || _picture || _said.startsWith('audio/')) _open(auto: true);
    // A thumbnail of its own only for what draws one: no other file shows it (mobile#356).
    if (_file.thumbnailRef case final ref? when _picture || _video) {
      final url = widget.attachment.thumbnailUrl;
      if (url != null) unawaited(_files.open(ref, url, widget.messageId, auto: true));
    }
  }

  @override
  void dispose() {
    _files.removeListener(_changed);
    _playback.failed.removeListener(_changed);
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
      // From a copy under its cleaned name, as the folder's are named by a hash (task 19's review, M1).
      final copy = await _files.aside('share', _file.name, from: ready.path);
      await MediaActions.instance.shareFile(copy.path, _file.name, _typeOut(ready));
    } catch (_) {
      _toast('Couldn’t share the file');
    }
  }

  void _toast(String text) {
    if (mounted) showFToast(context: context, title: Text(text), duration: const Duration(seconds: 3));
  }

  /// Its thumbnail while it comes, [width] wide, when its message has one the conventions draw (a JPEG or a PNG of
  /// 320 px a side at most): inside the message, or a file of its own, opened as any file is.
  Widget? _thumbnail(double width) {
    if (_file.thumbnail case final inside?) {
      final bytes = base64Decode(inside);
      return thumbnailDrawn(bytes) ? _Thumbnail.memory(bytes, width: width) : null;
    }
    final (ref, url) = (_file.thumbnailRef, widget.attachment.thumbnailUrl);
    if (ref == null || url == null) return null;
    return switch (_files.state(ref, url)) {
      final FileReady ready => _Thumbnail.file(ready.path, width: width, key: ValueKey(ready.path)),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = _files.state(_file, _url);
    final ready = state is FileReady ? state : null;
    final drawn = ready == null ? null : drawnBy(ready.type);
    // A sound the phone couldn't play is a file to save (task 19's review, M3).
    final plays = drawn == DrawnIn.audio && _playback.failed.value != widget.attachment.id;
    if (widget.voice && ready != null && plays) {
      return VoiceNotePlayer(
        attachment: _local(ready),
        mine: widget.mine,
        authorName: widget.authorName,
        authorAvatarUrl: widget.authorAvatarUrl,
        bars: _bars(),
      );
    }
    if (!widget.voice && _said.startsWith('audio/') && ready != null && plays) {
      return AudioFileTile(attachment: _local(ready), trailing: _saveAndShare(ready));
    }
    if (_picture && ready != null && drawn == DrawnIn.image) return _pictureOf(ready);
    if (_picture && (state == null || state is FileLoading || state is FileGone)) return _pictureBox(state);
    if (_video && state is! FileFailed && (ready == null || drawn == DrawnIn.video)) return _videoTile(state);
    return _card(state);
  }

  /// Its copy, as a player takes a file of this device's: a decrypted one, whose name the media session never gets.
  MessageAttachment _local(FileReady ready) => MessageAttachment(
    id: widget.attachment.id,
    filename: _file.name,
    contentType: ready.type,
    url: Uri.file(ready.path).toString(),
    sizeBytes: ready.size,
    local: true,
    sealed: _file,
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

  /// A picture's or a video's box, inside [SealedFileView.width] × 320 with its shape. It's drawn from what its sender
  /// says of it before its bytes are here, any sides from 1 to 65535: never thinner than a tap's room, so it shows and
  /// takes a tap (mobile#356).
  ({double width, double height}) _box() {
    final (w, h) = (_file.width ?? 0, _file.height ?? 0);
    final ratio = w <= 0 || h <= 0 ? 248 / 168 : w / h;
    final height = math.min(widget.width / ratio, 320.0);
    double side(double value, double most) => math.min(most, math.max(_leastSide, value));
    return (width: side(math.min(widget.width, height * ratio), widget.width), height: side(height, 320));
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
      // A decrypted copy: the viewer saves and shares it, with no link (task 19's review, M1 and M8).
      sealed: _file,
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

  /// A picture not drawn yet, on its way or let go of for room: its box, as large as the picture will be, with its
  /// thumbnail (blurred under a spoiler), how far it came, or a tap that asks for it (task 19's review, Missing 2).
  Widget _pictureBox(FileState? state) {
    final box = _box();
    final loading = state is FileLoading ? state : null;
    final asks = _spoiler || loading == null;
    final label = _spoiler
        ? 'Spoiler, Photo, ${_file.name}'
        : loading != null
        ? '${Notice.fileProgress.fill({'percent': '${(loading.progress * 100).floor()}'})}, ${_file.name}'
        : 'Photo, ${_file.name}. ${Notice.fileShow.text}';
    void tap() {
      if (_spoiler) return setState(() => _revealed = true);
      if (loading == null) _open(auto: false);
    }

    return Semantics(
      container: true,
      image: true,
      button: asks,
      label: label,
      excludeSemantics: true,
      onTap: asks ? tap : null,
      child: GestureDetector(
        onTap: tap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
          child: Container(
            width: box.width,
            height: box.height,
            color: context.theme.colors.secondary,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ImageFiltered(
                  enabled: _spoiler,
                  imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24, tileMode: TileMode.decal),
                  child: _thumbnail(box.width) ?? const SizedBox.shrink(),
                ),
                if (loading != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: DuvetTokens.mediaScrim,
                        borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: _Progress(share: loading.progress, onMedia: true),
                      ),
                    ),
                  )
                else if (!_spoiler)
                  const Center(child: PlayMark(icon: FLucideIcons.image)),
              ],
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
                child: _thumbnail(box.width) ?? const SizedBox.shrink(),
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
              if (ready != null)
                _saveAndShare(ready)
              else if (state == null || state is FileGone || again)
                ExcludeSemantics(child: Icon(FLucideIcons.download, size: 20, color: colors.mutedForeground)),
            ],
          ),
        ),
      ),
    );
  }

  /// Save and Share of its copy.
  Widget _saveAndShare(FileReady ready) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _Action(
        icon: FLucideIcons.download,
        label: Notice.fileSaveNamed.fill({'name': _file.name}),
        onTap: () => _save(ready),
      ),
      _Action(icon: FLucideIcons.share2, label: 'Share ${_file.name}', onTap: () => _share(ready)),
    ],
  );

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// A thumbnail decoded at its box's size, [width] wide: one inside its message, which the conventions checked, or one
/// of its own, drawn once its copy's header says it's 320 px a side at most (thumbnailDrawn: a sender's header can
/// claim any size, task 19's review, I3).
class _Thumbnail extends StatefulWidget {
  const _Thumbnail.memory(Uint8List this.bytes, {required this.width}) : path = null;
  const _Thumbnail.file(String this.path, {required this.width, super.key}) : bytes = null;

  final Uint8List? bytes;
  final String? path;
  final double width;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  late var _drawn = widget.bytes != null;

  @override
  void initState() {
    super.initState();
    if (widget.path case final path?) unawaited(_read(path));
  }

  Future<void> _read(String path) async {
    try {
      final file = await File(path).open();
      try {
        final head = await file.read(sniffPrefix);
        if (mounted && thumbnailDrawn(head)) setState(() => _drawn = true);
      } finally {
        await file.close();
      }
    } on FileSystemException catch (error) {
      debugPrint("e2e: a thumbnail's copy wasn't read: ${error.osError?.message ?? error.message}");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_drawn) return const SizedBox.shrink();
    final width = math.max(1, (widget.width * MediaQuery.devicePixelRatioOf(context)).round());
    return switch ((widget.bytes, widget.path)) {
      (final bytes?, _) => Image.memory(
        bytes,
        fit: BoxFit.cover,
        cacheWidth: width,
        gaplessPlayback: true,
        excludeFromSemantics: true,
      ),
      (_, final path?) => Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: width,
        gaplessPlayback: true,
        excludeFromSemantics: true,
      ),
      _ => const SizedBox.shrink(),
    };
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
