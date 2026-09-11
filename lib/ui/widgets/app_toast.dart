import 'package:flutter/material.dart';

/// Bottom floating dark pill mimicking Android's system `Toast` (spec 8's
/// toast inventory) — not a SnackBar with an action, and not themed: the
/// real Android Toast ignores the app's theme too. `long` maps to Android's
/// LENGTH_SHORT (2s) / LENGTH_LONG (3.5s).
void showToast(BuildContext context, String text, {bool long = false}) {
  final overlay = Overlay.of(context);
  final entry = OverlayEntry(builder: (_) => _ToastPill(text: text));
  overlay.insert(entry);
  Future.delayed(Duration(milliseconds: long ? 3500 : 2000), () {
    if (entry.mounted) entry.remove();
    entry.dispose();
  });
}

class _ToastPill extends StatelessWidget {
  const _ToastPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 24,
      right: 24,
      bottom: 64,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xE6333333),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
