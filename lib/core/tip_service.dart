import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'prefs.dart';

/// What a tip attempt ended in, for whichever sheet is open to react to.
enum TipOutcome { thanked, cancelled, failed }

/// The slice of the store the tip jar needs, so tests can stand in for StoreKit.
abstract class TipStore {
  Stream<List<PurchaseDetails>> get purchaseUpdates;
  Future<bool> isAvailable();
  Future<List<ProductDetails>> queryProducts(Set<String> ids);
  Future<bool> buyConsumable(ProductDetails product);
  Future<void> complete(PurchaseDetails purchase);
}

class StoreKitTipStore implements TipStore {
  StoreKitTipStore([InAppPurchase? iap]) : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;

  @override
  Stream<List<PurchaseDetails>> get purchaseUpdates => _iap.purchaseStream;

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Future<List<ProductDetails>> queryProducts(Set<String> ids) async {
    final response = await _iap.queryProductDetails(ids);
    return response.productDetails;
  }

  @override
  Future<bool> buyConsumable(ProductDetails product) =>
      _iap.buyConsumable(purchaseParam: PurchaseParam(productDetails: product));

  @override
  Future<void> complete(PurchaseDetails purchase) => _iap.completePurchase(purchase);
}

/// Owns the optional consumable tips. Created once at app level so the
/// purchase stream is listened to from launch: StoreKit re-delivers every
/// unfinished transaction there, and each one has to be completed or it
/// stays in the queue. Tips unlock nothing; the only state kept is a local
/// "has tipped" flag for the About header.
class TipService extends ChangeNotifier {
  TipService({required this._prefs, required this._store});

  static const productIds = ['tip_small', 'tip_medium', 'tip_large'];

  /// Play Billing can't work in the sideloaded Android build, so only iOS tips.
  static bool get platformSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  final Prefs _prefs;
  final TipStore _store;
  final _outcomes = StreamController<TipOutcome>.broadcast();
  StreamSubscription<List<PurchaseDetails>>? _sub;
  bool _loading = false;

  List<ProductDetails> _products = const [];
  String? _pendingId;

  Stream<TipOutcome> get outcomes => _outcomes.stream;

  /// Ordered small to large; empty when the store or the products are unavailable.
  List<ProductDetails> get products => _products;

  bool get canTip => _products.isNotEmpty;

  bool get hasTipped => _prefs.hasTipped;

  /// Id of the tile showing a spinner, or null.
  String? get pendingId => _pendingId;

  Future<void> start() async {
    _sub ??= _store.purchaseUpdates.listen(_onUpdates, onError: (Object _) {});
    await refresh();
  }

  Future<void> refresh() async {
    if (_loading || _products.isNotEmpty) return;
    _loading = true;
    try {
      if (!await _store.isAvailable()) return;
      final found = await _store.queryProducts(productIds.toSet());
      found.sort((a, b) => productIds.indexOf(a.id).compareTo(productIds.indexOf(b.id)));
      _products = found;
      notifyListeners();
    } catch (_) {
      // A store that can't be reached just hides the button.
    } finally {
      _loading = false;
    }
  }

  Future<void> buy(ProductDetails product) async {
    if (_pendingId != null) return;
    _pendingId = product.id;
    notifyListeners();
    try {
      if (!await _store.buyConsumable(product)) _finish(TipOutcome.failed);
    } catch (_) {
      _finish(TipOutcome.failed);
    }
  }

  void _onUpdates(List<PurchaseDetails> updates) {
    for (final purchase in updates) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          _pendingId = purchase.productID;
          notifyListeners();
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _prefs.setHasTipped(true);
          _finish(TipOutcome.thanked);
        case PurchaseStatus.canceled:
          _finish(TipOutcome.cancelled);
        case PurchaseStatus.error:
          _finish(TipOutcome.failed);
      }
      if (purchase.status != PurchaseStatus.pending && purchase.pendingCompletePurchase) {
        unawaited(_store.complete(purchase).catchError((Object _) {}));
      }
    }
  }

  void _finish(TipOutcome outcome) {
    // A transaction re-delivered at launch has no sheet waiting on it, so a
    // failure there must stay silent.
    final wasWaiting = _pendingId != null;
    _pendingId = null;
    notifyListeners();
    if (outcome == TipOutcome.thanked || wasWaiting) _outcomes.add(outcome);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _outcomes.close();
    super.dispose();
  }
}

/// Hands the app-level [TipService] to the Settings screen; null where tipping
/// isn't offered.
class TipScope extends InheritedNotifier<TipService> {
  const TipScope({super.key, required TipService? service, required super.child})
      : super(notifier: service);

  static TipService? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TipScope>()?.notifier;

  /// For initState, where subscribing to the scope isn't allowed.
  static TipService? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TipScope>()?.notifier;
}
