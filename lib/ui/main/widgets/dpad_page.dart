import 'package:flutter/material.dart';

import '../../../core/haptics.dart';
import '../../../theme/theme_manager.dart';
import '../../widgets/app_icon.dart';
import '../dims.dart';
import '../remote_controller.dart';
import 'circle_button.dart';
import 'dpad.dart';
import 'fill_viewport_page.dart';

/// The d-pad panel: swapped in by `main_screen.dart` in place of the main
/// column, like [NumpadPage], while the touchpad stands in for the d-pad on
/// the remote. It hosts the very same [Dpad] widget, so key sending, hold to
/// repeat and haptics cannot drift from the normal ring.
class DpadPage extends StatelessWidget {
  const DpadPage({super.key, required this.controller, required this.onClose});

  final RemoteController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final dims = MainDims.of(context);
    return FillViewportPage(
      // Same insets as the remote so the Remote button lands where the D-pad button sits
      padding: EdgeInsets.fromLTRB(dims.mainPadH, 16, dims.mainPadH, 48),
      children: [
        SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'D-pad',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.primaryText),
            ),
          ),
        ),
        const Spacer(),
        Center(child: Dpad(controller: controller, size: dims.dpadSize, okSize: dims.okSize)),
        const Spacer(),
        Center(
          child: CircleButton(
            size: 56,
            color: theme.circleBtnBg,
            label: 'Remote',
            labelColor: theme.secondaryText,
            semanticLabel: 'Back to Remote',
            onTap: () {
              Haptics.light();
              onClose();
            },
            child: AppIcon('ic_remote', size: 24, color: theme.circleBtnIconTint),
          ),
        ),
      ],
    );
  }
}
