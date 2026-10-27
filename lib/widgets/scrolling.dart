import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Scrolls like iOS on every platform: bounce at the ends, and no stretch or glow.
class DuvetScrollBehavior extends MaterialScrollBehavior {
  const DuvetScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    // getPlatform reports the host OS on the web, which should keep the touch rate.
    final desktop =
        !kIsWeb &&
        switch (getPlatform(context)) {
          TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
          _ => false,
        };
    return BouncingScrollPhysics(
      decelerationRate: desktop ? ScrollDecelerationRate.fast : ScrollDecelerationRate.normal,
      parent: const RangeMaintainingScrollPhysics(),
    );
  }

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}

/// Pages that turn on a light flick and settle quickly, as a carousel of
/// cards should: the bounce's own spring is soft, and a page asked a flick
/// twice as fast.
class CarouselPhysics extends PageScrollPhysics {
  const CarouselPhysics({super.parent});

  @override
  CarouselPhysics applyTo(ScrollPhysics? ancestor) => CarouselPhysics(parent: buildParent(ancestor));

  @override
  double get minFlingVelocity => kMinFlingVelocity;

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(mass: 0.5, stiffness: 300);
}

/// Glides each mouse wheel tick to its target over a few frames instead of
/// jumping there.
///
/// Every Scrollable claims wheel events for itself through the pointer signal
/// resolver, so nothing in the widget tree can smooth them app-wide. The
/// binding splits each tick into ordinary wheel events instead, so lists still
/// clamp at their ends and never overscroll into the bounce.
mixin SmoothWheelBinding on GestureBinding, SchedulerBinding {
  // Seconds the remaining distance takes to shrink by a factor of e.
  static const _tau = 0.1;
  static const _frame = Duration(microseconds: 16667);

  PointerScrollEvent? _tick;
  Offset _pending = Offset.zero;
  Duration? _lastFrame;
  bool _scheduled = false;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerScrollInertiaCancelEvent) _pending = Offset.zero;
    // Trackpads already scroll smoothly; the web is left as the browser sends it.
    if (kIsWeb ||
        event is! PointerScrollEvent ||
        event.kind != PointerDeviceKind.mouse ||
        platformDispatcher.accessibilityFeatures.disableAnimations) {
      return super.handlePointerEvent(event);
    }
    final previous = _tick;
    final delta = event.scrollDelta;
    if (previous == null ||
        previous.device != event.device ||
        previous.viewId != event.viewId ||
        (previous.position - event.position).distance > 8 ||
        _pending.dx * delta.dx < 0 ||
        _pending.dy * delta.dy < 0) {
      _pending = Offset.zero;
    }
    _tick = event;
    _pending += delta;
    // The first slice goes out while the real event is still handled, so its answer reaches the engine.
    _slice(_frame, event.respond);
    if (_pending != Offset.zero && !_scheduled) {
      _scheduled = true;
      _lastFrame = null;
      scheduleFrameCallback(_onFrame);
    }
  }

  void _onFrame(Duration now) {
    _scheduled = false;
    if (_pending == Offset.zero) return;
    final last = _lastFrame;
    _lastFrame = now;
    _slice(last == null ? _frame : now - last);
    if (_pending != Offset.zero) {
      _scheduled = true;
      scheduleFrameCallback(_onFrame);
    }
  }

  void _slice(Duration dt, [RespondPointerEventCallback? respond]) {
    final share = 1 - math.exp(-dt.inMicroseconds / Duration.microsecondsPerSecond / _tau);
    var delta = _pending * share;
    if ((_pending - delta).distance < 0.5) delta = _pending;
    _pending -= delta;
    final tick = _tick!;
    super.handlePointerEvent(
      PointerScrollEvent(
        viewId: tick.viewId,
        timeStamp: tick.timeStamp,
        kind: tick.kind,
        device: tick.device,
        position: tick.position,
        scrollDelta: delta,
        embedderId: tick.embedderId,
        onRespond: respond,
      ),
    );
  }
}

class DuvetBinding extends WidgetsFlutterBinding with SmoothWheelBinding {}
