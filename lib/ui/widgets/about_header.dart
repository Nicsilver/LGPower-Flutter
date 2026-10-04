import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/tip_service.dart';
import '../../theme/theme_manager.dart';
import 'app_icon.dart';
import 'buttons.dart';
import 'tip_sheet.dart';

/// App card at the top of Settings > About: icon, name, version and, where
/// tipping is on offer, the tip button.
class AboutHeader extends StatelessWidget {
  const AboutHeader({super.key, required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final tips = TipScope.of(context);
    final canTip = tips != null && tips.canTip;
    final tipped = canTip && tips.hasTipped;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, canTip ? 16 : 14),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset('assets/images/app_icon.png', width: 52, height: 52),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LG Power',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        color: theme.primaryText,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (tipped)
                      Row(
                        children: [
                          AppIcon('ic_heart_filled', size: 12, color: theme.secondaryText),
                          const SizedBox(width: 4),
                          Text(
                            'Thanks for the tip!',
                            style: TextStyle(fontSize: 12, color: theme.secondaryText),
                          ),
                        ],
                      )
                    else
                      Text(
                        version.isEmpty ? 'Free, no ads' : 'Version $version · free, no ads',
                        style: TextStyle(fontSize: 12, color: theme.secondaryText),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (canTip)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: tipped
                ? GhostButton(label: 'Tip again', height: 44, onPressed: () => _open(context, tips))
                : AccentButton(
                    label: 'Leave a tip',
                    icon: 'ic_heart',
                    height: 44,
                    onPressed: () => _open(context, tips),
                  ),
          ),
      ],
    );
  }

  void _open(BuildContext context, TipService tips) {
    Haptics.light();
    showTipSheet(context, tips);
  }
}
