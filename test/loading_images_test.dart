import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:duvet/data/images.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

const _api = 'https://api.duvet.example';
const _id = '0b9f6c2e-1a2b-4c3d-8e9f-0123456789ab';
const _stable = '$_api/attachments/$_id';
const _oldLink = '$_stable?sig=old&exp=1700000000';
const _newLink = '$_stable?sig=new&exp=1900000000';

/// A disk in memory: what's kept by key, every download asked for, and
/// every file dropped.
class _Store extends Fake implements BaseCacheManager {
  final kept = <String, FileInfo>{};
  final downloads = <(String, String?)>[];
  final removed = <String>[];
  var emptied = 0;

  /// Answers each download; refused unless a test says otherwise.
  Future<FileInfo> Function(String url, String key) answer = (url, _) async =>
      throw HttpExceptionWithStatus(404, 'Not found', uri: Uri.parse(url));

  @override
  Future<FileInfo?> getFileFromCache(String key, {bool ignoreMemCache = false}) async => kept[key];

  @override
  Future<FileInfo> downloadFile(String url, {String? key, Map<String, String>? authHeaders, bool force = false}) {
    downloads.add((url, key));
    return answer(url, key!);
  }

  @override
  Future<void> removeFile(String key) async {
    removed.add(key);
    kept.remove(key);
  }

  @override
  Future<void> emptyCache() async {
    emptied++;
    kept.clear();
  }
}

/// A 2×2 PNG; real decoding, so only inside `tester.runAsync`.
Future<List<int>> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint()..color = const ui.Color(0xFF7C3AED));
  final image = await recorder.endRecording().toImage(2, 2);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// A file on the in-memory disk holding [bytes], as the store gives it.
Future<FileInfo> _file(String url, List<int> bytes, {DateTime? validTill}) async {
  final file = await MemoryCacheSystem().createFile('picture.file');
  await file.writeAsBytes(bytes);
  return FileInfo(file, FileSource.Cache, validTill ?? DateTime.now().add(const Duration(days: 7)), url);
}

/// The first frame [provider] gives, or its error.
Future<ImageInfo> _load(ImageProvider provider) {
  final done = Completer<ImageInfo>();
  provider
      .resolve(ImageConfiguration.empty)
      .addListener(
        ImageStreamListener(
          (info, _) {
            if (!done.isCompleted) done.complete(info);
          },
          onError: (error, stack) {
            if (!done.isCompleted) done.completeError(error, stack ?? StackTrace.current);
          },
        ),
      );
  return done.future;
}

/// Issue #41: pictures are kept on disk between runs, fetched ahead, and
/// forgotten on signing out.
void main() {
  group('the key a picture is kept under', () {
    test('an attachment is one file whatever its signature', () {
      expect(imageKey(_oldLink), _stable);
      expect(imageKey(_newLink), _stable);
      expect(imageKey(_stable), _stable);
    });

    test('keeps every other parameter, and the host', () {
      expect(imageKey('$_oldLink&stream=1'), '$_stable?stream=1');
      expect(imageKey('https://other.example/attachments/$_id?sig=a&exp=1'), isNot(imageKey(_oldLink)));
    });

    test('anything not an attachment is its whole URL', () {
      for (final url in [
        '$_stable/resign?sig=a&exp=1',
        '$_api/attachments/not-a-uuid?sig=a&exp=1',
        'https://media.gifs.example/abc.gif?sig=a&exp=1',
        'https://avatars.example/u/1?v=4',
      ]) {
        expect(imageKey(url), url);
      }
    });
  });

  group('with a disk', () {
    late _Store store;
    late BaseCacheManager? before;

    setUp(() {
      before = imageStore;
      imageStore = store = _Store();
    });
    tearDown(() => imageStore = before);

    test('pictures are equal by their whole link, and decode at the size asked', () {
      expect(cachedImage(_oldLink), cachedImage(_oldLink));
      expect(cachedImage(_oldLink).hashCode, cachedImage(_oldLink).hashCode);
      // One signed again must load again: an equal provider wouldn't.
      expect(cachedImage(_oldLink), isNot(cachedImage(_newLink)));
      expect(cachedImage(_oldLink, cacheWidth: 96), cachedImage(_oldLink, cacheWidth: 96));
      expect(cachedImage(_oldLink, cacheWidth: 96), isA<ResizeImage>().having((r) => r.width, 'width', 96));
    });

    testWidgets('a kept picture shows from disk, without the network, from a link signed since', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      final info = await tester.runAsync(() async {
        store.kept[_stable] = await _file(_oldLink, await _png(), validTill: DateTime(2000));
        return _load(cachedImage(_newLink));
      });
      expect(info!.image.width, 2);
      expect(store.downloads, isEmpty);
    });

    testWidgets('one not kept is fetched from its own link and kept under the stable key', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      final info = await tester.runAsync(() async {
        final png = await _png();
        store.answer = (url, key) => _file(url, png);
        return _load(cachedImage(_newLink, cacheWidth: 2));
      });
      expect(info!.image.width, 2);
      expect(store.downloads, [(_newLink, _stable)]);
    });

    testWidgets('a refused link fails as Image.network does, with its status', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      store.answer = (url, _) async => throw HttpExceptionWithStatus(403, 'Forbidden', uri: Uri.parse(url));
      final error = await tester.runAsync(
        () => _load(cachedImage(_oldLink)).then<Object?>((_) => null, onError: (Object e) => e),
      );
      expect(error, isA<NetworkImageLoadException>().having((e) => e.statusCode, 'statusCode', 403));
    });

    testWidgets('a kept file that isn\'t a picture is dropped, not shown again', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      final error = await tester.runAsync(() async {
        store.kept[_stable] = await _file(_oldLink, utf8.encode('<html>Sign in to the wifi</html>'));
        return _load(cachedImage(_oldLink)).then<Object?>((_) => null, onError: (Object e) => e);
      });
      expect(error, isNotNull);
      expect(store.kept, isEmpty);
    });

    testWidgets('a kept picture at a link that may change is shown and fetched again behind it once stale', (
      tester,
    ) async {
      PaintingBinding.instance.imageCache.clear();
      const url = 'https://avatars.example/u/1';
      final info = await tester.runAsync(() async {
        store.kept[url] = await _file(url, await _png(), validTill: DateTime(2000));
        return _load(cachedImage(url));
      });
      expect(info!.image.width, 2);
      expect(store.downloads, [(url, url)]);
    });

    testWidgets('prefetching skips nulls and repeats, drops failures, and fetches 4 at once at most', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      final urls = [for (var i = 0; i < 10; i++) 'https://avatars.example/u/$i'];
      var inFlight = 0;
      var most = 0;
      final waiting = <Completer<FileInfo>>[];
      store.answer = (url, key) {
        most = max(most, ++inFlight);
        final answer = Completer<FileInfo>();
        waiting.add(answer);
        return answer.future.whenComplete(() => inFlight--);
      };
      await tester.runAsync(() async {
        final done = prefetchImages([null, ...urls, urls.first, null]);
        for (var i = 0; i < urls.length; i++) {
          await pumpEventQueue();
          waiting.removeAt(0).completeError(HttpExceptionWithStatus(500, 'Down', uri: Uri.parse(urls[i])));
        }
        await done;
      });
      expect(store.downloads.map((d) => d.$1), unorderedEquals(urls));
      expect(most, 4);
    });

    testWidgets('pictures asked for in several calls still come 4 at once at most', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      final urls = [for (var i = 0; i < 10; i++) 'https://avatars.example/s/$i'];
      var inFlight = 0;
      var most = 0;
      final waiting = <Completer<FileInfo>>[];
      store.answer = (url, key) {
        most = max(most, ++inFlight);
        final answer = Completer<FileInfo>();
        waiting.add(answer);
        return answer.future.whenComplete(() => inFlight--);
      };
      await tester.runAsync(() async {
        // As READY's Spaces do: each its own call.
        final done = prefetchImages([urls.first]);
        for (final url in urls.skip(1)) {
          unawaited(prefetchImages([url]));
        }
        for (var i = 0; i < urls.length; i++) {
          await pumpEventQueue();
          waiting.removeAt(0).completeError(HttpExceptionWithStatus(500, 'Down', uri: Uri.parse(urls[i])));
        }
        await done;
      });
      expect(store.downloads.map((d) => d.$1), unorderedEquals(urls));
      expect(most, 4);
    });

    testWidgets('signing out drops the pictures still waiting to be fetched ahead', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      final urls = [for (var i = 0; i < 10; i++) 'https://avatars.example/o/$i'];
      final waiting = <Completer<FileInfo>>[];
      store.answer = (url, key) {
        final answer = Completer<FileInfo>();
        waiting.add(answer);
        return answer.future;
      };
      await tester.runAsync(() async {
        final done = prefetchImages(urls);
        await pumpEventQueue();
        await clearImageCache();
        for (final answer in waiting) {
          answer.completeError(HttpExceptionWithStatus(500, 'Down', uri: Uri.parse(urls.first)));
        }
        await done;
      });
      // The 4 under way when signing out, and none of the 6 behind them.
      expect(store.downloads, hasLength(4));
    });

    testWidgets('prefetching skips a picture already decoded', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() async {
        final png = await _png();
        // Not kept on disk: a second fetch could only be skipped in memory.
        store.answer = (url, _) => _file(url, png);
        await prefetchImages([_oldLink]);
        await prefetchImages([_oldLink]);
      });
      expect(store.downloads, hasLength(1));
    });

    testWidgets('signing out forgets every picture, on disk and decoded', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() async {
        final png = await _png();
        store.answer = (url, _) => _file(url, png);
        await prefetchImages([_oldLink]);
        store.kept[_stable] = await _file(_oldLink, png);
        await clearImageCache();
      });
      expect(store.emptied, 1);
      expect(store.kept, isEmpty);
      expect(PaintingBinding.instance.imageCache.currentSize, 0);
      expect(PaintingBinding.instance.imageCache.liveImageCount, 0);
    });

    testWidgets('a picture that comes after signing out isn\'t kept', (tester) async {
      PaintingBinding.instance.imageCache.clear();
      final error = await tester.runAsync(() async {
        // Made in here: one made outside completes on the test's own clock, which nothing runs meanwhile.
        final coming = Completer<FileInfo>();
        store.answer = (url, key) => coming.future;
        final load = _load(cachedImage(_newLink)).then<Object?>((_) => null, onError: (Object e) => e);
        await pumpEventQueue();
        await clearImageCache();
        coming.complete(await _file(_newLink, await _png()));
        return load;
      });
      expect(error, isNotNull);
      expect(store.removed, [_stable]);
    });
  });

  test('without a disk (widget tests) pictures load as Image.network does', () {
    expect(imageStore, isNull);
    expect(cachedImage(_oldLink), isA<NetworkImage>().having((n) => n.url, 'url', _oldLink));
    expect(
      cachedImage(_oldLink, cacheWidth: 96),
      isA<ResizeImage>().having((r) => r.imageProvider, 'provider', isA<NetworkImage>()),
    );
  });
}
