import '../core/prefs.dart';
import '../core/tv_store.dart';

/// Whether a saved TV accepts typed text from this app, remembered per TV so
/// the keyboard stops offering something that cannot work. Set only by a real
/// permission refusal from that TV, never from a version number; a changed
/// software version or a few days of age clears it.
class TypingSupport {
  TypingSupport._();

  // A firmware update can fix the refusal, and a TV that never reports its
  // version still gets a retry.
  static const maxAge = Duration(days: 3);

  static String _markKey(Prefs prefs) {
    final id = TvStore.activeId(prefs);
    return id == null ? 'kbd_refused' : 'kbd_refused_$id';
  }

  static String _versionKey(Prefs prefs) {
    final id = TvStore.activeId(prefs);
    return id == null ? 'tv_sw' : 'tv_sw_$id';
  }

  static String? softwareVersion(Prefs prefs) => prefs.getString(_versionKey(prefs));

  static bool isRefused(Prefs prefs, {DateTime? now}) {
    final stamp = int.tryParse(prefs.getString(_markKey(prefs)) ?? '');
    if (stamp == null || stamp == 0) return false;
    final age = (now ?? DateTime.now()).millisecondsSinceEpoch - stamp;
    return age >= 0 && age <= maxAge.inMilliseconds;
  }

  static Future<void> markRefused(Prefs prefs, {DateTime? now}) => prefs.setString(
      _markKey(prefs), ((now ?? DateTime.now()).millisecondsSinceEpoch).toString());

  static Future<void> clear(Prefs prefs) => prefs.remove(_markKey(prefs));

  /// Stores the version the TV reports; a different one than before lifts the refusal.
  static Future<void> noteVersion(Prefs prefs, String reported) async {
    final old = softwareVersion(prefs);
    await prefs.setString(_versionKey(prefs), reported);
    if (old != null && old != reported) await clear(prefs);
  }

  /// One comparable string from a getCurrentSWInformation or system property
  /// reply payload, null when it holds none.
  static String? versionOf(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    const keys = [
      'product_name', 'major_ver', 'minor_ver', 'dre_ver', 'webos_release', 'firmwareVersion', 'sdkVersion',
    ];
    final parts = [
      for (final k in keys)
        if (payload[k] is String && (payload[k] as String).isNotEmpty) payload[k] as String,
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  static final _link = RegExp(r'^[\w-]+(\.[\w-]+)+(/\S*)?$');

  /// What the TV browser opens for typed text: a link as typed, anything else
  /// as a web search.
  static String browserTarget(String text) {
    final t = text.trim();
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    if (!t.contains(' ') && _link.hasMatch(t)) return 'https://$t';
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}';
  }
}

/// The text length the TV reports for the focused field, null when the frame
/// has none (hidden fields omit it).
int? keyboardTextLengthOf(Map<String, dynamic>? payload) {
  final widget = payload?['currentWidget'];
  if (widget is! Map) return null;
  final n = widget['surroundingTextLength'];
  return n is int ? n : null;
}
