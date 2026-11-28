import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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
    // A file on this device (a decrypted file's copy, lib/e2e/decrypted_files.dart) is read from where it is.
    if (url.startsWith('/')) return File(url).readAsBytes();
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

  /// Saves a decrypted file's copy at [path] through the system's save dialog, under [name], typed [type]
  /// (`application/octet-stream` for what the app doesn't draw, so nothing opens it as what it says it is): false when
  /// the person backs out.
  Future<bool> saveFile(String path, String name, String type) async =>
      await FilePicker.saveFile(fileName: name, bytes: await File(path).readAsBytes(), mimeType: type) != null;

  /// Hands a decrypted file's copy at [path] to the system share sheet, under [name], typed [type]: the person's act.
  Future<void> shareFile(String path, String name, String type) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, name: name, mimeType: type)],
      ),
    );
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
