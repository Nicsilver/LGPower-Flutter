import 'package:flutter/material.dart';

import '../../theme/release_notes.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import 'buttons.dart';

// See the identical helper in section.dart: Android letterSpacing is in em,
// Flutter's is in logical pixels.
double _letterSpacingPx(double em, double fontSize) => em * fontSize;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Formats an ISO `yyyy-MM-dd` date as "d MMM yyyy" (e.g. "11 Sep 2026"),
/// matching `DateTimeFormatter.ofPattern("d MMM yyyy")` in the Kotlin source.
/// Done by hand rather than pulling in `intl` for one format string.
String _formatReleaseDate(String isoDate) {
  final parts = isoDate.split('-');
  final year = parts[0];
  final month = int.parse(parts[1]);
  final day = int.parse(parts[2]);
  return '$day ${_months[month - 1]} $year';
}

/// Centred history/what's-new dialog (spec 5.2), mirroring
/// `showReleaseNotesDialog` in the Kotlin source. Used both for the full
/// "Release notes" list (Settings > About, `markLatest: true`) and the
/// post-update "What's new" popup (a filtered slice, no Latest chip).
Future<void> showReleaseNotesDialog(
  BuildContext context, {
  required String title,
  required List<Release> releases,
  required String buttonLabel,
  bool markLatest = false,
}) {
  final theme = AppTheme.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierLabel: title,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final size = MediaQuery.of(dialogContext).size;
      final maxListHeight = size.height * 0.62;
      return Center(
        child: SizedBox(
          width: size.width - 48,
          // showGeneralDialog (unlike showDialog's DialogRoute) doesn't supply
          // a Material ancestor itself, so text below falls back to the
          // framework's "no Material found" debug style (double underline).
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
              decoration: BoxDecoration(
                color: theme.windowBg,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: theme.btnGhostBorder, width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: _letterSpacingPx(-0.015, 24),
                      color: theme.primaryText,
                    ),
                  ),
                  const SizedBox(height: 18),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxListHeight),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (var i = 0; i < releases.length; i++)
                            _ReleaseSection(
                              release: releases[i],
                              isFirst: i == 0,
                              showLatestChip: markLatest && i == 0,
                              theme: theme,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  AccentButton(
                    label: buttonLabel,
                    height: 46,
                    radius: 12,
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ReleaseSection extends StatelessWidget {
  const _ReleaseSection({
    required this.release,
    required this.isFirst,
    required this.showLatestChip,
    required this.theme,
  });

  final Release release;
  final bool isFirst;
  final bool showLatestChip;
  final ThemeConfig theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(2, isFirst ? 0 : 18, 2, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                release.name,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: _letterSpacingPx(-0.02, 22),
                  color: theme.primaryText,
                ),
              ),
              if (showLatestChip) ...[
                const SizedBox(width: 10),
                _LatestChip(theme: theme),
              ],
              Expanded(
                child: Text(
                  _formatReleaseDate(release.date),
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 13, color: theme.secondaryText),
                ),
              ),
            ],
          ),
        ),
        for (var j = 0; j < release.notes.length; j++) ...[
          if (j > 0) Container(height: 1, color: theme.divider),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 2, right: 14),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(color: theme.secondaryText, shape: BoxShape.circle),
                  ),
                ),
                Expanded(
                  child: Text(
                    release.notes[j],
                    style: TextStyle(fontSize: 15, height: 1.25, color: theme.primaryText),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _LatestChip extends StatelessWidget {
  const _LatestChip({required this.theme});

  final ThemeConfig theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 4, 9, 4),
      decoration: BoxDecoration(color: theme.btnAccentBg, borderRadius: BorderRadius.circular(999)),
      child: Text(
        'Latest',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: theme.btnAccentText, height: 1.0),
      ),
    );
  }
}
