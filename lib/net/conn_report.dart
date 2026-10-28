import 'command_session.dart';

/// The last few session-death lines of this process, so a pasted report shows
/// how the connection behaved.
class DeathLog {
  DeathLog({this.capacity = 10, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static final DeathLog shared = DeathLog();

  final int capacity;
  final DateTime Function() _clock;
  final _entries = <DeathEntry>[];

  void add(String line) {
    _entries.add(DeathEntry(_clock(), line));
    if (_entries.length > capacity) _entries.removeRange(0, _entries.length - capacity);
  }

  List<DeathEntry> get recent => List.unmodifiable(_entries);
}

class DeathEntry {
  const DeathEntry(this.at, this.line);
  final DateTime at;
  final String line;
}

class WifiSnapshot {
  const WifiSnapshot(this.frequencyMhz, this.rssiDbm, this.linkMbps);
  final int frequencyMhz;
  final int rssiDbm;
  final int linkMbps;
}

/// What the timed TV probe found. [failure] is set when the TV part could not
/// run to the end.
class TvProbe {
  const TvProbe({
    this.failure,
    this.model,
    this.software,
    this.commandOpenMs,
    this.roundTripsMs = const [],
    this.roundTripFailures = 0,
    this.pointerOpenMs,
    this.pointerFailure,
  });

  final String? failure;
  final String? model;
  final String? software;
  final double? commandOpenMs;
  final List<double> roundTripsMs;
  final int roundTripFailures;
  final double? pointerOpenMs;
  final String? pointerFailure;
}

class ReportInputs {
  const ReportInputs({
    required this.appName,
    required this.versionName,
    required this.versionCode,
    required this.phone,
    required this.os,
    required this.wifi,
    required this.lockLine,
    required this.tv,
    required this.deaths,
    required this.now,
  });

  final String appName;
  final String versionName;
  final String versionCode;
  final String phone;
  final String os;
  final WifiSnapshot? wifi;
  final String lockLine;
  final TvProbe tv;
  final List<DeathEntry> deaths;
  final DateTime now;
}

/// Report wording is shared with the Kotlin app's report so the two read the same.
class ConnReport {
  ConnReport._();

  static String bandOf(int mhz) {
    if (mhz >= 2400 && mhz <= 2500) return '2.4 GHz';
    if (mhz >= 4900 && mhz <= 5924) return '5 GHz';
    if (mhz >= 5925 && mhz <= 7125) return '6 GHz';
    return 'unknown band ($mhz MHz)';
  }

  static String _fmt(double v) => v.toStringAsFixed(v >= 10 ? 0 : (v >= 1 ? 1 : 2));

  static String spread(List<double> values) {
    if (values.isEmpty) return 'no samples';
    final s = [...values]..sort();
    final median = s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
    return 'min ${_fmt(s.first)} / median ${_fmt(median)} / max ${_fmt(s.last)} ms';
  }

  static String _status(CmdReply reply) => switch (reply) {
        CmdReplyOk() => 'ok',
        CmdReplyErr(:final message) => 'error: $message',
        CmdReplyNeedsPairing() => 'TV is waiting for pairing',
      };

  static String tvModel(CmdReply reply) {
    if (reply is! CmdReplyOk) return 'unavailable (${_status(reply)})';
    final model = reply.payload['modelName'];
    return model is String && model.isNotEmpty ? model : 'unavailable (not reported)';
  }

  static String tvSoftware(CmdReply reply) {
    if (reply is! CmdReplyOk) return 'unavailable (${_status(reply)})';
    final p = reply.payload;
    String text(String key) => p[key] is String ? p[key] as String : '';
    final version = [text('major_ver'), text('minor_ver')].where((e) => e.isNotEmpty).join('.');
    final head = [text('product_name'), text('sw_type').toLowerCase(), version]
        .where((e) => e.isNotEmpty)
        .join(' ');
    final model = text('model_name');
    if (head.isEmpty && model.isEmpty) return 'unavailable (not reported)';
    return model.isEmpty ? head : '$head ($model)';
  }

  static String render(ReportInputs r) {
    final out = <String>[
      'Tiny TV Remote connection report',
      'App: ${r.appName} ${r.versionName} (versionCode ${r.versionCode})',
      'Phone: ${r.phone}',
      'OS: ${r.os}',
      r.wifi == null
          ? 'Wi-Fi: not connected'
          : 'Wi-Fi: ${bandOf(r.wifi!.frequencyMhz)}, RSSI ${r.wifi!.rssiDbm} dBm, '
              'link speed ${r.wifi!.linkMbps} Mbps',
      'Wi-Fi lock: ${r.lockLine}',
    ];
    final tv = r.tv;
    out.add('TV model: ${tv.model ?? 'unavailable'}');
    out.add('TV software: ${tv.software ?? 'unavailable'}');
    if (tv.failure != null) out.add('TV test failed: ${tv.failure}');
    if (tv.commandOpenMs != null) {
      out.add('Command connection: opened and registered in ${_fmt(tv.commandOpenMs!)} ms');
    }
    if (tv.roundTripsMs.isNotEmpty || tv.roundTripFailures > 0) {
      final failed = tv.roundTripFailures > 0 ? ', ${tv.roundTripFailures} failed' : '';
      out.add('Command round trips (${tv.roundTripsMs.length}$failed): ${spread(tv.roundTripsMs)}');
    }
    if (tv.pointerOpenMs != null) out.add('Pointer socket: opened in ${_fmt(tv.pointerOpenMs!)} ms');
    if (tv.pointerFailure != null) out.add('Pointer test failed: ${tv.pointerFailure}');
    if (r.deaths.isEmpty) {
      out.add('Session deaths this run: none');
    } else {
      out.add('Session deaths this run (newest last):');
      for (final d in r.deaths) {
        final secs = r.now.difference(d.at).inSeconds;
        out.add('- ${secs < 0 ? 0 : secs}s ago, ${d.line}');
      }
    }
    return out.join('\n');
  }

  /// The one place the report text leaves the app, so addresses are stripped
  /// here and nowhere else.
  static String finish(ReportInputs r) => scrubAddresses(render(r));
}
