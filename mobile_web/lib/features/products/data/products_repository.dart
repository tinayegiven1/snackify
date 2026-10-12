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
}
