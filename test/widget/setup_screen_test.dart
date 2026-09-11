// Covers spec §1's discovery/list/pairing states up to (but not through) a
// successful pair -- `onPaired` drives real WebOsClient network calls
// (getMacFromDevice) that need a live TV, exercised instead by the manual
// verification pass against the fake TV (plan 03).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/pairing_watcher.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/setup/setup_screen.dart';

import 'fake_path_provider.dart';

class _FakePairing {
  String? watchedIp;
  void Function()? onPromptShown;
  void Function(String)? onPaired;
  bool stopped = false;

  StopPairing watch(
    String ip, {
    required void Function() onPromptShown,
    required void Function(String) onPaired,
  }) {
    watchedIp = ip;
    this.onPromptShown = onPromptShown;
    this.onPaired = onPaired;
    return () => stopped = true;
  }
}

Future<(WebOsClient, AppThemeController)> _harness() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  final controller = await AppThemeController.load();
  return (WebOsClient(prefs), controller);
}

Widget _app(WebOsClient client, AppThemeController controller, {
  required Future<List<String>> Function() discover,
  PairingWatch? pairingWatch,
}) {
  return AppTheme(
    controller: controller,
    child: MaterialApp(
      home: SetupScreen(client: client, discover: discover, pairingWatch: pairingWatch),
    ),
  );
}

void main() {
  installFakePathProvider();

  group('discovery states', () {
    testWidgets('empty result shows "No TVs found" and manual-IP entry', (tester) async {
      final (client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller, discover: () async => const []));
      await tester.pump();
      await tester.pump();

      expect(find.text('No TVs found on this network'), findsOneWidget);
      expect(find.text('Search again'), findsOneWidget);
      expect(find.text('Enter IP manually'), findsOneWidget);
    });

    testWidgets('one result shows "TV FOUND" (singular) and the row', (tester) async {
      final (client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller, discover: () async => const ['10.0.0.5']));
      await tester.pump();
      await tester.pump();

      expect(find.text('TV FOUND'), findsOneWidget);
      expect(find.text('LG TV'), findsOneWidget);
      expect(find.text('10.0.0.5'), findsOneWidget);
    });

    testWidgets('two results show "TVS FOUND" (plural)', (tester) async {
      final (client, controller) = await _harness();
      await tester.pumpWidget(
        _app(client, controller, discover: () async => const ['10.0.0.5', '10.0.0.6']),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('TVS FOUND'), findsOneWidget);
      expect(find.text('LG TV'), findsNWidgets(2));
    });
  });

  group('pairing states', () {
    testWidgets('selecting a TV shows Connecting, then the prompt message', (tester) async {
      final (client, controller) = await _harness();
      final fake = _FakePairing();
      await tester.pumpWidget(
        _app(client, controller, discover: () async => const ['10.0.0.5'], pairingWatch: fake.watch),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('LG TV'));
      await tester.pump();

      expect(find.text('Connecting…'), findsOneWidget);
      expect(fake.watchedIp, '10.0.0.5');

      fake.onPromptShown!();
      await tester.pump();

      expect(find.text('Accept the pairing prompt\non your TV to continue'), findsOneWidget);

      // Prompt shown -> the 30s pre-prompt UI timeout must be cancelled, so
      // advancing well past it must not flip to the failure state.
      await tester.pump(const Duration(seconds: 31));
      expect(find.text('Accept the pairing prompt\non your TV to continue'), findsOneWidget);
      expect(find.textContaining("Can't reach the TV"), findsNothing);
    });

    testWidgets('30s with no prompt shows the failure state with both buttons', (tester) async {
      final (client, controller) = await _harness();
      final fake = _FakePairing();
      await tester.pumpWidget(
        _app(client, controller, discover: () async => const ['10.0.0.5'], pairingWatch: fake.watch),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('LG TV'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));

      expect(
        find.text("Can't reach the TV.\nMake sure it's on, restart it,\nthen try again."),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Search again'), findsOneWidget);
      expect(fake.stopped, isTrue);
    });

    testWidgets('Enter IP manually starts pairing against the typed IP', (tester) async {
      final (client, controller) = await _harness();
      final fake = _FakePairing();
      await tester.pumpWidget(
        _app(client, controller, discover: () async => const [], pairingWatch: fake.watch),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Enter IP manually'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '10.0.2.2');
      await tester.tap(find.text('Connect'));
      // Not pumpAndSettle: the pairing screen's indeterminate spinner never
      // settles. Advance past the dialog-close transition instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(fake.watchedIp, '10.0.2.2');
      expect(find.text('10.0.2.2'), findsOneWidget);
      expect(find.text('Connecting…'), findsOneWidget);
    });
  });
}
