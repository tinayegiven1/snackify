import '../../../core/network/api_client.dart';
import '../domain/forecast_models.dart';

/// Sales forecasts through the backend.
class ForecastsRepository {
  ForecastsRepository(this._api);

  final ApiClient _api;

  /// The latest forecast run (with restocking suggestions and accuracy so far).
  Future<ForecastView> latest() async {
    final body = await _api.getJson('/api/v1/forecasts');
    return ForecastView.fromJson(body['forecast'] as Map<String, dynamic>);
  }

  /// Forecasts every active product from today's data, and returns the new run.
  Future<ForecastView> run() async {
    final body = await _api.postJson('/api/v1/forecasts/run');
    return ForecastView.fromJson(body['forecast'] as Map<String, dynamic>);
  }
}
