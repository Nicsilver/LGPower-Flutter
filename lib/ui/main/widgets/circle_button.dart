import 'package:flutter/material.dart';

import 'press_scale.dart';

/// One circular remote control + its label underneath (spec §3.1): Home,
/// Mute, Input, Back, Menu, OK, Screen Off, Picture, Colors, Sound and the
/// numpad's "123"/close buttons all render through this. Callers compute
/// [color]/[iconColor] themselves so the active/inactive accent swap (mute,
/// screen off) and the never-themed power red both fall out naturally.
class CircleButton extends StatelessWidget {
  const CircleButton({
    super.key,
    required this.size,
    required this.color,
    required this.child,
    this.label,
    this.labelColor,
    this.labelFontSize = 11,
    this.labelTopMargin = 5,
    this.semanticLabel,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.82,
  });

  final double size;
  final Color color;
  final Widget child;
  final String? label;
  final Color? labelColor;
  final double labelFontSize;
  final double labelTopMargin;
  final String? semanticLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;

  @override
  Widget build(BuildContext context) {
    final circle = PressScale(
      onTap: onTap,
      onLongPress: onLongPress,
      pressedScale: pressedScale,
      semanticLabel: semanticLabel,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: child,
      ),
    );
    if (label == null) return circle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        circle,
        SizedBox(height: labelTopMargin),
        Text(label!, style: TextStyle(fontSize: labelFontSize, color: labelColor)),
      ],
    );
  }
}
