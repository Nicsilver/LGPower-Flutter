import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lgpower/core/prefs.dart';
import 'package:lgpower/core/tip_service.dart';

import 'widget/fake_tip_store.dart';

Future<(TipService, FakeTipStore, Prefs)> _service({FakeTipStore? store}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.load();
  final fake = store ?? FakeTipStore();
  final service = TipService(prefs: prefs, store: fake);
  addTearDown(service.dispose);
  await service.start();
  return (service, fake, prefs);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('only iOS offers tipping', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(TipService.platformSupported, platform == TargetPlatform.iOS);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  group('products', () {
    test('load ordered small to large', () async {
      final (service, _, _) = await _service();
      expect(service.canTip, isTrue);
      expect(service.products.map((p) => p.id), ['tip_small', 'tip_medium', 'tip_large']);
    });

    test('an unavailable store leaves nothing to show', () async {
      final (service, _, _) = await _service(store: FakeTipStore(available: false));
      expect(service.canTip, isFalse);
    });

    test('no products found leaves nothing to show', () async {
      final (service, _, _) = await _service(store: FakeTipStore(products: const []));
      expect(service.canTip, isFalse);
    });

    test('refresh picks up products once the store comes back', () async {
      final store = FakeTipStore(available: false);
      final (service, _, _) = await _service(store: store);
      store.available = true;
      await service.refresh();
      expect(service.canTip, isTrue);
    });
  });

  group('buying', () {
    test('a purchase thanks, remembers the tip and is completed', () async {
      final (service, store, prefs) = await _service();
      final outcomes = <TipOutcome>[];
      service.outcomes.listen(outcomes.add);

      await service.buy(service.products.first);
      expect(store.bought, ['tip_small']);
      expect(service.pendingId, 'tip_small');

      final purchase = fakePurchase('tip_small', PurchaseStatus.purchased);
      store.updates.add([purchase]);
      await _settle();

      expect(service.pendingId, isNull);
      expect(prefs.hasTipped, isTrue);
      expect(service.hasTipped, isTrue);
      expect(outcomes, [TipOutcome.thanked]);
      expect(store.completed, [purchase]);
    });

    test('a deferred purchase (Ask to Buy) frees the tiles and says it is waiting', () async {
      final (service, store, prefs) = await _service();
      final outcomes = <TipOutcome>[];
      service.outcomes.listen(outcomes.add);

      await service.buy(service.products[1]);
      store.updates.add([fakePurchase('tip_medium', PurchaseStatus.pending, pendingComplete: false)]);
      await _settle();

      expect(service.pendingId, isNull);
      expect(outcomes, [TipOutcome.awaitingApproval]);
      expect(store.completed, isEmpty);
      expect(prefs.hasTipped, isFalse);

      final approved = fakePurchase('tip_medium', PurchaseStatus.purchased);
      store.updates.add([approved]);
      await _settle();
      expect(prefs.hasTipped, isTrue);
      expect(store.completed, [approved]);
    });

    test('another product landing mid-purchase leaves the spinner alone', () async {
      final (service, store, prefs) = await _service();
      final outcomes = <TipOutcome>[];
      service.outcomes.listen(outcomes.add);

      await service.buy(service.products[2]);
      final other = fakePurchase('tip_small', PurchaseStatus.purchased);
      store.updates.add([other]);
      await _settle();

      expect(service.pendingId, 'tip_large');
      expect(outcomes, isEmpty);
      expect(prefs.hasTipped, isTrue);
      expect(store.completed, [other]);
    });

    test('a second tap while one is in flight is ignored', () async {
      final (service, store, _) = await _service();
      await service.buy(service.products[0]);
      await service.buy(service.products[1]);
      expect(store.bought, ['tip_small']);
    });

    test('cancelling ends quietly without remembering a tip', () async {
      final (service, store, prefs) = await _service();
      final outcomes = <TipOutcome>[];
      service.outcomes.listen(outcomes.add);

      await service.buy(service.products.first);
      final purchase = fakePurchase('tip_small', PurchaseStatus.canceled);
      store.updates.add([purchase]);
      await _settle();

      expect(service.pendingId, isNull);
      expect(prefs.hasTipped, isFalse);
      expect(outcomes, [TipOutcome.cancelled]);
      expect(store.completed, [purchase]);
    });

    test('an error fails the attempt and is still completed', () async {
      final (service, store, prefs) = await _service();
      final outcomes = <TipOutcome>[];
      service.outcomes.listen(outcomes.add);

      await service.buy(service.products.first);
      final purchase = fakePurchase('tip_small', PurchaseStatus.error);
      store.updates.add([purchase]);
      await _settle();

      expect(service.pendingId, isNull);
      expect(prefs.hasTipped, isFalse);
      expect(outcomes, [TipOutcome.failed]);
      expect(store.completed, [purchase]);
    });

    test('a store that refuses to start the purchase fails it', () async {
      final (service, store, _) = await _service();
      store.buyResult = false;
      final outcomes = <TipOutcome>[];
      service.outcomes.listen(outcomes.add);

      await service.buy(service.products.first);
      await _settle();

      expect(service.pendingId, isNull);
      expect(outcomes, [TipOutcome.failed]);
    });
  });

  group('transactions nobody is waiting on', () {
    test('a re-delivered purchase is credited and completed', () async {
      final (service, store, prefs) = await _service();
      final purchase = fakePurchase('tip_large', PurchaseStatus.restored);
      store.updates.add([purchase]);
      await _settle();

      expect(prefs.hasTipped, isTrue);
      expect(service.hasTipped, isTrue);
      expect(store.completed, [purchase]);
    });

    test('a re-delivered failure is completed without any message', () async {
      final (service, store, _) = await _service();
      final outcomes = <TipOutcome>[];
      service.outcomes.listen(outcomes.add);

      final purchase = fakePurchase('tip_small', PurchaseStatus.error);
      store.updates.add([purchase]);
      await _settle();

      expect(outcomes, isEmpty);
      expect(store.completed, [purchase]);
    });
  });

  test('the tipped flag survives a new service', () async {
    final (_, store, prefs) = await _service();
    store.updates.add([fakePurchase('tip_small', PurchaseStatus.purchased)]);
    await _settle();

    final again = TipService(prefs: prefs, store: FakeTipStore());
    addTearDown(again.dispose);
    expect(again.hasTipped, isTrue);
  });
}
