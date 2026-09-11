import 'package:flutter/material.dart';

import '../../theme/theme_manager.dart';

/// Filled call-to-action button (`btn_accent_bg`/`btn_accent_text`) — e.g.
/// "Connect", "Save Theme", the release-notes footer button.
class AccentButton extends StatelessWidget {
  const AccentButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 48,
    this.radius = 10,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return SizedBox(
      height: height,
      child: Material(
        color: theme.btnAccentBg,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onPressed,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: theme.btnAccentText,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outline button (`btn_ghost_border` / `secondary_text`) — e.g. "Cancel",
/// "Delete Theme". The Kotlin source swaps in `btnGhostBgPressed`/
/// `btnGhostBorderPressed` for the pressed state rather than a ripple, so
/// this tracks the press directly instead of using an InkWell splash.
class GhostButton extends StatefulWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 48,
    this.radius = 10,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final double radius;

  @override
  State<GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<GhostButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final border = _pressed ? theme.btnGhostBorderPressed : theme.btnGhostBorder;
    final background = _pressed ? theme.btnGhostBgPressed : Colors.transparent;
    return GestureDetector(
      onTapDown: widget.onPressed == null ? null : (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: widget.onPressed,
      child: Container(
        height: widget.height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(color: border, width: 1),
        ),
        child: Text(
          widget.label,
          style: TextStyle(color: theme.secondaryText, fontSize: 15),
        ),
      ),
    );
  }
}
