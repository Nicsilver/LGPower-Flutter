import 'package:flutter/material.dart';

import '../../theme/color_util.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';

const serviceAmber = Color(0xFFE8A33D);

/// One digit or nav key: ir is the NEC command byte, tv the pointer-socket key
/// name (null for keys the TV has no Wi-Fi equivalent for).
class ServiceKey {
  const ServiceKey(this.label, this.ir, this.tv);
  final String label;
  final int ir;
  final String? tv;
}

const _digitRows = [
  [ServiceKey('1', 0x11, '1'), ServiceKey('2', 0x12, '2'), ServiceKey('3', 0x13, '3')],
  [ServiceKey('4', 0x14, '4'), ServiceKey('5', 0x15, '5'), ServiceKey('6', 0x16, '6')],
  [ServiceKey('7', 0x17, '7'), ServiceKey('8', 0x18, '8'), ServiceKey('9', 0x19, '9')],
];
const _zero = ServiceKey('0', 0x10, '0');
const _power = ServiceKey('PWR', 0x08, null);

/// Look shared by the Wi-Fi and IR service pages: header, hazard band, tile
/// grid and footer. The pages differ only in what the tiles send.
class ServicePage extends StatelessWidget {
  const ServicePage({
    super.key,
    required this.subtitle,
    required this.footer,
    required this.sections,
  });

  final String subtitle;
  final String footer;
  final List<Widget> sections;

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
                  subtitle,
                  style: TextStyle(fontSize: 10.5, fontFamily: 'monospace', color: theme.sectionLabel),
                ),
              ),
              const _HazardBand(),
              ...sections,
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    footer,
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
}

class ServiceLabel extends StatelessWidget {
  const ServiceLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
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
}

class ServiceRow extends StatelessWidget {
  const ServiceRow(this.tiles, {super.key});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
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
}

class ServiceSpacer extends StatelessWidget {
  const ServiceSpacer({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 46);
}

class ServiceTile extends StatelessWidget {
  const ServiceTile(this.label, {super.key, required this.onTap, this.service = false});

  final String label;
  final VoidCallback onTap;
  final bool service;

  @override
  Widget build(BuildContext context) {
    final ThemeConfig theme = AppTheme.of(context);
    final bg = service
        ? ColorUtil.mix(theme.windowBg, serviceAmber, 0.07)
        : ColorUtil.mix(theme.windowBg, theme.surfaceBg, 0.55);
    final border = service
        ? ColorUtil.withAlpha(serviceAmber, 0x55)
        : ColorUtil.mix(theme.surfaceBg, theme.primaryText, 0.12);
    return SizedBox(
      height: 46,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
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
                color: service ? serviceAmber : theme.primaryText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Digits and nav as the same grid on both pages; [onKey] decides how a press is sent.
List<Widget> serviceKeyGrid({required bool withPower, required void Function(ServiceKey) onKey}) {
  Widget t(ServiceKey k) => ServiceTile(k.label, onTap: () => onKey(k));
  return [
    const ServiceLabel('PASSWORD · 0413 / 0000'),
    for (final r in _digitRows) ServiceRow([for (final k in r) t(k)]),
    ServiceRow([const ServiceSpacer(), t(_zero), const ServiceSpacer()]),
    const ServiceLabel('NAV'),
    ServiceRow([
      t(const ServiceKey('BACK', 0x28, 'BACK')),
      t(const ServiceKey('▲', 0x40, 'UP')),
      t(const ServiceKey('EXIT', 0x5B, 'EXIT')),
    ]),
    ServiceRow([
      t(const ServiceKey('◀\u{FE0E}', 0x07, 'LEFT')),
      t(const ServiceKey('OK', 0x44, 'ENTER')),
      t(const ServiceKey('▶\u{FE0E}', 0x06, 'RIGHT')),
    ]),
    ServiceRow([
      withPower ? t(_power) : const ServiceSpacer(),
      t(const ServiceKey('▼', 0x41, 'DOWN')),
      const ServiceSpacer(),
    ]),
  ];
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
      ..color = serviceAmber
      ..strokeWidth = 6;
    for (double x = -size.height - 120; x < size.width + 120; x += 12) {
      canvas.drawLine(Offset(x, size.height + 60), Offset(x + size.height + 120, -60), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HazardPainter oldDelegate) => false;
}
