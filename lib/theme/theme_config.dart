import 'package:flutter/material.dart';

import 'color_util.dart';

/// Mirrors `ThemeConfig.kt`: the 24 colour/flag roles every screen paints
/// from (spec 3.1/3.3), plus the editor metadata a custom theme needs — the
/// 5 seed colours it was built from, and whether it's user-editable at all.
/// Built-in themes back-fill their seeds from their own role values (see the
/// constructor defaults) so any theme, built-in or custom, can seed the
/// "Duplicate" flow in the editor.
@immutable
class ThemeConfig {
  const ThemeConfig({
    required this.id,
    required this.name,
    required this.windowBg,
    required this.surfaceBg,
    required this.primaryText,
    required this.secondaryText,
    required this.pillLabelText,
    required this.sectionLabel,
    required this.divider,
    required this.pillBg,
    required this.pillDivider,
    required this.circleBtnBg,
    required this.circleBtnIconTint,
    required this.dpadRingBg,
    required this.switchTrackOn,
    required this.switchTrackOff,
    required this.switchThumbOn,
    required this.switchThumbOff,
    required this.btnAccentBg,
    required this.btnAccentText,
    required this.btnGhostBorder,
    required this.btnGhostBorderPressed,
    required this.btnGhostBgPressed,
    required this.dpadOkBg,
    required this.statusBarLightIcons,
    this.editable = false,
    Color? seedBg,
    Color? seedSurface,
    Color? seedText,
    Color? seedSecondary,
    Color? seedAccent,
  })  : seedBg = seedBg ?? windowBg,
        seedSurface = seedSurface ?? surfaceBg,
        seedText = seedText ?? primaryText,
        seedSecondary = seedSecondary ?? secondaryText,
        seedAccent = seedAccent ?? btnAccentBg;

  final String id;
  final String name;

  final Color windowBg;
  final Color surfaceBg;
  final Color primaryText;
  final Color secondaryText;
  final Color pillLabelText;
  final Color sectionLabel;
  final Color divider;
  final Color pillBg;
  final Color pillDivider;
  final Color circleBtnBg;
  final Color circleBtnIconTint;
  final Color dpadRingBg;
  final Color switchTrackOn;
  final Color switchTrackOff;
  final Color switchThumbOn;
  final Color switchThumbOff;
  final Color btnAccentBg;
  final Color btnAccentText;
  final Color btnGhostBorder;
  final Color btnGhostBorderPressed;
  final Color btnGhostBgPressed;
  final Color dpadOkBg;
  final bool statusBarLightIcons;

  /// `false` for built-ins; `true` for anything produced by [derived] (i.e.
  /// every custom theme) — gates Edit/Delete in the theme picker's long-press
  /// menu.
  final bool editable;
  final Color seedBg;
  final Color seedSurface;
  final Color seedText;
  final Color seedSecondary;
  final Color seedAccent;

  static Color _requireColor(String hex) {
    final c = ColorUtil.parseOrNull(hex);
    if (c == null) {
      throw FormatException('Not a colour: "$hex"');
    }
    return c;
  }

  /// Parses a built-in theme asset (`assets/themes/<id>.json`).
  factory ThemeConfig.fromJson(Map<String, dynamic> json) {
    final colors = json['colors'] as Map<String, dynamic>;
    Color p(String key) => _requireColor(colors[key] as String);
    return ThemeConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      windowBg: p('window_bg'),
      surfaceBg: p('surface_bg'),
      primaryText: p('primary_text'),
      secondaryText: p('secondary_text'),
      pillLabelText: p('pill_label_text'),
      sectionLabel: p('section_label'),
      divider: p('divider'),
      pillBg: p('pill_bg'),
      pillDivider: p('pill_divider'),
      circleBtnBg: p('circle_btn_bg'),
      circleBtnIconTint: p('circle_btn_icon_tint'),
      dpadRingBg: p('dpad_ring_bg'),
      switchTrackOn: p('switch_track_on'),
      switchTrackOff: p('switch_track_off'),
      switchThumbOn: p('switch_thumb_on'),
      switchThumbOff: p('switch_thumb_off'),
      btnAccentBg: p('btn_accent_bg'),
      btnAccentText: p('btn_accent_text'),
      btnGhostBorder: p('btn_ghost_border'),
      btnGhostBorderPressed: p('btn_ghost_border_pressed'),
      btnGhostBgPressed: p('btn_ghost_bg_pressed'),
      dpadOkBg: p('dpad_ok_bg'),
      statusBarLightIcons: json['status_bar_light_icons'] as bool,
    );
  }

  /// Builds a full theme from 5 seed colours — the engine behind the custom
  /// theme editor. Every other role is computed from them (derivation table,
  /// spec 3.6) so a custom theme only ever needs to persist the seeds.
  factory ThemeConfig.derived({
    required String id,
    required String name,
    required bool light,
    required Color bg,
    required Color surface,
    required Color text,
    required Color secondary,
    required Color accent,
  }) {
    return ThemeConfig(
      id: id,
      name: name,
      windowBg: bg,
      surfaceBg: surface,
      primaryText: text,
      secondaryText: secondary,
      pillLabelText: ColorUtil.withAlpha(text, 0xCC),
      sectionLabel: secondary,
      divider: ColorUtil.mix(surface, text, 0.10),
      pillBg: surface,
      pillDivider: bg,
      circleBtnBg: ColorUtil.mix(surface, text, 0.06),
      circleBtnIconTint: text,
      dpadRingBg: ColorUtil.mix(surface, text, 0.06),
      switchTrackOn: accent,
      switchTrackOff: ColorUtil.mix(surface, text, 0.22),
      switchThumbOn: light ? const Color(0xFFFFFFFF) : text,
      switchThumbOff: light ? const Color(0xFFFFFFFF) : ColorUtil.mix(surface, text, 0.35),
      btnAccentBg: accent,
      btnAccentText: ColorUtil.contrastText(accent),
      btnGhostBorder: ColorUtil.mix(surface, text, 0.16),
      btnGhostBorderPressed: ColorUtil.mix(surface, text, 0.30),
      btnGhostBgPressed: ColorUtil.mix(surface, text, 0.06),
      dpadOkBg: ColorUtil.mix(bg, surface, 0.5),
      statusBarLightIcons: light,
      editable: true,
      seedBg: bg,
      seedSurface: surface,
      seedText: text,
      seedSecondary: secondary,
      seedAccent: accent,
    );
  }

  /// Loads a user-created theme stored as seed colours (re-derived on load,
  /// never itself persisted beyond the 5 seeds — see [toSeedJson]).
  factory ThemeConfig.fromSeedJson(Map<String, dynamic> json) {
    final seed = json['seed'] as Map<String, dynamic>;
    Color p(String key) => _requireColor(seed[key] as String);
    return ThemeConfig.derived(
      id: json['id'] as String,
      name: json['name'] as String,
      light: json['light'] as bool? ?? false,
      bg: p('background'),
      surface: p('surface'),
      text: p('text'),
      secondary: p('secondary'),
      accent: p('accent'),
    );
  }

  /// Serialises a custom theme as its seed colours. The `custom` key is
  /// written for parity with the Kotlin on-disk format but never read back.
  Map<String, dynamic> toSeedJson() => {
        'id': id,
        'name': name,
        'custom': true,
        'light': statusBarLightIcons,
        'seed': {
          'background': ColorUtil.toHexArgb(seedBg),
          'surface': ColorUtil.toHexArgb(seedSurface),
          'text': ColorUtil.toHexArgb(seedText),
          'secondary': ColorUtil.toHexArgb(seedSecondary),
          'accent': ColorUtil.toHexArgb(seedAccent),
        },
      };
}
