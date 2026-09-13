import 'dart:convert';

import 'prefs.dart';
import 'tv_store.dart';

/// What the Power tap does once a network-woken TV answers. Wake-on-LAN
/// brings most sets up on an input rather than where they were, so the
/// default lands on Home. Saved per TV because inputs and shortcuts differ
/// between sets.
class WakeAction {
  const WakeAction(this.kind, {this.id = '', this.label = ''});

  static const home = 'home';
  static const stay = 'stay';
  static const input = 'input';
  static const app = 'app';

  final String kind;
  final String id;
  final String label;

  String get display => switch (kind) {
    home => 'Home screen',
    stay => 'Leave as is',
    _ => label,
  };

  /// Picker row id; two actions with the same key are the same choice.
  String get key => '$kind:$id';

  static String _prefKey(Prefs prefs) {
    final id = TvStore.activeId(prefs);
    return id == null ? 'wake_action' : 'wake_action_$id';
  }

  static WakeAction get(Prefs prefs) {
    final json = prefs.getString(_prefKey(prefs));
    if (json == null) return const WakeAction(home);
    try {
      final o = jsonDecode(json) as Map<String, dynamic>;
      return WakeAction(
        o['kind'] as String,
        id: o['id'] as String? ?? '',
        label: o['label'] as String? ?? '',
      );
    } catch (_) {
      return const WakeAction(home);
    }
  }

  static Future<void> set(Prefs prefs, WakeAction a) => prefs.setString(
    _prefKey(prefs),
    jsonEncode({'kind': a.kind, 'id': a.id, 'label': a.label}),
  );
}
