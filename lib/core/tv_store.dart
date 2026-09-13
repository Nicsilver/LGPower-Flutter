import 'dart:convert';
import 'dart:math';

import 'prefs.dart';

class Tv {
  const Tv({
    required this.id,
    required this.name,
    required this.ip,
    required this.mac,
    required this.clientKey,
    this.udn = '',
  });

  final String id;
  final String name;
  final String ip;
  final String mac;
  final String clientKey;

  /// SSDP unique device name, when discovery had one. Tells two TVs apart
  /// even if they end up on the same address on different networks.
  final String udn;

  Tv copyWith({
    String? name,
    String? ip,
    String? mac,
    String? clientKey,
    String? udn,
  }) => Tv(
    id: id,
    name: name ?? this.name,
    ip: ip ?? this.ip,
    mac: mac ?? this.mac,
    clientKey: clientKey ?? this.clientKey,
    udn: udn ?? this.udn,
  );
}

/// Saved TVs. The flat `tv_ip` / `tv_mac` / `client_key` prefs stay the live
/// connection everything else reads, so switching TVs is a copy in and out of
/// this list: [syncFromLive] captures what pairing and Settings wrote for the
/// active TV, [switchTo] loads another one.
class TvStore {
  TvStore._();

  static const _list = 'tvs';
  static const _active = 'active_tv';
  static const _shortcuts = 'app_shortcuts';

  /// Shortcuts are saved per TV; the pre-1.35 single list belongs to whichever
  /// TV was migrated.
  static String shortcutsKey(Prefs prefs) {
    final id = prefs.getString(_active);
    return id == null ? _shortcuts : '${_shortcuts}_$id';
  }

  static List<Tv> list(Prefs prefs) {
    _migrate(prefs);
    return _read(prefs);
  }

  static String? activeId(Prefs prefs) {
    _migrate(prefs);
    return prefs.getString(_active);
  }

  static Tv? active(Prefs prefs) {
    final id = activeId(prefs);
    for (final tv in list(prefs)) {
      if (tv.id == id) return tv;
    }
    return null;
  }

  /// Display name for the remote's title.
  static String activeName(Prefs prefs) =>
      active(prefs)?.name ?? 'LG TV Remote';

  static String nextDefaultName(Prefs prefs) {
    final n = list(prefs).length;
    return n == 0 ? 'LG TV' : 'LG TV ${n + 1}';
  }

  /// Writes the live connection prefs into the active entry.
  static void syncFromLive(Prefs prefs) {
    _migrate(prefs);
    final id = prefs.getString(_active);
    if (id == null) return;
    final ip = prefs.tvIp;
    if (ip.trim().isEmpty) return;
    _write(prefs, [
      for (final tv in _read(prefs))
        if (tv.id == id)
          tv.copyWith(
            ip: ip,
            mac: prefs.tvMac,
            clientKey: prefs.clientKey ?? '',
          )
        else
          tv,
    ]);
  }

  /// Adds the live connection prefs as a new TV and makes it the active one.
  static Tv addFromLive(Prefs prefs, String name, {String udn = ''}) {
    final tv = Tv(
      id: _newId(),
      name: name.trim().isEmpty ? nextDefaultName(prefs) : name.trim(),
      ip: prefs.tvIp,
      mac: prefs.tvMac,
      clientKey: prefs.clientKey ?? '',
      udn: udn,
    );
    _write(prefs, [..._read(prefs), tv]);
    prefs.setString(_active, tv.id);
    return tv;
  }

  static void switchTo(Prefs prefs, String id) {
    syncFromLive(prefs);
    Tv? tv;
    for (final t in _read(prefs)) {
      if (t.id == id) tv = t;
    }
    if (tv == null) return;
    prefs.setString(_active, tv.id);
    prefs.setTvIp(tv.ip);
    prefs.setTvMac(tv.mac);
    prefs.setClientKey(tv.clientKey);
    prefs.remove('last_volume');
    prefs.remove('last_muted');
    prefs.remove('last_brightness');
  }

  /// Clears the live prefs so a new pairing starts clean; the active entry
  /// keeps its copy.
  static void beginAdd(Prefs prefs) {
    syncFromLive(prefs);
    prefs.remove('tv_ip');
    prefs.remove('tv_mac');
    prefs.remove('client_key');
  }

  /// Undo of [beginAdd] when the user backs out before pairing.
  static void cancelAdd(Prefs prefs) {
    _migrate(prefs);
    final id = prefs.getString(_active);
    if (id == null) return;
    for (final tv in _read(prefs)) {
      if (tv.id == id) {
        prefs.setTvIp(tv.ip);
        prefs.setTvMac(tv.mac);
        prefs.setClientKey(tv.clientKey);
        return;
      }
    }
  }

  /// Edits from the TV detail screen; the live prefs follow when it is the
  /// active TV.
  static void update(
    Prefs prefs,
    String id, {
    required String name,
    required String ip,
    required String mac,
  }) {
    _write(prefs, [
      for (final tv in _read(prefs))
        if (tv.id == id)
          tv.copyWith(
            name: name.trim().isEmpty ? tv.name : name.trim(),
            ip: ip.trim().isEmpty ? tv.ip : ip.trim(),
            mac: mac.trim(),
          )
        else
          tv,
    ]);
    if (prefs.getString(_active) == id) {
      prefs.setTvMac(mac.trim());
      if (ip.trim().isNotEmpty) prefs.setTvIp(ip.trim());
    }
  }

  /// Which saved TV a discovered one is, if any: by fingerprint when both
  /// sides have one, else by address.
  static Tv? match(Prefs prefs, String ip, String? udn) {
    for (final tv in list(prefs)) {
      final byUdn = udn != null && udn.isNotEmpty && tv.udn.isNotEmpty;
      if (byUdn ? tv.udn == udn : tv.ip == ip) return tv;
    }
    return null;
  }

  static void rename(Prefs prefs, String id, String name) {
    if (name.trim().isEmpty) return;
    _write(prefs, [
      for (final tv in _read(prefs))
        tv.id == id ? tv.copyWith(name: name.trim()) : tv,
    ]);
  }

  /// Removes a TV; if it was active, the first remaining one takes over, or
  /// the live prefs are cleared.
  static void remove(Prefs prefs, String id) {
    syncFromLive(prefs);
    final rest = _read(prefs).where((tv) => tv.id != id).toList();
    _write(prefs, rest);
    prefs.remove('${_shortcuts}_$id');
    if (prefs.getString(_active) == id) {
      if (rest.isNotEmpty) {
        switchTo(prefs, rest.first.id);
      } else {
        prefs.remove(_active);
        prefs.remove('tv_ip');
        prefs.remove('tv_mac');
        prefs.remove('client_key');
      }
    }
  }

  // Installs from before saved TVs existed have only the flat prefs
  static void _migrate(Prefs prefs) {
    if (prefs.containsKey(_list)) return;
    final ip = prefs.tvIp;
    if (ip.trim().isEmpty) {
      _write(prefs, const []);
      return;
    }
    final tv = Tv(
      id: _newId(),
      name: 'LG TV',
      ip: ip,
      mac: prefs.tvMac,
      clientKey: prefs.clientKey ?? '',
    );
    _write(prefs, [tv]);
    prefs.setString(_active, tv.id);
    final old = prefs.getString(_shortcuts);
    if (old != null) prefs.setString('${_shortcuts}_${tv.id}', old);
  }

  static List<Tv> _read(Prefs prefs) {
    try {
      final arr = jsonDecode(prefs.getString(_list) ?? '[]') as List<dynamic>;
      return [
        for (final entry in arr)
          Tv(
            id: (entry as Map<String, dynamic>)['id'] as String,
            name: entry['name'] as String,
            ip: entry['ip'] as String? ?? '',
            mac: entry['mac'] as String? ?? '',
            clientKey: entry['key'] as String? ?? '',
            udn: entry['udn'] as String? ?? '',
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static void _write(Prefs prefs, List<Tv> tvs) {
    prefs.setString(
      _list,
      jsonEncode([
        for (final tv in tvs)
          {
            'id': tv.id,
            'name': tv.name,
            'ip': tv.ip,
            'mac': tv.mac,
            'key': tv.clientKey,
            'udn': tv.udn,
          },
      ]),
    );
  }

  // Random UUID-shaped id; only ever compared for equality.
  static String _newId() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
