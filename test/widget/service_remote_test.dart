// Covers the Service Menu (IR) page: spec §4's tile grid (labels + row order),
// the POWER-ONLY / IN-STOP confirm sheets' accept-only send, and that nothing
// on it touches Wi-Fi. The real platform channel is never touched --
// hasEmitter/transmit are injected fakes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/net/ir.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/settings/service_remote_screen.dart';

import 'fake_path_provider.dart';

// AppThemeController.load() reads theme_id via SharedPreferences -- without
// a mock it hits the real (unregistered) plugin channel and hangs forever
// instead of failing fast.
Future<AppThemeController> _harness() {
  SharedPreferences.setMockInitialValues({});
  return AppThemeController.load();
}

// The default test surface (800x600) is shorter than a real phone, so the
// factory-controls/IN-STOP bodies (the longest text on this screen) overflow
// the bottom sheet's half-screen height cap. A phone-shaped canvas matches
// what this screen is actually designed for.
void _setPhoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _FakeIr {
  _FakeIr({required this.hasEmitter});

  bool hasEmitter;
  final List<(int, List<int>)> sent = [];

  Future<bool> hasEmitterFn() async => hasEmitter;

  Future<void> transmitFn(int carrierHz, List<int> pattern) async {
    sent.add((carrierHz, pattern));
  }
}

Widget _app(AppThemeController controller, _FakeIr fakeIr) {
  return AppTheme(
    controller: controller,
    child: MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ServiceRemoteScreen(
                hasEmitter: fakeIr.hasEmitterFn,
                transmit: fakeIr.transmitFn,
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

// Spec §4.2's exact tile order, left-to-right within a row, top-to-bottom
// across rows (spacers excluded -- they carry no text to find).
const _tileOrder = [
  'IN-START', 'EZ-ADJUST',
  'POWER-ONLY', 'IN-STOP',
  '1', '2', '3',
  '4', '5', '6',
  '7', '8', '9',
  '0',
  'BACK', '▲', 'EXIT',
  '◀', 'OK', '▶',
  'PWR', '▼',
];

Future<void> _open(WidgetTester tester, AppThemeController controller, _FakeIr fakeIr) async {
  await tester.pumpWidget(_app(controller, fakeIr));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('I understand the risks'));
  await tester.pumpAndSettle();
}

void main() {
  installFakePathProvider();

  testWidgets('renders the 22 IR tiles with the right labels/order and no Wi-Fi buttons', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    await _open(tester, controller, _FakeIr(hasEmitter: true));

    expect(_tileOrder.length, 22);
    for (final label in _tileOrder) {
      expect(find.text(label), findsOneWidget, reason: 'missing tile "$label"');
    }
    expect(find.text('CLOSE MENU'), findsNothing);
    expect(find.text('OVER WI-FI'), findsNothing);
    expect(find.text('FACTORY ENTRY'), findsOneWidget);
    expect(find.text('MKJ39170828 REPLICA · IR ONLY'), findsOneWidget);

    // Same row -> identical y, increasing x; next row -> strictly greater y.
    Offset? prev;
    for (final label in _tileOrder) {
      final pos = tester.getTopLeft(find.text(label));
      if (prev != null) {
        final sameRow = (pos.dy - prev.dy).abs() < 0.5;
        if (sameRow) {
          expect(pos.dx, greaterThan(prev.dx), reason: '"$label" is not right of its row neighbour');
        } else {
          expect(pos.dy, greaterThan(prev.dy), reason: '"$label" is not below the previous row');
        }
      }
      prev = pos;
    }
  });

  testWidgets('every tile sends its own NEC command', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final fakeIr = _FakeIr(hasEmitter: true);
    await _open(tester, controller, fakeIr);

    const commands = {
      'IN-START': 0xFB, 'EZ-ADJUST': 0xFF,
      '1': 0x11, '2': 0x12, '3': 0x13, '4': 0x14, '5': 0x15, '6': 0x16, '7': 0x17, '8': 0x18, '9': 0x19, '0': 0x10,
      'BACK': 0x28, '▲': 0x40, 'EXIT': 0x5B, '◀': 0x07, 'OK': 0x44, '▶': 0x06, 'PWR': 0x08, '▼': 0x41,
    };
    for (final e in commands.entries) {
      await tester.tap(find.text(e.key));
      await tester.pumpAndSettle();
    }
    expect(fakeIr.sent.map((s) => s.$2).toList(), [
      for (final cmd in commands.values) Ir.necPattern(Ir.lgCode(cmd)),
    ]);
    expect(fakeIr.sent.every((s) => s.$1 == 38000), isTrue);
  });

  for (final (title, cmd) in [('POWER-ONLY', 0xFE), ('IN-STOP', 0xFA)]) {
    testWidgets('$title opens a confirm sheet and only sends on accept', (tester) async {
      _setPhoneSize(tester);
      final controller = await _harness();
      final fakeIr = _FakeIr(hasEmitter: true);
      await _open(tester, controller, fakeIr);

      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.text('CONFIRM'), findsOneWidget);
      expect(find.text('Send $title'), findsOneWidget);
      expect(fakeIr.sent, isEmpty);

      // Cancelling (tap the dimmed barrier) must not send anything.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(fakeIr.sent, isEmpty);
      expect(find.text(title), findsOneWidget); // back on the main grid

      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send $title'));
      await tester.pumpAndSettle();

      expect(fakeIr.sent, hasLength(1));
      expect(fakeIr.sent.single.$1, 38000);
      expect(fakeIr.sent.single.$2, Ir.necPattern(Ir.lgCode(cmd)));
    });
  }

  testWidgets('no emitter: the page says so and cancelling closes it', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    await tester.pumpWidget(_app(controller, _FakeIr(hasEmitter: false)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('NO IR BLASTER'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(find.text('SERVICE MODE'), findsNothing);
  });
}
