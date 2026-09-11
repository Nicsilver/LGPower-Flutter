import 'package:flutter/material.dart';

import '../../theme/theme_manager.dart';

/// Switch painted from the theme's `switch_track_on/off` and
/// `switch_thumb_on/off` roles, matching the Android AppCompat switch's own
/// geometry (40x17dp track, 24dp thumb) instead of Material's Switch, which
/// has no themed equivalent for the M3 track outline and reads nothing like
/// the Kotlin app's control.
class AppSwitch extends StatefulWidget {
  const AppSwitch({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch> with SingleTickerProviderStateMixin {
  static const _trackWidth = 40.0;
  static const _trackHeight = 17.0;
  static const _thumbSize = 24.0;
  static const _thumbCenterOff = 12.0;
  static const _thumbCenterOn = 28.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    value: widget.value ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant AppSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      widget.value ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onChanged == null ? null : () => widget.onChanged!(!widget.value),
      child: SizedBox(
        width: _trackWidth,
        height: 48,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            final trackColor = Color.lerp(theme.switchTrackOff, theme.switchTrackOn, t)!;
            final thumbColor = Color.lerp(theme.switchThumbOff, theme.switchThumbOn, t)!;
            final thumbCenterX = _thumbCenterOff + (_thumbCenterOn - _thumbCenterOff) * t;
            return Center(
              child: SizedBox(
                width: _trackWidth,
                height: _thumbSize,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: (_thumbSize - _trackHeight) / 2,
                      child: Container(
                        width: _trackWidth,
                        height: _trackHeight,
                        decoration: BoxDecoration(
                          color: trackColor,
                          borderRadius: BorderRadius.circular(_trackHeight / 2),
                        ),
                      ),
                    ),
                    Positioned(
                      left: thumbCenterX - _thumbSize / 2,
                      top: 0,
                      child: Container(
                        width: _thumbSize,
                        height: _thumbSize,
                        decoration: BoxDecoration(
                          color: thumbColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 2,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
