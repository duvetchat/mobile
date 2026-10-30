import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// What the app does with a received file: open it in another app, save a
/// picture to the gallery, share it. Tests swap in their own [instance].
class MediaActions {
  const MediaActions();

  static MediaActions instance = const MediaActions();

  /// Opens [url] outside the app: the browser downloads or shows it.
  Future<bool> open(String url) => switch (Uri.tryParse(url)) {
    final uri? => launchUrl(uri, mode: LaunchMode.externalApplication),
    null => Future.value(false),
  };

  Future<List<int>> download(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) throw http.ClientException('${response.statusCode}', Uri.parse(url));
    return response.bodyBytes;
  }

  /// Saves a picture to the gallery, asking for access first; false when the
  /// person says no.
  Future<bool> saveToGallery(String url, String name) async {
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) return false;
    final bytes = await download(url);
    await Gal.putImageBytes(Uint8List.fromList(bytes), name: name.replaceAll(RegExp(r'\.[^.]+$'), ''));
    return true;
  }

  /// Hands the file to the system share sheet.
  Future<void> share(String url, String name, String contentType) async {
    final bytes = await download(url);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(Uint8List.fromList(bytes), name: name, mimeType: contentType)],
      ),
    );
  }
}
