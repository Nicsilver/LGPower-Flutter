import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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

  bool _hasMoved = false;
  Offset _lastGlobal = Offset.zero;
  double _moveAccumulator = 0;
  Timer? _lockTimer;

  // Phase 2 (locked-mode) multi-touch tracking.
  final Map<int, Offset> _pointers = {};

  // Cursor travel is summed here and sent at most once per display refresh.
  // Flutter asks Android for unbuffered input, so a touch panel reports
  // several times per refresh (hundreds of events a second on a fast one),
  // while the Kotlin app gets one batched event per vsync: that is the rate
  // the TV is used to. Sends are paced by the touch events' own timestamps,
  // not by frame callbacks: a slow or skipped frame (the reveal blur, a debug
  // build) must not hold the cursor back, and the first move goes out on the
  // first touch event. Pacing on a timer instead fires a few ms late each
  // time (~50 sends a second), so the timer only flushes what a stopped
  // finger leaves behind.
  // All travel is in physical pixels, as Android's rawX/rawY are; logical
  // pixels made the cursor move 1/devicePixelRatio as far as the Kotlin app.
  double _pendingDx = 0;
  double _pendingDy = 0;
  double _dxCarry = 0;
  double _dyCarry = 0;
  Duration? _lastSendAt;
  Timer? _tailFlush;
  bool _buttonDragging = false;
  bool _disposed = false;
  double _dragTotalDist = 0;
  bool _overlayDragging = false;
  bool _scrolling = false;
  double _lastScrollY = 0;
  double _scrollCarry = 0;

  // Physical pixels per send, compared like the Kotlin app's per-vsync
  // delta: a per-touch-event check almost never fires on a fast panel, so the
  // pad locked under a finger that was dragging and froze the cursor.
  static const double _moveThresholdPx = 12;
  static const double _hapticMovePx = 32;
  // Logical pixels, matching Kotlin's `12 * density`.
  static const double _tapThresholdPx = 12;
  static const double _scrollSensitivity = 18;

  static ui.FlutterView? get _view =>
      WidgetsBinding.instance.platformDispatcher.implicitView;

  static double get _dpr => _view?.devicePixelRatio ?? 1;

  // A little under one refresh, so touch samples that land just short of a
  // refresh boundary (8 ms apart against 16.7) do not stretch it to two.
  static Duration get _sendInterval {
    final hz = _view?.display.refreshRate ?? 60;
    return Duration(microseconds: (0.9e6 / (hz >= 30 ? hz : 60)).round());
  }

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
    _buttonDragging = true;
    _moveAccumulator = 0;
    _resetMoves();
    _stopPacing();
    center = _toLocal(globalCenter);
    _lastGlobal = globalPointer;
    reveal.value = 0;
    notifyListeners();
    client.warmPointer();
    _lockTimer?.cancel();
    _lockTimer = Timer(const Duration(milliseconds: 600), _onLockTimeout);
    unawaited(reveal.animateTo(1, duration: const Duration(milliseconds: 600), curve: Curves.linear));
  }

  // Looked up per frame rather than held for the gesture: the shared session
  // can be replaced under a long lock (TV dropped it), and frames sent to a
  // connecting one are queued, not lost.
  PointerSession? get _pointer => client.tvIp.isEmpty ? null : client.pointerSession();

  void _onLockTimeout() {
    if (_hasMoved || !active) return;
    isLocked = true;
    Haptics.heavy();
    notifyListeners();
  }

  // Keeps driving the cursor after the pad locks under a finger that held
  // still and then moved, as the Kotlin app's button listener does.
  void onButtonMove(Offset globalPointer, Duration timeStamp) {
    if (!active || !_buttonDragging) return;
    final dpr = _dpr;
    final dx = (globalPointer.dx - _lastGlobal.dx) * dpr;
    final dy = (globalPointer.dy - _lastGlobal.dy) * dpr;
    _lastGlobal = globalPointer;
    _moveAccumulator += math.sqrt(dx * dx + dy * dy);
    if (_moveAccumulator >= _hapticMovePx) {
      Haptics.selection();
      _moveAccumulator = 0;
    }
    _queueMove(dx, dy, timeStamp);
  }

  void _checkDragStarted(double windowDx, double windowDy) {
    if (_hasMoved || isLocked || !_buttonDragging) return;
    if (windowDx.abs() <= _moveThresholdPx && windowDy.abs() <= _moveThresholdPx) return;
    _hasMoved = true;
    _lockTimer?.cancel();
    reveal.stop();
    unawaited(reveal.animateTo(1, duration: const Duration(milliseconds: 100)));
  }

  void _resetMoves() {
    _pendingDx = 0;
    _pendingDy = 0;
    _dxCarry = 0;
    _dyCarry = 0;
  }

  void _queueMove(double dx, double dy, Duration at) {
    _pendingDx += dx;
    _pendingDy += dy;
    final last = _lastSendAt;
    if (last == null || at < last || at - last >= _sendInterval) {
      _stopPacing();
      _lastSendAt = at;
      flushMoves();
    } else {
      _tailFlush ??= Timer(_sendInterval, () {
        _tailFlush = null;
        _lastSendAt = null;
        if (!_disposed) flushMoves();
      });
    }
  }

  void _stopPacing() {
    _tailFlush?.cancel();
    _tailFlush = null;
    _lastSendAt = null;
  }

  /// Sends the travel gathered since the last send. The fraction that does
  /// not fit a whole unit stays in the carry so slow drags lose nothing.
  void flushMoves() {
    _checkDragStarted(_pendingDx, _pendingDy);
    final totalDx = _pendingDx + _dxCarry;
    final totalDy = _pendingDy + _dyCarry;
    _pendingDx = 0;
    _pendingDy = 0;
    final sendDx = totalDx.truncate();
    final sendDy = totalDy.truncate();
    _dxCarry = totalDx - sendDx;
    _dyCarry = totalDy - sendDy;
    if (sendDx != 0 || sendDy != 0) {
      _pointer?.move(sendDx.toDouble(), sendDy.toDouble());
    }
  }

  void onButtonUp() {
    _lockTimer?.cancel();
    flushMoves();
    _stopPacing();
    _buttonDragging = false;
    if (!isLocked) _exit();
  }

  void _exit() {
    flushMoves();
    _stopPacing();
    _lockTimer?.cancel();
    active = false;
    isLocked = false;
    _hasMoved = false;
    _buttonDragging = false;
    reveal.stop();
    reveal.value = 0;
    _pointers.clear();
    _scrolling = false;
    _overlayDragging = false;
    _resetMoves();
    notifyListeners();
  }

  void exitTapped() => _exit();

  void overlayPointerDown(int id, Offset global) {
    if (!isLocked) return;
    _pointers[id] = global;
    if (_pointers.length == 1) {
      _dragTotalDist = 0;
      _moveAccumulator = 0;
      _overlayDragging = false;
      _scrolling = false;
      _resetMoves();
      _stopPacing();
    } else if (_pointers.length == 2) {
      flushMoves();
      _scrolling = true;
      _overlayDragging = false;
      final ys = _pointers.values.map((o) => o.dy).toList();
      _lastScrollY = (ys[0] + ys[1]) / 2 * _dpr;
      _scrollCarry = 0;
    }
  }

  void overlayPointerMove(int id, Offset global, Duration timeStamp) {
    if (!isLocked) return;
    final prev = _pointers[id];
    _pointers[id] = global;
    if (_scrolling && _pointers.length >= 2) {
      final ys = _pointers.values.toList();
      final midY = (ys[0].dy + ys[1].dy) / 2 * _dpr;
      final total = (midY - _lastScrollY) + _scrollCarry;
      final units = (total / _scrollSensitivity).truncate();
      _scrollCarry = total - units * _scrollSensitivity;
      _lastScrollY = midY;
      // Sign inversion: dragging down scrolls TV content up (spec §10).
      if (units != 0) _pointer?.scroll(0, -units.toDouble());
      return;
    }
    if (prev == null || _pointers.length != 1) return;
    final dx = global.dx - prev.dx;
    final dy = global.dy - prev.dy;
    if (!_overlayDragging) {
      _dragTotalDist += math.sqrt(dx * dx + dy * dy);
      if (_dragTotalDist >= _tapThresholdPx) {
        _overlayDragging = true;
        _resetMoves();
      }
    } else {
      // Only once the drag has started, and in physical pixels: the same
      // tick spacing as the Kotlin pad.
      _moveAccumulator += math.sqrt(dx * dx + dy * dy) * _dpr;
      if (_moveAccumulator >= _hapticMovePx) {
        Haptics.selection();
        _moveAccumulator = 0;
      }
    }
    if (_overlayDragging) _queueMove(dx * _dpr, dy * _dpr, timeStamp);
  }

  void overlayPointerUp(int id) {
    if (!isLocked) return;
    final wasSingle = _pointers.length == 1;
    flushMoves();
    _pointers.remove(id);
    if (_pointers.isEmpty) {
      _stopPacing();
      if (wasSingle && !_overlayDragging && !_scrolling) {
        Haptics.light();
        client.pointerClick();
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
    flushMoves();
    client.pointerKey('BACK');
  }

  void overlayClick() {
    Haptics.light();
    flushMoves();
    client.pointerClick();
  }

  @override
  void dispose() {
    _disposed = true;
    _lockTimer?.cancel();
    _tailFlush?.cancel();
    reveal.dispose();
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
      onPointerMove: (event) => controller.onButtonMove(event.position, event.timeStamp),
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
        // The gesture Listener sits under the buttons, not around them: a
        // pointer that lands on a button is absorbed by its hit test, so the
        // tap-to-click on the bare pad never fires on top of the button's own
        // action.
        return Positioned.fill(
          child: Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => controller.overlayPointerDown(e.pointer, e.position),
                  onPointerMove: (e) => controller.overlayPointerMove(e.pointer, e.position, e.timeStamp),
                  onPointerUp: (e) => controller.overlayPointerUp(e.pointer),
                  onPointerCancel: (e) => controller.overlayPointerUp(e.pointer),
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
