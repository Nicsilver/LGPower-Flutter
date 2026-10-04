import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:lgpower/core/tip_service.dart';

ProductDetails fakeProduct(String id, String price) => ProductDetails(
      id: id,
      title: id,
      description: '',
      price: price,
      rawPrice: 1,
      currencyCode: 'USD',
    );

final fakeProducts = [
  // Deliberately out of order: the service sorts them small to large.
  fakeProduct('tip_large', '\$4.99'),
  fakeProduct('tip_small', '\$0.99'),
  fakeProduct('tip_medium', '\$2.99'),
];

PurchaseDetails fakePurchase(String productId, PurchaseStatus status, {bool pendingComplete = true}) {
  return PurchaseDetails(
    purchaseID: 'tx-$productId',
    productID: productId,
    verificationData: PurchaseVerificationData(
      localVerificationData: '',
      serverVerificationData: '',
      source: 'app_store',
    ),
    transactionDate: null,
    status: status,
  )..pendingCompletePurchase = pendingComplete;
}

class FakeTipStore implements TipStore {
  FakeTipStore({this.available = true, List<ProductDetails>? products})
      : products = products ?? fakeProducts;

  bool available;
  List<ProductDetails> products;
  bool buyResult = true;
  final bought = <String>[];
  final completed = <PurchaseDetails>[];
  final updates = StreamController<List<PurchaseDetails>>.broadcast();

  @override
  Stream<List<PurchaseDetails>> get purchaseUpdates => updates.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<ProductDetails>> queryProducts(Set<String> ids) async => List.of(products);

  @override
  Future<bool> buyConsumable(ProductDetails product) async {
    bought.add(product.id);
    return buyResult;
  }

  @override
  Future<void> complete(PurchaseDetails purchase) async => completed.add(purchase);
}
