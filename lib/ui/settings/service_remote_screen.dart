import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../net/ir.dart';
import '../../theme/color_util.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../widgets/app_toast.dart';
import '../widgets/warning_sheet.dart';

const _amber = Color(0xFFE8A33D);

/// Full IR-only replica of LG's factory service remote (spec §4). Every tile
/// transmits raw NEC 0x04 over the platform channel; there is no network
/// fallback because the TV's service menus don't reliably answer SSAP.
class ServiceRemoteScreen extends StatefulWidget {
  const ServiceRemoteScreen({
    super.key,
    this.hasEmitter = Ir.hasEmitter,
    this.transmit = Ir.transmit,
  });

  /// Injectable for tests; defaults to the real platform channel.
  final Future<bool> Function() hasEmitter;
  final Future<void> Function(int carrierHz, List<int> pattern) transmit;

  @override
  State<ServiceRemoteScreen> createState() => _ServiceRemoteScreenState();
}

class _ServiceRemoteScreenState extends State<ServiceRemoteScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showEntrySheet());
  }

  Future<void> _showEntrySheet() async {
    final hasEmitter = await widget.hasEmitter();
    if (!mounted) return;
    if (!hasEmitter) {
      await showWarningSheet(
        context,
        chip: 'NO IR BLASTER',
        title: "This phone can't transmit",
        body: "The service remote sends raw IR and this phone has no IR emitter. "
            "It needs a phone with a built-in IR blaster.",
        button: 'Got it',
        onCancel: _closeScreen,
      );
    } else {
      await showWarningSheet(
        context,
        chip: 'FACTORY CONTROLS',
        title: 'This can wreck your TV',
        body: "The TV obeys these instantly and never asks first. Wrong EZ-Adjust "
            "values (panel, white balance) can permanently ruin the picture, "
            "wrong IN-START values can leave the TV misconfigured, and IN-STOP "
            "factory resets it on the spot.\n\n"
            "Note every value down before changing it. If you're just curious: "
            "look, don't touch.",
        button: 'I understand the risks',
        onCancel: _closeScreen,
      );
    }
  }

  // Cancelling either entry sheet (back/outside tap) leaves nothing useful on
  // this screen -- accepting does, so only cancel closes it (spec §4.3).
  void _closeScreen() {
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _sendIr(int cmd) async {
    HapticFeedback.selectionClick();
    if (!await widget.hasEmitter()) {
      if (mounted) showToast(context, 'No IR blaster on this phone');
      return;
    }
    await widget.transmit(38000, Ir.necPattern(Ir.lgCode(cmd)));
  }

  void _confirmTile(String title, int cmd, String body) {
    HapticFeedback.selectionClick();
    unawaited(showWarningSheet(
      context,
      chip: 'CONFIRM',
      title: title,
      body: body,
      button: 'Send $title',
      onAccept: () => unawaited(_sendIr(cmd)),
    ));
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
              _label(theme, 'FACTORY ENTRY'),
              _row([
                _tile(theme, 'IN-START', 0xFB, service: true),
                _tile(theme, 'EZ-ADJUST', 0xFF, service: true),
              ]),
              _row([
                _tile(
                  theme,
                  'POWER-ONLY',
                  0xFE,
                  service: true,
                  onTap: () => _confirmTile(
                    'POWER-ONLY',
                    0xFE,
                    "Locks the TV into power-only mode: it stops responding to everything "
                        "except the power button, and the only way back out is through the "
                        "service menu. Don't send this unless you know why you need it.",
                  ),
                ),
                _tile(
                  theme,
                  'IN-STOP',
                  0xFA,
                  service: true,
                  onTap: () => _confirmTile(
                    'IN-STOP',
                    0xFA,
                    "FACTORY RESETS THE TV. Instantly, with no prompt on the TV.\n\n"
                        "This is the production line's 'prepare for shipment' command. It wipes "
                        "all settings, accounts, apps and pairings and restarts the TV into "
                        "out-of-box setup. Panel calibration survives, nothing else does.",
                  ),
                ),
              ]),
              _label(theme, 'PASSWORD · 0413 / 0000'),
              _row([_tile(theme, '1', 0x11), _tile(theme, '2', 0x12), _tile(theme, '3', 0x13)]),
              _row([_tile(theme, '4', 0x14), _tile(theme, '5', 0x15), _tile(theme, '6', 0x16)]),
              _row([_tile(theme, '7', 0x17), _tile(theme, '8', 0x18), _tile(theme, '9', 0x19)]),
              _row([_spacer(), _tile(theme, '0', 0x10), _spacer()]),
              _label(theme, 'NAV'),
              _row([
                _tile(theme, 'BACK', 0x28),
                _tile(theme, '▲', 0x40),
                _tile(theme, 'EXIT', 0x5B),
              ]),
              _row([
                _tile(theme, '◀', 0x07),
                _tile(theme, 'OK', 0x44),
                _tile(theme, '▶', 0x06),
              ]),
              _row([_tile(theme, 'PWR', 0x08), _tile(theme, '▼', 0x41), _spacer()]),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    'IR ONLY · AIM THE PHONE AT THE TV',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9,
                      fontFamily: 'monospace',
                      letterSpacing: 0.1 * 9,
                      color: ColorUtil.withAlpha(theme.sectionLabel, 0x99),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(ThemeConfig theme, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 7),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontFamily: 'monospace',
          letterSpacing: 0.14 * 10.5,
          color: theme.sectionLabel,
        ),
      ),
    );
  }

  Widget _row(List<Widget> tiles) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(child: tiles[i]),
          ],
        ],
      ),
    );
  }

  Widget _spacer() => const SizedBox(height: 46);

  Widget _tile(
    ThemeConfig theme,
    String label,
    int cmd, {
    bool service = false,
    VoidCallback? onTap,
  }) {
    final bg = service ? ColorUtil.mix(theme.windowBg, _amber, 0.07) : ColorUtil.mix(theme.windowBg, theme.surfaceBg, 0.55);
    final border = service
        ? ColorUtil.withAlpha(_amber, 0x55)
        : ColorUtil.mix(theme.surfaceBg, theme.primaryText, 0.12);
    final textColor = service ? _amber : theme.primaryText;
    return SizedBox(
      height: 46,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap ?? () => unawaited(_sendIr(cmd)),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: border, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                fontWeight: service ? FontWeight.bold : FontWeight.normal,
                letterSpacing: 0.05 * 13,
                color: textColor,
              ),
            ),
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
      ..color = _amber
      ..strokeWidth = 6;
    for (double x = -size.height - 120; x < size.width + 120; x += 12) {
      canvas.drawLine(Offset(x, size.height + 60), Offset(x + size.height + 120, -60), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HazardPainter oldDelegate) => false;
}
