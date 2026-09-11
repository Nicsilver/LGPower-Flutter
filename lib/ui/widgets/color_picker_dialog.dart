import 'package:flutter/material.dart';

import '../../theme/color_util.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';

/// Centred HSV colour picker (spec 3.8), mirroring `ColorPickerDialog.kt`:
/// a saturation/value square, a hue slider, a live swatch + editable hex
/// field, and Cancel/Done. No presets, no alpha — the result is always
/// fully opaque. Resolves with the picked [Color], or `null` on Cancel/dismiss.
Future<Color?> showColorPicker(
  BuildContext context, {
  required String title,
  required Color initial,
}) {
  final theme = AppTheme.of(context);
  return showGeneralDialog<Color>(
    context: context,
    barrierLabel: title,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final width = MediaQuery.of(dialogContext).size.width - 56;
      return Center(
        child: SizedBox(
          width: width,
          child: _ColorPickerContent(title: title, initial: initial, theme: theme),
        ),
      );
    },
  );
}

class _ColorPickerContent extends StatefulWidget {
  const _ColorPickerContent({required this.title, required this.initial, required this.theme});

  final String title;
  final Color initial;
  final ThemeConfig theme;

  @override
  State<_ColorPickerContent> createState() => _ColorPickerContentState();
}

class _ColorPickerContentState extends State<_ColorPickerContent> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;

  Color get _current => _hsv.toColor();

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial).withAlpha(1.0);
    _hexController = TextEditingController(text: ColorUtil.toHex(_current));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _refreshHexField() {
    final hex = ColorUtil.toHex(_current);
    // Programmatic controller updates don't invoke TextField.onChanged (only
    // user-driven edits do), so unlike the Kotlin TextWatcher, this needs no
    // "suppress" flag to avoid feeding back into itself.
    _hexController.value = TextEditingValue(
      text: hex,
      selection: TextSelection.collapsed(offset: hex.length),
    );
  }

  void _handleSquareInput(Offset local, double width, double height) {
    final sat = (local.dx / width).clamp(0.0, 1.0);
    final value = (1 - local.dy / height).clamp(0.0, 1.0);
    setState(() {
      _hsv = _hsv.withSaturation(sat).withValue(value);
      _refreshHexField();
    });
  }

  void _handleHueInput(double dx, double width) {
    final hue = ((dx / width) * 360).clamp(0.0, 360.0);
    setState(() {
      _hsv = _hsv.withHue(hue);
      _refreshHexField();
    });
  }

  void _onHexChanged(String text) {
    final parsed = ColorUtil.parseOrNull(text);
    if (parsed == null) return;
    setState(() => _hsv = HSVColor.fromColor(parsed.withAlpha(0xFF)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(color: theme.surfaceBg, borderRadius: BorderRadius.circular(22)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: theme.primaryText),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                const h = 200.0;
                return GestureDetector(
                  onPanDown: (d) => _handleSquareInput(d.localPosition, w, h),
                  onPanUpdate: (d) => _handleSquareInput(d.localPosition, w, h),
                  child: CustomPaint(
                    size: Size(w, h),
                    painter: _SatValPainter(hue: _hsv.hue, sat: _hsv.saturation, value: _hsv.value),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 26,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                return GestureDetector(
                  onPanDown: (d) => _handleHueInput(d.localPosition.dx, w),
                  onPanUpdate: (d) => _handleHueInput(d.localPosition.dx, w),
                  child: CustomPaint(size: Size(w, 26), painter: _HuePainter(hue: _hsv.hue)),
                );
              },
            ),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: _current, borderRadius: BorderRadius.circular(10)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: TextField(
                  controller: _hexController,
                  maxLength: 7,
                  style: TextStyle(fontSize: 16, color: theme.primaryText),
                  decoration: const InputDecoration(
                    counterText: '',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: _onHexChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.only(top: 12, bottom: 4)),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Cancel', style: TextStyle(fontSize: 16, color: theme.secondaryText)),
                ),
              ),
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.only(top: 12, bottom: 4)),
                  onPressed: () => Navigator.of(context).pop(_current),
                  child: Text(
                    'Done',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: theme.btnAccentBg),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Saturation (x) / value (y) square for a fixed hue.
class _SatValPainter extends CustomPainter {
  const _SatValPainter({required this.hue, required this.sat, required this.value});

  final double hue;
  final double sat;
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    final hueColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();

    canvas.drawRRect(
      rrect,
      Paint()..shader = LinearGradient(colors: [Colors.white, hueColor]).createShader(rect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );

    final center = Offset(sat * size.width, (1 - value) * size.height);
    canvas.drawCircle(
      center,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    canvas.drawCircle(
      center,
      10.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x40000000),
    );
  }

  @override
  bool shouldRepaint(covariant _SatValPainter oldDelegate) =>
      oldDelegate.hue != hue || oldDelegate.sat != sat || oldDelegate.value != value;
}

/// Horizontal rainbow hue slider, 0..360.
class _HuePainter extends CustomPainter {
  const _HuePainter({required this.hue});

  final double hue;

  static const _rainbow = [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(r));
    canvas.drawRRect(rrect, Paint()..shader = const LinearGradient(colors: _rainbow).createShader(rect));

    final cx = ((hue / 360) * size.width).clamp(r, size.width - r);
    final center = Offset(cx, size.height / 2);
    final thumbRadius = r - 1.5;
    final thumbColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    canvas.drawCircle(center, thumbRadius, Paint()..color = thumbColor);
    canvas.drawCircle(
      center,
      thumbRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _HuePainter oldDelegate) => oldDelegate.hue != hue;
}
