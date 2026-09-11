import 'package:flutter/material.dart';

import '../../theme/theme_manager.dart';

/// Switch painted from the theme's `switch_track_on/off` and
/// `switch_thumb_on/off` roles, scaled 1.2x like the Kotlin source. The
/// Material 3 track outline has no themed equivalent, so it's suppressed.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Transform.scale(
      scale: 1.2,
      child: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: theme.switchThumbOn,
        activeTrackColor: theme.switchTrackOn,
        inactiveThumbColor: theme.switchThumbOff,
        inactiveTrackColor: theme.switchTrackOff,
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    );
  }
}
