import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../net/ir.dart';
import '../../net/webos_client.dart';
import '../../theme/color_util.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../widgets/app_toast.dart';
import '../widgets/warning_sheet.dart';

const _amber = Color(0xFFE8A33D);

/// What the screen needs from the TV connection, so tests can stand in for it.
abstract interface class ServiceLink {
  Future<Result> launch(ServiceMenu menu);
  Future<Result> close();
  Future<Result> pressKey(String key);
}

class ClientServiceLink implements ServiceLink {
  const ClientServiceLink(this.client);
  final WebOsClient client;

  @override
  Future<Result> launch(ServiceMenu menu) => client.launchServiceMenu(menu);
  @override
  Future<Result> close() => client.closeServiceMenu();
  @override
  Future<Result> pressKey(String key) => client.pressKey(key);
}

// What WebOsClient says about a TV it never spoke to, as opposed to one that said no
const _unreachable = [
  'No TV IP',
  'Timeout',
  "Can't connect",
  'Not connected',
  'Connection',
  'Session closed',
  'Lost the connection',
];

const _pairingText = 'Accept pairing on your TV, then try again.';
const _unreachableText = "Can't reach the TV. Check it is on and on this Wi-Fi.";

/// Replica of LG's factory service remote (spec §4). The IR keys transmit raw
/// NEC 0x04 over the platform channel, so the phone must point at the TV.
/// IN-START and EZ-ADJUST can also be opened over Wi-Fi through the launcher,
/// which is the only way in on a phone without a blaster (and on iOS); there
/// the digit and nav tiles ride the pointer socket instead. POWER-ONLY and
/// IN-STOP stay IR-only (a reset or a locked TV is not something to fire from
/// a network call).
class ServiceRemoteScreen extends StatefulWidget {
  const ServiceRemoteScreen({
    super.key,
    required this.link,
    this.hasEmitter = Ir.hasEmitter,
    this.transmit = Ir.transmit,
  });

  final ServiceLink link;

  /// Injectable for tests; defaults to the real platform channel.
  final Future<bool> Function() hasEmitter;
  final Future<void> Function(int carrierHz, List<int> pattern) transmit;

  @override
  State<ServiceRemoteScreen> createState() => _ServiceRemoteScreenState();
}

class _ServiceRemoteScreenState extends State<ServiceRemoteScreen> {
  // Null until the emitter check answers; the grid is built after that
  bool? _hasIr;

  // A double tap would launch or close the factory app twice
  bool _menuBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final hasEmitter = await widget.hasEmitter();
    if (!mounted) return;
    setState(() => _hasIr = hasEmitter);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showEntrySheet(hasEmitter));
  }

  Future<void> _showEntrySheet(bool hasEmitter) async {
    if (!mounted) return;
    if (!hasEmitter) {
      await showWarningSheet(
        context,
        chip: 'FACTORY CONTROLS',
        title: 'This can wreck your TV',
        body: "Service menu settings can break your TV. Only change what you know.\n\n"
            "Wrong EZ-Adjust values (panel, white balance) can permanently ruin the "
            "picture, and wrong IN-START values can leave the TV misconfigured. "
            "Note every value down before changing it. If you're just curious: "
            "look, don't touch.",
        button: 'I understand the risks',
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
    Haptics.selection();
    if (!await widget.hasEmitter()) {
      if (mounted) showToast(context, 'No IR blaster on this phone');
      return;
    }
    await widget.transmit(38000, Ir.necPattern(Ir.lgCode(cmd)));
  }

  void _toast(String text) {
    if (mounted) showToast(context, text, long: true);
  }

  Future<void> _sendKey(int irCmd, String? tvKey) async {
    if (_hasIr == true || tvKey == null) return _sendIr(irCmd);
    Haptics.selection();
    final r = await widget.link.pressKey(tvKey);
    switch (r) {
      case NeedsPairing():
        _toast(_pairingText);
      case CmdError(:final message):
        _toast(message);
      case Success():
    }
  }

  String _refusedText() =>
      "Your TV didn't open the service menu over Wi-Fi.${_hasIr == true ? ' Try IR.' : ''}";

  bool _isUnreachable(String message) =>
      _unreachable.any((p) => message.toLowerCase().startsWith(p.toLowerCase()));

  Future<void> _openOverWifi(ServiceMenu menu) async {
    if (_menuBusy) return;
    _menuBusy = true;
    Haptics.selection();
    try {
      final r = await widget.link.launch(menu);
      final problem = switch (r) {
        NeedsPairing() => _pairingText,
        CmdError(:final message) => _isUnreachable(message) ? _unreachableText : _refusedText(),
        // The C4 never reports factorywin as the foreground app (it keeps naming
        // the app underneath), so the launch reply is the only signal there is.
        Success() => null,
      };
      if (problem != null) _toast(problem);
    } finally {
      _menuBusy = false;
    }
  }

  Future<void> _closeOverWifi() async {
    if (_menuBusy) return;
    _menuBusy = true;
    Haptics.selection();
    try {
      final r = await widget.link.close();
      switch (r) {
        case NeedsPairing():
          _toast(_pairingText);
        case CmdError(:final message):
          _toast(_isUnreachable(message) ? _unreachableText : message);
        case Success():
      }
    } finally {
      _menuBusy = false;
    }
  }

  void _confirmTile(String title, int cmd, String body) {
    Haptics.selection();
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
    final hasIr = _hasIr;
    if (hasIr == null) return Scaffold(backgroundColor: theme.windowBg);
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
                  hasIr ? 'Wi-Fi launch · NEC 0x04 over IR, aim at the TV' : 'Over Wi-Fi · the TV must be on',
                  style: TextStyle(fontSize: 10.5, fontFamily: 'monospace', color: theme.sectionLabel),
                ),
              ),
              const _HazardBand(),
              _label(theme, 'OVER WI-FI'),
              _row([
                _tile(
                  theme,
                  'IN-START',
                  0,
                  service: true,
                  tileKey: const ValueKey('wifi-IN-START'),
                  onTap: () => unawaited(_openOverWifi(ServiceMenu.inStart)),
                ),
                _tile(
                  theme,
                  'EZ-ADJUST',
                  0,
                  service: true,
                  tileKey: const ValueKey('wifi-EZ-ADJUST'),
                  onTap: () => unawaited(_openOverWifi(ServiceMenu.ezAdjust)),
                ),
                _tile(
                  theme,
                  'CLOSE MENU',
                  0,
                  tileKey: const ValueKey('wifi-CLOSE'),
                  onTap: () => unawaited(_closeOverWifi()),
                ),
              ]),
              if (hasIr) ...[
                _label(theme, 'FACTORY ENTRY · IR'),
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
              ],
              _label(theme, 'PASSWORD · 0413 / 0000'),
              _row([_tile(theme, '1', 0x11, key: '1'), _tile(theme, '2', 0x12, key: '2'), _tile(theme, '3', 0x13, key: '3')]),
              _row([_tile(theme, '4', 0x14, key: '4'), _tile(theme, '5', 0x15, key: '5'), _tile(theme, '6', 0x16, key: '6')]),
              _row([_tile(theme, '7', 0x17, key: '7'), _tile(theme, '8', 0x18, key: '8'), _tile(theme, '9', 0x19, key: '9')]),
              _row([_spacer(), _tile(theme, '0', 0x10, key: '0'), _spacer()]),
              _label(theme, 'NAV'),
              _row([
                _tile(theme, 'BACK', 0x28, key: 'BACK'),
                _tile(theme, '▲', 0x40, key: 'UP'),
                _tile(theme, 'EXIT', 0x5B, key: 'EXIT'),
              ]),
              _row([
                _tile(theme, '◀', 0x07, key: 'LEFT'),
                _tile(theme, 'OK', 0x44, key: 'ENTER'),
                _tile(theme, '▶', 0x06, key: 'RIGHT'),
              ]),
              _row([
                hasIr ? _tile(theme, 'PWR', 0x08) : _spacer(),
                _tile(theme, '▼', 0x41, key: 'DOWN'),
                _spacer(),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    hasIr ? 'KEYS OVER IR · AIM THE PHONE AT THE TV' : 'KEYS OVER WI-FI · THE TV MUST BE ON',
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
    String? key,
    Key? tileKey,
    VoidCallback? onTap,
  }) {
    final bg = service ? ColorUtil.mix(theme.windowBg, _amber, 0.07) : ColorUtil.mix(theme.windowBg, theme.surfaceBg, 0.55);
    final border = service
        ? ColorUtil.withAlpha(_amber, 0x55)
        : ColorUtil.mix(theme.surfaceBg, theme.primaryText, 0.12);
    final textColor = service ? _amber : theme.primaryText;
    return SizedBox(
      key: tileKey,
      height: 46,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap ?? () => unawaited(_sendKey(cmd, key)),
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
