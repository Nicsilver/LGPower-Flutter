import 'package:shared_preferences/shared_preferences.dart';

/// Wraps [SharedPreferences] with the exact key names/defaults the Android
/// app uses (file `"webos"` there; a single default-shared-prefs store here
/// is fine since this port has no equivalent per-file separation need yet).
///
/// Load once at startup with [Prefs.load]; every getter after that is
/// synchronous (SharedPreferences caches everything in memory once loaded),
/// and every setter is async because it also persists to disk.
class Prefs {
  Prefs._(this._sp);

  final SharedPreferences _sp;

  static Future<Prefs> load() async {
    final sp = await SharedPreferences.getInstance();
    return Prefs._(sp);
  }

  String get tvIp => _sp.getString('tv_ip') ?? '';
  Future<void> setTvIp(String value) => _sp.setString('tv_ip', value);

  String get tvMac => _sp.getString('tv_mac') ?? '';
  Future<void> setTvMac(String value) => _sp.setString('tv_mac', value);

  // Never cleared by the app — no unpair flow (spec §2.4).
  String? get clientKey => _sp.getString('client_key');
  Future<void> setClientKey(String value) => _sp.setString('client_key', value);

  String? get appShortcutsJson => _sp.getString('app_shortcuts');
  Future<void> setAppShortcutsJson(String value) =>
      _sp.setString('app_shortcuts', value);

  int? colorFor(String appId) {
    final key = 'color_$appId';
    return _sp.containsKey(key) ? _sp.getInt(key) : null;
  }

  Future<void> setColorFor(String appId, int argb) =>
      _sp.setInt('color_$appId', argb);

  bool get volSlider => _sp.getBool('vol_slider') ?? true;
  Future<void> setVolSlider(bool value) => _sp.setBool('vol_slider', value);

  bool get brightnessSlider => _sp.getBool('brightness_slider') ?? true;
  Future<void> setBrightnessSlider(bool value) =>
      _sp.setBool('brightness_slider', value);

  bool get rightPillChannel => _sp.getBool('right_pill_channel') ?? false;
  Future<void> setRightPillChannel(bool value) =>
      _sp.setBool('right_pill_channel', value);

  int get lastVolume => _sp.getInt('last_volume') ?? -1;
  Future<void> setLastVolume(int value) => _sp.setInt('last_volume', value);

  bool get lastMuted => _sp.getBool('last_muted') ?? false;
  Future<void> setLastMuted(bool value) => _sp.setBool('last_muted', value);

  int get lastBrightness => _sp.getInt('last_brightness') ?? -1;
  Future<void> setLastBrightness(int value) =>
      _sp.setInt('last_brightness', value);

  int get lastSeenVersion => _sp.getInt('last_seen_version') ?? -1;
  Future<void> setLastSeenVersion(int value) =>
      _sp.setInt('last_seen_version', value);

  String get themeId => _sp.getString('theme_id') ?? 'dark';
  Future<void> setThemeId(String value) => _sp.setString('theme_id', value);
}
