import 'package:flutter/material.dart';

import '../../../theme/theme_manager.dart';
import '../remote_controller.dart';
import 'press_scale.dart';

/// App shortcut pills above the Power row (spec §9): 1-3 shortcuts share one
/// row, exactly 4 become two rows of two. Text-only, coloured pills -- no
/// icons on the main screen (those live in the settings app grid).
class ShortcutsRow extends StatelessWidget {
  const ShortcutsRow({super.key, required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final shortcuts = controller.shortcuts;
    if (shortcuts.isEmpty) return const SizedBox.shrink();
    final rows = shortcuts.length == 4
        ? [shortcuts.sublist(0, 2), shortcuts.sublist(2, 4)]
        : [shortcuts];

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
                      color: Color(controller.client.loadCachedColor(rows[i][j].id) ??
                          theme.circleBtnBg.toARGB32()),
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
  const _ShortcutPill({required this.title, required this.color, required this.onTap});

  final String title;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      pressedScale: 0.95,
      onTap: onTap,
      semanticLabel: title,
      child: Container(
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16)),
        alignment: Alignment.center,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
    );
  }
}
