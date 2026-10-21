import '../../../core/network/api_client.dart';
import '../domain/catalogue_models.dart';

/// Suppliers, categories, warehouses and units, through the backend.
class CatalogueRepository {
  CatalogueRepository(this._api);

  final ApiClient _api;

  Future<List<CatalogueItem>> list(CatalogueKind kind, {bool includeInactive = false}) async {
    final query = includeInactive ? '?includeInactive=true' : '';
    final body = await _api.getJson('/api/v1/${kind.path}$query');
    return (body['items'] as List)
        .map((item) => CatalogueItem.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<CatalogueItem> create(CatalogueKind kind, Map<String, Object?> fields) async {
    final body = await _api.postJson('/api/v1/${kind.path}', fields);
    return CatalogueItem.fromJson(body['item'] as Map<String, dynamic>);
  }

  Future<CatalogueItem> update(CatalogueKind kind, String id, Map<String, Object?> changes) async {
    final body = await _api.patchJson('/api/v1/${kind.path}/$id', changes);
    return CatalogueItem.fromJson(body['item'] as Map<String, dynamic>);
  }
}
