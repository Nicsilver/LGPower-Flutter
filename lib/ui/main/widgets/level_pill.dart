import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/theme_manager.dart';
import '../../widgets/app_icon.dart';
import 'fill_viewport_page.dart';

/// Volume/brightness/channel pill (spec §6): a `Listener`-driven touch state
/// machine rather than a `GestureDetector`, because tap-vs-drag and the
/// button-mode hold-to-repeat both need raw pointer coordinates and their
/// own timers, not a canned recognizer.
///
/// Three modes selected by the caller:
/// - slider ([sliderEnabled] true, [channelMode] false): drag sets the level
///   continuously, a plain tap steps by whatever [onTapUp]/[onTapDown] do.
/// - button ([sliderEnabled] false): no drag; the half tapped fires
///   immediately on pointer-down and repeats every 120ms after a 400ms hold.
/// - channel ([channelMode] true): no drag, no repeat; the half tapped fires
///   on pointer-*up* only.
class LevelPill extends StatefulWidget {
  const LevelPill({
    super.key,
    required this.width,
    required this.height,
    required this.label,
    required this.level,
    required this.fillColor,
    required this.topIcon,
    required this.bottomIcon,
    required this.topSemanticLabel,
    required this.bottomSemanticLabel,
    this.iconSize = 28,
    this.sliderEnabled = true,
    this.channelMode = false,
    this.onTapUp,
    this.onTapDown,
    this.onDragMove,
    this.onDragEnd,
  });

  final double width;
  final double height;
  final String label;
  final int? level;
  final Color? fillColor;
  final String topIcon;
  final String bottomIcon;
  final String topSemanticLabel;
  final String bottomSemanticLabel;
  final double iconSize;
  final bool sliderEnabled;
  final bool channelMode;

  /// Fired for the top half: drag-disabled tap, button-mode repeat tick, or
  /// (in channel mode) the up-half release.
  final VoidCallback? onTapUp;
  final VoidCallback? onTapDown;
  final ValueChanged<int>? onDragMove;
  final ValueChanged<int>? onDragEnd;

  @override
  State<LevelPill> createState() => _LevelPillState();
}

class _LevelPillState extends State<LevelPill> {
  double? _startY;
  bool _dragging = false;
  int _lastHapticLevel = -1;
  bool _showTop = false;
  bool _showBottom = false;
  Timer? _initialDelay;
  Timer? _repeat;
  bool _repeatIsUp = false;

  int _levelFromY(double y) => (((1 - y / widget.height) * 100).toInt()).clamp(0, 100);

  void _cancelTimers() {
    _initialDelay?.cancel();
    _initialDelay = null;
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _fireHalf(bool up) {
    if (up) {
      widget.onTapUp?.call();
    } else {
      widget.onTapDown?.call();
    }
  }

  void _onDown(PointerDownEvent event) {
    // Claim the gesture before the page's own scrollable can start a
    // competing vertical drag (Kotlin's requestDisallowInterceptTouchEvent).
    FillViewportPage.scrollLockOf(context)?.value = true;
    final y = event.localPosition.dy;
    _startY = y;
    _dragging = false;
    _lastHapticLevel = -1;
    final isTop = y < widget.height / 2;
    setState(() {
      _showTop = isTop;
      _showBottom = !isTop;
    });
    if (widget.channelMode) return;
    if (!widget.sliderEnabled) {
      _repeatIsUp = isTop;
      _fireHalf(isTop);
      _cancelTimers();
      _initialDelay = Timer(const Duration(milliseconds: 400), () {
        _repeat = Timer.periodic(const Duration(milliseconds: 120), (_) {
          HapticFeedback.selectionClick();
          _fireHalf(_repeatIsUp);
        });
      });
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (widget.channelMode || !widget.sliderEnabled) return;
    final y = event.localPosition.dy;
    if (!_dragging && (y - _startY!).abs() > 10) {
      setState(() {
        _dragging = true;
        _showTop = false;
        _showBottom = false;
      });
    }
    if (_dragging) {
      final level = _levelFromY(y);
      widget.onDragMove?.call(level);
      if (_lastHapticLevel == -1 || (level - _lastHapticLevel).abs() >= 3) {
        HapticFeedback.selectionClick();
        _lastHapticLevel = level;
      }
    }
  }

  void _onUp(PointerUpEvent event) {
    FillViewportPage.scrollLockOf(context)?.value = false;
    _cancelTimers();
    setState(() {
      _showTop = false;
      _showBottom = false;
    });
    HapticFeedback.lightImpact();
    final y = event.localPosition.dy;
    final isTop = y < widget.height / 2;
    if (widget.channelMode) {
      _fireHalf(isTop);
    } else if (widget.sliderEnabled) {
      if (_dragging) {
        widget.onDragEnd?.call(_levelFromY(y));
      } else {
        _fireHalf(isTop);
      }
    }
    _dragging = false;
  }

  void _onCancel(PointerCancelEvent event) {
    FillViewportPage.scrollLockOf(context)?.value = false;
    _cancelTimers();
    setState(() {
      _showTop = false;
      _showBottom = false;
    });
    _dragging = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final highlight =
        theme.id == 'light' ? const Color(0x20000000) : const Color(0x33FFFFFF);
    final level = (widget.level ?? 0).clamp(0, 100);
    final barHeight = widget.fillColor == null ? 0.0 : widget.height * level / 100;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.width,
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: theme.pillLabelText),
          ),
        ),
        const SizedBox(height: 6),
        Listener(
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onCancel,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: SizedBox(
              width: widget.width,
              height: widget.height,
              child: ColoredBox(
                color: theme.pillBg,
                child: Stack(
                  children: [
                    if (widget.fillColor != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: barHeight,
                        child: ColoredBox(color: widget.fillColor!),
                      ),
                    Column(
                      children: [
                        Expanded(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Semantics(
                                label: widget.topSemanticLabel,
                                child: AppIcon(widget.topIcon,
                                    size: widget.iconSize, color: theme.circleBtnIconTint),
                              ),
                            ),
                          ),
                        ),
                        Container(width: 34, height: 1, color: theme.pillDivider),
                        Expanded(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Semantics(
                                label: widget.bottomSemanticLabel,
                                child: AppIcon(widget.bottomIcon,
                                    size: widget.iconSize, color: theme.circleBtnIconTint),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_showTop)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: widget.height / 2,
                        child: IgnorePointer(child: ColoredBox(color: highlight)),
                      ),
                    if (_showBottom)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: widget.height / 2,
                        child: IgnorePointer(child: ColoredBox(color: highlight)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
