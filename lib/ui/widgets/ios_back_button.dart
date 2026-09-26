import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../theme/theme_manager.dart';

/// "‹ Remote" chevron above a pushed screen's big title, iPhone only. The
/// screens draw their own title instead of an AppBar, so iOS users would
/// otherwise have only the edge swipe; Android has its system back.
class IosBackButton extends StatelessWidget {
  const IosBackButton(this.label, {super.key});

  /// The screen underneath, as iOS names the back button after it.
  final String label;

  static bool visible(BuildContext context) =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      (ModalRoute.of(context)?.canPop ?? false);

  @override
  Widget build(BuildContext context) {
    if (!visible(context)) return const SizedBox.shrink();
    final color = AppTheme.of(context).btnAccentBg;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(44, 44),
      // maybePop so PopScope handlers (TV detail saves on the way out) still run
      onPressed: () => Navigator.maybePop(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.back, size: 26, color: color),
          Text(label, style: TextStyle(fontSize: 17, color: color)),
        ],
      ),
    );
  }
}
