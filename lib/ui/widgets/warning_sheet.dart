import 'package:flutter/material.dart';

import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import 'buttons.dart';

/// Bottom sheet warning shared by the service-remote stub and the
/// keep-screen-on toggle: grab handle, red mono chip, title, body, one accent
/// button. The button is the only path that counts as acceptance -- dismissing
/// any other way (tap outside, back) is a cancel, so callers that must persist
/// something only on explicit agreement can rely on [onCancel] firing for
/// every other dismissal.
Future<void> showWarningSheet(
  BuildContext context, {
  required String chip,
  required String title,
  required String body,
  required String button,
  VoidCallback? onAccept,
  VoidCallback? onCancel,
}) async {
  final theme = AppTheme.of(context);
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    shape: const RoundedRectangleBorder(),
    // The Kotlin dialog is WRAP_CONTENT height with no cap; without this the
    // default modal sheet clamps to a fraction of the screen and a long body
    // (e.g. the service remote's factory-controls warning) overflows it.
    isScrollControlled: true,
    builder: (_) => _WarningSheet(theme: theme, chip: chip, title: title, body: body, buttonLabel: button),
  );
  if (accepted ?? false) {
    onAccept?.call();
  } else {
    onCancel?.call();
  }
}

class _WarningSheet extends StatelessWidget {
  const _WarningSheet({
    required this.theme,
    required this.chip,
    required this.title,
    required this.body,
    required this.buttonLabel,
  });

  final ThemeConfig theme;
  final String chip;
  final String title;
  final String body;
  final String buttonLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
      decoration: BoxDecoration(
        color: theme.surfaceBg,
        borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(color: theme.divider, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(9, 2, 9, 2),
            margin: const EdgeInsets.only(bottom: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: const Color(0x59E05555), width: 1),
            ),
            child: Text(
              chip,
              style: const TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                letterSpacing: 0.9,
                color: Color(0xFFE05555),
              ),
            ),
          ),
          Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: theme.primaryText)),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: Text(body, style: TextStyle(fontSize: 13, color: theme.secondaryText)),
          ),
          SizedBox(
            width: double.infinity,
            child: AccentButton(
              label: buttonLabel,
              height: 46,
              radius: 11,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ),
        ],
      ),
    );
  }
}
