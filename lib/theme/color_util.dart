import 'package:flutter/material.dart';

/// Colour-math helpers mirroring `ColorUtil.kt`, kept as static methods on a
/// bare class (not extensions) so call sites read the same as the Kotlin
/// source when cross-checking against the port spec.
///
/// Channel maths is done in 0-255 int space rather than on `Color`'s 0.0-1.0
/// double components, and truncates (not rounds) the blended result — that
/// mirrors Kotlin's `Int`-returning `Color.rgb` arithmetic (`.toInt()`
/// truncates) exactly, which matters for byte-for-byte parity with the
/// derived-theme hex values in the port spec.
class ColorUtil {
  ColorUtil._();

  static int _channel(double component) => (component * 255.0).round();

  /// Linear RGB blend. t=0 -> a, t=1 -> b; result is always opaque, matching
  /// `Color.rgb(...)` in the Kotlin source (alpha on either input is dropped).
  static Color mix(Color a, Color b, double t) {
    final s = t.clamp(0.0, 1.0);
    final ra = _channel(a.r), ga = _channel(a.g), ba = _channel(a.b);
    final rb = _channel(b.r), gb = _channel(b.g), bb = _channel(b.b);
    int lerp(int ca, int cb) => (ca + (cb - ca) * s).toInt();
    return Color.fromARGB(0xFF, lerp(ra, rb), lerp(ga, gb), lerp(ba, bb));
  }

  /// Same RGB, new alpha (0..255).
  static Color withAlpha(Color color, int alpha) => color.withAlpha(alpha.clamp(0, 255));

  /// Perceived luminance, 0 (black) .. 1 (white).
  static double luminance(Color color) {
    final r = _channel(color.r);
    final g = _channel(color.g);
    final b = _channel(color.b);
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
  }

  /// Black or white, whichever reads better on top of [color].
  static Color contrastText(Color color) =>
      luminance(color) > 0.55 ? const Color(0xFF1A1A1A) : const Color(0xFFFFFFFF);

  /// "#RRGGBB" (alpha dropped), for display in the editor.
  static String toHex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// "#AARRGGBB", used when persisting so semi-transparent values survive.
  static String toHexArgb(Color color) {
    final argb = color.toARGB32();
    return '#${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  /// Parses "#RGB", "#RRGGBB" or "#AARRGGBB" (leading # optional); returns
  /// null on malformed input rather than throwing, matching `Color.parseColor`
  /// wrapped in `runCatching` in the Kotlin source. A bare "#RRGGBB" is always
  /// opaque, same as `Color.parseColor`.
  static Color? parseOrNull(String text) {
    var s = text.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 3) {
      s = s.split('').map((c) => '$c$c').join();
    }
    if (s.length != 6 && s.length != 8) return null;
    final value = int.tryParse(s, radix: 16);
    if (value == null) return null;
    return s.length == 6 ? Color(0xFF000000 | value) : Color(value);
  }
}
