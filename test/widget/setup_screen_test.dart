// Covers spec §1's discovery/list/pairing states up to (but not through) a
// successful pair -- `onPaired` drives real WebOsClient network calls
// (getMacFromDevice) that need a live TV, exercised instead by the manual
// verification pass against the fake TV (plan 03).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/core/tv_store.dart';
import 'package:lgpower/net/pairing_watcher.dart';
import 'package:lgpower/net/tv_discovery.dart';
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

/// Overrides the two calls the post-pairing steps make so no socket is ever
/// opened towards the fake address.
class _FakeClient extends WebOsClient {
  _FakeClient(super.prefs);

  @override
  Future<String?> getMacFromDevice() async => 'CC:CC:CC:CC:CC:CC';

  @override
  Future<(List<TvApp>, String?)> listApps() async => (
    const [
      TvApp('com.webos.app.browser', 'Web Browser'),
      TvApp('netflix', 'Netflix'),
      TvApp('youtube.leanback.v4', 'YouTube'),
      TvApp('io.strem.tv', 'Stremio'),
    ],
    null,
  );
}

Future<(WebOsClient, AppThemeController)> _harness([
  Map<String, Object> initial = const {},
]) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await Prefs.load();
  final controller = await AppThemeController.load();
  return (_FakeClient(prefs), controller);
}

List<FoundTv> _found(List<String> ips) => [
  for (final ip in ips) FoundTv(ip, null),
];

Widget _app(
  WebOsClient client,
  AppThemeController controller, {
  required Future<List<FoundTv>> Function() discover,
  PairingWatch? pairingWatch,
  bool addMode = false,
}) {
  return AppTheme(
    controller: controller,
    child: MaterialApp(
      home: SetupScreen(
        client: client,
        discover: discover,
        pairingWatch: pairingWatch,
        addMode: addMode,
        fingerprint: (_) async => null,
      ),
    ),
  );
}

void main() {
  installFakePathProvider();

  group('discovery states', () {
    testWidgets('empty result shows "No TVs found" and manual-IP entry', (
      tester,
    ) async {
      final (client, controller) = await _harness();
      await tester.pumpWidget(
        _app(client, controller, discover: () async => const []),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('No TVs found on this network'), findsOneWidget);
      expect(find.text('Search again'), findsOneWidget);
      expect(find.text('Enter IP manually'), findsOneWidget);
    });

    testWidgets('one result shows "TV FOUND" (singular) and the row', (
      tester,
    ) async {
      final (client, controller) = await _harness();
      await tester.pumpWidget(
        _app(client, controller, discover: () async => _found(['10.0.0.5'])),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('TV FOUND'), findsOneWidget);
      expect(find.text('LG TV'), findsOneWidget);
      expect(find.text('10.0.0.5'), findsOneWidget);
    });

    testWidgets('two results show "TVS FOUND" (plural)', (tester) async {
      final (client, controller) = await _harness();
      await tester.pumpWidget(
        _app(
          client,
          controller,
          discover: () async => _found(['10.0.0.5', '10.0.0.6']),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('TVS FOUND'), findsOneWidget);
      expect(find.text('LG TV'), findsNWidgets(2));
    });
  });

  group('pairing states', () {
    testWidgets('selecting a TV shows Connecting, then the prompt message', (
      tester,
    ) async {
      final (client, controller) = await _harness();
      final fake = _FakePairing();
      await tester.pumpWidget(
        _app(
          client,
          controller,
          discover: () async => _found(['10.0.0.5']),
          pairingWatch: fake.watch,
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('LG TV'));
      await tester.pump();

      expect(find.text('Connecting…'), findsOneWidget);
      expect(fake.watchedIp, '10.0.0.5');

      fake.onPromptShown!();
      await tester.pump();

      expect(
        find.text('Accept the pairing prompt\non your TV to continue'),
        findsOneWidget,
      );

      // Prompt shown -> the 30s pre-prompt UI timeout must be cancelled, so
      // advancing well past it must not flip to the failure state.
      await tester.pump(const Duration(seconds: 31));
      expect(
        find.text('Accept the pairing prompt\non your TV to continue'),
        findsOneWidget,
      );
      expect(find.textContaining("Can't reach the TV"), findsNothing);
    });

    testWidgets('30s with no prompt shows the failure state with both buttons', (
      tester,
    ) async {
      final (client, controller) = await _harness();
      final fake = _FakePairing();
      await tester.pumpWidget(
        _app(
          client,
          controller,
          discover: () async => _found(['10.0.0.5']),
          pairingWatch: fake.watch,
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('LG TV'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));

      expect(
        find.text(
          "Can't reach the TV.\nMake sure it's on, restart it,\nthen try again.",
        ),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Search again'), findsOneWidget);
      expect(fake.stopped, isTrue);
    });

    testWidgets('Enter IP manually starts pairing against the typed IP', (
      tester,
    ) async {
      final (client, controller) = await _harness();
      final fake = _FakePairing();
      await tester.pumpWidget(
        _app(
          client,
          controller,
          discover: () async => const [],
          pairingWatch: fake.watch,
        ),
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

  group('saved TVs', () {
    final saved = {
      'tvs': jsonEncode([
        {
          'id': 'a',
          'name': 'Living room',
          'ip': '10.0.0.5',
          'mac': 'AA:AA:AA:AA:AA:AA',
          'key': 'ka',
          'udn': '',
        },
      ]),
      'active_tv': 'a',
      'tv_ip': '10.0.0.5',
      'tv_mac': 'AA:AA:AA:AA:AA:AA',
      'client_key': 'ka',
    };

    testWidgets(
      'an already-saved TV is listed greyed by name and not tappable',
      (tester) async {
        final (client, controller) = await _harness(saved);
        final fake = _FakePairing();
        await tester.pumpWidget(
          _app(
            client,
            controller,
            discover: () async => _found(['10.0.0.5', '10.0.0.6']),
            pairingWatch: fake.watch,
            addMode: true,
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Add another TV'), findsOneWidget);
        expect(find.text('Living room'), findsOneWidget);
        expect(find.text('10.0.0.5 · already added'), findsOneWidget);
        expect(find.text('LG TV'), findsOneWidget);

        await tester.tap(find.text('Living room'));
        await tester.pump();
        expect(fake.watchedIp, isNull);
      },
    );

    testWidgets('add mode parks the live prefs and restores them on back-out', (
      tester,
    ) async {
      final (client, controller) = await _harness(saved);
      await tester.pumpWidget(
        _app(client, controller, discover: () async => const [], addMode: true),
      );
      await tester.pump();
      expect(client.prefs.tvIp, '');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(client.prefs.tvIp, '10.0.0.5');
      expect(client.prefs.clientKey, 'ka');
    });

    testWidgets(
      'pairing in add mode ends in the name step and saves a second TV with default shortcuts',
      (tester) async {
        final (client, controller) = await _harness(saved);
        final fake = _FakePairing();
        await tester.pumpWidget(
          _app(
            client,
            controller,
            discover: () async => _found(['10.0.0.6']),
            pairingWatch: fake.watch,
            addMode: true,
          ),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('LG TV'));
        await tester.pump();
        // The real PairingWatcher stores the key itself before reporting.
        await client.prefs.setClientKey('kb');
        fake.onPaired!('kb');
        await tester.pump();
        await tester.pump();

        expect(find.text('Connected!'), findsOneWidget);
        expect(find.text('NAME THIS TV'), findsOneWidget);
        // Second TV, so the suggested name counts up.
        expect(find.widgetWithText(TextField, 'LG TV 2'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'Bedroom');
        await tester.tap(find.text('Done'));
        await tester.pump();
        await tester.pump();

        final tvs = TvStore.list(client.prefs);
        expect(tvs.map((t) => t.name), ['Living room', 'Bedroom']);
        final added = tvs.last;
        expect(TvStore.activeId(client.prefs), added.id);
        expect(added.ip, '10.0.0.6');
        expect(added.clientKey, 'kb');
        // Popular apps first, then the rest of the launcher list minus system apps.
        expect(client.loadShortcuts().map((a) => a.title), [
          'YouTube',
          'Netflix',
          'Stremio',
        ]);
        // First-run only: adding a TV never re-queues the tour.
        expect(client.prefs.tourPending, isFalse);
      },
    );
  });
}
