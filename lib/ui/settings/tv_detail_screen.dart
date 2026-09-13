import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/prefs.dart';
import '../../core/tv_store.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../widgets/buttons.dart';
import '../widgets/edit_row.dart';
import '../widgets/section.dart';
import '../widgets/warning_sheet.dart';

/// One saved TV: name, address, MAC, and the switch / remove actions. Edits
/// are saved when the screen is left, like the Kotlin activity's onPause.
class TvDetailScreen extends StatefulWidget {
  const TvDetailScreen({super.key, required this.prefs, required this.tvId});

  final Prefs prefs;
  final String tvId;

  @override
  State<TvDetailScreen> createState() => _TvDetailScreenState();
}

class _TvDetailScreenState extends State<TvDetailScreen> {
  late final TextEditingController _name;
  late final TextEditingController _ip;
  late final TextEditingController _mac;
  Tv? _tv;
  bool _removed = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _tv = TvStore.list(
      widget.prefs,
    ).where((t) => t.id == widget.tvId).firstOrNull;
    _name = TextEditingController(text: _tv?.name ?? '');
    _ip = TextEditingController(text: _tv?.ip ?? '');
    _mac = TextEditingController(text: _tv?.mac ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _ip.dispose();
    _mac.dispose();
    super.dispose();
  }

  // Runs on the pop itself (system back or a button), not on dispose, which
  // only comes after the exit transition -- too late for the Settings list
  // underneath to show the new name when it refreshes.
  void _save() {
    if (_saved || _removed || _tv == null) return;
    _saved = true;
    TvStore.update(
      widget.prefs,
      widget.tvId,
      name: _name.text,
      ip: _ip.text,
      mac: _mac.text,
    );
  }

  void _useThisTv() {
    _save();
    TvStore.switchTo(widget.prefs, widget.tvId);
    Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final tv = _tv!;
    await showWarningSheet(
      context,
      chip: 'REMOVE TV',
      title: 'Remove ${tv.name}?',
      body:
          'The pairing with this TV is forgotten. Adding it again asks the TV to pair once more.',
      button: 'Remove',
      onAccept: () {
        _removed = true;
        TvStore.remove(widget.prefs, widget.tvId);
        if (mounted) Navigator.of(context).pop();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final tv = _tv;
    if (tv == null) {
      // Opened for a TV that no longer exists -- nothing to show.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return Scaffold(backgroundColor: theme.windowBg);
    }
    final isActive = TvStore.activeId(widget.prefs) == widget.tvId;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save();
      },
      child: Scaffold(
        backgroundColor: theme.windowBg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 56),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    tv.name,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      color: theme.primaryText,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: SectionLabel('TV'),
                ),
                SurfaceCard(
                  radius: 14,
                  child: Column(
                    children: [
                      EditRow(
                        label: 'Name',
                        controller: _name,
                        hint: 'Living room',
                        textCapitalization: TextCapitalization.sentences,
                      ),
                      const RowDivider(),
                      EditRow(
                        label: 'IP Address',
                        controller: _ip,
                        hint: '192.168.1.x',
                        keyboardType: TextInputType.url,
                      ),
                      const RowDivider(),
                      EditRow(
                        label: 'MAC Address',
                        controller: _mac,
                        hint: 'AA:BB:CC:DD:EE:FF',
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 28),
                  child: Text(
                    _macHint,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: theme.secondaryText,
                    ),
                  ),
                ),
                if (!isActive) ...[
                  SizedBox(
                    width: double.infinity,
                    child: AccentButton(
                      label: 'Use this TV',
                      height: 48,
                      onPressed: _useThisTv,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  child: _RemoveButton(
                    theme: theme,
                    onPressed: () => unawaited(_remove()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const _macHint =
      'Filled in when the TV was paired. The MAC address is what wakes the TV from standby. '
      'On the TV, enable Turn on via Wi-Fi (Settings › General › Devices › External Devices › '
      'TV On With Mobile; on 2025 and newer sets Support › IP control settings › Wake on LAN). '
      'If waking only works for a few minutes after switching off, also enable Quick Start+ '
      '(Always Ready on 2022+ models) so the network stays awake.';
}

/// Ghost outline with red text -- the one destructive button in the app.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.theme, required this.onPressed});

  final ThemeConfig theme;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: theme.btnGhostBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: const Text(
          'Remove this TV',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Color(0xFFE05555),
          ),
        ),
      ),
    );
  }
}
