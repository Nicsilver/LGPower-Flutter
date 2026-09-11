import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_config.dart';

/// Loads, lists and persists themes. Mirrors `ThemeManager.kt`, reading
/// `theme_id` straight out of `SharedPreferences` rather than through
/// `lib/core/prefs.dart` (owned separately) to keep this plan's surface
/// self-contained.
class ThemeManager {
  ThemeManager._();

  static const _prefKey = 'theme_id';
  static const _fallbackId = 'dark';

  // Dark and Light are pinned to the top of the picker, in that order; the
  // rest (built-in then custom) follow alphabetically by name (spec 3.2).
  static const _pinnedOrder = ['dark', 'light'];

  static final Map<String, ThemeConfig> _cache = {};

  static Future<String> getActiveThemeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKey) ?? _fallbackId;
  }

  static Future<void> setActiveThemeId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, id);
  }

  /// Falls back to the built-in dark theme on any failure (missing custom
  /// file, corrupt JSON, …), same as the Kotlin `runCatching`.
  static Future<ThemeConfig> getActiveTheme() async {
    try {
      return await loadTheme(await getActiveThemeId());
    } catch (_) {
      return loadTheme(_fallbackId);
    }
  }

  /// Custom file first (`<documents>/themes/<id>.json`), else the built-in
  /// asset; memoised in-process like the Kotlin cache.
  static Future<ThemeConfig> loadTheme(String id) async {
    final cached = _cache[id];
    if (cached != null) return cached;

    // path_provider has no platform implementation in a bare `flutter test`
    // process; treat that the same as "no custom theme saved yet" rather
    // than failing every built-in theme load.
    File? custom;
    try {
      custom = await _customFile(id);
    } catch (_) {
      custom = null;
    }

    final ThemeConfig cfg;
    if (custom != null && await custom.exists()) {
      final text = await custom.readAsString();
      cfg = ThemeConfig.fromSeedJson(jsonDecode(text) as Map<String, dynamic>);
    } else {
      final text = await rootBundle.loadString('assets/themes/$id.json');
      cfg = ThemeConfig.fromJson(jsonDecode(text) as Map<String, dynamic>);
    }
    _cache[id] = cfg;
    return cfg;
  }

  /// Union of built-in and custom theme ids, each loaded with failures
  /// swallowed (a broken theme file is skipped, not fatal), sorted by
  /// (pinned index, name.lowercase()).
  static Future<List<ThemeConfig>> listThemes() async {
    final ids = {...await _builtInIds(), ...await _customIds()};
    final themes = <ThemeConfig>[];
    for (final id in ids) {
      try {
        themes.add(await loadTheme(id));
      } catch (_) {
        // Skip silently — matches `runCatching{}.getOrNull()` in the source.
      }
    }
    int pinnedRank(String id) {
      final i = _pinnedOrder.indexOf(id);
      return i == -1 ? _pinnedOrder.length : i;
    }

    themes.sort((a, b) {
      final rank = pinnedRank(a.id).compareTo(pinnedRank(b.id));
      return rank != 0 ? rank : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return themes;
  }

  /// Persists a user theme by its seed colours and refreshes the cache.
  static Future<void> saveCustom(ThemeConfig theme) async {
    final file = await _customFile(theme.id);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(theme.toSeedJson()),
    );
    _cache[theme.id] = theme;
  }

  static Future<void> deleteCustom(String id) async {
    try {
      final file = await _customFile(id);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // No on-device storage (tests) — nothing to delete.
    }
    _cache.remove(id);
    if (await getActiveThemeId() == id) await setActiveThemeId(_fallbackId);
  }

  /// A fresh, unused id for a new custom theme.
  static Future<String> newCustomId() async {
    var n = 1;
    while (await (await _customFile('custom_$n')).exists()) {
      n++;
    }
    return 'custom_$n';
  }

  static Future<Directory> _customDir() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory('${base.path}/themes');
  }

  static Future<File> _customFile(String id) async {
    final dir = await _customDir();
    return File('${dir.path}/$id.json');
  }

  static Future<List<String>> _builtInIds() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return manifest
        .listAssets()
        .where((key) => key.startsWith('assets/themes/') && key.endsWith('.json'))
        .map(_basenameWithoutExtension)
        .toList();
  }

  static Future<List<String>> _customIds() async {
    try {
      final dir = await _customDir();
      if (!await dir.exists()) return const [];
      return dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .map((f) => _basenameWithoutExtension(f.path))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String _basenameWithoutExtension(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    return name.endsWith('.json') ? name.substring(0, name.length - 5) : name;
  }

  /// `window.statusBarColor`/`navigationBarColor` + light/dark icons — the
  /// Flutter side of the theming contract every screen applies (spec 0.2).
  /// iOS has no navigation bar and only honours `statusBarBrightness`.
  static void applySystemChrome(ThemeConfig theme) {
    SystemChrome.setSystemUIOverlayStyle(overlayStyle(theme));
  }

  static SystemUiOverlayStyle overlayStyle(ThemeConfig theme) {
    final iconBrightness = theme.statusBarLightIcons ? Brightness.dark : Brightness.light;
    return SystemUiOverlayStyle(
      statusBarColor: theme.windowBg,
      statusBarIconBrightness: iconBrightness,
      statusBarBrightness: theme.statusBarLightIcons ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: theme.windowBg,
      systemNavigationBarIconBrightness: iconBrightness,
    );
  }
}

/// Holds the active [ThemeConfig] and notifies listeners on change, so
/// screens rebuild in place instead of the app being torn down and rebuilt
/// (the Kotlin source's `recreate()`, which flashes the old theme first).
class AppThemeController extends ChangeNotifier {
  AppThemeController(ThemeConfig initial) : _theme = initial {
    ThemeManager.applySystemChrome(initial);
  }

  /// Loads the currently-active theme from prefs, applying system chrome
  /// as a side effect.
  static Future<AppThemeController> load() async {
    return AppThemeController(await ThemeManager.getActiveTheme());
  }

  ThemeConfig _theme;
  ThemeConfig get theme => _theme;

  Future<void> _apply(ThemeConfig next) async {
    _theme = next;
    ThemeManager.applySystemChrome(next);
    notifyListeners();
  }

  /// Re-reads the active theme id from prefs (e.g. after the editor saves).
  Future<void> refresh() async => _apply(await ThemeManager.getActiveTheme());

  /// Activates [id] and rebuilds every listening screen with it.
  Future<void> setThemeId(String id) async {
    await ThemeManager.setActiveThemeId(id);
    await _apply(await ThemeManager.loadTheme(id));
  }
}

/// Exposes the active [ThemeConfig] to the widget tree. Wrap the app (or a
/// screen subtree) with this and read it via `AppTheme.of(context)`.
class AppTheme extends InheritedNotifier<AppThemeController> {
  const AppTheme({super.key, required AppThemeController controller, required super.child})
      : super(notifier: controller);

  static ThemeConfig of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<AppTheme>();
    assert(widget != null, 'No AppTheme found in context');
    return widget!.notifier!.theme;
  }

  static AppThemeController controllerOf(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<AppTheme>();
    assert(widget != null, 'No AppTheme found in context');
    return widget!.notifier!;
  }
}
