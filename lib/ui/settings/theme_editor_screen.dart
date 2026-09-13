import 'package:flutter/material.dart';

import '../../theme/color_util.dart';
import '../../theme/theme_config.dart';
import '../../theme/theme_manager.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_toast.dart';
import '../widgets/buttons.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/section.dart';

/// Spec §3.7. The editor's chrome (everything but the mock remote) is always
/// painted with the *active* app theme; only `preview_frame` renders with the
/// theme being edited -- that split is intentional, not a bug.
class ThemeEditorScreen extends StatefulWidget {
  const ThemeEditorScreen({super.key, required this.baseId, this.editId});

  /// Theme to copy seed colours from. Ignored once loading if [editId] is
  /// set (the theme being edited is always its own base).
  final String baseId;

  /// Present only in edit-in-place mode.
  final String? editId;

  @override
  State<ThemeEditorScreen> createState() => _ThemeEditorScreenState();
}

class _ThemeEditorScreenState extends State<ThemeEditorScreen> {
  final _nameController = TextEditingController();

  bool _loading = true;
  String _name = '';
  bool _light = false;
  late Color _seedBg;
  late Color _seedSurface;
  late Color _seedText;
  late Color _seedSecondary;
  late Color _seedAccent;

  // Interactive preview state: the switch and the pill level
  bool _previewSwitch = true;
  int _previewLevel = 24;

  bool get _editing => widget.editId != null;

  // Appearance is a starting point: it swaps the neutral seeds for the
  // built-in Dark or Light palette and keeps the accent, so the choice is
  // visible straight away
  Future<void> _setAppearance(bool light) async {
    ThemeConfig? base;
    try {
      base = await ThemeManager.loadTheme(light ? 'light' : 'dark');
    } catch (_) {
      base = null;
    }
    if (!mounted) return;
    setState(() {
      _light = light;
      if (base != null) {
        _seedBg = base.seedBg;
        _seedSurface = base.seedSurface;
        _seedText = base.seedText;
        _seedSecondary = base.seedSecondary;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final themes = await ThemeManager.listThemes();
    final activeId = await ThemeManager.getActiveThemeId();
    final resolvedBaseId = widget.editId ?? widget.baseId;
    final base = themes.firstWhere(
      (t) => t.id == resolvedBaseId,
      orElse: () => themes.firstWhere(
        (t) => t.id == activeId,
        orElse: () => themes.first,
      ),
    );
    if (!mounted) return;
    setState(() {
      _name = _editing ? base.name : '${base.name} Copy';
      _nameController.text = _name;
      _light = base.statusBarLightIcons;
      _seedBg = base.seedBg;
      _seedSurface = base.seedSurface;
      _seedText = base.seedText;
      _seedSecondary = base.seedSecondary;
      _seedAccent = base.seedAccent;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  ThemeConfig get _preview => ThemeConfig.derived(
        id: widget.editId ?? '_preview',
        name: _name.trim().isEmpty ? 'My Theme' : _name.trim(),
        light: _light,
        bg: _seedBg,
        surface: _seedSurface,
        text: _seedText,
        secondary: _seedSecondary,
        accent: _seedAccent,
      );

  Future<void> _save() async {
    final finalName = _name.trim().isEmpty ? 'My Theme' : _name.trim();
    final id = widget.editId ?? await ThemeManager.newCustomId();
    final theme = ThemeConfig.derived(
      id: id,
      name: finalName,
      light: _light,
      bg: _seedBg,
      surface: _seedSurface,
      text: _seedText,
      secondary: _seedSecondary,
      accent: _seedAccent,
    );
    await ThemeManager.saveCustom(theme);
    if (!mounted) return;
    // Saving always activates the theme, editing included (spec §3.7).
    await AppTheme.controllerOf(context).setThemeId(id);
    if (!mounted) return;
    showToast(context, '"$finalName" saved');
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final active = AppTheme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: active.surfaceBg,
        title: Text('Delete "$_name"?', style: TextStyle(color: active.primaryText)),
        content: Text('This custom theme will be removed.', style: TextStyle(color: active.secondaryText)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('Cancel', style: TextStyle(color: active.secondaryText)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF453A))),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = widget.editId;
    if (id == null) return;
    await ThemeManager.deleteCustom(id);
    if (!mounted) return;
    await AppTheme.controllerOf(context).refresh();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final active = AppTheme.of(context);
    if (_loading) {
      return Scaffold(backgroundColor: active.windowBg);
    }
    return Scaffold(
      backgroundColor: active.windowBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 56),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _editing ? 'Edit Theme' : 'New Theme',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: active.primaryText),
                ),
              ),
              const SizedBox(height: 28),
              const SectionLabel('Preview'),
              const SizedBox(height: 8),
              _buildPreview(_preview),
              const SizedBox(height: 28),
              const SectionLabel('Name'),
              const SizedBox(height: 8),
              _buildNameCard(active),
              const SizedBox(height: 28),
              const SectionLabel('Appearance'),
              const SizedBox(height: 8),
              _buildAppearanceSegment(active),
              const SizedBox(height: 28),
              const SectionLabel('Colors'),
              const SizedBox(height: 8),
              SurfaceCard(radius: 14, child: _buildColorsColumn(active)),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: AccentButton(label: 'Save Theme', height: 48, radius: 12, onPressed: _save),
              ),
              if (_editing) ...[
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: _confirmDelete,
                    child: const Text('Delete Theme', style: TextStyle(fontSize: 15, color: Color(0xFFFF453A))),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Cancel', style: TextStyle(fontSize: 15, color: active.secondaryText)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNameCard(ThemeConfig active) {
    return SurfaceCard(
      radius: 14,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        child: TextField(
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          style: TextStyle(fontSize: 15, color: active.primaryText),
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            hintText: 'My Theme',
            hintStyle: TextStyle(color: active.secondaryText.withAlpha(0x66)),
          ),
          onChanged: (v) => setState(() => _name = v),
        ),
      ),
    );
  }

  Widget _buildAppearanceSegment(ThemeConfig active) {
    final segmentBg = ColorUtil.mix(active.surfaceBg, active.primaryText, 0.08);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: segmentBg, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          Expanded(
            child: _segmentHalf('Dark', selected: !_light, active: active, onTap: () {
              if (_light) _setAppearance(false);
            }),
          ),
          Expanded(
            child: _segmentHalf('Light', selected: _light, active: active, onTap: () {
              if (!_light) _setAppearance(true);
            }),
          ),
        ],
      ),
    );
  }

  Widget _segmentHalf(String label, {required bool selected, required ThemeConfig active, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: selected
            ? BoxDecoration(color: active.btnAccentBg, borderRadius: BorderRadius.circular(8))
            : null,
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? active.btnAccentText : active.secondaryText,
          ),
        ),
      ),
    );
  }

  Widget _buildColorsColumn(ThemeConfig active) {
    return Column(
      children: [
        _colorRow(active, 'Background', _seedBg, (c) => setState(() => _seedBg = c)),
        const RowDivider(),
        _colorRow(active, 'Surface', _seedSurface, (c) => setState(() => _seedSurface = c)),
        const RowDivider(),
        _colorRow(active, 'Text', _seedText, (c) => setState(() => _seedText = c)),
        const RowDivider(),
        _colorRow(active, 'Secondary Text', _seedSecondary, (c) => setState(() => _seedSecondary = c)),
        const RowDivider(),
        _colorRow(active, 'Accent', _seedAccent, (c) => setState(() => _seedAccent = c)),
      ],
    );
  }

  Widget _colorRow(ThemeConfig active, String label, Color value, ValueChanged<Color> onChanged) {
    return InkWell(
      onTap: () async {
        final picked = await showColorPicker(context, title: label, initial: value);
        if (picked != null) onChanged(picked.withAlpha(0xFF));
      },
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 15, color: active.primaryText))),
            Text(ColorUtil.toHex(value), style: TextStyle(fontSize: 14, color: active.secondaryText)),
            const SizedBox(width: 10),
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: value,
                shape: BoxShape.circle,
                border: Border.all(color: active.primaryText.withAlpha(0x33), width: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeConfig preview) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        color: preview.windowBg,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Living Room TV',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: preview.primaryText),
            ),
            const SizedBox(height: 2),
            Text('Connected · webOS', style: TextStyle(fontSize: 13, color: preview.secondaryText)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: preview.surfaceBg, borderRadius: BorderRadius.circular(14)),
              child: Column(
                children: [
                  Row(
                    children: [
                      _PreviewCircleButton(icon: 'ic_power', theme: preview),
                      const SizedBox(width: 14),
                      _PreviewCircleButton(icon: 'ic_home', theme: preview),
                      const Spacer(),
                      SizedBox(
                        height: 44,
                        child: Material(
                          color: preview.btnAccentBg,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            splashColor: preview.btnAccentText.withAlpha(0x33),
                            highlightColor: preview.btnAccentText.withAlpha(0x33),
                            onTap: () => setState(() => _previewSwitch = !_previewSwitch),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: Center(
                                child: Text(
                                  'Connect',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: preview.btnAccentText),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _PreviewPill(
                    theme: preview,
                    level: _previewLevel,
                    onLevel: (v) => setState(() => _previewLevel = v),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Auto-connect', style: TextStyle(color: preview.primaryText, fontSize: 15)),
                      ),
                      Transform.scale(
                        scale: 1.2,
                        child: Switch(
                          value: _previewSwitch,
                          onChanged: (v) => setState(() => _previewSwitch = v),
                          activeThumbColor: preview.switchThumbOn,
                          activeTrackColor: preview.switchTrackOn,
                          inactiveThumbColor: preview.switchThumbOff,
                          inactiveTrackColor: preview.switchTrackOff,
                          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The preview pill behaves like the volume pill on the remote: drag to set
/// a level. A raw Listener so the editor's scroll view never steals the drag.
class _PreviewPill extends StatelessWidget {
  const _PreviewPill({required this.theme, required this.level, required this.onLevel});

  final ThemeConfig theme;
  final int level;
  final ValueChanged<int> onLevel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void set(Offset local) => onLevel((local.dx / width * 100).toInt().clamp(0, 100));
        return Listener(
          onPointerDown: (e) => set(e.localPosition),
          onPointerMove: (e) => set(e.localPosition),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SizedBox(
              height: 48,
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: theme.pillBg)),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: width * level / 100,
                    child: ColoredBox(color: theme.pillLabelText.withAlpha(0x33)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Expanded(child: Text('Volume', style: TextStyle(color: theme.pillLabelText, fontSize: 15))),
                        Text('$level', style: TextStyle(color: theme.pillLabelText, fontSize: 15)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PreviewCircleButton extends StatelessWidget {
  const _PreviewCircleButton({required this.icon, required this.theme});

  final String icon;
  final ThemeConfig theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: theme.circleBtnBg, shape: BoxShape.circle),
      child: AppIcon(icon, size: 22, color: theme.circleBtnIconTint),
    );
  }
}
