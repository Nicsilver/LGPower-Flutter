import 'package:flutter/material.dart';

/// The main remote and numpad scrolls both need to fill the screen when tall
/// and scroll when short (spec §18: `fillViewport=true` on an Android
/// `ScrollView`). `ConstrainedBox(minHeight)` alone doesn't let `Spacer`s
/// inside a `Column` size themselves -- a vertical `SingleChildScrollView`
/// gives its child unbounded height, and `Expanded`/`Spacer` need a bounded
/// one. `IntrinsicHeight` supplies that: `RenderFlex`'s intrinsic-height pass
/// gives flexible children a real (non-zero) share based on the rigid
/// children's extent, so the spacers still divide the leftover space evenly.
class FillViewportPage extends StatefulWidget {
  const FillViewportPage({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> children;
  final EdgeInsets padding;

  /// Lets a raw-pointer-driven descendant (e.g. `LevelPill`) suspend this
  /// page's own scrolling for the life of its drag, mirroring Android's
  /// `requestDisallowInterceptTouchEvent` -- otherwise the page's vertical
  /// drag competes with the pill's, and the pill only ever sees the final
  /// pointer-up. Found by ancestor state so callers need no wiring.
  static ValueNotifier<bool>? scrollLockOf(BuildContext context) {
    return context.findAncestorStateOfType<_FillViewportPageState>()?._scrollLock;
  }

  @override
  State<FillViewportPage> createState() => _FillViewportPageState();
}

class _FillViewportPageState extends State<FillViewportPage> {
  final _scrollLock = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _scrollLock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight = (constraints.maxHeight - widget.padding.vertical).clamp(0.0, double.infinity);
        final content = ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: widget.children,
            ),
          ),
        );
        return ValueListenableBuilder<bool>(
          valueListenable: _scrollLock,
          builder: (context, locked, child) => SingleChildScrollView(
            padding: widget.padding,
            physics: locked ? const NeverScrollableScrollPhysics() : null,
            child: child,
          ),
          child: content,
        );
      },
    );
  }
}
