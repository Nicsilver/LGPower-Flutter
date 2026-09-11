import 'package:flutter/material.dart';

import '../../theme/theme_manager.dart';
import '../widgets/warning_sheet.dart';

/// Stub (plan §03): no iPhone has an IR emitter and this port does not
/// implement Android IR either (out of scope), so the screen always shows
/// the "no IR blaster" warning sheet from spec §4.3 with an added body line,
/// then closes itself on dismissal either way ("Cancel/Got it closes the
/// screen").
class ServiceRemoteScreen extends StatefulWidget {
  const ServiceRemoteScreen({super.key});

  @override
  State<ServiceRemoteScreen> createState() => _ServiceRemoteScreenState();
}

class _ServiceRemoteScreenState extends State<ServiceRemoteScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showStubSheet());
  }

  Future<void> _showStubSheet() async {
    await showWarningSheet(
      context,
      chip: 'NO IR BLASTER',
      title: "This phone can't transmit",
      body: "The service remote sends raw IR and this phone has no IR emitter. "
          "It needs a phone with a built-in IR blaster.\n\n"
          "On iPhone the service remote is not available. Use the Android app "
          "on a phone with an IR blaster.",
      button: 'Got it',
    );
    // Closes either way (spec §4.3: "Cancel/Got it closes the screen") --
    // there's nothing to persist here, so accept vs. cancel doesn't matter.
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Scaffold(
      backgroundColor: theme.windowBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SERVICE MODE',
                style: TextStyle(
                  fontSize: 18,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.04 * 18,
                  color: theme.primaryText,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 3, bottom: 9),
                child: Text(
                  'NEC 0x04 over IR · aim at the TV',
                  style: TextStyle(fontSize: 10.5, fontFamily: 'monospace', color: theme.sectionLabel),
                ),
              ),
              const _HazardBand(),
            ],
          ),
        ),
      ),
    );
  }
}

class _HazardBand extends StatelessWidget {
  const _HazardBand();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: 5, width: double.infinity, child: CustomPaint(painter: _HazardPainter()));
  }
}

class _HazardPainter extends CustomPainter {
  const _HazardPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = const Color(0xFFE8A33D)
      ..strokeWidth = 6;
    for (double x = -size.height - 120; x < size.width + 120; x += 12) {
      canvas.drawLine(Offset(x, size.height + 60), Offset(x + size.height + 120, -60), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HazardPainter oldDelegate) => false;
}
