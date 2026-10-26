// Covers the Service Menu (Wi-Fi) page: launch/close of the factory app, every
// digit and nav key riding the pointer socket, the failure toasts, and that
// nothing IR-only (POWER-ONLY, IN-STOP, PWR) is offered. The real TV and
// platform channel are never touched.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/settings/service_menu_wifi_screen.dart';

import 'fake_path_provider.dart';

Future<AppThemeController> _harness() {
  SharedPreferences.setMockInitialValues({});
  return AppThemeController.load();
}

void _setPhoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _FakeLink implements ServiceLink {
  Result launchResult = const Success();
  final List<ServiceMenu> launched = [];
  final List<String> keys = [];
  int closed = 0;

  @override
  Future<Result> launch(ServiceMenu menu) async {
    launched.add(menu);
    // In flight long enough for a second tap to land on the busy guard
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return launchResult;
  }

  @override
  Future<Result> close() async {
    closed++;
    return const Success();
  }

  @override
  Future<Result> pressKey(String key) async {
    keys.add(key);
    return const Success();
  }
}

Widget _app(AppThemeController controller, _FakeLink link, {bool hasIr = false}) {
  return AppTheme(
    controller: controller,
    child: MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ServiceMenuWifiScreen(link: link, hasEmitter: () async => hasIr),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester, AppThemeController controller, _FakeLink link, {bool hasIr = false}) async {
  await tester.pumpWidget(_app(controller, link, hasIr: hasIr));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('I understand the risks'));
  await tester.pumpAndSettle();
}

// Lets the toast's own timer run out so the test doesn't end with it pending
Future<void> _expireToast(WidgetTester tester) => tester.pump(const Duration(seconds: 4));

void main() {
  installFakePathProvider();

  for (final hasIr in [false, true]) {
    testWidgets('${hasIr ? 'IR' : 'no-IR'} phone: same page, only Wi-Fi tiles', (tester) async {
      _setPhoneSize(tester);
      final controller = await _harness();
      await _open(tester, controller, _FakeLink(), hasIr: hasIr);

      for (final label in [
        'IN-START', 'EZ-ADJUST', 'CLOSE MENU',
        '1', '2', '3', '4', '5', '6', '7', '8', '9', '0',
        'BACK', '▲', 'EXIT', '◀\u{FE0E}', 'OK', '▶\u{FE0E}', '▼',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'missing tile "$label"');
      }
      for (final gone in ['POWER-ONLY', 'IN-STOP', 'PWR', 'FACTORY ENTRY']) {
        expect(find.text(gone), findsNothing, reason: '"$gone" is IR-only');
      }
      expect(find.text('KEYS OVER WI-FI · THE TV MUST BE ON'), findsOneWidget);
    });
  }

  testWidgets('IN-START and EZ-ADJUST launch factorywin, CLOSE MENU closes it', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink();
    await _open(tester, controller, link);

    await tester.tap(find.text('IN-START'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EZ-ADJUST'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CLOSE MENU'));
    await tester.pumpAndSettle();

    expect(link.launched, [ServiceMenu.inStart, ServiceMenu.ezAdjust]);
    expect(link.closed, 1);
  });

  testWidgets('every digit and nav key goes over the pointer socket', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink();
    await _open(tester, controller, link);

    const keys = {
      '1': '1', '2': '2', '3': '3', '4': '4', '5': '5', '6': '6', '7': '7', '8': '8', '9': '9', '0': '0',
      '▲': 'UP', '▼': 'DOWN', '◀\u{FE0E}': 'LEFT', '▶\u{FE0E}': 'RIGHT', 'OK': 'ENTER', 'BACK': 'BACK', 'EXIT': 'EXIT',
    };
    for (final label in keys.keys) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(link.keys, keys.values.toList());
  });

  testWidgets('a double tap on a launch tile launches once', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink();
    await _open(tester, controller, link);

    await tester.tap(find.text('IN-START'));
    await tester.tap(find.text('IN-START'));
    await tester.tap(find.text('CLOSE MENU'));
    await tester.pumpAndSettle();

    expect(link.launched, [ServiceMenu.inStart]);
    expect(link.closed, 0);
  });

  testWidgets('an error from the TV shows the refusal, no reply shows unreachable, no key shows pairing',
      (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink()..launchResult = const CmdError('404 application not found');
    await _open(tester, controller, link);

    await tester.tap(find.text('IN-START'));
    await tester.pumpAndSettle();
    expect(find.text("Your TV didn't open the service menu over Wi-Fi."), findsOneWidget);
    await _expireToast(tester);

    link.launchResult = const CmdError('Timeout. Is the TV on and reachable?');
    await tester.tap(find.text('EZ-ADJUST'));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach the TV. Check it is on and on this Wi-Fi."), findsOneWidget);
    await _expireToast(tester);

    link.launchResult = const NeedsPairing();
    await tester.tap(find.text('IN-START'));
    await tester.pumpAndSettle();
    expect(find.text('Accept pairing on your TV, then try again.'), findsOneWidget);
    await _expireToast(tester);
  });

  testWidgets('on an IR phone the refusal points at the IR page', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    final link = _FakeLink()..launchResult = const CmdError('404 application not found');
    await _open(tester, controller, link, hasIr: true);

    await tester.tap(find.text('IN-START'));
    await tester.pumpAndSettle();
    expect(find.text("Your TV didn't open the service menu over Wi-Fi. Try Service Menu (IR)."), findsOneWidget);
    await _expireToast(tester);
  });

  testWidgets('cancelling the warning closes the screen', (tester) async {
    _setPhoneSize(tester);
    final controller = await _harness();
    await tester.pumpWidget(_app(controller, _FakeLink()));
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
