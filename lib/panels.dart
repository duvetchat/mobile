import 'package:flutter/material.dart';
import 'dart:core';

const double bleedWidth = 20;

/// Display sections
enum RevealSide { left, right, main }

/// Widget to display three view panels with the [OverlappingPanels.main] being
/// in the center, [OverlappingPanels.left] and [OverlappingPanels.right] also
/// revealing from their respective sides. Just like you will see in the
/// Discord mobile app's navigation.
class OverlappingPanels extends StatefulWidget {
  /// The left panel
  final Widget? left;

  /// The main panel
  final Widget main;

  /// The right panel
  final Widget? right;

  /// The offset to use to keep the main panel visible when the left or right
  /// panel is revealed.
  final double restWidth;

  /// A callback to notify when a panel reveal has completed.
  final ValueChanged<RevealSide>? onSideChange;

  const OverlappingPanels({
    this.left,
    required this.main,
    this.right,
    this.restWidth = 40,
    this.onSideChange,
    super.key,
  });

  static OverlappingPanelsState? of(BuildContext context) {
    return context.findAncestorStateOfType<OverlappingPanelsState>();
  }

  @override
  State<StatefulWidget> createState() {
    return OverlappingPanelsState();
  }
}

class OverlappingPanelsState extends State<OverlappingPanels>
    with TickerProviderStateMixin {
  AnimationController? controller;
  double translate = 0;

  double _calculateGoal(double width, int multiplier) {
    return (multiplier * width) + (-multiplier * widget.restWidth);
  }

  void _onApplyTranslation() {
    final mediaWidth = MediaQuery.of(context).size.width;

    final animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    animationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (widget.onSideChange != null) {
          widget.onSideChange!(
            translate == 0
                ? RevealSide.main
                : (translate > 0 ? RevealSide.left : RevealSide.right),
          );
        }
        animationController.dispose();
      }
    });

    if (translate.abs() >= mediaWidth / 2) {
      final multiplier = (translate > 0 ? 1 : -1);
      final goal = _calculateGoal(mediaWidth, multiplier);
      final Tween<double> tween = Tween(begin: translate, end: goal);

      final animation = tween.animate(animationController);

      animation.addListener(() {
        setState(() {
          translate = animation.value;
        });
      });
    } else {
      final animation = Tween<double>(
        begin: translate,
        end: 0,
      ).animate(animationController);

      animation.addListener(() {
        setState(() {
          translate = animation.value;
        });
      });
    }

    animationController.forward();
  }

  void reveal(RevealSide direction) {
    // can only reveal when showing main
    if (translate != 0) {
      return;
    }

    final mediaWidth = MediaQuery.of(context).size.width;

    final multiplier = (direction == RevealSide.left ? 1 : -1);
    final goal = _calculateGoal(mediaWidth, multiplier);

    final animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    animationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _onApplyTranslation();
        animationController.dispose();
      }
    });

    final animation = Tween<double>(
      begin: translate,
      end: goal,
    ).animate(animationController);

    animation.addListener(() {
      setState(() {
        translate = animation.value;
      });
    });

    animationController.forward();
  }

  void onTranslate(double delta) {
    setState(() {
      final mediaWidth = MediaQuery.of(context).size.width;

      // Check full-open goals
      double? rightGoal = widget.right != null
          ? _calculateGoal(mediaWidth, -1)
          : null;
      double? leftGoal = widget.left != null
          ? _calculateGoal(mediaWidth, 1)
          : null;

      // Right panel fully open? Only allow closing (positive delta) or staying.
      if (rightGoal != null && translate == rightGoal) {
        if (delta > 0) {
          // Move toward main (less negative)
          translate = (translate + delta).clamp(rightGoal, 0.0);
        }
        // else: block (do nothing) – prevents further opening
        return;
      }

      // Left panel fully open? Only allow closing (negative delta) or staying.
      if (leftGoal != null && translate == leftGoal) {
        if (delta < 0) {
          translate = (translate + delta).clamp(0.0, leftGoal);
        }
        return;
      }

      // Normal dragging with safety clamps (prevents crossing zero)
      final newVal = this.translate + delta;
      if (widget.right != null && this.translate < 0) {
        if (newVal <= 0) {
          this.translate = newVal;
        } else {
          this.translate = 0;
        }
      } else if (widget.left != null && this.translate > 0) {
        if (newVal >= 0) {
          this.translate = newVal;
        } else {
          this.translate = 0;
        }
      } else if (this.translate == 0) {
        if (widget.right != null && newVal < 0) {
          this.translate = newVal;
        } else if (widget.left != null && newVal > 0) {
          this.translate = newVal;
        } else {
          this.translate = 0;
        }
      } else {
        this.translate = 0; // snap back
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Offstage(offstage: translate < 0, child: widget.left),
        Offstage(offstage: translate > 0, child: widget.right),
        Transform.translate(offset: Offset(translate, 0), child: widget.main),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (details) {
            onTranslate(details.delta.dx);
          },
          onHorizontalDragEnd: (details) {
            _onApplyTranslation();
          },
        ),
      ],
    );
  }
}
