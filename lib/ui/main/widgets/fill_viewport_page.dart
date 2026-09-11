import 'package:flutter/material.dart';

/// The main remote and numpad scrolls both need to fill the screen when tall
/// and scroll when short (spec §18: `fillViewport=true` on an Android
/// `ScrollView`). `ConstrainedBox(minHeight)` alone doesn't let `Spacer`s
/// inside a `Column` size themselves -- a vertical `SingleChildScrollView`
/// gives its child unbounded height, and `Expanded`/`Spacer` need a bounded
/// one. `IntrinsicHeight` supplies that: `RenderFlex`'s intrinsic-height pass
/// gives flexible children a real (non-zero) share based on the rigid
/// children's extent, so the spacers still divide the leftover space evenly.
class FillViewportPage extends StatelessWidget {
  const FillViewportPage({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight = (constraints.maxHeight - padding.vertical).clamp(0.0, double.infinity);
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}
