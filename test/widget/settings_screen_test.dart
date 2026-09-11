// Covers spec §2's prefs-facing behaviour: switches write immediately, the
// IP/MAC commit-on-leave asymmetry, and the shortcuts grid's 4-item cap.
// Network-backed rows (Discover TV, Auto-detect MAC, Load Apps from TV) are
// exercised through injectable fakes here and against the real fake TV in
// manual verification (plan 03) -- WebOsClient itself is not mocked.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/settings/settings_screen.dart';
import 'package:lgpower/ui/widgets/app_switch.dart';
import 'package:lgpower/ui/widgets/buttons.dart';

import 'fake_path_provider.dart';

Future<(Prefs, WebOsClient, AppThemeController)> _harness() async {
  final controller = await AppThemeController.load();
  final prefs = await Prefs.load();
  return (prefs, WebOsClient(prefs), controller);
}

Widget _app(WebOsClient client, AppThemeController controller, {
  Future<(List<TvApp>, String?)> Function()? listApps,
}) {
  return AppTheme(
    controller: controller,
    child: MaterialApp(home: SettingsScreen(client: client, listApps: listApps)),
  );
}

void main() {
  installFakePathProvider();

  group('CONTROLS switches', () {
    testWidgets('toggling a switch writes the pref immediately', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller));
      await tester.pump();

      expect(prefs.volSlider, isTrue);
      await tester.tap(find.byType(AppSwitch).first);
      await tester.pump();

      expect(prefs.volSlider, isFalse);
    });
  });

  group('Keep screen on', () {
    testWidgets('cancelling the warning sheet flips the switch back off', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller));
      await tester.pump();

      expect(prefs.keepScreenOn, isFalse);
      await tester.ensureVisible(find.text('Keep screen on'));
      await tester.tap(find.byType(AppSwitch).last);
      await tester.pumpAndSettle();

      expect(find.text('Careful with OLED screens'), findsOneWidget);
      expect((tester.widget(find.byType(AppSwitch).last) as AppSwitch).value, isTrue);

      // Tapping the barrier (top of the screen, well above the sheet) is a
      // cancel -- the switch flips back and the pref is never written.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Careful with OLED screens'), findsNothing);
      expect((tester.widget(find.byType(AppSwitch).last) as AppSwitch).value, isFalse);
      expect(prefs.keepScreenOn, isFalse);
    });

    testWidgets('accepting the warning sheet writes the pref', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller));
      await tester.pump();

      await tester.ensureVisible(find.text('Keep screen on'));
      await tester.tap(find.byType(AppSwitch).last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(AccentButton));
      await tester.pumpAndSettle();

      expect(find.text('Careful with OLED screens'), findsNothing);
      expect((tester.widget(find.byType(AppSwitch).last) as AppSwitch).value, isTrue);
      expect(prefs.keepScreenOn, isTrue);
    });
  });

  group('IP/MAC commit-on-leave asymmetry', () {
    testWidgets('clearing the IP field does not clear the saved IP', (tester) async {
      SharedPreferences.setMockInitialValues({'tv_ip': '192.168.1.50'});
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller));
      await tester.pump();

      await tester.enterText(find.text('192.168.1.50'), '');
      // Losing focus (not just editing) is what commits (spec §2.1).
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      expect(prefs.tvIp, '192.168.1.50');
    });

    testWidgets('clearing the MAC field clears the saved MAC', (tester) async {
      SharedPreferences.setMockInitialValues({'tv_mac': 'AA:BB:CC:DD:EE:FF'});
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller));
      await tester.pump();

      await tester.enterText(find.text('AA:BB:CC:DD:EE:FF'), '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      expect(prefs.tvMac, '');
    });

    testWidgets('a non-empty IP is committed on unfocus', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, '10.0.2.2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      expect(prefs.tvIp, '10.0.2.2');
    });
  });

  group('App shortcuts', () {
    testWidgets('selecting a 5th app shows the "Max 4 shortcuts" toast', (tester) async {
      final saved = jsonEncode([
        {'id': 'app1', 'title': 'App1'},
        {'id': 'app2', 'title': 'App2'},
        {'id': 'app3', 'title': 'App3'},
        {'id': 'app4', 'title': 'App4'},
      ]);
      SharedPreferences.setMockInitialValues({'app_shortcuts': saved});
      final (_, client, controller) = await _harness();

      Future<(List<TvApp>, String?)> fakeListApps() async => (
            const [
              TvApp('app1', 'App1'),
              TvApp('app2', 'App2'),
              TvApp('app3', 'App3'),
              TvApp('app4', 'App4'),
              TvApp('app5', 'App5'),
            ],
            null,
          );

      await tester.pumpWidget(_app(client, controller, listApps: fakeListApps));
      await tester.pump();

      // The default 800x600 test surface is shorter than the full Settings
      // scroll content -- scroll the row into view before tapping it.
      await tester.ensureVisible(find.text('Load Apps from TV'));
      await tester.tap(find.text('Load Apps from TV'));
      await tester.pump();
      await tester.pump();

      expect(find.text('App5'), findsOneWidget);
      await tester.ensureVisible(find.text('App5'));
      await tester.tap(find.text('App5'));
      await tester.pump();

      expect(find.text('Max 4 shortcuts'), findsOneWidget);
      // showToast's auto-dismiss uses a real Timer; let it fire so the test
      // doesn't end with a pending timer (flutter_test's invariant check).
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
