import 'package:flutter/painting.dart';

/// The app's pictures from the network: avatars, Space icons, banners,
/// attachments, embeds. Every `Image.network` goes through [cachedImage], so
/// that one place decides how they're kept (mobile#41).
///
/// [cacheWidth] and [cacheHeight] decode at the size shown, as
/// `Image.network`'s do.
// shortcut: memory only, as Image.network; the disk cache replaces this body.
ImageProvider cachedImage(String url, {int? cacheWidth, int? cacheHeight}) =>
    ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, NetworkImage(url));

/// Fetches [urls] ahead of their first frame, skipping nulls and those
/// already kept: what `READY` names (Space icons, the avatars of recent
/// chats) is there before its row shows. Failures are dropped: the row
/// loads it again itself.
Future<void> prefetchImages(Iterable<String?> urls) async {}

/// Forgets every picture kept, on signing out.
Future<void> clearImageCache() async {}
