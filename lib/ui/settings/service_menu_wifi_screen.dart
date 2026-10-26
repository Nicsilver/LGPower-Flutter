import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../net/ir.dart';
import '../../net/webos_client.dart';
import '../widgets/app_toast.dart';
import '../widgets/warning_sheet.dart';
import 'service_page.dart';

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

/// Service Menu (Wi-Fi): opens IN-START and EZ-ADJUST through the launcher and
/// drives the menu with the digit and nav keys over the pointer socket. Works
/// on every phone, blaster or not. POWER-ONLY and IN-STOP are not offered
/// here: a factory reset or a locked TV is not something to fire from a
/// network call.
class ServiceMenuWifiScreen extends StatefulWidget {
  const ServiceMenuWifiScreen({super.key, required this.link, this.hasEmitter = Ir.hasEmitter});

  final ServiceLink link;

  /// Only decides whether a refusal toast points at the IR page.
  final Future<bool> Function() hasEmitter;

  @override
  State<ServiceMenuWifiScreen> createState() => _ServiceMenuWifiScreenState();
}

class _ServiceMenuWifiScreenState extends State<ServiceMenuWifiScreen> {
  bool _hasIr = false;

  // A double tap would launch or close the factory app twice
  bool _menuBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.hasEmitter().then((v) {
      if (mounted) _hasIr = v;
    }));
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_showEntrySheet()));
  }

  Future<void> _showEntrySheet() async {
    if (!mounted) return;
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
  }

  // Cancelling the entry sheet (back/outside tap) leaves nothing useful on
  // this screen -- accepting does, so only cancel closes it.
  void _closeScreen() {
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(String text) {
    if (mounted) showToast(context, text, long: true);
  }

  Future<void> _sendKey(String tvKey) async {
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
      "Your TV didn't open the service menu over Wi-Fi.${_hasIr ? ' Try Service Menu (IR).' : ''}";

  bool _isUnreachable(String message) =>
      _unreachable.any((p) => message.toLowerCase().startsWith(p.toLowerCase()));

  Future<void> _open(ServiceMenu menu) async {
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

  Future<void> _close() async {
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

  @override
  Widget build(BuildContext context) {
    return ServicePage(
      subtitle: 'Over Wi-Fi · the TV must be on',
      footer: 'KEYS OVER WI-FI · THE TV MUST BE ON',
      sections: [
        const ServiceLabel('OVER WI-FI'),
        ServiceRow([
          ServiceTile('IN-START', service: true, onTap: () => unawaited(_open(ServiceMenu.inStart))),
          ServiceTile('EZ-ADJUST', service: true, onTap: () => unawaited(_open(ServiceMenu.ezAdjust))),
          ServiceTile('CLOSE MENU', onTap: () => unawaited(_close())),
        ]),
        ...serviceKeyGrid(
          withPower: false,
          onKey: (k) {
            final tv = k.tv;
            if (tv != null) unawaited(_sendKey(tv));
          },
        ),
      ],
    );
  }
}
