import 'package:flutter/material.dart';

import '../../theme/theme_manager.dart';

// Android's letterSpacing is in em (a fraction of the text size); Flutter's
// TextStyle.letterSpacing is in logical pixels, so every spot that copies a
// spec letterSpacing value has to scale it by the font size first.
double _letterSpacingPx(double em, double fontSize) => em * fontSize;

/// ALL-CAPS section header — "TV CONNECTION", "THEME" (picker title), etc.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    const fontSize = 12.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: fontSize,
          letterSpacing: _letterSpacingPx(0.06, fontSize),
          color: theme.sectionLabel,
        ),
      ),
    );
  }
}

/// Rounded card in `surfaceBg` — section/group cards, pairing card, etc.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({super.key, required this.child, this.radius = 14});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(color: theme.surfaceBg, child: child),
    );
  }
}

/// 1dp hairline between rows, inset to line up with row text (`marginStart
/// 16dp`).
class RowDivider extends StatelessWidget {
  const RowDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Container(height: 1, color: theme.divider),
    );
  }
}
