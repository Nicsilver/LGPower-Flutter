import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/right_pill.dart';
import '../../core/tv_store.dart';
import '../../core/wake_action.dart';
import '../../net/ir.dart';
import '../../net/webos_client.dart';
import '../../theme/release_notes.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../setup/setup_screen.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_switch.dart';
import '../widgets/app_toast.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/release_notes_dialog.dart';
import '../widgets/section.dart';
import '../widgets/spotlight_tour.dart';
import '../widgets/warning_sheet.dart';
import 'service_remote_screen.dart';
import 'theme_editor_screen.dart';
import 'tv_detail_screen.dart';

/// Spec §2: six sections, TVS -> CONTROLS -> APP SHORTCUTS -> APPEARANCE ->
/// ADVANCED -> ABOUT. Every colour comes from `AppTheme.of`, which rebuilds
/// this screen live on a theme change (no `recreate()` flash, unlike the
/// Kotlin source -- see spec §2.9).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.client, this.listApps});

  final WebOsClient client;

  /// Injectable for tests; defaults to [WebOsClient.listApps] (real TV call).
  final Future<(List<TvApp>, String?)> Function()? listApps;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Tour targets: the three group cards the Settings leg rings
  final GlobalKey _tvsGroupKey = GlobalKey();
  final GlobalKey _shortcutsGroupKey = GlobalKey();
  final GlobalKey _appearanceGroupKey = GlobalKey();

  bool _channelPill = false;
  bool _keepScreenOn = false;

  List<TvApp> _apps = const [];
  List<TvApp> _selected = const [];
  bool _loadingApps = false;

  String _version = '';

  bool _hasIrEmitter = false;

  @override
  void initState() {
    super.initState();
    final prefs = widget.client.prefs;
    _channelPill = RightPill.get(prefs) == RightPill.channel;
    _keepScreenOn = prefs.keepScreenOn;
    _selected = widget.client.loadShortcuts();
    _apps = List.of(_selected);
    _loadVersion();
    _loadIrEmitter();
    if (prefs.tourSettingsPending) {
      prefs.setTourSettingsPending(false);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_runTour()),
      );
    }
  }

  Future<void> _runTour() async {
    // Let the enter transition settle so the highlight lands on laid-out cards
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    await showSpotlightTour(context, [
      TourStep(
        [_tvsGroupKey],
        'Saved TVs',
        'Every TV you have paired. Tap one to rename it or change its address, or add another.',
      ),
      TourStep(
        [_shortcutsGroupKey],
        'Pick your shortcuts',
        'Load the app list from the TV, then tap apps to add them, up to eight. Tap a numbered one to '
            'remove it, long-press and drag to reorder.',
      ),
      TourStep(
        [_appearanceGroupKey],
        'Themes',
        'Pick a theme, or create your own with a few colours.',
      ),
    ]);
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = info.version);
  }

  Future<void> _loadIrEmitter() async {
    final hasEmitter = await Ir.hasEmitter();
    if (mounted) setState(() => _hasIrEmitter = hasEmitter);
  }

  // ---------------------------------------------------------------------
  // TVs
  // ---------------------------------------------------------------------

  Future<void> _openTvDetail(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvDetailScreen(prefs: widget.client.prefs, tvId: id),
      ),
    );
    if (mounted) _reloadForActiveTv();
  }

  Future<void> _addTv() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SetupScreen(client: widget.client, addMode: true),
      ),
    );
    if (mounted) _reloadForActiveTv();
  }

  // Switching or removing a TV changes whose shortcuts and wake action the
  // rest of the screen shows
  void _reloadForActiveTv() {
    setState(() {
      _selected = widget.client.loadShortcuts();
      final selectedIds = _selected.map((a) => a.id).toSet();
      _apps = [
        ..._selected,
        ..._apps.where((a) => !selectedIds.contains(a.id)),
      ];
    });
  }

  // ---------------------------------------------------------------------
  // Controls
  // ---------------------------------------------------------------------

  // Inputs come from the TV when it answers, otherwise from the last list it
  // gave us, so the picker still works with the TV off. Shortcuts are local.
  Future<void> _openWakeActionPicker() async {
    final client = widget.client;
    final (live, _) = await client.getInputs();
    final inputs = live.isEmpty ? client.cachedInputs() : live;
    final apps = client.loadShortcuts();
    if (!mounted) return;
    if (inputs.isEmpty) {
      showToast(context, 'Turn the TV on once to list its inputs here', long: true);
    }
    final current = WakeAction.get(client.prefs);
    final options = [
      const WakeAction(WakeAction.home),
      const WakeAction(WakeAction.stay),
      for (final i in inputs)
        WakeAction(WakeAction.input, id: i.id, label: i.label),
      for (final a in apps)
        WakeAction(WakeAction.app, id: a.id, label: a.title),
    ];
    await showPickerSheet(
      context,
      title: 'After waking the TV',
      rows: [for (final o in options) (o.key, o.display, o.key == current.key)],
      onSelect: (key) {
        final chosen = options.where((o) => o.key == key).firstOrNull;
        if (chosen == null) return;
        WakeAction.set(client.prefs, chosen);
        if (mounted) setState(() {});
      },
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
    unawaited(
      showWarningSheet(
        context,
        chip: 'SCREEN STAYS ON',
        title: 'Careful with OLED screens',
        body:
            "The remote will keep the screen awake for as long as it's open, even if you put "
            "the phone down. On an OLED phone that can burn the remote layout into the panel over "
            "time, and it drains the battery. Meant for a spare phone used as a dedicated remote.",
        button: 'Keep screen on',
        onAccept: () => widget.client.prefs.setKeepScreenOn(true),
        onCancel: () {
          if (mounted) setState(() => _keepScreenOn = false);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Shortcuts
  // ---------------------------------------------------------------------

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
    return 'Tap to add or remove · Long-press to reorder · ${_selected.length}/${WebOsClient.maxShortcuts} selected';
  }

  void _toggleApp(TvApp app) {
    final idx = _selected.indexWhere((a) => a.id == app.id);
    if (idx >= 0) {
      setState(() {
        _selected = List.of(_selected)..removeAt(idx);
      });
    } else {
      if (_selected.length >= WebOsClient.maxShortcuts) {
        showToast(context, 'Max ${WebOsClient.maxShortcuts} shortcuts');
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
      unawaited(
        widget.client.cacheIcon(app.id, url).then((_) {
          if (mounted) setState(() {});
        }),
      );
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

  // ---------------------------------------------------------------------
  // Appearance / Advanced / About
  // ---------------------------------------------------------------------

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

  Future<void> _openThemeLongPressSheet(
    String id,
    List<ThemeConfig> themes,
  ) async {
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
          MaterialPageRoute(
            builder: (_) => ThemeEditorScreen(baseId: id, editId: id),
          ),
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
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ServiceRemoteScreen()));
  }

  // The tour runs on the remote itself, so hand back to it
  void _showTour() {
    widget.client.prefs.setTourPending(true);
    Navigator.of(context).pop();
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

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

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
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: theme.primaryText,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              _section(
                'TVs',
                first: true,
                cardKey: _tvsGroupKey,
                child: _tvsGroup(theme),
              ),
              _section('Controls', child: _controlsGroup(theme)),
              _section(
                'App Shortcuts',
                cardKey: _shortcutsGroupKey,
                child: _shortcutsGroup(theme),
              ),
              _section(
                'Appearance',
                cardKey: _appearanceGroupKey,
                child: _appearanceGroup(theme),
              ),
              if (_hasIrEmitter)
                _section('Advanced', child: _advancedGroup(theme)),
              _section('About', child: _aboutGroup(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(
    String label, {
    required Widget child,
    bool first = false,
    Key? cardKey,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SectionLabel(label),
          ),
          SurfaceCard(key: cardKey, radius: 14, child: child),
        ],
      ),
    );
  }

  Widget _tvsGroup(ThemeConfig theme) {
    final prefs = widget.client.prefs;
    final tvs = TvStore.list(prefs);
    final activeId = TvStore.activeId(prefs);
    final chevronColor = theme.statusBarLightIcons
        ? const Color(0xFFAAAAAA)
        : const Color(0xFF555555);
    return Column(
      children: [
        for (final tv in tvs) ...[
          InkWell(
            onTap: () => unawaited(_openTvDetail(tv.id)),
            child: Container(
              height: 56,
              padding: const EdgeInsets.only(left: 16, right: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tv.name,
                          style: TextStyle(
                            fontSize: 15,
                            color: theme.primaryText,
                          ),
                        ),
                        Text(
                          tv.ip.isEmpty ? 'No address' : tv.ip,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (tv.id == activeId)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        'In use',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.btnAccentBg,
                        ),
                      ),
                    ),
                  AppIcon('ic_chevron_right', size: 16, color: chevronColor),
                ],
              ),
            ),
          ),
          const RowDivider(),
        ],
        _navRow(
          theme,
          label: 'Add a TV',
          onTap: _addTv,
          correctedChevron: false,
        ),
        const RowDivider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            'Tap a TV to rename it or change its address. On the remote, tap the TV name at the top to switch.',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: theme.secondaryText,
            ),
          ),
        ),
      ],
    );
  }

  Widget _controlsGroup(ThemeConfig theme) {
    return Column(
      children: [
        _switchRow(
          theme,
          'Channel buttons instead of brightness',
          _channelPill,
          (v) {
            setState(() => _channelPill = v);
            RightPill.set(
              widget.client.prefs,
              v ? RightPill.channel : RightPill.brightness,
            );
          },
        ),
        const RowDivider(),
        _switchRow(
          theme,
          'Keep screen on',
          _keepScreenOn,
          _onKeepScreenOnChanged,
        ),
        const RowDivider(),
        _navRow(
          theme,
          label: 'After waking the TV',
          value: WakeAction.get(widget.client.prefs).display,
          onTap: () => unawaited(_openWakeActionPicker()),
          correctedChevron: false,
          chevron: false,
        ),
      ],
    );
  }

  Widget _switchRow(
    ThemeConfig theme,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 15, color: theme.primaryText),
            ),
          ),
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
          child: Text(
            _shortcutsSummary,
            style: TextStyle(fontSize: 13, color: theme.sectionLabel),
          ),
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

  Widget _buildGridItem(
    ThemeConfig theme,
    int displayIndex,
    TvApp app,
    bool selected,
  ) {
    final content = _AppGridTile(
      app: app,
      theme: theme,
      selected: selected,
      order: selected ? displayIndex + 1 : null,
      client: widget.client,
    );
    final tappable = GestureDetector(
      onTap: () => _toggleApp(app),
      child: content,
    );
    if (!selected) return tappable;

    return LongPressDraggable<int>(
      data: displayIndex,
      onDragStarted: HapticFeedback.heavyImpact,
      feedback: Transform.scale(
        scale: 1.12,
        child: Opacity(
          opacity: 0.85,
          child: SizedBox(width: 72, child: content),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: content),
      child: DragTarget<int>(
        onWillAcceptWithDetails: (details) => details.data < _selected.length,
        onAcceptWithDetails: (details) =>
            _reorderSelected(details.data, displayIndex),
        builder: (context, candidate, rejected) => tappable,
      ),
    );
  }

  Widget _appearanceGroup(ThemeConfig theme) {
    return Column(
      children: [
        _navRow(
          theme,
          label: 'Theme',
          value: theme.name,
          onTap: _openThemePicker,
          correctedChevron: false,
        ),
        const RowDivider(),
        _navRow(
          theme,
          label: 'Create Custom Theme',
          onTap: _openCreateTheme,
          correctedChevron: false,
        ),
      ],
    );
  }

  Widget _advancedGroup(ThemeConfig theme) {
    return _navRow(
      theme,
      label: 'Service Remote (IR)',
      onTap: _openServiceRemote,
      correctedChevron: false,
    );
  }

  Widget _aboutGroup(ThemeConfig theme) {
    return Column(
      children: [
        _navRow(
          theme,
          label: 'Show the tour',
          onTap: _showTour,
          correctedChevron: false,
        ),
        const RowDivider(),
        _navRow(
          theme,
          label: 'Release notes',
          value: _version,
          onTap: _openReleaseNotes,
          correctedChevron: false,
        ),
      ],
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
    bool chevron = true,
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
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 15, color: theme.primaryText),
              ),
            ),
            if (value != null && value.isNotEmpty) ...[
              // Capped rather than flexible: a Flexible here is handed half the
              // row and the value ends up left-aligned in the middle
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: theme.secondaryText),
                ),
              ),
              if (chevron) const SizedBox(width: 4),
            ],
            if (chevron)
              AppIcon('ic_chevron_right', size: 16, color: chevronColor),
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
    final chevronColor = theme.statusBarLightIcons
        ? const Color(0xFFAAAAAA)
        : const Color(0xFF555555);
    return InkWell(
      onTap: loading ? null : onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Load Apps from TV',
                style: TextStyle(fontSize: 15, color: theme.primaryText),
              ),
            ),
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
                      ? Image.file(
                          file,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        )
                      : _LetterPlaceholder(
                          letter: app.title.isNotEmpty
                              ? app.title[0].toUpperCase()
                              : '?',
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
                      decoration: const BoxDecoration(
                        color: Color(0xFF444444),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$order',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
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
        style: TextStyle(
          fontSize: 60 * 0.42,
          fontWeight: FontWeight.bold,
          color: theme.secondaryText,
        ),
      ),
    );
  }
}
