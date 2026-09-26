import 'package:flutter_test/flutter_test.dart';

import 'package:lgpower/net/command_session.dart';
import 'package:lgpower/net/wol.dart';

void main() {
  test('getinfo yields the Wi-Fi and the wired MAC', () {
    expect(
      extractMacAddresses({
        'wifiInfo': {'macAddress': '20:3D:BD:DE:49:12'},
        'wiredInfo': {'macAddress': 'E8:5B:5B:82:6D:3C'},
      }),
      ['20:3D:BD:DE:49:12', 'E8:5B:5B:82:6D:3C'],
    );
    expect(extractMacAddresses({'wiredInfo': {'macAddress': ''}}), isEmpty);
    expect(extractMacAddresses(null), isEmpty);
  });

  test('merging keeps a hand-typed MAC and skips duplicates', () {
    expect(
      mergeMacs('20:3d:bd:de:49:12', ['20:3D:BD:DE:49:12', 'E8:5B:5B:82:6D:3C']),
      '20:3d:bd:de:49:12, E8:5B:5B:82:6D:3C',
    );
    expect(mergeMacs('', ['AA:AA:AA:AA:AA:AA']), 'AA:AA:AA:AA:AA:AA');
  });

  test('the tv_mac pref splits into single MACs', () {
    expect(macList('AA:AA:AA:AA:AA:AA, BB:BB:BB:BB:BB:BB'), hasLength(2));
    expect(macList(''), isEmpty);
  });
}
