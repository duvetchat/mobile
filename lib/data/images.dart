import 'dart:async';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Where pictures are kept between runs: the OS's cache directory, so it's
/// reclaimed when the phone runs short of space.
///
/// Null in widget tests (test/flutter_test_config.dart), which have no
/// plugins behind it: pictures then load as `Image.network` does, and
/// nothing is fetched ahead or kept. Built on first use, never in a test that
/// sets it first.
// The bounds: 1,000 files, each forgotten after 30 days unseen; past 1,000,
// the least recently seen go first. A few hundred avatars and icons, and the
// pictures of the chats opened lately.
// shortcut: a count, not bytes (flutter_cache_manager has no byte cap), so a run of large photos can take a few
// hundred MB until the count or the OS clears them; upgrade to a byte budget if storage complaints come in.
@visibleForTesting
BaseCacheManager? imageStore = CacheManager(
  Config('pictures', maxNrOfCacheObjects: 1000, stalePeriod: const Duration(days: 30)),
);

final _attachment = RegExp(
  r'^/attachments/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// The key [url]'s file is kept under. A Duvet attachment
/// (`/attachments/<uuid>`) is one file whatever its signature, and a new
/// avatar is a new attachment: its `sig` and `exp` are left out, so a link
/// signed again finds the file kept from the old one. Anything else is the
/// whole URL.
@visibleForTesting
String imageKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !_attachment.hasMatch(uri.path)) return url;
  final rest = {...uri.queryParametersAll}
    ..remove('sig')
    ..remove('exp');
  final base = '${uri.scheme}://${uri.authority}${uri.path}';
  return rest.isEmpty ? base : '$base?${Uri(queryParameters: rest).query}';
}

/// The app's pictures from the network: avatars, Space icons, banners,
/// attachments, embeds. Every network picture goes through here (mobile#41):
/// kept on disk, so a picture seen once shows on the next launch without the
/// network.
///
/// [cacheWidth] and [cacheHeight] decode at the size shown, as
/// `Image.network`'s do.
ImageProvider cachedImage(String url, {int? cacheWidth, int? cacheHeight}) =>
    ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, imageStore == null ? NetworkImage(url) : _KeptImage(url));

// Counts the clears: a download that lands after one is dropped, not kept for
// whoever signs in next.
var _clears = 0;

/// A picture kept on disk under [imageKey]; fetched from [url] when it isn't.
/// Equal by the whole URL: a link signed again after a refusal must load
/// again, which an `Image` given an equal provider wouldn't.
@immutable
class _KeptImage extends ImageProvider<_KeptImage> {
  final String url;
  const _KeptImage(this.url);

  @override
  Future<_KeptImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_KeptImage key, ImageDecoderCallback decode) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: url,
    informationCollector: () => [DiagnosticsProperty<ImageProvider>('Image provider', this)],
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final store = imageStore!;
    final key = imageKey(url);
    try {
      final bytes = await _bytes(store, key);
      try {
        if (bytes.isEmpty) throw StateError('$url is an empty file');
        return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      } catch (_) {
        // Not a picture (a captive portal's page, say): never kept, or it
        // would stand in for this one from now on.
        unawaited(store.removeFile(key).catchError((Object _) {}));
        rethrow;
      }
    } catch (_) {
      // As NetworkImage: the next frame that wants it tries again.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    }
  }

  // The kept file, whatever its age: nothing at a proven key changes, and
  // offline it's all there is. Anything else past its HTTP freshness is
  // fetched again behind it, for the next time.
  Future<Uint8List> _bytes(BaseCacheManager store, String key) async {
    final kept = await store.getFileFromCache(key);
    if (kept == null) return (await _download(store, key)).file.readAsBytes();
    if (key == url && kept.validTill.isBefore(clock.now())) {
      unawaited(_download(store, key).then<void>((_) {}, onError: (_) {}));
    }
    return kept.file.readAsBytes();
  }

  Future<FileInfo> _download(BaseCacheManager store, String key) async {
    final clears = _clears;
    final FileInfo info;
    try {
      info = await store.downloadFile(url, key: key);
    } on HttpExceptionWithStatus catch (e) {
      // What the callers check for a refused link, as Image.network throws it.
      throw NetworkImageLoadException(statusCode: e.statusCode, uri: Uri.parse(url));
    }
    if (clears != _clears) {
      await store.removeFile(key);
      throw StateError('Signed out while $url came');
    }
    return info;
  }

  @override
  bool operator ==(Object other) => other is _KeptImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => '${objectRuntimeType(this, '_KeptImage')}("$url")';
}

/// How many pictures [prefetchImages] warms at once, and at most per call: a
/// low-end phone decodes a few at a time without dropping frames.
const _prefetchAtOnce = 4;
const _prefetchAtMost = 200;

// Every call's pictures wait in one line, fetched by a few at once whoever
// asked: READY's Spaces each ask on their own, and together they'd be far
// more than a few.
final _wanted = <String>{};
var _fetching = 0;

/// Fetches [urls] ahead of their first frame, skipping nulls and those
/// already kept: what `READY` names (Space icons, the avatars of recent
/// chats) is there before its row shows. Each is kept on disk and decoded at
/// a chat row's avatar size (48), the size `UserAvatar` and `SpaceIcon` there
/// ask for, so the row shows it on its first frame. Failures are dropped: the
/// row loads it again itself. Completes with the fetchers this call started,
/// at once when others were already at work.
Future<void> prefetchImages(Iterable<String?> urls) {
  if (imageStore == null) return Future.value();
  _wanted.addAll(urls.nonNulls.take(_prefetchAtMost));
  final width = (48 * (ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1)).round();
  // One already decoded answers at once; one on disk is only read.
  Future<void> fetch() async {
    try {
      while (_wanted.isNotEmpty) {
        final url = _wanted.first;
        _wanted.remove(url);
        await _resolved(cachedImage(url, cacheWidth: width));
      }
    } finally {
      _fetching--;
    }
  }

  final started = <Future<void>>[];
  while (_wanted.isNotEmpty && _fetching < _prefetchAtOnce) {
    _fetching++;
    started.add(fetch());
  }
  return Future.wait(started);
}

// Loads [provider] into the image cache, as precacheImage does without a
// context; done once it has a frame or has failed.
Future<void> _resolved(ImageProvider provider) {
  final done = Completer<void>();
  final stream = provider.resolve(ImageConfiguration.empty);
  void end() {
    if (!done.isCompleted) done.complete();
  }

  final listener = ImageStreamListener((_, _) => end(), onError: (_, _) => end());
  stream.addListener(listener);
  return done.future.whenComplete(() => stream.removeListener(listener));
}

/// Forgets every picture kept, on disk and decoded, on signing out: they
/// include private attachments.
Future<void> clearImageCache() async {
  final store = imageStore;
  if (store == null) return;
  _clears++;
  // Those still waiting were the account's too: never fetched for the next.
  _wanted.clear();
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
  await store.emptyCache();
}
