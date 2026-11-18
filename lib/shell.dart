import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:forui/forui.dart';

import 'theme.dart';

/// How much room the window gives the app, by its width alone (inside the notch's sides): a phone on its side is
/// short, but a long one is as wide as a small tablet, and takes the same two panes.
enum SizeClass {
  /// A phone upright, a narrow window: the tabs over a tab bar, a chat over everything.
  compact,

  /// The desktop's shape: a rail, the list, and the open chat beside them.
  medium,

  /// Room for the chat's members too.
  expanded;

  static const mediumFrom = 720.0;
  static const expandedFrom = 1100.0;

  static SizeClass of(double width) => width < mediumFrom
      ? compact
      : width < expandedFrom
      ? medium
      : expanded;

  bool get wide => this != compact;
}

/// The widths of the wide layout's columns.
abstract final class ShellSizes {
  static const rail = 72.0;
  static const members = 280.0;

  /// A full page (settings, a form) over a wide window: centered, no wider.
  static const page = 720.0;

  /// A sheet over a wide window: centered, no wider.
  static const sheet = 560.0;

  /// The list beside the rail: narrower where the chat would be left too little.
  static double list(double width) => width < 800
      ? 300
      : width < SizeClass.expandedFrom
      ? 320
      : 340;
}

/// A route that shows in the wide layout's pane: a chat, a thread.
mixin PaneRoute<T> on PageRoute<T> {
  /// What it shows, e.g. the chat's ID: the list marks its row.
  String get paneId;

  /// No transition: a chat swapped in the pane, a route moved between the pane and the screen.
  bool instant = false;

  /// The same page for another navigator, its state kept.
  PaneRoute<T> moved();

  /// Whether it shows what [other] does, so opening [other] over it changes nothing.
  bool same(PaneRoute<Object?> other) => false;

  @override
  Duration get transitionDuration => instant ? Duration.zero : super.transitionDuration;
}

/// Where chats open: over everything on a compact window, in the pane beside the list on a wide one. It moves the
/// open ones across when the window crosses from one to the other, so a chat stays open through a rotation or a
/// resize.
class Shell extends ChangeNotifier {
  /// The app's own navigator.
  final GlobalKey<NavigatorState> root;

  /// The pane's, while the wide layout shows.
  final pane = GlobalKey<NavigatorState>();

  late final rootObserver = RouteStack(_changed);
  late final paneObserver = RouteStack(_changed);

  Shell(this.root);

  bool _wide = false;
  bool _showMembers = true;
  bool _settling = false;
  String? _openId;
  bool _paneOpen = false;

  bool get wide => _wide;

  /// What the pane shows, null when nothing or on a compact window.
  String? get openId => _openId;

  /// Whether the pane holds routes: on a compact window, for the frame before they move over everything.
  bool get paneOpen => _paneOpen;

  /// Whether a chat's members show beside it where there's room.
  bool get showMembers => _showMembers;

  void toggleMembers() {
    _showMembers = !_showMembers;
    notifyListeners();
  }

  /// The home screen says which layout it draws.
  void layout({required bool wide}) {
    if (wide == _wide) return;
    _wide = wide;
    _settleSoon();
  }

  /// Opens [route]: in the pane on a wide window, in place of what it shows; else over everything.
  ///
  /// Pages over the home screen (Friends, a settings page) close for it when [reveal], as following a link from
  /// one does; a notice tapped over one leaves it open and puts the chat over it.
  void open(PaneRoute<void> route, {bool reveal = true}) {
    final rootNav = root.currentState;
    final paneNav = pane.currentState;
    if (rootNav == null) return;
    // Whatever is over the home screen, a sheet being filled as much as a page, stays under a notice's chat.
    if (!_wide || paneNav == null || (!reveal && rootObserver.routes.length > 1)) {
      rootNav.push(route);
      return;
    }
    rootNav.popUntil((r) => r.isFirst);
    final shown = paneObserver.routes;
    if (shown.length == 1 && shown.single is PaneRoute && (shown.single as PaneRoute).same(route)) return;
    paneNav.pushAndRemoveUntil(route..instant = true, (_) => false);
  }

  /// Empties the pane: its chat is gone (a conversation left, a room deleted).
  void close() {
    if (_paneOpen) pane.currentState?.pushAndRemoveUntil(emptyRoute(), (_) => false);
  }

  /// The pane with nothing open.
  Route<void> emptyRoute() =>
      PageRouteBuilder<void>(transitionDuration: Duration.zero, pageBuilder: (_, _, _) => const PaneEmpty());

  void _changed() {
    final open = paneObserver.routes.whereType<PaneRoute<Object?>>().firstOrNull;
    final id = _wide ? open?.paneId : null;
    if ((open != null) != _paneOpen || id != _openId) {
      _paneOpen = open != null;
      _openId = id;
      _notifySoon();
    }
    // A chat pushed over the home screen on a wide window belongs in the pane.
    if (_wide && rootObserver.routes.length > 1) _settleSoon();
    // The pane's chats, kept there under a page while the window narrowed, go over the home screen once it closes.
    if (!_wide && _paneOpen && rootObserver.routes.length == 1) _settleSoon();
  }

  void _notifySoon() => afterBuild(notifyListeners);

  void _settleSoon() {
    if (_settling) return;
    _settling = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _settle());
    SchedulerBinding.instance.scheduleFrame();
  }

  // After the frame that drew the new layout, the open chats move to where it shows them. Both navigators rebuild
  // in the next frame, so each page changes parent with its state.
  void _settle() {
    _settling = false;
    final rootNav = root.currentState;
    final paneNav = pane.currentState;
    if (rootNav == null || paneNav == null) return;
    if (_wide) {
      // Only chats over the home screen: one over Friends, or under an open sheet, stays where it is.
      final over = rootObserver.routes.skip(1).toList();
      if (over.isEmpty || !over.every((r) => r is PaneRoute && r.isActive)) return;
      final moved = [for (final r in over) (r as PaneRoute).moved()..instant = true];
      for (final r in over) {
        rootNav.removeRoute(r);
      }
      paneNav.pushAndRemoveUntil(moved.first, (_) => false);
      for (final r in moved.skip(1)) {
        paneNav.push(r);
      }
    } else {
      // Not over a page open on the home screen (Friends, a video, a call): the chats wait in the pane, under it,
      // till it closes.
      if (rootObserver.routes.length > 1) return;
      // What isn't a chat over them (a search waiting for its answer) closes.
      final open = paneObserver.routes.takeWhile((r) => r is PaneRoute).toList();
      if (open.isEmpty) return;
      final moved = [for (final r in open) (r as PaneRoute).moved()..instant = true];
      paneNav.pushAndRemoveUntil(emptyRoute(), (_) => false);
      for (final r in moved) {
        rootNav.push(r);
      }
    }
    _changed();
  }

  static Shell? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<ShellScope>()?.notifier;

  /// The same, rebuilding [context] as what's open changes.
  static Shell? watch(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>()?.notifier;
}

/// Runs [change] now, or after the frame when the tree is building: a navigator tells its observers of its first
/// route while it builds.
void afterBuild(VoidCallback change) {
  if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
    SchedulerBinding.instance.addPostFrameCallback((_) => change());
  } else {
    change();
  }
}

/// Hands the [Shell] down the tree, from over the app's navigator: every route reaches it.
class ShellScope extends InheritedNotifier<Shell> {
  const ShellScope({required Shell shell, required super.child, super.key}) : super(notifier: shell);
}

/// A navigator's routes, the first at the bottom.
class RouteStack extends NavigatorObserver {
  final VoidCallback onChange;
  final routes = <Route<Object?>>[];
  RouteStack(this.onChange);

  @override
  void didPush(Route<Object?> route, Route<Object?>? previousRoute) {
    // A navigator's first route: what an earlier navigator left listed is gone with it.
    if (previousRoute == null) routes.clear();
    routes.add(route);
    onChange();
  }

  @override
  void didPop(Route<Object?> route, Route<Object?>? previousRoute) {
    routes.remove(route);
    onChange();
  }

  @override
  void didRemove(Route<Object?> route, Route<Object?>? previousRoute) {
    routes.remove(route);
    onChange();
  }

  @override
  void didReplace({Route<Object?>? newRoute, Route<Object?>? oldRoute}) {
    final i = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) routes[i] = newRoute;
    onChange();
  }
}

/// Around the pane: tells a chat it shows beside the list, not over it.
class PaneScope extends InheritedWidget {
  /// Whether there's room for the members beside the chat.
  final bool roomForMembers;

  /// Whether they show.
  final bool showMembers;
  final VoidCallback toggleMembers;

  const PaneScope({
    required this.roomForMembers,
    required this.showMembers,
    required this.toggleMembers,
    required super.child,
    super.key,
  });

  static PaneScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PaneScope>();

  /// Whether [context]'s route is the pane's own: nothing under it to go back to, so no Back.
  static bool rootOf(BuildContext context) => maybeOf(context) != null && (ModalRoute.of(context)?.isFirst ?? false);

  @override
  bool updateShouldNotify(PaneScope old) => old.roomForMembers != roomForMembers || old.showMembers != showMembers;
}

/// The pane with no chat open.
class PaneEmpty extends StatelessWidget {
  const PaneEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return ColoredBox(
      color: colors.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FLucideIcons.messageCircle, size: 32, color: colors.mutedForeground),
            const SizedBox(height: 12),
            Text('Pick a chat to open it here', style: DuvetType.body.copyWith(color: colors.mutedForeground)),
          ],
        ),
      ),
    );
  }
}

/// Keeps a screen clear of the notch and the rounded corners at the sides (a phone on its side): it sits between
/// them, over the background. The top and bottom insets stay the screen's own.
///
/// Around the home screen, a chat and a [ReadablePage], not the app's navigator: a video, a call and a sheet's
/// scrim still reach the window's edges, and what is placed over the app by where a widget is on screen (a menu, a
/// message held up) is measured from the same corner.
class SafeSides extends StatelessWidget {
  final Widget child;
  const SafeSides({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final sides = EdgeInsets.only(left: media.padding.left, right: media.padding.right);
    // The same tree with no insets: the navigator under it keeps its state through a rotation.
    return ColoredBox(
      color: context.theme.colors.background,
      child: Padding(
        padding: sides,
        child: MediaQuery(
          data: media.copyWith(
            size: Size(media.size.width - sides.horizontal, media.size.height),
            padding: media.padding.copyWith(left: 0, right: 0),
            viewPadding: media.viewPadding.copyWith(left: 0, right: 0),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A full page over a wide window: centered at a width that reads, not stretched across it. A phone's width
/// passes through.
class ReadablePage extends StatelessWidget {
  final Widget child;
  const ReadablePage({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return SafeSides(
      child: Builder(
        builder: (context) {
          final media = MediaQuery.of(context);
          final width = media.size.width < ShellSizes.page ? media.size.width : ShellSizes.page;
          return Center(
            child: SizedBox(
              width: width,
              child: MediaQuery(
                data: media.copyWith(size: Size(width, media.size.height)),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }
}

extension ReadableWidth on Widget {
  /// This page in a [ReadablePage].
  Widget get readable => ReadablePage(child: this);
}
