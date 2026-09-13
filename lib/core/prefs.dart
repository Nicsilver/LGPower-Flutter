import 'package:shared_preferences/shared_preferences.dart';

/// Wraps [SharedPreferences] with the exact key names/defaults the Android
/// app uses (file `"webos"` there; a single default-shared-prefs store here
/// is fine since this port has no equivalent per-file separation need yet).
///
/// Load once at startup with [Prefs.load]; every getter after that is
/// synchronous (SharedPreferences caches everything in memory once loaded),
/// and every setter is async because it also persists to disk. The in-memory
/// value is updated before the returned future completes, so a setter
/// followed by the matching getter on the same tick already reads the new
/// value -- callers that don't care about the disk write may `unawaited` it.
class Prefs {
  Prefs._(this._sp);

  final SharedPreferences _sp;

  static Future<Prefs> load() async {
    final sp = await SharedPreferences.getInstance();
    return Prefs._(sp);
  }

  // Raw access for the keyed stores (saved TVs, per-TV shortcuts, wake
  // actions, input caches) whose key names are computed at runtime.
  String? getString(String key) => _sp.getString(key);
  Future<void> setString(String key, String value) => _sp.setString(key, value);
  bool? getBool(String key) => _sp.getBool(key);
  Future<void> setBool(String key, bool value) => _sp.setBool(key, value);
  bool containsKey(String key) => _sp.containsKey(key);
  Future<void> remove(String key) => _sp.remove(key);

  String get tvIp => _sp.getString('tv_ip') ?? '';
  Future<void> setTvIp(String value) => _sp.setString('tv_ip', value);

  String get tvMac => _sp.getString('tv_mac') ?? '';
  Future<void> setTvMac(String value) => _sp.setString('tv_mac', value);

  // Never cleared by the app -- no unpair flow (spec §2.4). Switching TVs
  // swaps it for the other TV's key (see TvStore).
  String? get clientKey => _sp.getString('client_key');
  Future<void> setClientKey(String value) => _sp.setString('client_key', value);

  int? colorFor(String appId) {
    final key = 'color_$appId';
    return _sp.containsKey(key) ? _sp.getInt(key) : null;
  }

  Future<void> setColorFor(String appId, int argb) =>
      _sp.setInt('color_$appId', argb);

  // Pre-1.35 switch; only read by RightPill's migration path.
  bool get rightPillChannel => _sp.getBool('right_pill_channel') ?? false;

  bool get keepScreenOn => _sp.getBool('keep_screen_on') ?? false;
  Future<void> setKeepScreenOn(bool value) =>
      _sp.setBool('keep_screen_on', value);

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

  /// Set by first-run setup and Settings › About › Show the tour; the remote
  /// consumes it on its next resume.
  bool get tourPending => _sp.getBool('tour_pending') ?? false;
  Future<void> setTourPending(bool value) => _sp.setBool('tour_pending', value);

  /// Set when the remote's tour leg ends with "Open Settings"; Settings
  /// consumes it on open.
  bool get tourSettingsPending => _sp.getBool('tour_settings_pending') ?? false;
  Future<void> setTourSettingsPending(bool value) =>
      _sp.setBool('tour_settings_pending', value);
}
