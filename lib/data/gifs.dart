import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// The most bytes of a GIF the picker found that the app takes to send sealed (Ruling 12): what Duvet's storage takes
/// of one file.
const _gifMost = 20 << 20;

/// A GIF's bytes from where the picker found it, as an encrypted conversation sends it: a file sealed as any picture,
/// never its link (Ruling 12). Null when they don't come, or pass [_gifMost].
Future<Uint8List?> gifBytes(String url, {http.Client? client}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  final own = client ?? http.Client();
  try {
    final response = await own.send(http.Request('GET', uri)).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(const Duration(seconds: 15))) {
      bytes.add(chunk);
      if (bytes.length > _gifMost) return null;
    }
    return bytes.takeBytes();
  } catch (_) {
    return null;
  } finally {
    if (client == null) own.close();
  }
}

/// A GIF to send: its full [url] goes out as the message, as on desktop.
class Gif {
  final String id;
  final String url;

  /// A small version for the picker's grid.
  final String preview;
  final double width;
  final double height;
  final String description;
  const Gif({
    required this.id,
    required this.url,
    required this.preview,
    required this.width,
    required this.height,
    this.description = '',
  });
}

/// Where GIFs come from: KLIPY (desktop's `GifPicker.svelte` still asks
/// Tenor).
abstract interface class GifSource {
  Future<List<Gif>> trending();
  Future<List<Gif>> search(String query);

  /// Who to credit under the grid.
  String get attribution;

  /// A GIF's bytes, for an encrypted conversation, which sends it as a sealed file (Ruling 12): null when they don't
  /// come.
  Future<Uint8List?> bytes(String url);

  /// The app's; tests swap in their own.
  static GifSource instance = KlipyGifs();
}

class KlipyGifs implements GifSource {
  static const _key = 'wrQpsWVVgJF6SQwLGINJ4D8uEJsya3rB0gmmwKF3SgN5SdkGZH3z6r2L0z2JJqUF';
  static const _limit = 20;
  final http.Client Function() _client;
  KlipyGifs({http.Client Function()? client}) : _client = client ?? http.Client.new;

  @override
  String get attribution => 'GIFs from KLIPY';

  @override
  Future<Uint8List?> bytes(String url) => gifBytes(url);

  @override
  Future<List<Gif>> trending() => _get('trending', {'per_page': '$_limit'});

  @override
  Future<List<Gif>> search(String query) =>
      query.trim().isEmpty ? trending() : _get('search', {'q': query.trim(), 'per_page': '$_limit'});

  Future<List<Gif>> _get(String path, Map<String, String> query) async {
    final uri = Uri.https('api.klipy.com', '/api/v1/$_key/gifs/$path', query);
    final client = _client();
    try {
      final response = await client.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) throw http.ClientException('KLIPY answered ${response.statusCode}', uri);
      return parse(jsonDecode(response.body));
    } finally {
      client.close();
    }
  }

  /// KLIPY's results: each one's medium GIF to send and its small one for the
  /// grid. Ads (any `type` but `gif`) are left out.
  static List<Gif> parse(Object? json) => [
    for (final r in ((json as Map?)?['data'] as Map?)?['data'] as List? ?? const [])
      if (r is Map && r['type'] == 'gif')
        if (r['file'] case final Map file)
          if (((file['md'] ?? file['hd']) as Map?)?['gif'] case {'url': final String url})
            if (((file['sm'] ?? file['xs'] ?? file['md']) as Map?)?['gif'] case final Map small)
              Gif(
                id: '${r['id']}',
                url: url,
                preview: small['url'] as String? ?? url,
                width: (small['width'] as num?)?.toDouble() ?? 1,
                height: (small['height'] as num?)?.toDouble() ?? 1,
                description: r['title'] as String? ?? '',
              ),
  ];
}
