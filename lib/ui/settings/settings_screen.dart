import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../net/ir.dart';
import '../../net/tv_discovery.dart';
import '../../net/webos_client.dart';
import '../../theme/release_notes.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_switch.dart';
import '../widgets/app_toast.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/release_notes_dialog.dart';
import '../widgets/section.dart';
import '../widgets/warning_sheet.dart';
import 'service_remote_screen.dart';
import 'theme_editor_screen.dart';

/// Spec §2: six sections, TV CONNECTION -> CONTROLS -> APP SHORTCUTS ->
/// APPEARANCE -> ADVANCED -> ABOUT. Every colour comes from `AppTheme.of`,
/// which rebuilds this screen live on a theme change (no `recreate()` flash,
/// unlike the Kotlin source -- see spec §2.9).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.client,
    this.discover = discoverTvs,
    this.listApps,
  });

  final WebOsClient client;

  /// Injectable for tests; defaults to the real network scan.
  final Future<List<String>> Function() discover;

  /// Injectable for tests; defaults to [WebOsClient.listApps] (real TV call).
  final Future<(List<TvApp>, String?)> Function()? listApps;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _ipController;
  late final TextEditingController _macController;
  late final FocusNode _ipFocus;
  late final FocusNode _macFocus;

  bool _volSlider = true;
  bool _brightnessSlider = true;
  bool _rightPillChannel = false;
  bool _keepScreenOn = false;

  bool _detectingMac = false;
  bool _discovering = false;

  List<TvApp> _apps = const [];
  List<TvApp> _selected = const [];
  bool _loadingApps = false;

  String _version = '';

  bool _hasIrEmitter = false;

  @override
  void initState() {
    super.initState();
    final prefs = widget.client.prefs;
    _ipController = TextEditingController(text: widget.client.tvIp);
    _macController = TextEditingController(text: widget.client.tvMac);
    _ipFocus = FocusNode()..addListener(_onIpFocusChange);
    _macFocus = FocusNode()..addListener(_onMacFocusChange);
    _volSlider = prefs.volSlider;
    _brightnessSlider = prefs.brightnessSlider;
    _rightPillChannel = prefs.rightPillChannel;
    _keepScreenOn = prefs.keepScreenOn;
    _selected = widget.client.loadShortcuts();
    _apps = List.of(_selected);
    _loadVersion();
    _loadIrEmitter();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = info.version);
  }

  Future<void> _loadIrEmitter() async {
    final hasEmitter = await Ir.hasEmitter();
    if (mounted) setState(() => _hasIrEmitter = hasEmitter);
  }

  void _onIpFocusChange() {
    if (!_ipFocus.hasFocus) _commitIp();
  }

  void _onMacFocusChange() {
    if (!_macFocus.hasFocus) _commitMac();
  }

  // IP: never cleared by an empty field (spec §2.1). MAC: always committed,
  // including blank (spec §2.1) -- the one deliberate asymmetry in the app.
  void _commitIp() {
    final ip = _ipController.text;
    if (ip.isNotEmpty) widget.client.saveTvIp(ip);
  }

  void _commitMac() {
    widget.client.saveTvMac(_macController.text.trim());
  }

  @override
  void dispose() {
    _commitIp();
    _commitMac();
    _ipFocus.dispose();
    _macFocus.dispose();
    _ipController.dispose();
    _macController.dispose();
    super.dispose();
  }

  Future<void> _autoDetectMac() async {
    setState(() => _detectingMac = true);
    final mac = await widget.client.getMacFromDevice();
    if (!mounted) return;
    setState(() => _detectingMac = false);
    if (mac != null && mac.isNotEmpty) {
      _macController.text = mac;
      await widget.client.saveTvMac(mac);
      if (!mounted) return;
      showToast(context, 'Found $mac');
    } else {
      showToast(context, 'Not found — TV must be on to auto-detect', long: true);
    }
  }

  Future<void> _discoverTv() async {
    setState(() => _discovering = true);
    final results = await widget.discover();
    if (!mounted) return;
    setState(() => _discovering = false);
    if (results.isEmpty) {
      showToast(context, 'No TV found');
      return;
    }
    if (results.length == 1) {
      _ipController.text = results.first;
      showToast(context, 'Found ${results.first}');
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Select TV'),
        children: [
          for (final ip in results)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(ip),
              child: Text(ip),
            ),
        ],
      ),
    );
    if (selected != null) _ipController.text = selected;
  }

  List<TvApp> get _gridOrder {
    final selectedIds = _selected.map((a) => a.id).toSet();
    final unselected = _apps.where((a) => !selectedIds.contains(a.id)).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return [..._selected, ...unselected];
  }

  String get _shortcutsSummary {
    if (_selected.isEmpty) {
      return 'No shortcuts configured — load apps from TV to pick some';
    }
    return 'Tap to select · Long-press to reorder · ${_selected.length}/4 selected';
  }

  void _toggleApp(TvApp app) {
    final idx = _selected.indexWhere((a) => a.id == app.id);
    if (idx >= 0) {
      setState(() {
        _selected = List.of(_selected)..removeAt(idx);
      });
    } else {
      if (_selected.length >= 4) {
        showToast(context, 'Max 4 shortcuts');
        return;
      }
      setState(() {
        _selected = List.of(_selected)..add(app);
      });
    }
    _saveShortcuts();
  }

  void _reorderSelected(int oldIndex, int newIndex) {
    // Only positions within the already-selected front block are valid drag
    // sources/targets (spec §2.3) -- the caller already filters this, this
    // is the belt-and-braces check.
    if (oldIndex >= _selected.length || newIndex >= _selected.length) return;
    setState(() {
      final list = List.of(_selected);
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
      _selected = list;
    });
    _saveShortcuts();
  }

  Future<void> _saveShortcuts() async {
    await widget.client.saveShortcuts(_selected);
    // Auto-save only caches icons for the chosen apps (spec §2.3); the full
    // grid's icons are backfilled separately, right after a TV load.
    _cacheMissingIconsFor(_selected);
  }

  void _cacheMissingIconsFor(List<TvApp> apps) {
    for (final app in apps) {
      final url = app.iconUrl;
      if (url == null) continue;
      if (widget.client.cachedIconFile(app.id) != null) continue;
      unawaited(widget.client.cacheIcon(app.id, url).then((_) {
        if (mounted) setState(() {});
      }));
    }
  }

  Future<void> _loadAppsFromTv() async {
    setState(() => _loadingApps = true);
    final (apps, error) = await (widget.listApps ?? widget.client.listApps)();
    if (!mounted) return;
    setState(() => _loadingApps = false);
    if (error != null) {
      showToast(context, error, long: true);
      return;
    }
    if (apps.isEmpty) {
      showToast(context, 'No apps returned by TV');
      return;
    }
    setState(() => _apps = apps);
    // Every tile in the grid gets its icon downloaded here, not just the
    // selected ones (spec §2.3's "missing icons download on an 8-thread
    // pool" applies to the whole loaded list).
    _cacheMissingIconsFor(apps);
  }

  Future<void> _openThemePicker() async {
    final controller = AppTheme.controllerOf(context);
    final activeId = controller.theme.id;
    final themes = await ThemeManager.listThemes();
    if (!mounted) return;
    await showPickerSheet(
      context,
      title: 'Theme',
      rows: [for (final t in themes) (t.id, t.name, t.id == activeId)],
      onSelect: controller.setThemeId,
      onLongPress: (id) => _openThemeLongPressSheet(id, themes),
    );
  }

  Future<void> _openThemeLongPressSheet(String id, List<ThemeConfig> themes) async {
    final theme = themes.firstWhere((t) => t.id == id);
    final rows = <PickerRow>[
      ('duplicate', 'Duplicate', false),
      if (theme.editable) ('edit', 'Edit', false),
      if (theme.editable) ('delete', 'Delete', false),
    ];
    if (!mounted) return;
    await showPickerSheet(
      context,
      title: theme.name,
      rows: rows,
      onSelect: (action) => _handleThemeAction(action, id),
    );
  }

  void _handleThemeAction(String action, String id) {
    switch (action) {
      case 'duplicate':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ThemeEditorScreen(baseId: id)),
        );
      case 'edit':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ThemeEditorScreen(baseId: id, editId: id)),
        );
      case 'delete':
        _deleteThemeNoConfirm(id);
    }
  }

  // No confirmation on this path -- unlike the editor's own Delete button
  // (spec §3.5).
  Future<void> _deleteThemeNoConfirm(String id) async {
    await ThemeManager.deleteCustom(id);
    if (!mounted) return;
    await AppTheme.controllerOf(context).refresh();
  }

  void _openCreateTheme() {
    final activeId = AppTheme.controllerOf(context).theme.id;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ThemeEditorScreen(baseId: activeId)),
    );
  }

  void _openServiceRemote() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ServiceRemoteScreen()),
    );
  }

  void _openReleaseNotes() {
    showReleaseNotesDialog(
      context,
      title: 'Release notes',
      releases: ReleaseNotes.all,
      buttonLabel: 'Close',
      markLatest: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Scaffold(
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
                  'Settings',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: theme.primaryText),
                ),
              ),
              const SizedBox(height: 32),
              _section('TV Connection', first: true, child: _connectionGroup(theme)),
              _section('Controls', child: _controlsGroup(theme)),
              _section('App Shortcuts', child: _shortcutsGroup(theme)),
              _section('Appearance', child: _appearanceGroup(theme)),
              if (_hasIrEmitter) _section('Advanced', child: _advancedGroup(theme)),
              _section('About', child: _aboutGroup(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String label, {required Widget child, bool first = false}) {
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(bottom: 8), child: SectionLabel(label)),
          SurfaceCard(radius: 14, child: child),
        ],
      ),
    );
  }

  Widget _connectionGroup(ThemeConfig theme) {
    return Column(
      children: [
        _editRow(
          theme: theme,
          label: 'IP Address',
          controller: _ipController,
          focusNode: _ipFocus,
          hint: '192.168.1.x',
          keyboardType: TextInputType.url,
        ),
        const RowDivider(),
        _editRow(
          theme: theme,
          label: 'MAC Address',
          controller: _macController,
          focusNode: _macFocus,
          hint: 'AA:BB:CC:DD:EE:FF',
          keyboardType: TextInputType.text,
        ),
        const RowDivider(),
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: _SmallGhostButton(
                  label: 'Auto-detect MAC',
                  enabled: !_detectingMac,
                  onPressed: _autoDetectMac,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SmallAccentButton(
                  label: 'Discover TV',
                  spinning: _discovering,
                  onPressed: _discoverTv,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _editRow({
    required ThemeConfig theme,
    required String label,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required TextInputType keyboardType,
  }) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 15, color: theme.primaryText)),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textAlign: TextAlign.end,
              keyboardType: keyboardType,
              style: TextStyle(fontSize: 15, color: theme.secondaryText),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: hint,
                hintStyle: TextStyle(color: theme.secondaryText.withAlpha(120)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlsGroup(ThemeConfig theme) {
    return Column(
      children: [
        _switchRow(theme, 'Volume slider', _volSlider, (v) {
          setState(() => _volSlider = v);
          widget.client.prefs.setVolSlider(v);
        }),
        const RowDivider(),
        _switchRow(theme, 'Brightness slider', _brightnessSlider, (v) {
          setState(() => _brightnessSlider = v);
          widget.client.prefs.setBrightnessSlider(v);
        }),
        const RowDivider(),
        _switchRow(theme, 'Channel buttons', _rightPillChannel, (v) {
          setState(() => _rightPillChannel = v);
          widget.client.prefs.setRightPillChannel(v);
        }),
        const RowDivider(),
        _switchRow(theme, 'Keep screen on', _keepScreenOn, _onKeepScreenOnChanged),
      ],
    );
  }

  // Turning off never needs confirmation. Turning on flips the switch
  // immediately for a responsive toggle, then shows the OLED warning; the
  // pref is only written on accept, and a cancel (tap outside/back) flips
  // the switch back off without ever having persisted anything (plan 05).
  void _onKeepScreenOnChanged(bool value) {
    setState(() => _keepScreenOn = value);
    if (!value) {
      widget.client.prefs.setKeepScreenOn(false);
      return;
    }
    unawaited(showWarningSheet(
      context,
      chip: 'SCREEN STAYS ON',
      title: 'Careful with OLED screens',
      body: "The remote will keep the screen awake for as long as it's open, even if you put "
          "the phone down. On an OLED phone that can burn the remote layout into the panel over "
          "time, and it drains the battery. Meant for a spare phone used as a dedicated remote.",
      button: 'Keep screen on',
      onAccept: () => widget.client.prefs.setKeepScreenOn(true),
      onCancel: () {
        if (mounted) setState(() => _keepScreenOn = false);
      },
    ));
  }

  Widget _switchRow(ThemeConfig theme, String label, bool value, ValueChanged<bool> onChanged) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 15, color: theme.primaryText))),
          AppSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _shortcutsGroup(ThemeConfig theme) {
    final order = _gridOrder;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Text(_shortcutsSummary, style: TextStyle(fontSize: 13, color: theme.sectionLabel)),
        ),
        if (order.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
            child: GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < order.length; i++)
                  _buildGridItem(theme, i, order[i], i < _selected.length),
              ],
            ),
          ),
        const RowDivider(),
        _LoadAppsRow(loading: _loadingApps, onTap: _loadAppsFromTv),
      ],
    );
  }

  Widget _buildGridItem(ThemeConfig theme, int displayIndex, TvApp app, bool selected) {
    final content = _AppGridTile(
      app: app,
      theme: theme,
      selected: selected,
      order: selected ? displayIndex + 1 : null,
      client: widget.client,
    );
    final tappable = GestureDetector(onTap: () => _toggleApp(app), child: content);
    if (!selected) return tappable;

    return LongPressDraggable<int>(
      data: displayIndex,
      feedback: Opacity(opacity: 0.85, child: SizedBox(width: 72, child: content)),
      childWhenDragging: Opacity(opacity: 0.3, child: content),
      child: DragTarget<int>(
        onWillAcceptWithDetails: (details) => details.data < _selected.length,
        onAcceptWithDetails: (details) => _reorderSelected(details.data, displayIndex),
        builder: (context, candidate, rejected) => tappable,
      ),
    );
  }

  Widget _appearanceGroup(ThemeConfig theme) {
    return Column(
      children: [
        _navRow(theme, label: 'Theme', value: theme.name, onTap: _openThemePicker, correctedChevron: false),
        const RowDivider(),
        _navRow(theme, label: 'Create Custom Theme', onTap: _openCreateTheme, correctedChevron: false),
      ],
    );
  }

  Widget _advancedGroup(ThemeConfig theme) {
    return _navRow(theme, label: 'Service Remote (IR)', onTap: _openServiceRemote, correctedChevron: false);
  }

  Widget _aboutGroup(ThemeConfig theme) {
    return _navRow(
      theme,
      label: 'Release notes',
      value: _version,
      onTap: _openReleaseNotes,
      correctedChevron: false,
    );
  }

  // `correctedChevron` reproduces spec §2.9's known rough edge: every static
  // chevron keeps a hardcoded #555555 tint in every theme except
  // `btn_load_apps`, which alone corrects for light themes.
  Widget _navRow(
    ThemeConfig theme, {
    required String label,
    String? value,
    required VoidCallback onTap,
    required bool correctedChevron,
  }) {
    final chevronColor = correctedChevron && theme.statusBarLightIcons
        ? const Color(0xFFAAAAAA)
        : const Color(0xFF555555);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.only(left: 16, right: 12),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 15, color: theme.primaryText))),
            if (value != null && value.isNotEmpty) ...[
              Text(value, style: TextStyle(fontSize: 15, color: theme.secondaryText)),
              const SizedBox(width: 4),
            ],
            AppIcon('ic_chevron_right', size: 16, color: chevronColor),
          ],
        ),
      ),
    );
  }
}

class _SmallGhostButton extends StatelessWidget {
  const _SmallGhostButton({required this.label, required this.enabled, required this.onPressed});

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return SizedBox(
      height: 36,
      child: OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: theme.btnGhostBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: theme.secondaryText),
        ),
      ),
    );
  }
}

class _SmallAccentButton extends StatelessWidget {
  const _SmallAccentButton({required this.label, required this.spinning, required this.onPressed});

  final String label;
  final bool spinning;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return SizedBox(
      height: 36,
      child: ElevatedButton(
        onPressed: spinning ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: theme.btnAccentBg,
          disabledBackgroundColor: theme.btnAccentBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: theme.btnAccentText),
            ),
            if (spinning) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF888888)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LoadAppsRow extends StatelessWidget {
  const _LoadAppsRow({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    final chevronColor = theme.statusBarLightIcons ? const Color(0xFFAAAAAA) : const Color(0xFF555555);
    return InkWell(
      onTap: loading ? null : onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(child: Text('Load Apps from TV', style: TextStyle(fontSize: 15, color: theme.primaryText))),
            if (loading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Color(0xFF888888)),
                ),
              )
            else
              AppIcon('ic_chevron_right', size: 16, color: chevronColor),
          ],
        ),
      ),
    );
  }
}

class _AppGridTile extends StatelessWidget {
  const _AppGridTile({
    required this.app,
    required this.theme,
    required this.selected,
    required this.order,
    required this.client,
  });

  final TvApp app;
  final ThemeConfig theme;
  final bool selected;
  final int? order;
  final WebOsClient client;

  @override
  Widget build(BuildContext context) {
    final file = client.cachedIconFile(app.id);
    return Opacity(
      opacity: selected ? 1.0 : 0.5,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 60,
            height: 60,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipOval(
                  child: file != null
                      ? Image.file(file, width: 60, height: 60, fit: BoxFit.cover)
                      : _LetterPlaceholder(
                          letter: app.title.isNotEmpty ? app.title[0].toUpperCase() : '?',
                          theme: theme,
                        ),
                ),
                if (order != null)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: Color(0xFF444444), shape: BoxShape.circle),
                      child: Text(
                        '$order',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            width: 60,
            child: Text(
              app.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: theme.primaryText),
            ),
          ),
        ],
      ),
    );
  }
}

class _LetterPlaceholder extends StatelessWidget {
  const _LetterPlaceholder({required this.letter, required this.theme});

  final String letter;
  final ThemeConfig theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: theme.windowBg,
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(fontSize: 60 * 0.42, fontWeight: FontWeight.bold, color: theme.secondaryText),
      ),
    );
  }
}
