import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/haptics.dart';
import '../../../net/pointer_session.dart';
import '../../../net/webos_client.dart';
import '../../../theme/color_util.dart';
import '../../../theme/theme_config.dart';
import '../../../theme/theme_manager.dart';
import '../../widgets/app_icon.dart';

/// Owns the touchpad gesture state machine (spec §10). Two widgets share one
/// instance: [TouchpadButton] (in the normal button row -- its own pointer
/// listener runs the pre-lock phase, since Flutter routes a captured
/// pointer's move/up events back to whichever widget saw its down event
/// regardless of where the finger travels) and [TouchpadOverlayLayer] (a
/// full-screen sibling that paints the reveal and, once locked, runs a
/// second listener for fresh click/drag/scroll gestures).
class TouchpadController extends ChangeNotifier {
  TouchpadController({required this.client, required TickerProvider vsync, required this.rootKey})
      : reveal = AnimationController(vsync: vsync, duration: const Duration(milliseconds: 600));

  final WebOsClient client;
  final GlobalKey rootKey;
  final AnimationController reveal;

  bool active = false;
  bool isLocked = false;
  Offset center = Offset.zero;

  PointerSession? _session;
  bool _hasMoved = false;
  Offset _lastGlobal = Offset.zero;
  double _moveAccumulator = 0;
  Timer? _lockTimer;

  // Phase 2 (locked-mode) multi-touch tracking.
  final Map<int, Offset> _pointers = {};
  double _dxCarry = 0;
  double _dyCarry = 0;
  double _dragTotalDist = 0;
  bool _overlayDragging = false;
  bool _scrolling = false;
  double _lastScrollY = 0;
  double _scrollCarry = 0;

  static const double _moveThresholdPx = 12;
  static const double _hapticMovePx = 32;
  static const double _tapThresholdPx = 12;
  static const double _scrollSensitivity = 18;

  Offset _toLocal(Offset global) {
    final box = rootKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return global;
    return box.globalToLocal(global);
  }

  void onButtonDown(Offset globalCenter, Offset globalPointer) {
    Haptics.light();
    active = true;
    isLocked = false;
    _hasMoved = false;
    _moveAccumulator = 0;
    center = _toLocal(globalCenter);
    _lastGlobal = globalPointer;
    reveal.value = 0;
    notifyListeners();
    unawaited(_openSession());
    _lockTimer?.cancel();
    _lockTimer = Timer(const Duration(milliseconds: 600), _onLockTimeout);
    unawaited(reveal.animateTo(1, duration: const Duration(milliseconds: 600), curve: Curves.linear));
  }

  Future<void> _openSession() async {
    _session = await client.openPointerSession();
  }

  void _onLockTimeout() {
    if (_hasMoved || !active) return;
    isLocked = true;
    Haptics.heavy();
    notifyListeners();
  }

  void onButtonMove(Offset globalPointer) {
    if (!active || isLocked) return;
    final dx = globalPointer.dx - _lastGlobal.dx;
    final dy = globalPointer.dy - _lastGlobal.dy;
    if (!_hasMoved && (dx.abs() > _moveThresholdPx || dy.abs() > _moveThresholdPx)) {
      _hasMoved = true;
      _lockTimer?.cancel();
      reveal.stop();
      unawaited(reveal.animateTo(1, duration: const Duration(milliseconds: 100)));
    }
    _lastGlobal = globalPointer;
    _moveAccumulator += math.sqrt(dx * dx + dy * dy);
    if (_moveAccumulator >= _hapticMovePx) {
      Haptics.selection();
      _moveAccumulator = 0;
    }
    _session?.move(dx, dy);
  }

  void onButtonUp() {
    _lockTimer?.cancel();
    if (!isLocked) _exit();
  }

  void _exit() {
    _lockTimer?.cancel();
    active = false;
    isLocked = false;
    _hasMoved = false;
    reveal.stop();
    reveal.value = 0;
    _session?.close();
    _session = null;
    _pointers.clear();
    _scrolling = false;
    _overlayDragging = false;
    notifyListeners();
  }

  void exitTapped() => _exit();

  void overlayPointerDown(int id, Offset global) {
    if (!isLocked) return;
    _pointers[id] = global;
    if (_pointers.length == 1) {
      _dragTotalDist = 0;
      _overlayDragging = false;
      _scrolling = false;
      _dxCarry = 0;
      _dyCarry = 0;
    } else if (_pointers.length == 2) {
      _scrolling = true;
      _overlayDragging = false;
      final ys = _pointers.values.map((o) => o.dy).toList();
      _lastScrollY = (ys[0] + ys[1]) / 2;
      _scrollCarry = 0;
    }
  }

  void overlayPointerMove(int id, Offset global) {
    if (!isLocked) return;
    final prev = _pointers[id];
    _pointers[id] = global;
    if (_scrolling && _pointers.length >= 2) {
      final ys = _pointers.values.toList();
      final midY = (ys[0].dy + ys[1].dy) / 2;
      final total = (midY - _lastScrollY) + _scrollCarry;
      final units = (total / _scrollSensitivity).truncate();
      _scrollCarry = total - units * _scrollSensitivity;
      _lastScrollY = midY;
      // Sign inversion: dragging down scrolls TV content up (spec §10).
      if (units != 0) _session?.scroll(0, -units.toDouble());
      return;
    }
    if (prev == null || _pointers.length != 1) return;
    final dx = global.dx - prev.dx;
    final dy = global.dy - prev.dy;
    if (!_overlayDragging) {
      _dragTotalDist += math.sqrt(dx * dx + dy * dy);
      if (_dragTotalDist >= _tapThresholdPx) {
        _overlayDragging = true;
        _dxCarry = 0;
        _dyCarry = 0;
      }
    }
    if (_overlayDragging) {
      final totalDx = dx + _dxCarry;
      final totalDy = dy + _dyCarry;
      final sendDx = totalDx.truncate();
      final sendDy = totalDy.truncate();
      _dxCarry = totalDx - sendDx;
      _dyCarry = totalDy - sendDy;
      if (sendDx != 0 || sendDy != 0) {
        _session?.move(sendDx.toDouble(), sendDy.toDouble());
      }
    }
  }

  void overlayPointerUp(int id) {
    if (!isLocked) return;
    final wasSingle = _pointers.length == 1;
    _pointers.remove(id);
    if (_pointers.isEmpty) {
      if (wasSingle && !_overlayDragging && !_scrolling) {
        Haptics.light();
        _session?.click();
      }
      _scrolling = false;
      _overlayDragging = false;
      _dragTotalDist = 0;
    } else if (_pointers.length == 1) {
      _scrolling = false;
      _overlayDragging = false;
      _dragTotalDist = 0;
    }
  }

  void overlayBack() {
    Haptics.light();
    _session?.sendKey('BACK');
  }

  void overlayClick() {
    Haptics.light();
    _session?.click();
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    reveal.dispose();
    _session?.close();
    super.dispose();
  }
}

/// The 72dp button in the Power/Touchpad/Keyboard row. A raw `Listener`, not
/// [PressScale] -- Android's `btn_touchpad` is a plain `FrameLayout` with its
/// own `OnTouchListener` and never had the scale animation.
class TouchpadButton extends StatelessWidget {
  const TouchpadButton({super.key, required this.controller});

  final TouchpadController controller;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Listener(
      onPointerDown: (event) {
        final box = context.findRenderObject() as RenderBox;
        final center = box.localToGlobal(box.size.center(Offset.zero));
        controller.onButtonDown(center, event.position);
      },
      onPointerMove: (event) => controller.onButtonMove(event.position),
      onPointerUp: (_) => controller.onButtonUp(),
      onPointerCancel: (_) => controller.onButtonUp(),
      child: Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: theme.circleBtnBg, shape: BoxShape.circle),
        child: Semantics(
          button: true,
          label: 'Touchpad',
          child: AppIcon('ic_touchpad', size: 28, color: theme.circleBtnIconTint),
        ),
      ),
    );
  }
}

/// Full-screen overlay: the blurred lock reveal, and (once locked) the Exit
/// button plus the Back/Click row. Placed as the top-most child of the
/// screen's outer `Stack` so it paints over everything, matching
/// `touchpad_overlay`'s z-order in `activity_main.xml`.
class TouchpadOverlayLayer extends StatelessWidget {
  const TouchpadOverlayLayer({super.key, required this.controller});

  final TouchpadController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.active) return const SizedBox.shrink();
        final theme = AppTheme.of(context);
        return Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => controller.overlayPointerDown(e.pointer, e.position),
            onPointerMove: (e) => controller.overlayPointerMove(e.pointer, e.position),
            onPointerUp: (e) => controller.overlayPointerUp(e.pointer),
            onPointerCancel: (e) => controller.overlayPointerUp(e.pointer),
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: controller.reveal,
                    builder: (context, _) => CustomPaint(
                      painter: _LockRevealPainter(
                        center: controller.center,
                        progress: controller.reveal.value,
                        scrimColor: ColorUtil.withAlpha(theme.windowBg, 0xF2),
                      ),
                    ),
                  ),
                ),
                if (controller.isLocked) ...[
                  Positioned(
                    top: 48,
                    right: 24,
                    child: _ExitButton(onTap: controller.exitTapped),
                  ),
                  Positioned(
                    left: 36,
                    right: 36,
                    bottom: 72,
                    height: 72,
                    child: Row(
                      children: [
                        _BackButton(theme: theme, onTap: controller.overlayBack),
                        const SizedBox(width: 12),
                        Expanded(child: _ClickButton(theme: theme, onTap: controller.overlayClick)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ExitButton extends StatelessWidget {
  const _ExitButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: 'Exit',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0x33E53935),
            border: Border.all(color: const Color(0xFFE53935), width: 1.5),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Text(
            'Exit',
            style: TextStyle(color: Color(0xFFE53935), fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.theme, required this.onTap});
  final ThemeConfig theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: 'Back',
        child: Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: theme.surfaceBg, shape: BoxShape.circle),
          child: AppIcon('ic_back', size: 24, color: theme.primaryText),
        ),
      ),
    );
  }
}

class _ClickButton extends StatelessWidget {
  const _ClickButton({required this.theme, required this.onTap});
  final ThemeConfig theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: 'Click',
        child: Container(
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: theme.surfaceBg, borderRadius: BorderRadius.circular(20)),
          child: Text(
            'Click',
            style: TextStyle(color: theme.primaryText, fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

/// Mirrors `LockRevealView`: a rounded square growing from the touchpad
/// button's centre, blurred while animating, solid once fully revealed.
class _LockRevealPainter extends CustomPainter {
  _LockRevealPainter({required this.center, required this.progress, required this.scrimColor});

  final Offset center;
  final double progress;
  final Color scrimColor;

  // Logical-pixel approximation of `28dp * density` -- close enough at
  // typical phone density and avoids threading a `MediaQuery` devicePixelRatio
  // through the painter.
  static const double _blur = 28;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final light = (scrimColor.r + scrimColor.g + scrimColor.b) * 255 > 384;
    final rimColor = light ? const Color(0x14000000) : const Color(0x22FFFFFF);
    if (progress >= 1) {
      canvas.drawRect(Offset.zero & size, Paint()..color = scrimColor);
      return;
    }
    final cx = center.dx;
    final cy = center.dy;
    final half =
        (math.max(math.max(cx, size.width - cx), math.max(cy, size.height - cy)) + _blur) * progress;
    final rect = Rect.fromCenter(center: center, width: half * 2, height: half * 2);
    final radius = Radius.circular(0.45 * half);
    final fillPaint = Paint()
      ..color = scrimColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _blur);
    final edgePaint = Paint()
      ..color = rimColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(rect, radius);
    canvas.drawRRect(rrect, fillPaint);
    canvas.drawRRect(rrect, edgePaint);
  }

  @override
  bool shouldRepaint(covariant _LockRevealPainter oldDelegate) =>
      oldDelegate.center != center ||
      oldDelegate.progress != progress ||
      oldDelegate.scrimColor != scrimColor;
}
