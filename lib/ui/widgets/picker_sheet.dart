import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import 'section.dart';

/// (id, label, is currently active) — one row in the sheet.
typedef PickerRow = (String id, String label, bool ticked);

/// Bottom sheet picker (spec 3.5), mirroring `PickerSheet.kt`'s
/// `showPickerSheet`. Selecting a row waits 110ms before dismissing so its
/// ripple is visible first; [onLongPress], when given, dismisses immediately
/// with a haptic (the caller is expected to show a follow-up action sheet —
/// this function only reports which row id was held).
Future<void> showPickerSheet(
  BuildContext context, {
  required String title,
  required List<PickerRow> rows,
  required ValueChanged<String> onSelect,
  ValueChanged<String>? onLongPress,
}) {
  final theme = AppTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    // The Material default sheet shape/clip would round its own corners on
    // top of the windowBg container painting its own 20dp top radius below.
    shape: const RoundedRectangleBorder(),
    builder: (sheetContext) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        decoration: BoxDecoration(
          color: theme.windowBg,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(bottom: 8), child: SectionLabel(title)),
            SurfaceCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const RowDivider(),
                    _PickerRowTile(
                      row: rows[i],
                      theme: theme,
                      onTap: () async {
                        // Let the ripple show before the sheet goes away.
                        await Future.delayed(const Duration(milliseconds: 110));
                        if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                        onSelect(rows[i].$1);
                      },
                      onLongPress: onLongPress == null
                          ? null
                          : () {
                              // Flutter has no equivalent of Android's
                              // HapticFeedbackConstants.LONG_PRESS; heavyImpact
                              // is the closest built-in analog.
                              HapticFeedback.heavyImpact();
                              Navigator.of(sheetContext).pop();
                              onLongPress(rows[i].$1);
                            },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PickerRowTile extends StatelessWidget {
  const _PickerRowTile({
    required this.row,
    required this.theme,
    required this.onTap,
    this.onLongPress,
  });

  final PickerRow row;
  final ThemeConfig theme;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final (_, label, ticked) = row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        splashColor: theme.primaryText.withAlpha(0x2A),
        highlightColor: theme.primaryText.withAlpha(0x2A),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 15, color: theme.primaryText)),
              ),
              if (ticked)
                Text(
                  '✓',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: theme.btnAccentBg,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
