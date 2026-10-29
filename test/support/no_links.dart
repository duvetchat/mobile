import 'package:duvet/deep_links.dart';

/// No links from the system: the app opens on its own.
class NoLinks implements DeepLinkSource {
  @override
  Stream<Uri> get links => const Stream.empty();
}
