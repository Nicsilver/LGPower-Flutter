import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lgpower/theme/color_util.dart';
import 'package:lgpower/theme/release_notes.dart';
import 'package:lgpower/theme/theme_config.dart';
import 'package:lgpower/theme/theme_manager.dart';

// Expected role -> "#AARRGGBB" for every built-in theme, transcribed from
// port-spec-secondary-screens.md section 3.2. 6-digit spec values are always
// implicitly opaque (FF alpha).
const Map<String, Map<String, String>> _expectedColors = {
  'dark': {
    'window_bg': '#FF000000',
    'surface_bg': '#FF161616',
    'primary_text': '#FFFFFFFF',
    'secondary_text': '#FFAAAAAA',
    'pill_label_text': '#CCFFFFFF',
    'section_label': '#FF8E8E93',
    'divider': '#FF242424',
    'pill_bg': '#FF1C1C1C',
    'pill_divider': '#FF000000',
    'circle_btn_bg': '#FF1C1C1C',
    'circle_btn_icon_tint': '#FFFFFFFF',
    'dpad_ring_bg': '#FF1C1C1C',
    'switch_track_on': '#FF909090',
    'switch_track_off': '#FF3E3E3E',
    'switch_thumb_on': '#FFFFFFFF',
    'switch_thumb_off': '#FF4A4A4A',
    'btn_accent_bg': '#FFFFFFFF',
    'btn_accent_text': '#FF000000',
    'btn_ghost_border': '#FF383838',
    'btn_ghost_border_pressed': '#FF505050',
    'btn_ghost_bg_pressed': '#FF2A2A2A',
    'dpad_ok_bg': '#FF111111',
  },
  'light': {
    'window_bg': '#FFF2F2F7',
    'surface_bg': '#FFFFFFFF',
    'primary_text': '#FF000000',
    'secondary_text': '#FF555555',
    'pill_label_text': '#CC000000',
    'section_label': '#FF6C6C70',
    'divider': '#FFE5E5EA',
    'pill_bg': '#FFFFFFFF',
    'pill_divider': '#FFE5E5EA',
    'circle_btn_bg': '#FFFFFFFF',
    'circle_btn_icon_tint': '#FF1C1C1E',
    'dpad_ring_bg': '#FFFFFFFF',
    'switch_track_on': '#FF555555',
    'switch_track_off': '#FFD1D1D6',
    'switch_thumb_on': '#FFFFFFFF',
    'switch_thumb_off': '#FFFFFFFF',
    'btn_accent_bg': '#FF48484C',
    'btn_accent_text': '#FFFFFFFF',
    'btn_ghost_border': '#FFCCCCCC',
    'btn_ghost_border_pressed': '#FFAAAAAA',
    'btn_ghost_bg_pressed': '#FFEEEEEE',
    'dpad_ok_bg': '#FFFAFAFA',
  },
  'catppuccin': {
    'window_bg': '#FF1E1E2E',
    'surface_bg': '#FF313244',
    'primary_text': '#FFCDD6F4',
    'secondary_text': '#FFA6ADC8',
    'pill_label_text': '#CCCDD6F4',
    'section_label': '#FF6C7086',
    'divider': '#FF313244',
    'pill_bg': '#FF313244',
    'pill_divider': '#FF1E1E2E',
    'circle_btn_bg': '#FF45475A',
    'circle_btn_icon_tint': '#FFCDD6F4',
    'dpad_ring_bg': '#FF45475A',
    'switch_track_on': '#FFCBA6F7',
    'switch_track_off': '#FF45475A',
    'switch_thumb_on': '#FFCDD6F4',
    'switch_thumb_off': '#FF6C7086',
    'btn_accent_bg': '#FFCBA6F7',
    'btn_accent_text': '#FF1E1E2E',
    'btn_ghost_border': '#FF45475A',
    'btn_ghost_border_pressed': '#FF585B70',
    'btn_ghost_bg_pressed': '#FF313244',
    'dpad_ok_bg': '#FF26263A',
  },
  'dracula': {
    'window_bg': '#FF282A36',
    'surface_bg': '#FF343746',
    'primary_text': '#FFF8F8F2',
    'secondary_text': '#FF6272A4',
    'pill_label_text': '#CCF8F8F2',
    'section_label': '#FF6272A4',
    'divider': '#FF343746',
    'pill_bg': '#FF343746',
    'pill_divider': '#FF282A36',
    'circle_btn_bg': '#FF44475A',
    'circle_btn_icon_tint': '#FFF8F8F2',
    'dpad_ring_bg': '#FF44475A',
    'switch_track_on': '#FFBD93F9',
    'switch_track_off': '#FF44475A',
    'switch_thumb_on': '#FFF8F8F2',
    'switch_thumb_off': '#FF6272A4',
    'btn_accent_bg': '#FFBD93F9',
    'btn_accent_text': '#FF282A36',
    'btn_ghost_border': '#FF44475A',
    'btn_ghost_border_pressed': '#FF6272A4',
    'btn_ghost_bg_pressed': '#FF343746',
    'dpad_ok_bg': '#FF2F313F',
  },
  'monokai': {
    'window_bg': '#FF272822',
    'surface_bg': '#FF33342B',
    'primary_text': '#FFF8F8F2',
    'secondary_text': '#FFA59F85',
    'pill_label_text': '#CCF8F8F2',
    'section_label': '#FF75715E',
    'divider': '#FF33342B',
    'pill_bg': '#FF33342B',
    'pill_divider': '#FF272822',
    'circle_btn_bg': '#FF3E3D32',
    'circle_btn_icon_tint': '#FFF8F8F2',
    'dpad_ring_bg': '#FF3E3D32',
    'switch_track_on': '#FFA6E22E',
    'switch_track_off': '#FF3E3D32',
    'switch_thumb_on': '#FFF8F8F2',
    'switch_thumb_off': '#FF75715E',
    'btn_accent_bg': '#FFF92672',
    'btn_accent_text': '#FFFFFFFF',
    'btn_ghost_border': '#FF3E3D32',
    'btn_ghost_border_pressed': '#FF75715E',
    'btn_ghost_bg_pressed': '#FF33342B',
    'dpad_ok_bg': '#FF2D2E27',
  },
  'nord': {
    'window_bg': '#FF2E3440',
    'surface_bg': '#FF3B4252',
    'primary_text': '#FFECEFF4',
    'secondary_text': '#FF81A1C1',
    'pill_label_text': '#CCECEFF4',
    'section_label': '#FF81A1C1',
    'divider': '#FF3B4252',
    'pill_bg': '#FF3B4252',
    'pill_divider': '#FF2E3440',
    'circle_btn_bg': '#FF434C5E',
    'circle_btn_icon_tint': '#FFECEFF4',
    'dpad_ring_bg': '#FF434C5E',
    'switch_track_on': '#FF88C0D0',
    'switch_track_off': '#FF434C5E',
    'switch_thumb_on': '#FFECEFF4',
    'switch_thumb_off': '#FF4C566A',
    'btn_accent_bg': '#FF88C0D0',
    'btn_accent_text': '#FF2E3440',
    'btn_ghost_border': '#FF4C566A',
    'btn_ghost_border_pressed': '#FF5E81AC',
    'btn_ghost_bg_pressed': '#FF3B4252',
    'dpad_ok_bg': '#FF353C4A',
  },
  'onelight': {
    'window_bg': '#FFEAEAEB',
    'surface_bg': '#FFFAFAFA',
    'primary_text': '#FF383A42',
    'secondary_text': '#FF696C77',
    'pill_label_text': '#CC383A42',
    'section_label': '#FFA0A1A7',
    'divider': '#FFE5E5E6',
    'pill_bg': '#FFFAFAFA',
    'pill_divider': '#FFE5E5E6',
    'circle_btn_bg': '#FFFFFFFF',
    'circle_btn_icon_tint': '#FF383A42',
    'dpad_ring_bg': '#FFFFFFFF',
    'switch_track_on': '#FF4078F2',
    'switch_track_off': '#FFD3D3D6',
    'switch_thumb_on': '#FFFFFFFF',
    'switch_thumb_off': '#FFFFFFFF',
    'btn_accent_bg': '#FF4078F2',
    'btn_accent_text': '#FFFFFFFF',
    'btn_ghost_border': '#FFD3D3D6',
    'btn_ghost_border_pressed': '#FFB9B9BD',
    'btn_ghost_bg_pressed': '#FFF0F0F0',
    'dpad_ok_bg': '#FFFCFCFC',
  },
  'solarized_light': {
    'window_bg': '#FFEEE8D5',
    'surface_bg': '#FFFDF6E3',
    'primary_text': '#FF586E75',
    'secondary_text': '#FF657B83',
    'pill_label_text': '#CC586E75',
    'section_label': '#FF657B83',
    'divider': '#FFE0D9C4',
    'pill_bg': '#FFFDF6E3',
    'pill_divider': '#FFDDD6C0',
    'circle_btn_bg': '#FFFDF6E3',
    'circle_btn_icon_tint': '#FF586E75',
    'dpad_ring_bg': '#FFFDF6E3',
    'switch_track_on': '#FF2AA198',
    'switch_track_off': '#FFD6CFB8',
    'switch_thumb_on': '#FFFDF6E3',
    'switch_thumb_off': '#FFFDF6E3',
    'btn_accent_bg': '#FF268BD2',
    'btn_accent_text': '#FFFDF6E3',
    'btn_ghost_border': '#FFD6CFB8',
    'btn_ghost_border_pressed': '#FFB8B095',
    'btn_ghost_bg_pressed': '#FFEEE8D5',
    'dpad_ok_bg': '#FFFBF5E1',
  },
};

const _expectedNames = {
  'dark': 'Dark',
  'light': 'Light',
  'catppuccin': 'Catppuccin',
  'dracula': 'Dracula',
  'monokai': 'Monokai',
  'nord': 'Nord',
  'onelight': 'One Light',
  'solarized_light': 'Solarized Light',
};

const _expectedLightIcons = {
  'dark': false,
  'light': true,
  'catppuccin': false,
  'dracula': false,
  'monokai': false,
  'nord': false,
  'onelight': true,
  'solarized_light': true,
};

// role field name -> ThemeConfig getter, so the assertion loop below can walk
// every role generically instead of one assertion per field per theme.
Color _roleValue(ThemeConfig c, String jsonKey) => switch (jsonKey) {
      'window_bg' => c.windowBg,
      'surface_bg' => c.surfaceBg,
      'primary_text' => c.primaryText,
      'secondary_text' => c.secondaryText,
      'pill_label_text' => c.pillLabelText,
      'section_label' => c.sectionLabel,
      'divider' => c.divider,
      'pill_bg' => c.pillBg,
      'pill_divider' => c.pillDivider,
      'circle_btn_bg' => c.circleBtnBg,
      'circle_btn_icon_tint' => c.circleBtnIconTint,
      'dpad_ring_bg' => c.dpadRingBg,
      'switch_track_on' => c.switchTrackOn,
      'switch_track_off' => c.switchTrackOff,
      'switch_thumb_on' => c.switchThumbOn,
      'switch_thumb_off' => c.switchThumbOff,
      'btn_accent_bg' => c.btnAccentBg,
      'btn_accent_text' => c.btnAccentText,
      'btn_ghost_border' => c.btnGhostBorder,
      'btn_ghost_border_pressed' => c.btnGhostBorderPressed,
      'btn_ghost_bg_pressed' => c.btnGhostBgPressed,
      'dpad_ok_bg' => c.dpadOkBg,
      _ => throw ArgumentError('unknown role $jsonKey'),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemeConfig.fromJson', () {
    for (final id in _expectedColors.keys) {
      test('$id.json matches spec 3.2 exactly', () async {
        final text = await rootBundle.loadString('assets/themes/$id.json');
        final theme = ThemeConfig.fromJson(jsonDecode(text) as Map<String, dynamic>);

        expect(theme.id, id);
        expect(theme.name, _expectedNames[id]);
        expect(theme.statusBarLightIcons, _expectedLightIcons[id]);
        expect(theme.editable, isFalse);

        for (final entry in _expectedColors[id]!.entries) {
          final actual = ColorUtil.toHexArgb(_roleValue(theme, entry.key));
          expect(actual, entry.value, reason: '${entry.key} on $id');
        }
      });
    }
  });

  group('ThemeConfig.derived', () {
    test('matches the derivation table for a known seed set', () {
      // All-grey seeds (except accent) so mix() results are trivial to hand-check.
      const bg = Color(0xFF202020); // 32,32,32
      const surface = Color(0xFF303030); // 48,48,48
      const text = Color(0xFFFFFFFF);
      const secondary = Color(0xFFA0A0A0);
      const accent = Color(0xFF3366FF);

      final theme = ThemeConfig.derived(
        id: 'custom_1',
        name: 'Test',
        light: false,
        bg: bg,
        surface: surface,
        text: text,
        secondary: secondary,
        accent: accent,
      );

      expect(ColorUtil.toHexArgb(theme.windowBg), '#FF202020');
      expect(ColorUtil.toHexArgb(theme.surfaceBg), '#FF303030');
      expect(ColorUtil.toHexArgb(theme.primaryText), '#FFFFFFFF');
      expect(ColorUtil.toHexArgb(theme.secondaryText), '#FFA0A0A0');
      expect(ColorUtil.toHexArgb(theme.pillLabelText), '#CCFFFFFF');
      expect(ColorUtil.toHexArgb(theme.sectionLabel), '#FFA0A0A0');
      expect(ColorUtil.toHexArgb(theme.divider), '#FF444444'); // 48+(207*0.10)=68.7->68
      expect(ColorUtil.toHexArgb(theme.pillBg), '#FF303030');
      expect(ColorUtil.toHexArgb(theme.pillDivider), '#FF202020');
      expect(ColorUtil.toHexArgb(theme.circleBtnBg), '#FF3C3C3C'); // 48+(207*0.06)=60.4->60
      expect(ColorUtil.toHexArgb(theme.circleBtnIconTint), '#FFFFFFFF');
      expect(ColorUtil.toHexArgb(theme.dpadRingBg), '#FF3C3C3C');
      expect(ColorUtil.toHexArgb(theme.switchTrackOn), '#FF3366FF');
      expect(ColorUtil.toHexArgb(theme.switchTrackOff), '#FF5D5D5D'); // 48+(207*0.22)=93.5->93
      expect(ColorUtil.toHexArgb(theme.switchThumbOn), '#FFFFFFFF');
      expect(ColorUtil.toHexArgb(theme.switchThumbOff), '#FF787878'); // 48+(207*0.35)=120.45->120
      expect(ColorUtil.toHexArgb(theme.btnAccentBg), '#FF3366FF');
      expect(ColorUtil.toHexArgb(theme.btnAccentText), '#FFFFFFFF'); // accent luminance ~0.41 <= 0.55
      expect(ColorUtil.toHexArgb(theme.btnGhostBorder), '#FF515151'); // 48+(207*0.16)=81.1->81
      expect(ColorUtil.toHexArgb(theme.btnGhostBorderPressed), '#FF6E6E6E'); // 48+(207*0.30)=110.1->110
      expect(ColorUtil.toHexArgb(theme.btnGhostBgPressed), '#FF3C3C3C');
      expect(ColorUtil.toHexArgb(theme.dpadOkBg), '#FF282828'); // 32+(16*0.5)=40
      expect(theme.statusBarLightIcons, isFalse);
      expect(theme.editable, isTrue);
      expect(theme.seedBg, bg);
      expect(theme.seedAccent, accent);
    });

    test('light flag forces white switch thumbs', () {
      final theme = ThemeConfig.derived(
        id: 'custom_2',
        name: 'Light Test',
        light: true,
        bg: const Color(0xFFF0F0F0),
        surface: const Color(0xFFFFFFFF),
        text: const Color(0xFF000000),
        secondary: const Color(0xFF555555),
        accent: const Color(0xFF0000FF),
      );
      expect(ColorUtil.toHexArgb(theme.switchThumbOn), '#FFFFFFFF');
      expect(ColorUtil.toHexArgb(theme.switchThumbOff), '#FFFFFFFF');
    });
  });

  group('ColorUtil.parseOrNull', () {
    test('expands #RGB by doubling each nibble', () {
      expect(ColorUtil.parseOrNull('#0F0'), const Color(0xFF00FF00));
    });

    test('accepts a hex string with no leading #', () {
      expect(ColorUtil.parseOrNull('336699'), const Color(0xFF336699));
    });

    test('accepts #AARRGGBB with explicit alpha', () {
      expect(ColorUtil.parseOrNull('#80336699'), const Color(0x80336699));
    });

    test('returns null for garbage', () {
      expect(ColorUtil.parseOrNull('zzz'), isNull);
      expect(ColorUtil.parseOrNull('12345'), isNull);
      expect(ColorUtil.parseOrNull(''), isNull);
    });
  });

  group('ThemeManager.listThemes', () {
    test('pins Dark, Light, then sorts the rest by name.toLowerCase()', () async {
      final themes = await ThemeManager.listThemes();
      final ids = themes.map((t) => t.id).toList();
      expect(ids, [
        'dark',
        'light',
        'catppuccin',
        'dracula',
        'monokai',
        'nord',
        'onelight',
        'solarized_light',
      ]);
    });
  });

  group('Seed JSON round-trip', () {
    test('toSeedJson -> fromSeedJson reproduces the derived theme', () {
      final original = ThemeConfig.derived(
        id: 'custom_3',
        name: 'Round Trip',
        light: true,
        bg: const Color(0xFFEFEFEF),
        surface: const Color(0xFFFFFFFF),
        text: const Color(0xFF111111),
        secondary: const Color(0xFF666666),
        accent: const Color(0xFFFF6600),
      );

      final restored = ThemeConfig.fromSeedJson(original.toSeedJson());

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.statusBarLightIcons, original.statusBarLightIcons);
      expect(ColorUtil.toHexArgb(restored.seedBg), ColorUtil.toHexArgb(original.seedBg));
      expect(ColorUtil.toHexArgb(restored.seedAccent), ColorUtil.toHexArgb(original.seedAccent));
      expect(ColorUtil.toHexArgb(restored.divider), ColorUtil.toHexArgb(original.divider));
      expect(ColorUtil.toHexArgb(restored.btnAccentText), ColorUtil.toHexArgb(original.btnAccentText));
      expect(ColorUtil.toHexArgb(restored.dpadOkBg), ColorUtil.toHexArgb(original.dpadOkBg));
    });
  });

  group('ReleaseNotes.since', () {
    test('32 returns exactly 33, 34, 35, 36, 37 (newest first)', () {
      final releases = ReleaseNotes.since(32);
      expect(releases.map((r) => r.code).toList(), [37, 36, 35, 34, 33]);
    });

    test('all has no gaps below 1.22.0 and is sorted newest-first', () {
      expect(ReleaseNotes.all.length, 38);
      for (var i = 1; i < ReleaseNotes.all.length; i++) {
        expect(ReleaseNotes.all[i].code, lessThanOrEqualTo(ReleaseNotes.all[i - 1].code));
      }
    });
  });
}
