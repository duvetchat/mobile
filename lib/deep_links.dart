import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:forui/forui.dart';

import 'account.dart';
import 'chat_view.dart';
import 'data/links.dart';
import 'data/models.dart';
import 'data/scope.dart';
import 'spaces.dart';
import 'widgets/link_embeds.dart';

/// Links the system hands the app. Tests swap in their own [instance].
abstract interface class DeepLinkSource {
  /// The link the app was opened with, then each one after.
  Stream<Uri> get links;

  static DeepLinkSource instance = AppLinksSource();

  /// Duvet's own links tapped in a message's text, opened in the app rather
  /// than handed to the browser.
  static final tapped = StreamController<Uri>.broadcast();
}

/// How long a notification's tap waits for a sign-in, as one can start the app: past it, it opens nothing.
const tapWait = Duration(seconds: 30);

// The links of the taps waiting for a sign-in, and the link a tap opened last: a tap that starts the app comes as its
// launch's details and as its response.
final _waitingTaps = <String>{};
String? _lastTapped;

/// Opens a notification's [link] once the user is signed in ([profile] not null): at once, or once the session
/// restores, [tapWait] at most. The same link opens once; one that waited in vain opens when it's tapped again.
Future<void> openWhenSignedIn(ValueListenable<Profile?> profile, Uri link) async {
  final tap = link.toString();
  if (tap == _lastTapped || !_waitingTaps.add(tap)) return;
  try {
    if (profile.value == null) {
      final signedIn = Completer<void>();
      void follow() {
        if (profile.value != null && !signedIn.isCompleted) signedIn.complete();
      }

      profile.addListener(follow);
      try {
        await signedIn.future.timeout(tapWait);
      } on TimeoutException {
        return;
      } finally {
        profile.removeListener(follow);
      }
    }
    _lastTapped = tap;
    DeepLinkSource.tapped.add(link);
  } finally {
    _waitingTaps.remove(tap);
  }
}

class AppLinksSource implements DeepLinkSource {
  @override
  Stream<Uri> get links => AppLinks().uriLinkStream;
}

/// Opens Duvet's links while signed in: an invite opens the join sheet, a
/// message link its chat, at the message.
class DeepLinkHandler extends StatefulWidget {
  final Widget child;
  const DeepLinkHandler({required this.child, super.key});

  @override
  State<DeepLinkHandler> createState() => _DeepLinkHandlerState();
}

class _DeepLinkHandlerState extends State<DeepLinkHandler> {
  StreamSubscription<Uri>? _sub;
  late final StreamSubscription<Uri> _tapped = DeepLinkSource.tapped.stream.listen(_open);

  @override
  void initState() {
    super.initState();
    _tapped;
    try {
      _sub = DeepLinkSource.instance.links.listen(_open, onError: (Object e) => debugPrint('links: $e'));
    } catch (e) {
      // No link plugin (tests, desktop).
      debugPrint('links: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tapped.cancel();
    super.dispose();
  }

  void _open(Uri uri) {
    if (!mounted) return;
    final signedIn = context.repository.profile.value != null;
    switch (parseDeepLink(uri.toString())) {
      case OpenVerify(:final token):
        verifyFromLink(context, token);
      case OpenReset(:final token):
        Navigator.of(
          context,
          rootNavigator: true,
        ).push(MaterialPageRoute<void>(builder: (_) => ResetPasswordPage(token: token)));
      case OpenChangeEmail(:final token, :final email):
        changeEmailFromLink(context, token, email);
      case OpenInvite() || OpenMessage() when !signedIn:
        showFToast(
          context: context,
          title: const Text('Sign in to open that link'),
          duration: const Duration(seconds: 3),
        );
      case OpenInvite(:final code):
        showJoinSheet(context, code: code);
      case OpenMessage(:final link) when linksHiddenRoom(context.repository, link):
        showFToast(context: context, title: const Text(roomUnavailable), duration: const Duration(seconds: 3));
      case OpenMessage(:final link):
        final repository = context.repository;
        final target = targetOf(link);
        final String title;
        if (target case ConversationTarget(:final conversationId)) {
          title =
              repository.conversations.value.where((c) => c.id == conversationId).firstOrNull?.title ??
              'Direct message';
        } else {
          final room = repository.spaces.value.expand((s) => s.rooms).where((r) => r.id == link.roomId).firstOrNull;
          title = '# ${room?.name ?? 'room'}';
        }
        // Over a page left open (a form half filled): a link from outside doesn't close it.
        openChatRoute(context, ChatRoute(target: target, title: title, jumpTo: link.messageId), reveal: false);
      case null:
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
