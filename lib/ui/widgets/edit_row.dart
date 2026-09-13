import 'package:flutter/material.dart';

import '../../theme/theme_manager.dart';

/// Settings-style row: label on the left, a borderless right-aligned text
/// field filling the rest (the TV detail screen's Name / IP / MAC rows).
class EditRow extends StatelessWidget {
  const EditRow({
    super.key,
    required this.label,
    required this.controller,
    required this.hint,
    this.focusNode,
    this.keyboardType = TextInputType.text,
    this.textCapitalization = TextCapitalization.none,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final FocusNode? focusNode;
  final TextInputType keyboardType;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 15, color: theme.primaryText)),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textAlign: TextAlign.end,
              keyboardType: keyboardType,
              textCapitalization: textCapitalization,
              maxLines: 1,
              style: TextStyle(fontSize: 15, color: theme.secondaryText),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: hint,
                hintStyle: TextStyle(color: theme.secondaryText.withAlpha(120)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
