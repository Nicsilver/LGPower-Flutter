import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/haptics.dart';
import '../../../theme/theme_manager.dart';
import '../../widgets/app_icon.dart';
import '../dims.dart';
import '../remote_controller.dart';
import 'circle_button.dart';
import 'fill_viewport_page.dart';

/// The numpad page (spec §3.4, §5 "Numpad"): dialer grid, echo readout,
/// CH rocker, guide/info/cc/exit row and the close button back to the
/// remote. Swapped in by `main_screen.dart` in place of the main column.
class NumpadPage extends StatefulWidget {
  const NumpadPage({super.key, required this.controller, required this.onClose});

  final RemoteController controller;
  final VoidCallback onClose;

  @override
  State<NumpadPage> createState() => _NumpadPageState();
}

class _NumpadPageState extends State<NumpadPage> with SingleTickerProviderStateMixin {
  late final AnimationController _fade =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600), value: 1);
  String _readout = '';
  Timer? _holdTimer;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _echo(String s) {
    _holdTimer?.cancel();
    _fade.stop();
    _fade.value = 1;
    setState(() => _readout = (_readout.length >= 4 ? '' : _readout) + s);
    _holdTimer = Timer(const Duration(milliseconds: 2000), () async {
      await _fade.animateTo(0, duration: const Duration(milliseconds: 600));
      if (!mounted) return;
      setState(() => _readout = '');
      _fade.value = 1;
    });
  }

  void _digit(String d) {
    unawaited(widget.controller.pressSimple(d));
    _echo(d);
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final dims = MainDims.of(context);
    final ghostBg = theme.primaryText.withAlpha(0x0C);

    Widget ghostKey(String label, VoidCallback onTap,
        {double width = 88, double height = 56, double fontSize = 32, Color? color, String? cd}) {
      return CircleButtonLikeKey(
        width: width,
        height: height,
        color: ghostBg,
        onTap: onTap,
        semanticLabel: cd ?? label,
        child: Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: fontSize >= 32 ? FontWeight.w300 : FontWeight.w500,
            color: color ?? theme.primaryText,
          ),
        ),
      );
    }

    Widget smallKey(String label, VoidCallback onTap, {String? cd}) {
      return CircleButtonLikeKey(
        width: null,
        height: 44,
        color: Colors.transparent,
        onTap: onTap,
        semanticLabel: cd ?? label,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 11 * 0.2,
            color: theme.secondaryText,
          ),
        ),
      );
    }

    return FillViewportPage(
      // Same insets as the remote so the Remote button lands where 123 sits
      padding: EdgeInsets.fromLTRB(dims.mainPadH, 16, dims.mainPadH, 48),
      children: [
        SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Numpad',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.primaryText),
            ),
          ),
        ),
        const Spacer(),
        AnimatedBuilder(
          animation: _fade,
          builder: (context, _) => Opacity(
            opacity: _fade.value,
            child: SizedBox(
              height: 68,
              child: Center(
                child: Text(
                  _readout,
                  style: TextStyle(
                    fontSize: 52,
                    fontWeight: FontWeight.w100,
                    letterSpacing: 52 * 0.06,
                    color: theme.primaryText.withAlpha(0x40),
                  ),
                ),
              ),
            ),
          ),
        ),
        const Spacer(),
        Column(
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ghostKey('1', () => _digit('1')),
              const SizedBox(width: 8),
              ghostKey('2', () => _digit('2')),
              const SizedBox(width: 8),
              ghostKey('3', () => _digit('3')),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ghostKey('4', () => _digit('4')),
              const SizedBox(width: 8),
              ghostKey('5', () => _digit('5')),
              const SizedBox(width: 8),
              ghostKey('6', () => _digit('6')),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ghostKey('7', () => _digit('7')),
              const SizedBox(width: 8),
              ghostKey('8', () => _digit('8')),
              const SizedBox(width: 8),
              ghostKey('9', () => _digit('9')),
            ]),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ghostKey(
                'LIST',
                () => unawaited(widget.controller.pressSimple('LIST')),
                fontSize: 11,
                color: theme.secondaryText,
                cd: 'Channel List',
              ),
              const SizedBox(width: 8),
              ghostKey('0', () => _digit('0')),
              const SizedBox(width: 8),
              ghostKey('–', () {
                unawaited(widget.controller.pressSimple('DASH'));
                _echo('–');
              }, cd: 'Dash'),
            ]),
            const SizedBox(height: 8),
            // Wide OK under the digits: confirms a typed channel without a
            // trip back to the d-pad
            ghostKey(
              'OK',
              () => unawaited(widget.controller.pressSimple('ENTER')),
              width: 280,
              height: 52,
              fontSize: 13,
              cd: 'Enter',
            ),
          ],
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ghostKey(
              '−',
              () => unawaited(widget.controller.channelDown()),
              height: 48,
              fontSize: 26,
              cd: 'Channel Down',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'CH',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 10 * 0.3,
                  color: theme.secondaryText,
                ),
              ),
            ),
            ghostKey(
              '+',
              () => unawaited(widget.controller.channelUp()),
              height: 48,
              fontSize: 26,
              cd: 'Channel Up',
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Five spaced keys outgrow a 360 dp screen; shrink the row rather
        // than wrap it
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              smallKey('GUIDE', () => unawaited(widget.controller.pressSimple('GUIDE'))),
              const SizedBox(width: 14),
              smallKey('INFO', () => unawaited(widget.controller.pressSimple('INFO'))),
              const SizedBox(width: 14),
              smallKey('CC', () => unawaited(widget.controller.pressSimple('CC')), cd: 'Subtitles'),
              const SizedBox(width: 14),
              smallKey('EXIT', () => unawaited(widget.controller.pressSimple('EXIT'))),
              const SizedBox(width: 14),
              smallKey(
                'LIVE TV',
                () => unawaited(widget.controller.sendCommand(
                    () => widget.controller.client.launchApp('com.webos.app.livetv'))),
                cd: 'Live TV',
              ),
            ],
          ),
        ),
        const Spacer(),
        Center(
          child: CircleButton(
            size: 56,
            color: theme.circleBtnBg,
            label: 'Remote',
            labelColor: theme.secondaryText,
            semanticLabel: 'Back to Remote',
            onTap: () {
              Haptics.light();
              widget.onClose();
            },
            child: AppIcon('ic_remote', size: 24, color: theme.circleBtnIconTint),
          ),
        ),
      ],
    );
  }
}

/// A ghost/small numpad key: a plain tappable box (no press-scale animation
/// in the source -- these are custom `Button` styles the press-animation
/// pass still reaches, but the spec doesn't call out a numpad-specific scale
/// so the shared 0.82 rule from [PressScale] would be redundant chrome on
/// keys this small and frequently tapped; a plain `InkWell` ripple reads
/// better here).
class CircleButtonLikeKey extends StatelessWidget {
  const CircleButtonLikeKey({
    super.key,
    required this.height,
    required this.color,
    required this.onTap,
    required this.child,
    this.width,
    this.padding,
    this.semanticLabel,
  });

  final double? width;
  final double height;
  final Color color;
  final VoidCallback onTap;
  final Widget child;
  final EdgeInsets? padding;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            width: width,
            height: height,
            padding: padding,
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}
