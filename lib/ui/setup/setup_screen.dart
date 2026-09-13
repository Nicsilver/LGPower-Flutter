import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/tv_store.dart';
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

/// Setup flow (spec §1): search, pick, pair, name. Reached with a blank
/// `tv_ip` on first run, and again in [addMode] from the remote's TV picker
/// or Settings › TVs › Add a TV to pair a second set.
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.client,
    this.discover = discoverTvsDetailed,
    this.pairingWatch,
    this.addMode = false,
    this.fingerprint = fingerprintTv,
  });

  final WebOsClient client;

  /// Injectable for tests; defaults to the real network scan.
  final Future<List<FoundTv>> Function() discover;

  /// Injectable for tests; defaults to a fresh [PairingWatcher] per attempt.
  final PairingWatch? pairingWatch;

  /// Adding another TV from the remote, as opposed to first-run setup: the
  /// live prefs are parked (and restored on back-out), the name step feeds
  /// a new saved TV, and the tour is not queued.
  final bool addMode;

  /// Unicast SSDP lookup for TVs typed in by hand; injectable for tests.
  final Future<String?> Function(String ip) fingerprint;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  _Screen _screen = _Screen.searching;
  List<FoundTv> _tvList = const [];

  String? _selectedIp;
  _PairingPhase _pairingPhase = _PairingPhase.connecting;

  Timer? _uiTimeout;
  StopPairing? _stopPairing;
  bool _promptShown = false;
  bool _paired = false;
  bool _finishing = false;

  // Fingerprints from discovery, and the one for the TV being paired
  // (fetched for manual entries)
  final Map<String, String> _udns = {};
  String? _pairedUdn;

  late final TextEditingController _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final prefs = widget.client.prefs;
    // Settles the saved-TV list before pairing writes the live prefs, so a
    // fresh install is not mistaken for an upgrade with an unnamed TV
    TvStore.list(prefs);
    if (widget.addMode) TvStore.beginAdd(prefs);
    _startDiscovery();
  }

  @override
  void dispose() {
    _uiTimeout?.cancel();
    _stopPairing?.call();
    if (widget.addMode && !_paired) TvStore.cancelAdd(widget.client.prefs);
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _startDiscovery() async {
    setState(() => _screen = _Screen.searching);
    final found = await widget.discover();
    if (!mounted) return;
    for (final f in found) {
      if (f.udn != null) _udns[f.ip] = f.udn!;
    }
    setState(() {
      _tvList = found;
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

    final watch =
        widget.pairingWatch ?? PairingWatcher(widget.client.prefs).watch;
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
    _stopPairing = null;
    _paired = true;
    await widget.client.saveTvIp(ip);
    _pairedUdn = _udns[ip];
    // Grab MAC (and the fingerprint, if discovery did not have it) while the
    // name step shows -- neither blocks it (spec §1.5).
    unawaited(
      widget.client.getMacFromDevice().then((mac) {
        if (mac != null && mac.isNotEmpty) widget.client.saveTvMac(mac);
      }),
    );
    if (_pairedUdn == null) {
      unawaited(widget.fingerprint(ip).then((udn) => _pairedUdn ??= udn));
    }
    if (!mounted) return;
    _nameController
      ..text = TvStore.nextDefaultName(widget.client.prefs)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameController.text.length,
      );
    setState(() => _pairingPhase = _PairingPhase.success);
  }

  Future<void> _finishSetup() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    FocusManager.instance.primaryFocus?.unfocus();
    final client = widget.client;
    final prefs = client.prefs;
    TvStore.addFromLive(prefs, _nameController.text, udn: _pairedUdn ?? '');
    if (!widget.addMode) await prefs.setTourPending(true);
    // The new TV's shortcuts come from its own app list, so the remote opens
    // populated
    final (apps, _) = await client.listApps();
    final picked = WebOsClient.pickDefaultShortcuts(apps);
    if (picked.isNotEmpty) {
      await client.saveShortcuts(picked);
      for (final app in picked) {
        final url = app.iconUrl;
        if (url != null) unawaited(client.cacheIcon(app.id, url));
      }
    }
    if (!mounted) return;
    if (widget.addMode) {
      // Back to the remote, which re-reads the active TV on return
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const MainScreen()));
    }
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
                widget.addMode ? 'Add another TV' : 'Connect to your TV',
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
    // Scaffold.body is only loosely width-constrained (max, not tight), so
    // without a child that claims the full width this Column shrink-wraps to
    // its widest line (the label) and the whole group -- title/subtitle
    // included -- ends up flush against the left padding instead of centred
    // on the page. The list/pairing states dodge this because their
    // full-width buttons force it; this branch has no such child.
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
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
      ),
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
            child: GhostButton(
              label: 'Search again',
              height: 48,
              onPressed: _startDiscovery,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: GhostButton(
              label: 'Enter IP manually',
              height: 48,
              onPressed: _showManualIpDialog,
            ),
          ),
        ],
      );
    }

    final prefs = widget.client.prefs;
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
                _TvRow(
                  ip: _tvList[i].ip,
                  // A TV already in the list stays visible but greyed, so a
                  // second TV that happens to share an address on another
                  // network can still be told apart
                  already: TvStore.match(
                    prefs,
                    _tvList[i].ip,
                    _udns[_tvList[i].ip],
                  ),
                  theme: theme,
                  onTap: () => _selectTv(_tvList[i].ip),
                ),
              ],
            ],
          ),
        ),
        // Discovery can list the wrong box (or miss a TV on another VLAN), so
        // typing an address stays available even when something was found.
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: GhostButton(
            label: 'Enter IP manually',
            height: 48,
            onPressed: _showManualIpDialog,
          ),
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
        message =
            "Can't reach the TV.\nMake sure it's on, restart it,\nthen try again.";
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
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: theme.primaryText,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.27,
                  color: messageColor,
                ),
              ),
              const SizedBox(height: 28),
              if (_pairingPhase == _PairingPhase.connecting ||
                  _pairingPhase == _PairingPhase.promptShown)
                const SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              if (_pairingPhase == _PairingPhase.success) _buildNameStep(theme),
              if (_pairingPhase == _PairingPhase.failed) ...[
                SizedBox(
                  width: double.infinity,
                  child: AccentButton(
                    label: 'Try again',
                    height: 44,
                    onPressed: _retry,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: GhostButton(
                    label: 'Search again',
                    height: 44,
                    onPressed: _searchAgain,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNameStep(ThemeConfig theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: SectionLabel('Name this TV'),
        ),
        SizedBox(
          height: 44,
          child: TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            maxLines: 1,
            style: TextStyle(fontSize: 18, color: theme.primaryText),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: theme.windowBg,
              hintText: 'Living room',
              hintStyle: TextStyle(color: theme.secondaryText.withAlpha(0x78)),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: theme.btnGhostBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: theme.btnGhostBorderPressed),
              ),
            ),
            onSubmitted: (_) => unawaited(_finishSetup()),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: AccentButton(
            label: _finishing ? 'Setting up…' : 'Done',
            height: 44,
            onPressed: _finishing ? null : () => unawaited(_finishSetup()),
          ),
        ),
      ],
    );
  }
}

class _TvRow extends StatelessWidget {
  const _TvRow({
    required this.ip,
    required this.already,
    required this.theme,
    required this.onTap,
  });

  final String ip;
  final Tv? already;
  final ThemeConfig theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final row = Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            already?.name ?? 'LG TV',
            style: TextStyle(fontSize: 16, color: theme.primaryText),
          ),
          Text(
            already == null ? ip : '$ip · already added',
            style: TextStyle(fontSize: 13, color: theme.secondaryText),
          ),
        ],
      ),
    );
    if (already != null) return Opacity(opacity: 0.45, child: row);
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: row),
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
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: theme.primaryText,
              ),
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
                    onPressed: () =>
                        Navigator.of(context).pop(_controller.text.trim()),
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
