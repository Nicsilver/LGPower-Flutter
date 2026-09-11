import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Renders `assets/icons/<name>.svg` (converted from the Android `ic_*.xml`
/// vectors by `tool/vd2svg.py`), tinted with [color] via a srcIn colour
/// filter — the originals were always drawn as single-colour tintable
/// vectors, so the filter replaces whatever fill/stroke the SVG carries.
class AppIcon extends StatelessWidget {
  const AppIcon(this.name, {super.key, this.size = 24, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/$name.svg',
      width: size,
      height: size,
      colorFilter: color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}
