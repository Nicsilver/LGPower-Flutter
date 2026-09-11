import 'package:flutter/material.dart';

/// Shared press-scale feedback (spec §5's "global press animation"): scale to
/// [pressedScale] over 70ms on down, back to 1.0 over 150ms on up/cancel,
/// same as Android's `applyPressAnimations`. The listener still lets the tap
/// fire (Android's touch listener returns `false` for the same reason).
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.82,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final String? semanticLabel;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 1,
    lowerBound: widget.pressedScale,
    upperBound: 1.0,
    duration: const Duration(milliseconds: 150),
    reverseDuration: const Duration(milliseconds: 70),
  );

  // A raw pointer down/up pair that lands inside the 70ms down animation
  // would otherwise call reverse() then forward() back to back, reversing
  // direction mid-flight so a quick tap never visibly reaches pressedScale.
  // Queuing the up until the down's TickerFuture completes guarantees the
  // full dip is seen even on the fastest tap.
  bool _releasePending = false;

  void _onDown() {
    if (widget.onTap == null) return;
    _releasePending = false;
    _controller.reverse().whenComplete(() {
      if (_releasePending && mounted) _controller.forward();
    });
  }

  void _onRelease() {
    if (widget.onTap == null) return;
    if (_controller.status == AnimationStatus.reverse) {
      _releasePending = true;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      // A raw Listener fires on the very first pointer contact regardless of
      // the gesture arena -- GestureDetector's onTapDown is delayed until the
      // tap recognizer actually wins (an ancestor scrollable, or another
      // recognizer on this same detector, can hold that up), which is late
      // enough to read as no press feedback at all on a quick tap.
      child: Listener(
        onPointerDown: (_) => _onDown(),
        onPointerUp: (_) => _onRelease(),
        onPointerCancel: (_) => _onRelease(),
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: ScaleTransition(scale: _controller, child: widget.child),
        ),
      ),
    );
  }
}
