import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../core/haptics.dart';
import '../../core/tip_service.dart';
import '../../theme/theme_manager.dart';
import 'app_toast.dart';
import 'section.dart';

const _tileNames = {
  'tip_small': 'Small tip',
  'tip_medium': 'Medium tip',
  'tip_large': 'Large tip',
};

/// Bottom sheet with one price tile per tip size. Closes itself once a tip
/// goes through; a cancel just stops the spinner, a failure toasts.
Future<void> showTipSheet(BuildContext context, TipService service) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    isScrollControlled: true,
    // Same as the picker sheet: the default shape would round the corners again.
    shape: const RoundedRectangleBorder(),
    builder: (_) => TipSheetBody(service: service),
  );
}

class TipSheetBody extends StatefulWidget {
  const TipSheetBody({super.key, required this.service});

  final TipService service;

  @override
  State<TipSheetBody> createState() => _TipSheetBodyState();
}

class _TipSheetBodyState extends State<TipSheetBody> {
  StreamSubscription<TipOutcome>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.service.outcomes.listen(_onOutcome);
  }

  void _onOutcome(TipOutcome outcome) {
    if (!mounted) return;
    switch (outcome) {
      case TipOutcome.thanked:
        Haptics.medium();
        Navigator.of(context).pop();
      case TipOutcome.awaitingApproval:
        showToast(context, 'The tip is waiting for approval.', long: true);
      case TipOutcome.cancelled:
        break;
      case TipOutcome.failed:
        showToast(context, 'The tip did not go through. Please try again.', long: true);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      decoration: BoxDecoration(
        color: theme.windowBg,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: ListenableBuilder(
        listenable: widget.service,
        builder: (context, _) {
          final service = widget.service;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: SectionLabel('Leave a tip'),
              ),
              Row(
                children: [
                  for (var i = 0; i < service.products.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _TipTile(
                        product: service.products[i],
                        pending: service.pendingId == service.products[i].id,
                        enabled: service.pendingId == null,
                        onTap: () {
                          Haptics.light();
                          unawaited(service.buy(service.products[i]));
                        },
                      ),
                    ),
                  ],
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                child: Text(
                  "Doesn't unlock anything. Thanks for thinking of it.",
                  style: TextStyle(fontSize: 12, height: 1.4, color: theme.secondaryText),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TipTile extends StatelessWidget {
  const _TipTile({
    required this.product,
    required this.pending,
    required this.enabled,
    required this.onTap,
  });

  final ProductDetails product;
  final bool pending;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return SurfaceCard(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          splashColor: theme.primaryText.withAlpha(0x2A),
          highlightColor: theme.primaryText.withAlpha(0x2A),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            height: 104,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _tileNames[product.id] ?? product.title,
                  style: TextStyle(fontSize: 12, color: theme.secondaryText),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 28,
                  child: Center(
                    child: pending
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.primaryText,
                            ),
                          )
                        : Text(
                            product.price,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w500,
                              color: theme.primaryText,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
