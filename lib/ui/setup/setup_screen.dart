import 'dart:async';

import 'package:flutter/material.dart';

import '../../net/pairing_watcher.dart';
import '../../net/tv_discovery.dart';
import '../../net/webos_client.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../main/main_screen.dart';
import '../widgets/buttons.dart';
import '../widgets/section.dart';

enum _Screen { searching, list, pairing }

enum _PairingPhase { connecting, promptShown, failed, success }

/// First-launch setup flow (spec §1): search, pick, pair. Only ever reached
/// with a blank `tv_ip` -- there is no menu entry back into it, matching the
/// original app.
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.client,
    this.discover = discoverTvs,
    this.pairingWatch,
  });

  final WebOsClient client;

  /// Injectable for tests; defaults to the real network scan.
  final Future<List<String>> Function() discover;

  /// Injectable for tests; defaults to a fresh [PairingWatcher] per attempt.
  final PairingWatch? pairingWatch;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  _Screen _screen = _Screen.searching;
  List<String> _tvList = const [];

  String? _selectedIp;
  _PairingPhase _pairingPhase = _PairingPhase.connecting;

  Timer? _uiTimeout;
  StopPairing? _stopPairing;
  bool _promptShown = false;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  @override
  void dispose() {
    _uiTimeout?.cancel();
    _stopPairing?.call();
    super.dispose();
  }

  Future<void> _startDiscovery() async {
    setState(() => _screen = _Screen.searching);
    final ips = await widget.discover();
    if (!mounted) return;
    setState(() {
      _tvList = ips;
      _screen = _Screen.list;
    });
  }

  void _selectTv(String ip) {
    _uiTimeout?.cancel();
    _stopPairing?.call();
    _promptShown = false;
    setState(() {
      _selectedIp = ip;
      _pairingPhase = _PairingPhase.connecting;
      _screen = _Screen.pairing;
    });

    // Once the prompt is on screen the user may take as long as they like
    // (spec §1.5) -- this timeout only guards the pre-prompt silence.
    _uiTimeout = Timer(const Duration(seconds: 30), () {
      if (_promptShown) return;
      _stopPairing?.call();
      if (mounted) setState(() => _pairingPhase = _PairingPhase.failed);
    });

    final watch = widget.pairingWatch ?? PairingWatcher(widget.client.prefs).watch;
    _stopPairing = watch(
      ip,
      onPromptShown: () {
        _promptShown = true;
        _uiTimeout?.cancel();
        if (mounted) setState(() => _pairingPhase = _PairingPhase.promptShown);
      },
      onPaired: (_) => _onPaired(ip),
    );
  }

  Future<void> _onPaired(String ip) async {
    _uiTimeout?.cancel();
    await widget.client.saveTvIp(ip);
    // Runs while the success screen is on screen -- does not block the
    // 1200ms navigation below (spec §1.5).
    unawaited(widget.client.getMacFromDevice().then((mac) {
      if (mac != null && mac.isNotEmpty) widget.client.saveTvMac(mac);
    }));
    if (!mounted) return;
    setState(() => _pairingPhase = _PairingPhase.success);
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainScreen()),
    );
  }

  void _retry() {
    final ip = _selectedIp;
    if (ip != null) _selectTv(ip);
  }

  void _searchAgain() {
    _uiTimeout?.cancel();
    _stopPairing?.call();
    _startDiscovery();
  }

  Future<void> _showManualIpDialog() async {
    final ip = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _ManualIpDialog(),
    );
    final trimmed = ip?.trim();
    if (trimmed != null && trimmed.isNotEmpty) _selectTv(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Scaffold(
      backgroundColor: theme.windowBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 72, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                'LG Power',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.02 * 30,
                  color: theme.primaryText,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Connect to your TV',
                style: TextStyle(fontSize: 15, color: theme.secondaryText),
              ),
              const SizedBox(height: 48),
              _buildScreen(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScreen(ThemeConfig theme) {
    switch (_screen) {
      case _Screen.searching:
        return _buildSearching(theme);
      case _Screen.list:
        return _buildList(theme);
      case _Screen.pairing:
        return _buildPairing(theme);
    }
  }

  Widget _buildSearching(ThemeConfig theme) {
    return Column(
      children: [
        const SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(height: 18),
        Text(
          'Searching for TVs on your network…',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: theme.secondaryText),
        ),
      ],
    );
  }

  Widget _buildList(ThemeConfig theme) {
    if (_tvList.isEmpty) {
      return Column(
        children: [
          Text(
            'No TVs found on this network',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: theme.secondaryText),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: GhostButton(label: 'Search again', height: 48, onPressed: _startDiscovery),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: GhostButton(label: 'Enter IP manually', height: 48, onPressed: _showManualIpDialog),
          ),
        ],
      );
    }

    final label = _tvList.length == 1 ? 'TV FOUND' : 'TVS FOUND';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SectionLabel(label),
        ),
        SurfaceCard(
          radius: 14,
          child: Column(
            children: [
              for (var i = 0; i < _tvList.length; i++) ...[
                if (i > 0) const RowDivider(),
                _TvRow(ip: _tvList[i], theme: theme, onTap: () => _selectTv(_tvList[i])),
              ],
            ],
          ),
        ),
        // Discovery can list the wrong box (or miss a TV on another VLAN), so
        // typing an address stays available even when something was found.
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: GhostButton(label: 'Enter IP manually', height: 48, onPressed: _showManualIpDialog),
        ),
      ],
    );
  }

  Widget _buildPairing(ThemeConfig theme) {
    final String message;
    final Color messageColor;
    switch (_pairingPhase) {
      case _PairingPhase.connecting:
        message = 'Connecting…';
        messageColor = theme.secondaryText;
      case _PairingPhase.promptShown:
        message = 'Accept the pairing prompt\non your TV to continue';
        messageColor = theme.secondaryText;
      case _PairingPhase.failed:
        message = "Can't reach the TV.\nMake sure it's on, restart it,\nthen try again.";
        messageColor = theme.secondaryText;
      case _PairingPhase.success:
        message = 'Connected!';
        messageColor = theme.btnAccentBg;
    }

    return SizedBox(
      width: double.infinity,
      child: SurfaceCard(
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _selectedIp ?? '',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.primaryText),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, height: 1.27, color: messageColor),
              ),
              const SizedBox(height: 28),
              if (_pairingPhase == _PairingPhase.connecting ||
                  _pairingPhase == _PairingPhase.promptShown)
                const SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              if (_pairingPhase == _PairingPhase.failed) ...[
                SizedBox(
                  width: double.infinity,
                  child: AccentButton(label: 'Try again', height: 44, onPressed: _retry),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: GhostButton(label: 'Search again', height: 44, onPressed: _searchAgain),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TvRow extends StatelessWidget {
  const _TvRow({required this.ip, required this.theme, required this.onTap});

  final String ip;
  final ThemeConfig theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.centerLeft,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('LG TV', style: TextStyle(fontSize: 16, color: theme.primaryText)),
              Text(ip, style: TextStyle(fontSize: 13, color: theme.secondaryText)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A `TextEditingController` owned by the caller and disposed right after
/// `showDialog` returns can outlive the dialog's closing transition,
/// throwing "used after being disposed" mid-animation -- owning it in the
/// dialog's own State (disposed from its own `dispose()`) avoids the race.
class _ManualIpDialog extends StatefulWidget {
  const _ManualIpDialog();

  @override
  State<_ManualIpDialog> createState() => _ManualIpDialogState();
}

class _ManualIpDialogState extends State<_ManualIpDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Dialog(
      backgroundColor: theme.surfaceBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Enter IP manually',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: theme.primaryText),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.text,
              style: TextStyle(fontSize: 15, color: theme.secondaryText),
              decoration: InputDecoration(
                hintText: '192.168.1.x',
                hintStyle: TextStyle(color: theme.secondaryText.withAlpha(120)),
                isDense: true,
              ),
              onSubmitted: (value) => Navigator.of(context).pop(value),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: GhostButton(
                    label: 'Cancel',
                    height: 44,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AccentButton(
                    label: 'Connect',
                    height: 44,
                    onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
