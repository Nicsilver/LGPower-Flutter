// Covers spec §4's tile grid (labels + row order), the IN-STOP confirm
// sheet's accept-only send, and the Wi-Fi service menu launch with its failure
// messages. The real platform channel and TV are never touched --
// hasEmitter/transmit/link are injected fakes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/net/ir.dart';
import 'package:lgpower/net/webos_client.dart';
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

class _FakeLink implements ServiceLink {
  Result launchResult = const Success();
  // Null reads as "the TV doesn't say"
  String? foreground = factoryAppId;
  final List<ServiceMenu> launched = [];
  final List<String> keys = [];
  int closed = 0;
  int polls = 0;

  @override
  Future<Result> launch(ServiceMenu menu) async {
    launched.add(menu);
    return launchResult;
  }

  @override
  Future<Result> close() async {
    closed++;
    return const Success();
  }

  @override
  Future<String?> foregroundAppId() async {
    polls++;
    return foreground;
  }

  @override
  Future<Result> pressKey(String key) async {
    keys.add(key);
    return const Success();
  }
}

Widget _app(AppThemeController controller, _FakeIr fakeIr, _FakeLink link) {
  return AppTheme(
    controller: controller,
    child: MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ServiceRemoteScreen(
                link: link,
                hasEmitter: fakeIr.hasEmitterFn,
                transmit: fakeIr.transmitFn,
                menuPollDelay: Duration.zero,
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

// IN-START and EZ-ADJUST sit twice on an IR phone (Wi-Fi row, IR row); the IR
// copy is the later one.
Finder _tile(String label) =>
    label == 'IN-START' || label == 'EZ-ADJUST' ? find.text(label).last : find.text(label);

const _wifiStart = ValueKey('wifi-IN-START');
const _wifiEz = ValueKey('wifi-EZ-ADJUST');
const _wifiClose = ValueKey('wifi-CLOSE');

// Opens the screen and accepts the entry warning, which both phone kinds show
Future<void> _open(WidgetTester tester, AppThemeController controller, _FakeIr fakeIr, _FakeLink link) async {
  await tester.pumpWidget(_app(controller, fakeIr, link));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('I understand the risks'));
  await tester.pumpAndSettle();
}

// Lets the toast's own timer run out so the test doesn't end with it pending
Future<void> _expireToast(WidgetTester tester) => tester.pump(const Duration(seconds: 4));

void main() {
  installFakePathProvider();

  testWidgets('renders the Wi-Fi row and 22 IR tiles with the right labels/order', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    await _open(tester, controller, _FakeIr(hasEmitter: true), _FakeLink());

    expect(_tileOrder.length, 22);
    for (final label in _tileOrder) {
      expect(_tile(label), findsOneWidget, reason: 'missing tile "$label"');
    }
    expect(find.byKey(_wifiStart), findsOneWidget);
    expect(find.byKey(_wifiEz), findsOneWidget);
    expect(find.byKey(_wifiClose), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(_wifiStart)).dy,
      lessThan(tester.getTopLeft(find.text('POWER-ONLY')).dy),
      reason: 'the Wi-Fi row comes first',
    );

    // Same row -> identical y, increasing x; next row -> strictly greater y.
    Offset? prev;
    for (final label in _tileOrder) {
      final pos = tester.getTopLeft(_tile(label));
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
    await _open(tester, controller, fakeIr, _FakeLink());

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

  testWidgets('IR phone: Wi-Fi tiles launch factorywin and send no IR', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final fakeIr = _FakeIr(hasEmitter: true);
    final link = _FakeLink();
    await _open(tester, controller, fakeIr, link);

    await tester.tap(find.byKey(_wifiStart));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_wifiEz));
    await tester.pumpAndSettle();

    expect(link.launched, [ServiceMenu.inStart, ServiceMenu.ezAdjust]);
    expect(link.polls, 2);
    expect(fakeIr.sent, isEmpty);
    expect(find.textContaining("didn't open"), findsNothing);
  });

  testWidgets('IR phone keeps sending digits over IR, not the pointer', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final fakeIr = _FakeIr(hasEmitter: true);
    final link = _FakeLink();
    await _open(tester, controller, fakeIr, link);

    await tester.tap(find.text('4'));
    await tester.pumpAndSettle();

    expect(link.keys, isEmpty);
    expect(fakeIr.sent.single.$2, Ir.necPattern(Ir.lgCode(0x14)));
  });

  testWidgets('a TV that answers success but never shows the menu gets the message', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink()..foreground = 'com.webos.app.home';
    await _open(tester, controller, _FakeIr(hasEmitter: true), link);

    await tester.tap(find.byKey(_wifiStart));
    await tester.pumpAndSettle();

    expect(link.polls, 4);
    expect(find.text("Your TV didn't open the service menu over Wi-Fi. Try IR."), findsOneWidget);
    await _expireToast(tester);
  });

  testWidgets('a double tap on a Wi-Fi tile launches once', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink();
    await _open(tester, controller, _FakeIr(hasEmitter: true), link);

    await tester.tap(find.byKey(_wifiStart));
    await tester.tap(find.byKey(_wifiStart));
    await tester.tap(find.byKey(_wifiClose));
    await tester.pumpAndSettle();

    expect(link.launched, [ServiceMenu.inStart]);
    expect(link.closed, 0);
  });

  testWidgets('a foreground reply that cannot be read is not a refusal', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink()..foreground = null;
    await _open(tester, controller, _FakeIr(hasEmitter: true), link);

    await tester.tap(find.byKey(_wifiStart));
    await tester.pumpAndSettle();

    expect(find.textContaining("didn't open"), findsNothing);
  });

  testWidgets('an error from the TV shows the refusal, no reply shows unreachable, no key shows pairing', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink()..launchResult = const CmdError('404 application not found');
    await _open(tester, controller, _FakeIr(hasEmitter: true), link);

    await tester.tap(find.byKey(_wifiStart));
    await tester.pumpAndSettle();
    expect(find.text("Your TV didn't open the service menu over Wi-Fi. Try IR."), findsOneWidget);
    expect(link.polls, 0);
    await _expireToast(tester);

    link.launchResult = const CmdError('Timeout. Is the TV on and reachable?');
    await tester.tap(find.byKey(_wifiEz));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach the TV. Check it is on and on this Wi-Fi."), findsOneWidget);
    await _expireToast(tester);

    link.launchResult = const NeedsPairing();
    await tester.tap(find.byKey(_wifiStart));
    await tester.pumpAndSettle();
    expect(find.text('Accept pairing on your TV, then try again.'), findsOneWidget);
    await _expireToast(tester);
  });

  testWidgets('CLOSE MENU closes the factory app', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink();
    await _open(tester, controller, _FakeIr(hasEmitter: true), link);

    await tester.tap(find.byKey(_wifiClose));
    await tester.pumpAndSettle();

    expect(link.closed, 1);
  });

  testWidgets('no emitter: Wi-Fi tiles only, keys ride the pointer', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final fakeIr = _FakeIr(hasEmitter: false);
    final link = _FakeLink();
    await _open(tester, controller, fakeIr, link);

    expect(find.text('NO IR BLASTER'), findsNothing);
    for (final gone in ['POWER-ONLY', 'IN-STOP', 'PWR', 'FACTORY ENTRY · IR']) {
      expect(find.text(gone), findsNothing, reason: '"$gone" is IR-only');
    }
    expect(find.text('IN-START'), findsOneWidget);
    expect(find.text('EZ-ADJUST'), findsOneWidget);

    for (final label in ['0', '4', '1', '3', 'BACK', '▲', '▼', '◀', '▶', 'OK', 'EXIT']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(link.keys, ['0', '4', '1', '3', 'BACK', 'UP', 'DOWN', 'LEFT', 'RIGHT', 'ENTER', 'EXIT']);
    expect(fakeIr.sent, isEmpty);

    link.launchResult = const CmdError('404 application not found');
    await tester.tap(find.byKey(_wifiStart));
    await tester.pumpAndSettle();
    expect(find.text("Your TV didn't open the service menu over Wi-Fi."), findsOneWidget);
    await _expireToast(tester);
  });

  testWidgets('no emitter: cancelling the warning closes the screen', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    await tester.pumpWidget(_app(controller, _FakeIr(hasEmitter: false), _FakeLink()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('FACTORY CONTROLS'), findsOneWidget);
    expect(find.textContaining('Only change what you know.'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(find.text('SERVICE MODE'), findsNothing);
  });
}
