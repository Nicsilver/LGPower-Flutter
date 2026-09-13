import 'prefs.dart';

/// What the pill on the right of the d-pad does.
enum RightPill {
  brightness('brightness', 'Brightness'),
  channel('channel', 'Channel buttons');

  const RightPill(this.key, this.label);

  final String key;
  final String label;

  static const _pref = 'right_pill';

  static RightPill get(Prefs prefs) {
    switch (prefs.getString(_pref)) {
      case 'channel':
        return channel;
      case 'brightness':
      case 'brightness_slider':
      case 'brightness_buttons':
        return brightness;
      default:
        // Pre-1.35 installs stored a channel switch
        return prefs.rightPillChannel ? channel : brightness;
    }
  }

  static Future<void> set(Prefs prefs, RightPill mode) =>
      prefs.setString(_pref, mode.key);
}
