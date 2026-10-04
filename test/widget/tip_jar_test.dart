import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/core/tip_service.dart';
import 'package:lgpower/net/webos_client.dart';
import 'package:lgpower/theme/theme_manager.dart';
import 'package:lgpower/ui/settings/settings_screen.dart';
import 'package:lgpower/ui/widgets/buttons.dart';

import 'fake_path_provider.dart';
import 'fake_tip_store.dart';

const _packageInfoChannel = MethodChannel('dev.fluttercommunity.plus/package_info');

Future<TipService> _pumpSettings(
  WidgetTester tester, {
  bool tipsOffered = true,
  FakeTipStore? store,
  Map<String, Object> prefValues = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefValues);
  final prefs = await Prefs.load();
  final controller = await AppThemeController.load();
  final fake = store ?? FakeTipStore();
  final service = TipService(prefs: prefs, store: fake);
  addTearDown(service.dispose);
  await service.start();

  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    AppTheme(
      controller: controller,
      child: MaterialApp(
        builder: (context, child) => TipScope(service: tipsOffered ? service : null, child: child!),
        home: SettingsScreen(client: WebOsClient(prefs)),
      ),
    ),
  );
  await tester.pump();
  await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
  await tester.pump();
  return service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  installFakePathProvider();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_packageInfoChannel, (call) async {
      if (call.method == 'getAll') {
        return <String, dynamic>{
          'appName': 'lgpower',
          'packageName': 'com.nic.lgpower.flutter',
          'version': '1.40.3',
          'buildNumber': '49',
          'buildSignature': '',
        };
      }
      return null;
    });
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('with tips on offer the header has the button and the version line', (tester) async {
    await _pumpSettings(tester);
    expect(find.text('LG Power'), findsOneWidget);
    expect(find.text('Version 1.40.3 · free, no ads'), findsOneWidget);
    expect(find.text('Leave a tip'), findsOneWidget);
    expect(find.text('Tip again'), findsNothing);
    // The version lives in the header now, not on the Release notes row.
    expect(find.text('1.40.3'), findsNothing);
  });

  testWidgets('without a tip service (Android, web) the header stays and the button goes', (tester) async {
    await _pumpSettings(tester, tipsOffered: false);
    expect(find.text('Version 1.40.3 · free, no ads'), findsOneWidget);
    expect(find.text('Leave a tip'), findsNothing);
  });

  testWidgets('a store that is unavailable hides the button rather than erroring', (tester) async {
    await _pumpSettings(tester, store: FakeTipStore(available: false));
    expect(find.text('Version 1.40.3 · free, no ads'), findsOneWidget);
    expect(find.text('Leave a tip'), findsNothing);
  });

  testWidgets('after a tip the header says thanks and the button reads Tip again', (tester) async {
    await _pumpSettings(tester, prefValues: {'has_tipped': true});
    expect(find.text('Thanks for the tip!'), findsOneWidget);
    expect(find.text('Version 1.40.3 · free, no ads'), findsNothing);
    expect(find.text('Tip again'), findsOneWidget);
    expect(find.byType(GhostButton), findsWidgets);
    expect(find.text('Leave a tip'), findsNothing);
  });

  testWidgets('the sheet lists the three store prices and the no-unlock line', (tester) async {
    await _pumpSettings(tester);
    await tester.tap(find.text('Leave a tip'));
    await tester.pumpAndSettle();

    expect(find.text('LEAVE A TIP'), findsOneWidget);
    for (final text in ['Small tip', 'Medium tip', 'Large tip', '\$0.99', '\$2.99', '\$4.99']) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.text("Doesn't unlock anything. Thanks for thinking of it."), findsOneWidget);
  });

  testWidgets('tapping a tile buys it, shows a spinner and closes on the thanks', (tester) async {
    final store = FakeTipStore();
    final service = await _pumpSettings(tester, store: store);
    await tester.tap(find.text('Leave a tip'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('\$2.99'));
    await tester.pump();
    expect(store.bought, ['tip_medium']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('\$2.99'), findsNothing);

    store.updates.add([fakePurchase('tip_medium', PurchaseStatus.purchased)]);
    await tester.pumpAndSettle();

    expect(find.text('LEAVE A TIP'), findsNothing);
    expect(service.hasTipped, isTrue);
    expect(find.text('Thanks for the tip!'), findsOneWidget);
    expect(find.text('Tip again'), findsOneWidget);
  });

  testWidgets('cancelling keeps the sheet open without a message', (tester) async {
    final store = FakeTipStore();
    await _pumpSettings(tester, store: store);
    await tester.tap(find.text('Leave a tip'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('\$0.99'));
    await tester.pump();
    store.updates.add([fakePurchase('tip_small', PurchaseStatus.canceled)]);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('\$0.99'), findsOneWidget);
    expect(find.textContaining('did not go through'), findsNothing);
  });

  testWidgets('an error toasts and leaves the tiles usable', (tester) async {
    final store = FakeTipStore();
    await _pumpSettings(tester, store: store);
    await tester.tap(find.text('Leave a tip'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('\$4.99'));
    await tester.pump();
    store.updates.add([fakePurchase('tip_large', PurchaseStatus.error)]);
    await tester.pump();

    expect(find.textContaining('did not go through'), findsOneWidget);
    expect(find.text('\$4.99'), findsOneWidget);
    // Let the toast's own timer run out.
    await tester.pump(const Duration(seconds: 4));
  });
}
