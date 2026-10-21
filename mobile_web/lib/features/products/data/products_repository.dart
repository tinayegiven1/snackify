import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../domain/product.dart';

class ProductPage {
  const ProductPage({required this.products, required this.total});

  final List<Product> products;

  /// How many products match in total (may be more than [products] holds).
  final int total;
}

/// Reads and changes the product catalogue through the backend.
class ProductsRepository {
  ProductsRepository(this._api);

  final ApiClient _api;

  /// The catalogue is small, so one page of this size normally holds everything.
  static const pageSize = 200;

  Future<ProductPage> list({String search = '', bool includeInactive = false}) async {
    final query = Uri(
      queryParameters: {
        if (search.trim().isNotEmpty) 'q': search.trim(),
        if (includeInactive) 'includeInactive': 'true',
        'limit': '$pageSize',
      },
    ).query;
    final body = await _api.getJson('/api/v1/products?$query');
    return ProductPage(
      products: (body['products'] as List)
          .map((item) => Product.fromJson(item as Map<String, dynamic>))
          .toList(),
      total: body['total'] as int,
    );
  }

  Future<Product> create(ProductInput input) async {
    final body = await _api.postJson('/api/v1/products', input.toJson());
    return Product.fromJson(body['product'] as Map<String, dynamic>);
  }

  Future<Product> update(String id, ProductInput input) async {
    final body = await _api.patchJson('/api/v1/products/$id', {
      ...input.toJson(),
      'isActive': input.isActive,
    });
    return Product.fromJson(body['product'] as Map<String, dynamic>);
  }

  Future<Product> get(String id) async {
    final body = await _api.getJson('/api/v1/products/$id');
    return Product.fromJson(body['product'] as Map<String, dynamic>);
  }

  /// Replaces the product's unit conversions, e.g. {cartonUnitId: 24} (admins).
  Future<Product> setConversions(String id, Map<String, int> baseQuantities) async {
    final body = await _api.putJson('/api/v1/products/$id/conversions', {
      'conversions': [
        for (final MapEntry(key: unitId, value: baseQuantity) in baseQuantities.entries)
          {'unitId': unitId, 'baseQuantity': baseQuantity},
      ],
    });
    return Product.fromJson(body['product'] as Map<String, dynamic>);
  }

  /// The product with exactly this barcode. Throws [ApiException] with code BARCODE_NOT_FOUND
  /// when no product has it.
  Future<Product> findByBarcode(String barcode) async {
    final body = await _api.getJson('/api/v1/products/barcode/${Uri.encodeComponent(barcode)}');
    return Product.fromJson(body['product'] as Map<String, dynamic>);
  }

  /// Gives a product without a barcode one of Snackify's own (admins only).
  Future<Product> generateBarcode(String id) async {
    final body = await _api.postJson('/api/v1/products/$id/barcode');
    return Product.fromJson(body['product'] as Map<String, dynamic>);
  }

  /// A PDF of [count] barcode labels (A4, 24 per sheet), leaving the first [skip] labels of the
  /// sheet blank (storekeepers and admins).
  Future<Uint8List> labelsPdf(String id, {required int count, int skip = 0}) => _api.getBytes(
    '/api/v1/products/$id/labels?count=$count&skip=$skip',
    accept: 'application/pdf',
  );
}
