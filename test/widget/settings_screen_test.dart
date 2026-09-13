// Covers spec §2's prefs-facing behaviour: switches write immediately, the
// saved-TV rows, the TV detail screen's save-on-leave, and the shortcuts
// grid's 8-item cap. Network-backed rows (Load Apps from TV, the wake-action
// picker) are exercised through injectable fakes here and against the real
// fake TV in manual verification -- WebOsClient itself is not mocked.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/core/right_pill.dart';
import 'package:lgpower/core/tv_store.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/settings/settings_screen.dart';
import 'package:lgpower/ui/settings/tv_detail_screen.dart';
import 'package:lgpower/ui/widgets/app_switch.dart';
import 'package:lgpower/ui/widgets/buttons.dart';

import 'fake_path_provider.dart';

Future<(Prefs, WebOsClient, AppThemeController)> _harness() async {
  final controller = await AppThemeController.load();
  final prefs = await Prefs.load();
  return (prefs, WebOsClient(prefs), controller);
}

Widget _app(
  WebOsClient client,
  AppThemeController controller, {
  Future<(List<TvApp>, String?)> Function()? listApps,
}) {
  return AppTheme(
    controller: controller,
    child: MaterialApp(
      home: SettingsScreen(client: client, listApps: listApps),
    ),
  );
}

void main() {
  installFakePathProvider();

  group('CONTROLS switches', () {
    testWidgets(
      'the channel-buttons switch writes the right_pill pref immediately',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final (prefs, client, controller) = await _harness();
        await tester.pumpWidget(_app(client, controller));
        await tester.pump();

        expect(RightPill.get(prefs), RightPill.brightness);
        await tester.tap(find.byType(AppSwitch).first);
        await tester.pump();

        expect(RightPill.get(prefs), RightPill.channel);
      },
    );

    testWidgets('a pre-1.35 channel switch pref still reads as channel', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'right_pill_channel': true});
      final prefs = await Prefs.load();
      expect(RightPill.get(prefs), RightPill.channel);
    });
  });

  group('Keep screen on', () {
    testWidgets('cancelling the warning sheet flips the switch back off', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller));
      await tester.pump();

      expect(prefs.keepScreenOn, isFalse);
      await tester.ensureVisible(find.text('Keep screen on'));
      await tester.tap(find.byType(AppSwitch).last);
      await tester.pumpAndSettle();

      expect(find.text('Careful with OLED screens'), findsOneWidget);
      expect(
        (tester.widget(find.byType(AppSwitch).last) as AppSwitch).value,
        isTrue,
      );

      // Tapping the barrier (top of the screen, well above the sheet) is a
      // cancel -- the switch flips back and the pref is never written.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Careful with OLED screens'), findsNothing);
      expect(
        (tester.widget(find.byType(AppSwitch).last) as AppSwitch).value,
        isFalse,
      );
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
      expect(
        (tester.widget(find.byType(AppSwitch).last) as AppSwitch).value,
        isTrue,
      );
      expect(prefs.keepScreenOn, isTrue);
    });
  });

  group('Saved TVs', () {
    testWidgets('a flat-pref install shows one migrated TV marked In use', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'tv_ip': '192.168.1.50',
        'tv_mac': 'AA:BB:CC:DD:EE:FF',
      });
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(_app(client, controller));
      await tester.pump();

      expect(find.text('LG TV'), findsOneWidget);
      expect(find.text('192.168.1.50'), findsOneWidget);
      expect(find.text('In use'), findsOneWidget);
      expect(find.text('Add a TV'), findsOneWidget);
      expect(TvStore.list(prefs).single.mac, 'AA:BB:CC:DD:EE:FF');
    });

    testWidgets(
      'the detail screen saves edits when left and hides Use this TV for the active one',
      (tester) async {
        SharedPreferences.setMockInitialValues({'tv_ip': '192.168.1.50'});
        final (prefs, client, controller) = await _harness();
        await tester.pumpWidget(_app(client, controller));
        await tester.pump();

        await tester.tap(find.text('LG TV'));
        await tester.pumpAndSettle();

        expect(find.byType(TvDetailScreen), findsOneWidget);
        expect(find.text('Use this TV'), findsNothing);
        expect(find.text('Remove this TV'), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextField, 'LG TV'),
          'Bedroom',
        );
        await tester.enterText(
          find.widgetWithText(TextField, '192.168.1.50'),
          '192.168.1.60',
        );
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.pop();
        await tester.pumpAndSettle();

        final tv = TvStore.list(prefs).single;
        expect(tv.name, 'Bedroom');
        expect(tv.ip, '192.168.1.60');
        // The active TV's edits follow into the live connection prefs.
        expect(prefs.tvIp, '192.168.1.60');
        expect(find.text('Bedroom'), findsOneWidget);
      },
    );

    testWidgets(
      'a second saved TV offers Use this TV, which switches the live prefs',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'tvs': jsonEncode([
            {
              'id': 'a',
              'name': 'Living room',
              'ip': '10.0.0.5',
              'mac': 'AA:AA:AA:AA:AA:AA',
              'key': 'ka',
              'udn': '',
            },
            {
              'id': 'b',
              'name': 'Bedroom',
              'ip': '10.0.0.6',
              'mac': 'BB:BB:BB:BB:BB:BB',
              'key': 'kb',
              'udn': '',
            },
          ]),
          'active_tv': 'a',
          'tv_ip': '10.0.0.5',
          'tv_mac': 'AA:AA:AA:AA:AA:AA',
          'client_key': 'ka',
        });
        final (prefs, client, controller) = await _harness();
        await tester.pumpWidget(_app(client, controller));
        await tester.pump();

        await tester.tap(find.text('Bedroom'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use this TV'));
        await tester.pumpAndSettle();

        expect(TvStore.activeId(prefs), 'b');
        expect(prefs.tvIp, '10.0.0.6');
        expect(prefs.clientKey, 'kb');
        expect(find.byType(SettingsScreen), findsOneWidget);
      },
    );
  });

  group('App shortcuts', () {
    testWidgets('selecting a 9th app shows the "Max 8 shortcuts" toast', (
      tester,
    ) async {
      final saved = jsonEncode([
        for (var i = 1; i <= 8; i++) {'id': 'app$i', 'title': 'App$i'},
      ]);
      SharedPreferences.setMockInitialValues({'app_shortcuts': saved});
      final (_, client, controller) = await _harness();

      Future<(List<TvApp>, String?)> fakeListApps() async =>
          ([for (var i = 1; i <= 9; i++) TvApp('app$i', 'App$i')], null);

      await tester.pumpWidget(_app(client, controller, listApps: fakeListApps));
      await tester.pump();

      // The default 800x600 test surface is shorter than the full Settings
      // scroll content -- scroll the row into view before tapping it.
      await tester.ensureVisible(find.text('Load Apps from TV'));
      await tester.tap(find.text('Load Apps from TV'));
      await tester.pump();
      await tester.pump();

      expect(find.text('App9'), findsOneWidget);
      await tester.ensureVisible(find.text('App9'));
      await tester.tap(find.text('App9'));
      await tester.pump();

      expect(find.text('Max 8 shortcuts'), findsOneWidget);
      // showToast's auto-dismiss uses a real Timer; let it fire so the test
      // doesn't end with a pending timer (flutter_test's invariant check).
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('About', () {
    testWidgets('Show the tour queues the remote leg and leaves Settings', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final (prefs, client, controller) = await _harness();
      await tester.pumpWidget(
        AppTheme(
          controller: controller,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(client: client),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Show the tour'));
      await tester.tap(find.text('Show the tour'));
      await tester.pumpAndSettle();

      expect(prefs.tourPending, isTrue);
      expect(find.byType(SettingsScreen), findsNothing);
    });
  });
}
