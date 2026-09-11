import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/theme_manager.dart';
import '../../widgets/app_icon.dart';
import '../remote_controller.dart';
import 'circle_button.dart';

enum _Sector { up, right, down, left }

/// The d-pad ring, wedge highlight and OK button (spec §3.1 g2, §5). The
/// four arrows skip the global press-scale animation on purpose -- Android's
/// `setDpadRepeatListener` installs its own touch handling *before*
/// `applyPressAnimations` would have reached them, so the only feedback is
/// the quarter-circle sector highlight. OK is a plain button and keeps the
/// scale animation via [CircleButton].
class Dpad extends StatefulWidget {
  const Dpad({super.key, required this.controller, required this.size, required this.okSize});

  final RemoteController controller;
  final double size;
  final double okSize;

  @override
  State<Dpad> createState() => _DpadState();
}

class _DpadState extends State<Dpad> {
  _Sector? _sector;
  Timer? _initialDelay;
  Timer? _repeat;

  void _cancelTimers() {
    _initialDelay?.cancel();
    _initialDelay = null;
    _repeat?.cancel();
    _repeat = null;
  }

  void _start(_Sector sector, String keyCode) {
    setState(() => _sector = sector);
    unawaited(widget.controller.pressSimple(keyCode));
    _cancelTimers();
    _initialDelay = Timer(const Duration(milliseconds: 400), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 120), (_) {
        HapticFeedback.selectionClick();
        unawaited(widget.controller.client.pressKey(keyCode));
      });
    });
  }

  void _end() {
    setState(() => _sector = null);
    _cancelTimers();
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  Widget _arrow({
    required Alignment alignment,
    required EdgeInsets margin,
    required _Sector sector,
    required String icon,
    required String keyCode,
    required String semanticLabel,
    required Color iconColor,
  }) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: margin,
        child: Listener(
          onPointerDown: (_) => _start(sector, keyCode),
          onPointerUp: (_) => _end(),
          onPointerCancel: (_) => _end(),
          child: SizedBox(
            width: 68,
            height: 68,
            child: Semantics(
              button: true,
              label: semanticLabel,
              child: Center(child: AppIcon(icon, size: 24, color: iconColor)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final highlight =
        theme.id == 'light' ? const Color(0x20000000) : const Color(0x33FFFFFF);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(color: theme.dpadRingBg, shape: BoxShape.circle),
          ),
          Positioned.fill(
            child: CustomPaint(painter: _DpadHighlightPainter(sector: _sector, color: highlight)),
          ),
          _arrow(
            alignment: Alignment.topCenter,
            margin: const EdgeInsets.only(top: 4),
            sector: _Sector.up,
            icon: 'ic_arrow_up',
            keyCode: 'UP',
            semanticLabel: 'Up',
            iconColor: theme.circleBtnIconTint,
          ),
          _arrow(
            alignment: Alignment.bottomCenter,
            margin: const EdgeInsets.only(bottom: 4),
            sector: _Sector.down,
            icon: 'ic_arrow_down',
            keyCode: 'DOWN',
            semanticLabel: 'Down',
            iconColor: theme.circleBtnIconTint,
          ),
          _arrow(
            alignment: Alignment.centerLeft,
            margin: const EdgeInsets.only(left: 4),
            sector: _Sector.left,
            icon: 'ic_arrow_left',
            keyCode: 'LEFT',
            semanticLabel: 'Left',
            iconColor: theme.circleBtnIconTint,
          ),
          _arrow(
            alignment: Alignment.centerRight,
            margin: const EdgeInsets.only(right: 4),
            sector: _Sector.right,
            icon: 'ic_arrow_right',
            keyCode: 'RIGHT',
            semanticLabel: 'Right',
            iconColor: theme.circleBtnIconTint,
          ),
          CircleButton(
            size: widget.okSize,
            color: theme.dpadOkBg,
            semanticLabel: 'OK',
            onTap: () => widget.controller.pressSimple('ENTER'),
            child: Text(
              'OK',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: theme.primaryText),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mirrors `DpadHighlightView`: a 90 degree pie slice from the d-pad's
/// centre, clipped to the inscribed circle. Android measures angles
/// clockwise from 3 o'clock with a y-down canvas, same convention as
/// `Canvas.drawArc`, so the sector start angles carry over unchanged.
class _DpadHighlightPainter extends CustomPainter {
  _DpadHighlightPainter({required this.sector, required this.color});

  final _Sector? sector;
  final Color color;

  static const _startAnglesDeg = {
    _Sector.up: 225.0,
    _Sector.right: 315.0,
    _Sector.down: 45.0,
    _Sector.left: 135.0,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final sector = this.sector;
    if (sector == null) return;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = math.min(cx, cy);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r)));
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    final startRad = _startAnglesDeg[sector]! * math.pi / 180;
    canvas.drawArc(rect, startRad, math.pi / 2, true, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DpadHighlightPainter oldDelegate) =>
      oldDelegate.sector != sector || oldDelegate.color != color;
}
