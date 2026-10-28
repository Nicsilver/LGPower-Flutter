import 'package:flutter_test/flutter_test.dart';
import 'package:lgpower/net/command_session.dart';
import 'package:lgpower/net/conn_report.dart';

ReportInputs _inputs(
  TvProbe tv, {
  WifiSnapshot? wifi = const WifiSnapshot(5180, -52, 866),
  List<DeathEntry> deaths = const [],
}) =>
    ReportInputs(
      appName: 'LG Power (Flutter)',
      versionName: '1.40.3',
      versionCode: '49',
      phone: 'Google Pixel 8',
      os: 'Android 14 (API 34)',
      wifi: wifi,
      lockLine: 'low-latency, held during the test',
      tv: tv,
      deaths: deaths,
      now: DateTime.utc(2026, 1, 1, 0, 1, 40),
    );

void main() {
  test('band from frequency', () {
    expect(ConnReport.bandOf(2437), '2.4 GHz');
    expect(ConnReport.bandOf(5180), '5 GHz');
    expect(ConnReport.bandOf(5885), '5 GHz');
    expect(ConnReport.bandOf(5955), '6 GHz');
    expect(ConnReport.bandOf(7115), '6 GHz');
    expect(ConnReport.bandOf(900), 'unknown band (900 MHz)');
  });

  test('spread uses the median for odd and even counts', () {
    expect(ConnReport.spread([20, 4, 6]), 'min 4.0 / median 6.0 / max 20 ms');
    expect(ConnReport.spread([4, 1, 3, 2]), 'min 1.0 / median 2.5 / max 4.0 ms');
    expect(ConnReport.spread([0.03, 0.02, 0.3]), 'min 0.02 / median 0.03 / max 0.30 ms');
    expect(ConnReport.spread([]), 'no samples');
  });

  test('TV model and software come from the reply payloads', () {
    expect(
      ConnReport.tvModel(const CmdReplyOk({'returnValue': true, 'modelName': 'OLED65C4PUA'})),
      'OLED65C4PUA',
    );
    expect(
      ConnReport.tvSoftware(const CmdReplyOk({
        'product_name': 'webOS',
        'model_name': 'HE_DTV_W24P_AFADATAA',
        'sw_type': 'FIRMWARE',
        'major_ver': '04',
        'minor_ver': '40.43',
      })),
      'webOS firmware 04.40.43 (HE_DTV_W24P_AFADATAA)',
    );
  });

  test('refused or missing TV calls say unavailable', () {
    expect(
      ConnReport.tvSoftware(const CmdReplyErr('401 insufficient permissions')),
      'unavailable (error: 401 insufficient permissions)',
    );
    expect(ConnReport.tvModel(const CmdReplyOk({})), 'unavailable (not reported)');
    expect(ConnReport.tvModel(const CmdReplyNeedsPairing()), 'unavailable (TV is waiting for pairing)');
  });

  test('full report has every item on its own line', () {
    final tv = TvProbe(
      model: 'OLED65C4PUA',
      software: 'webOS firmware 04.40.43',
      commandOpenMs: 183,
      roundTripsMs: [for (var i = 0; i < 10; i++) 6.0 + i],
      pointerOpenMs: 96,
    );
    final lines = ConnReport.finish(_inputs(tv, deaths: [
      DeathEntry(
        DateTime.utc(2026, 1, 1, 0, 0, 58),
        'cmd session died: cause=own close age=1ms sinceRx=never pointer=none',
      ),
    ])).split('\n');
    expect(lines.first, 'Tiny TV Remote connection report');
    expect(lines[1], 'App: LG Power (Flutter) 1.40.3 (versionCode 49)');
    expect(lines, contains('Wi-Fi: 5 GHz, RSSI -52 dBm, link speed 866 Mbps'));
    expect(lines, contains('Command connection: opened and registered in 183 ms'));
    expect(lines, contains('Command round trips (10): min 6.0 / median 11 / max 15 ms'));
    expect(
      lines,
      contains('- 42s ago, cmd session died: cause=own close age=1ms sinceRx=never pointer=none'),
    );
  });

  test('addresses are scrubbed but ordinary report lines survive', () {
    final failed = ConnReport.finish(_inputs(
      const TvProbe(failure: "Can't connect to 192.168.1.157:3001 or fe80::1:2:3"),
      wifi: null,
    ));
    expect(failed, isNot(contains('192.168')));
    expect(failed, isNot(contains('fe80')));
    expect(failed, contains("TV test failed: Can't connect to <ip> or <ip>"));
    expect(failed, contains('Wi-Fi: not connected'));

    const tv = TvProbe(
      model: 'OLED65C4PUA',
      software: 'webOS firmware 04.40.43 (HE_DTV_W24P_AFADATAA)',
      commandOpenMs: 12,
      roundTripsMs: [5],
      roundTripFailures: 2,
      pointerOpenMs: 9,
    );
    expect(ConnReport.finish(_inputs(tv)), ConnReport.render(_inputs(tv)));
  });

  test('a failed TV test still leaves the phone and Wi-Fi parts', () {
    final text = ConnReport.finish(_inputs(const TvProbe(failure: 'No TV is set up')));
    expect(text, contains('Phone: Google Pixel 8'));
    expect(text, contains('Wi-Fi: 5 GHz'));
    expect(text, contains('TV model: unavailable'));
    expect(text, contains('TV test failed: No TV is set up'));
    expect(text, endsWith('Session deaths this run: none'));
  });

  test('death log keeps only the newest ten', () {
    final log = DeathLog(capacity: 10);
    for (var i = 0; i < 14; i++) {
      log.add('line $i');
    }
    final kept = log.recent.map((e) => e.line).toList();
    expect(kept, hasLength(10));
    expect(kept.first, 'line 4');
    expect(kept.last, 'line 13');
  });
}
