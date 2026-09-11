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
      child: GestureDetector(
        onTapDown: widget.onTap == null ? null : (_) => _controller.reverse(),
        onTapCancel: widget.onTap == null ? null : () => _controller.forward(),
        onTapUp: widget.onTap == null ? null : (_) => _controller.forward(),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: ScaleTransition(scale: _controller, child: widget.child),
      ),
    );
  }
}
