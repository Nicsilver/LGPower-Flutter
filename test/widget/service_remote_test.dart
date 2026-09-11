// Covers spec §4's tile grid (labels + row order) and the IN-STOP confirm
// sheet's accept-only send. The real platform channel is never touched --
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

void main() {
  installFakePathProvider();

  testWidgets('renders 22 tiles with the right labels/order', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final fakeIr = _FakeIr(hasEmitter: true);
    await tester.pumpWidget(_app(controller, fakeIr));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand the risks'));
    await tester.pumpAndSettle();

    expect(_tileOrder.length, 22);
    for (final label in _tileOrder) {
      expect(find.text(label), findsOneWidget, reason: 'missing tile "$label"');
    }

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

  testWidgets('IN-STOP opens a confirm sheet and only sends on accept', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final fakeIr = _FakeIr(hasEmitter: true);
    await tester.pumpWidget(_app(controller, fakeIr));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand the risks'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('IN-STOP'));
    await tester.pumpAndSettle();
    expect(find.text('CONFIRM'), findsOneWidget);
    expect(find.text('Send IN-STOP'), findsOneWidget);
    expect(fakeIr.sent, isEmpty);

    // Cancelling (tap the dimmed barrier) must not send anything.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(fakeIr.sent, isEmpty);
    expect(find.text('IN-STOP'), findsOneWidget); // back on the main grid

    await tester.tap(find.text('IN-STOP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send IN-STOP'));
    await tester.pumpAndSettle();

    expect(fakeIr.sent, hasLength(1));
    expect(fakeIr.sent.single.$1, 38000);
    expect(fakeIr.sent.single.$2, Ir.necPattern(Ir.lgCode(0xFA)));
  });

  testWidgets('no emitter shows the warning and cancelling closes the screen', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final fakeIr = _FakeIr(hasEmitter: false);
    await tester.pumpWidget(_app(controller, fakeIr));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('NO IR BLASTER'), findsOneWidget);
    expect(find.text("This phone can't transmit"), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(find.text('SERVICE MODE'), findsNothing);
  });
}
