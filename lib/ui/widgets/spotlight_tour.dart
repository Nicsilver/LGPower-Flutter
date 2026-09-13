import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';

/// One stop of the walkthrough: the controls to ring (all of them share one
/// hole per target, the card sits beside their union) and the copy.
class TourStep {
  const TourStep(this.targets, this.title, this.body);

  final List<GlobalKey> targets;
  final String title;
  final String body;
}

/// Walkthrough that dims the whole screen except the control being
/// explained, with a card next to it. Pushed as a transparent route on top
/// of the screen so nothing underneath moves and the system back gesture
/// ends it like Skip does. Resolves to true when the last step's button was
/// pressed, false for Skip / back.
Future<bool> showSpotlightTour(
  BuildContext context,
  List<TourStep> steps, {
  String lastLabel = 'Done',
}) async {
  final theme = AppTheme.of(context);
  final completed = await Navigator.of(context).push<bool>(
    PageRouteBuilder<bool>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) =>
          _SpotlightView(steps: steps, lastLabel: lastLabel, theme: theme),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
  return completed ?? false;
}

class _SpotlightView extends StatefulWidget {
  const _SpotlightView({
    required this.steps,
    required this.lastLabel,
    required this.theme,
  });

  final List<TourStep> steps;
  final String lastLabel;
  final ThemeConfig theme;

  @override
  State<_SpotlightView> createState() => _SpotlightViewState();
}

class _SpotlightViewState extends State<_SpotlightView>
    with TickerProviderStateMixin {
  static const _pad = 8.0;
  static const _minHole = 40.0;
  static const _cardGap = 16.0;

  late final AnimationController _glide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  int _index = -1;
  List<Rect> _from = const [];
  List<Rect> _to = const [];
  Rect? _union;
  bool _downInHole = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _glide.addListener(() => setState(() {}));
    _pulse.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _go(0));
  }

  @override
  void dispose() {
    _glide.dispose();
    _pulse.dispose();
    super.dispose();
  }

  List<Rect> get _holes {
    if (_from.isEmpty) return _to;
    final t = Curves.decelerate.transform(_glide.value);
    return [
      for (var i = 0; i < _to.length; i++) Rect.lerp(_from[i], _to[i], t)!,
    ];
  }

  Offset _myOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    return box == null || !box.attached
        ? Offset.zero
        : box.localToGlobal(Offset.zero);
  }

  List<BuildContext> _targetContexts(TourStep step) {
    final out = <BuildContext>[];
    for (final key in step.targets) {
      final ctx = key.currentContext;
      final box = ctx?.findRenderObject();
      if (ctx == null ||
          box is! RenderBox ||
          !box.attached ||
          !box.hasSize ||
          box.size.width <= 0) {
        continue;
      }
      out.add(ctx);
    }
    return out;
  }

  Rect _rectOf(BuildContext target) {
    final box = target.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero) - _myOrigin();
    var r = Rect.fromLTWH(
      origin.dx - _pad,
      origin.dy - _pad,
      box.size.width + 2 * _pad,
      box.size.height + 2 * _pad,
    );
    // Tiny targets (the status dot) still need a hole a finger can find
    if (r.width < _minHole) {
      r = Rect.fromCenter(center: r.center, width: _minHole, height: r.height);
    }
    if (r.height < _minHole) {
      r = Rect.fromCenter(center: r.center, width: r.width, height: _minHole);
    }
    return r;
  }

  Future<void> _go(int to) async {
    if (!mounted || _finishing) return;
    if (to < 0) return;
    if (to >= widget.steps.length) {
      _finish(true);
      return;
    }
    final targets = _targetContexts(widget.steps[to]);
    if (targets.isEmpty) {
      // A control that isn't on this screen (no shortcuts yet, say) is skipped
      // in whichever direction the user was going.
      await _go(to > _index ? to + 1 : to - 1);
      return;
    }
    final height = _viewHeight;
    final origin = _myOrigin();
    final offScreen = targets.any((t) {
      final box = t.findRenderObject() as RenderBox;
      final top = box.localToGlobal(Offset.zero).dy - origin.dy;
      return top < 80 || top + box.size.height > height - 80;
    });
    if (offScreen) {
      // A target further down a scrolling screen has to be brought on screen
      // first; the layout catches up on the next frame
      await Scrollable.ensureVisible(targets.first, alignment: 0.35);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    _show(to, targets);
  }

  void _show(int to, List<BuildContext> targets) {
    final rects = targets.map(_rectOf).toList();
    var union = rects.first;
    for (final r in rects) {
      union = union.expandToInclude(r);
    }
    final previous = _holes;
    setState(() {
      _index = to;
      _union = union;
      _to = rects;
      if (previous.isEmpty) {
        _from = const [];
      } else {
        // Every hole glides from the nearest previous one, so a single ring
        // appears to travel
        _from = [
          for (final r in rects)
            previous.reduce(
              (a, b) =>
                  (a.center - r.center).distanceSquared <=
                      (b.center - r.center).distanceSquared
                  ? a
                  : b,
            ),
        ];
      }
    });
    _glide.forward(from: 0);
  }

  bool _inHole(Offset p) => _holes.any((h) => h.contains(p));

  void _onTapDown(TapDownDetails d) => _downInHole = _inHole(d.localPosition);

  // The dimmed area advances; the highlighted control is shown, not usable,
  // so a tap on it just nudges the ring instead of jumping ahead
  void _onTapUp(TapUpDetails d) {
    if (_downInHole || _inHole(d.localPosition)) {
      _pulse.forward(from: 0);
    } else {
      unawaited(_go(_index + 1));
    }
  }

  void _finish(bool completed) {
    if (_finishing || !mounted) return;
    _finishing = true;
    Navigator.of(context).pop(completed);
  }

  // Our own height, recorded at layout time: build must not read it off the
  // render object
  double _viewHeight = 0;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final pulseT = _pulse.isAnimating ? math.sin(_pulse.value * math.pi) : 0.0;
    // A transparent route has no Material of its own; without one the card's
    // text falls back to the framework's debug underline style
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
      builder: (context, constraints) {
        _viewHeight = constraints.maxHeight;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _onTapDown,
          onTapUp: _onTapUp,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _ScrimPainter(
                  holes: _holes,
                  ringWidth: 1.5 + 2.5 * pulseT,
                  ringAlpha: (0x66 + (0x99 * pulseT).round()).clamp(0, 255),
                ),
              ),
              if (_index >= 0 && _union != null) _card(theme, _union!, constraints.maxHeight),
            ],
          ),
        );
      },
      ),
    );
  }

  // Card goes under the highlighted control when that sits in the top half,
  // above it otherwise
  Widget _card(ThemeConfig theme, Rect rect, double height) {
    final below = rect.center.dy < height / 2;
    final step = widget.steps[_index];
    final last = _index == widget.steps.length - 1;
    final card = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        decoration: BoxDecoration(
          color: theme.surfaceBg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              step.title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: theme.primaryText,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 14),
              child: Text(
                step.body,
                style: TextStyle(fontSize: 13, color: theme.secondaryText),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.steps.length; i++)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(right: 5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == _index
                                ? theme.btnAccentBg
                                : theme.divider,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_index > 0)
                  _ghost(theme, 'Back', () => unawaited(_go(_index - 1))),
                if (!last) _ghost(theme, 'Skip', () => _finish(false)),
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: GestureDetector(
                    onTap: () => unawaited(_go(_index + 1)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: theme.btnAccentBg,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        last ? widget.lastLabel : 'Next',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: theme.btnAccentText,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (below) {
      return Positioned(
        left: 20,
        right: 20,
        top: rect.bottom + _cardGap,
        child: card,
      );
    }
    return Positioned(
      left: 20,
      right: 20,
      bottom: math.max(0, height - (rect.top - _cardGap)),
      child: card,
    );
  }

  Widget _ghost(ThemeConfig theme, String label, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          label,
          style: TextStyle(fontSize: 13, color: theme.secondaryText),
        ),
      ),
    );
  }
}

class _ScrimPainter extends CustomPainter {
  const _ScrimPainter({
    required this.holes,
    required this.ringWidth,
    required this.ringAlpha,
  });

  final List<Rect> holes;
  final double ringWidth;
  final int ringAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    // Clearing only punches through on a layer, otherwise it erases the
    // window itself
    canvas.saveLayer(bounds, Paint());
    canvas.drawRect(bounds, Paint()..color = const Color(0xC4000000));
    final clear = Paint()..blendMode = BlendMode.clear;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth
      ..color = Color.fromARGB(ringAlpha, 0xFF, 0xFF, 0xFF);
    for (final h in holes) {
      final rr = RRect.fromRectAndRadius(h, const Radius.circular(18));
      canvas.drawRRect(rr, clear);
      canvas.drawRRect(rr, ring);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.holes != holes ||
      old.ringWidth != ringWidth ||
      old.ringAlpha != ringAlpha;
}
