import '../../../core/network/api_client.dart';
import '../domain/report_models.dart';

/// Reports and the dashboard, through the backend.
class ReportsRepository {
  ReportsRepository(this._api);

  final ApiClient _api;

  String _query(Map<String, String> parameters) => Uri(queryParameters: parameters).query;

  Future<DashboardSummary> dashboard() async {
    final body = await _api.getJson('/api/v1/reports/dashboard');
    return DashboardSummary.fromJson(body['dashboard'] as Map<String, dynamic>);
  }

  Future<SalesReport> sales(ReportRange range, GroupBy groupBy) async {
    final body = await _api.getJson(
      '/api/v1/reports/sales?${_query({...range.toQuery(), 'groupBy': groupBy.name})}',
    );
    return SalesReport.fromJson(body);
  }

  /// Best sellers, by value or by packs.
  Future<List<ProductSales>> products(ReportRange range, {required bool byPacks}) async {
    final body = await _api.getJson(
      '/api/v1/reports/products?${_query({...range.toQuery(), 'sortBy': byPacks ? 'packs' : 'value'})}',
    );
    return [
      for (final item in body['products'] as List)
        ProductSales.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<List<CustomerSummary>> customers(ReportRange range) async {
    final body = await _api.getJson('/api/v1/reports/customers?${_query(range.toQuery())}');
    return [
      for (final item in body['customers'] as List)
        CustomerSummary.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<({List<ProductReceived> products, int receipts, int packs})> stockReceived(
    ReportRange range,
  ) async {
    final body = await _api.getJson('/api/v1/reports/stock-received?${_query(range.toQuery())}');
    final totals = body['totals'] as Map<String, dynamic>;
    return (
      products: [
        for (final item in body['products'] as List)
          ProductReceived.fromJson(item as Map<String, dynamic>),
      ],
      receipts: totals['receipts'] as int,
      packs: totals['packs'] as int,
    );
  }

  Future<List<ExpiringBatch>> expiring({int days = 30}) async {
    final body = await _api.getJson('/api/v1/reports/expiring?days=$days');
    return [
      for (final item in body['batches'] as List)
        ExpiringBatch.fromJson(item as Map<String, dynamic>),
    ];
  }
}
