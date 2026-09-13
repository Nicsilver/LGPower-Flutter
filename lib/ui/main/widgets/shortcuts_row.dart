import 'package:flutter/material.dart';

import '../../../net/webos_client.dart';
import '../../../theme/theme_manager.dart';
import '../remote_controller.dart';
import 'press_scale.dart';

/// App shortcut pills above the Power row (spec §9): one row up to 2
/// shortcuts, otherwise two rows split as evenly as possible (up to 8 in
/// total). Text-only, coloured pills -- no icons on the main screen (those
/// live in the settings app grid).
class ShortcutsRow extends StatelessWidget {
  const ShortcutsRow({super.key, required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final shortcuts = controller.shortcuts;
    if (shortcuts.isEmpty) return const SizedBox.shrink();
    final perRow = shortcuts.length <= 2
        ? shortcuts.length
        : (shortcuts.length + 1) ~/ 2;
    final rows = <List<TvApp>>[];
    for (var i = 0; i < shortcuts.length; i += perRow) {
      rows.add(shortcuts.sublist(i, (i + perRow).clamp(0, shortcuts.length)));
    }
    // Three or four pills across leave too little room for 14 sp labels
    final fontSize = perRow >= 3 ? 12.0 : 14.0;

    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          SizedBox(
            height: 52,
            child: Row(
              children: [
                for (var j = 0; j < rows[i].length; j++) ...[
                  if (j > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _ShortcutPill(
                      title: rows[i][j].title,
                      fontSize: fontSize,
                      color: Color(
                        controller.client.loadCachedColor(rows[i][j].id) ??
                            theme.circleBtnBg.toARGB32(),
                      ),
                      onTap: () => controller.launchShortcut(rows[i][j]),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ShortcutPill extends StatelessWidget {
  const _ShortcutPill({
    required this.title,
    required this.color,
    required this.fontSize,
    required this.onTap,
  });

  final String title;
  final Color color;
  final double fontSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      pressedScale: 0.95,
      onTap: onTap,
      semanticLabel: title,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
