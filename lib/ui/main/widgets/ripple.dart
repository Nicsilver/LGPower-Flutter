import 'package:flutter/material.dart';

/// Soft translucent foreground colour for button ripples: white on dark
/// themes, black on light ones.
Color rippleColorOf(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0x33FFFFFF) : const Color(0x1F000000);

/// Paints a bounded ripple over [child] from the raw pointer position.
///
/// It is a plain pointer [Listener] rather than an `InkResponse` so it never
/// joins the gesture arena: the ripple starts on the first contact (no
/// recogniser delay) and the caller's own tap, hold and repeat handling stay
/// exactly as they were. The app theme sets `NoSplash`, so the splash factory
/// is passed explicitly.
class PointerRipple extends StatefulWidget {
  const PointerRipple({super.key, required this.child, this.shape = const CircleBorder(), this.enabled = true});

  final Widget child;
  final ShapeBorder shape;
  final bool enabled;

  @override
  State<PointerRipple> createState() => _PointerRippleState();
}

class _PointerRippleState extends State<PointerRipple> {
  // A context below the Material: Material.of looks above the context it is given.
  BuildContext? _layer;
  InteractiveInkFeature? _splash;

  void _down(PointerDownEvent event) {
    if (!widget.enabled) return;
    final layer = _layer;
    final box = layer?.findRenderObject();
    if (layer == null || !layer.mounted || box is! RenderBox || !box.hasSize) return;
    _splash?.cancel();
    _splash = InkRipple.splashFactory.create(
      controller: Material.of(layer),
      referenceBox: box,
      position: box.globalToLocal(event.position),
      color: rippleColorOf(context),
      containedInkWell: true,
      customBorder: widget.shape,
      textDirection: Directionality.of(context),
      onRemoved: () => _splash = null,
    );
  }

  void _up(PointerUpEvent event) => _splash?.confirm();

  void _cancel(PointerCancelEvent event) => _splash?.cancel();

  // Before the Material below is torn down: its ripple tickers must be gone by then.
  @override
  void deactivate() {
    _splash?.dispose();
    _splash = null;
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: Material(
                type: MaterialType.transparency,
                child: Builder(
                  builder: (layer) {
                    _layer = layer;
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
