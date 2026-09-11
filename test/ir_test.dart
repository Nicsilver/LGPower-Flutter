// Table from port-spec-secondary-screens.md §4.2 -- every service remote
// tile's command byte and the full NEC code it should encode to.
import 'package:flutter_test/flutter_test.dart';

import 'package:lgpower/net/ir.dart';

const _codes = <String, (int cmd, int code)>{
  'IN-START': (0xFB, 0x20DFDF20),
  'EZ-ADJUST': (0xFF, 0x20DFFF00),
  'POWER-ONLY': (0xFE, 0x20DF7F80),
  'IN-STOP': (0xFA, 0x20DF5FA0),
  '1': (0x11, 0x20DF8877),
  '2': (0x12, 0x20DF48B7),
  '3': (0x13, 0x20DFC837),
  '4': (0x14, 0x20DF28D7),
  '5': (0x15, 0x20DFA857),
  '6': (0x16, 0x20DF6897),
  '7': (0x17, 0x20DFE817),
  '8': (0x18, 0x20DF18E7),
  '9': (0x19, 0x20DF9867),
  '0': (0x10, 0x20DF08F7),
  'BACK': (0x28, 0x20DF14EB),
  'UP': (0x40, 0x20DF02FD),
  'EXIT': (0x5B, 0x20DFDA25),
  'LEFT': (0x07, 0x20DFE01F),
  'OK': (0x44, 0x20DF22DD),
  'RIGHT': (0x06, 0x20DF609F),
  'PWR': (0x08, 0x20DF10EF),
  'DOWN': (0x41, 0x20DF827D),
};

void main() {
  group('Ir.lgCode', () {
    for (final entry in _codes.entries) {
      test(entry.key, () {
        expect(Ir.lgCode(entry.value.$1), entry.value.$2);
      });
    }
  });

  test('lgPowerCode matches the PWR tile', () {
    expect(Ir.lgPowerCode, 0x20DF10EF);
    expect(Ir.lgPowerCode, Ir.lgCode(0x08));
  });

  group('Ir.necPattern', () {
    test('has 68 entries: leader + 32 bits + stop', () {
      expect(Ir.necPattern(Ir.lgPowerCode).length, 68);
    });

    test('exact pulse train for the PWR code', () {
      expect(Ir.necPattern(Ir.lgPowerCode), const [
        9000, 4500, //
        562, 562, 562, 562, 562, 1687, 562, 562, //
        562, 562, 562, 562, 562, 562, 562, 562, //
        562, 1687, 562, 1687, 562, 562, 562, 1687, //
        562, 1687, 562, 1687, 562, 1687, 562, 1687, //
        562, 562, 562, 562, 562, 562, 562, 1687, //
        562, 562, 562, 562, 562, 562, 562, 562, //
        562, 1687, 562, 1687, 562, 1687, 562, 562, //
        562, 1687, 562, 1687, 562, 1687, 562, 1687, //
        562, 562,
      ]);
    });

    test('every entry after the leader is a valid NEC mark/space duration', () {
      final pattern = Ir.necPattern(Ir.lgCode(0x11));
      expect(pattern.length, 68);
      expect(pattern.sublist(0, 2), [9000, 4500]);
      expect(pattern.sublist(2, 66).every((d) => d == 562 || d == 1687), isTrue);
      expect(pattern.sublist(66), [562, 562]);
    });
  });
}
