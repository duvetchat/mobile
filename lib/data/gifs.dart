import 'dart:convert';

import 'package:http/http.dart' as http;

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

/// Where GIFs come from: Tenor, with the desktop app's key and requests
/// (`GifPicker.svelte`).
abstract interface class GifSource {
  Future<List<Gif>> trending();
  Future<List<Gif>> search(String query);

  /// Who to credit under the grid.
  String get attribution;

  /// The app's; tests swap in their own.
  static GifSource instance = TenorGifs();
}

class TenorGifs implements GifSource {
  static const _key = 'LIVDSRZULELA';
  static const _limit = 20;
  final http.Client Function() _client;
  TenorGifs({http.Client Function()? client}) : _client = client ?? http.Client.new;

  @override
  String get attribution => 'GIFs from Tenor';

  @override
  Future<List<Gif>> trending() => _get(Uri.https('g.tenor.com', '/v1/trending', {'key': _key, 'limit': '$_limit'}));

  @override
  Future<List<Gif>> search(String query) => query.trim().isEmpty
      ? trending()
      : _get(Uri.https('g.tenor.com', '/v1/search', {'q': query.trim(), 'key': _key, 'limit': '$_limit'}));

  Future<List<Gif>> _get(Uri uri) async {
    final client = _client();
    try {
      final response = await client.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) throw http.ClientException('Tenor answered ${response.statusCode}', uri);
      return parse(jsonDecode(response.body));
    } finally {
      client.close();
    }
  }

  /// Tenor v1's results: each one's GIF and its tiny preview.
  static List<Gif> parse(Object? json) => [
    for (final r in (json as Map?)?['results'] as List? ?? const [])
      if (r is Map)
        if ((r['media'] as List?)?.firstOrNull case final Map media)
          if ((media['gif'] as Map?)?['url'] case final String url)
            Gif(
              id: '${r['id']}',
              url: url,
              preview: ((media['tinygif'] ?? media['nanogif'] ?? media['gif']) as Map)['url'] as String,
              width: (((media['tinygif'] ?? media['gif']) as Map)['dims'] as List?)?.first.toDouble() ?? 1,
              height: (((media['tinygif'] ?? media['gif']) as Map)['dims'] as List?)?.last.toDouble() ?? 1,
              description: (r['content_description'] ?? r['title'] ?? '') as String,
            ),
  ];
}
