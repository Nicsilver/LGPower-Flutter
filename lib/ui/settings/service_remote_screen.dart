import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../net/ir.dart';
import '../../theme/theme_manager.dart';
import '../widgets/app_toast.dart';
import '../widgets/warning_sheet.dart';
import 'service_page.dart';

/// Service Menu (IR): IR-only replica of LG's factory service remote
/// (105-201M / MKJ39170828, spec §4). Service menus don't reliably react to
/// network (SSAP) input, so every button transmits raw NEC 0x04 over the
/// platform channel and the phone must point at the TV.
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
  // Null until the emitter check answers; the grid is built after that
  bool? _hasIr;

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
        chip: 'NO IR BLASTER',
        title: "This phone can't transmit",
        body: 'The service remote sends raw IR and this phone has no IR emitter. '
            'It needs a phone with a built-in IR blaster.',
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

  // Cancelling the entry sheet (back/outside tap) leaves nothing useful on
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
    if (_hasIr == null) return Scaffold(backgroundColor: AppTheme.of(context).windowBg);
    return ServicePage(
      subtitle: 'NEC 0x04 over IR · aim at the TV',
      footer: 'MKJ39170828 REPLICA · IR ONLY',
      sections: [
        const ServiceLabel('FACTORY ENTRY'),
        ServiceRow([
          ServiceTile('IN-START', service: true, onTap: () => unawaited(_sendIr(0xFB))),
          ServiceTile('EZ-ADJUST', service: true, onTap: () => unawaited(_sendIr(0xFF))),
        ]),
        ServiceRow([
          ServiceTile(
            'POWER-ONLY',
            service: true,
            onTap: () => _confirmTile(
              'POWER-ONLY',
              0xFE,
              "Locks the TV into power-only mode: it stops responding to everything "
                  "except the power button, and the only way back out is through the "
                  "service menu. Don't send this unless you know why you need it.",
            ),
          ),
          ServiceTile(
            'IN-STOP',
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
        ...serviceKeyGrid(withPower: true, onKey: (k) => unawaited(_sendIr(k.ir))),
      ],
    );
  }
}
