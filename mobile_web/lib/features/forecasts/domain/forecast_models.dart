import '../../auth/domain/app_user.dart';

/// Admins, accounts staff and storekeepers (who plan deliveries) see forecasts.
bool canUseForecasts(StaffRole role) =>
    role == StaffRole.admin || role == StaffRole.accounts || role == StaffRole.storekeeper;

enum ForecastStatus {
  ok,
  insufficientHistory,
  noHistory;

  static ForecastStatus fromApi(String value) => switch (value) {
    'ok' => ForecastStatus.ok,
    'insufficient_history' => ForecastStatus.insufficientHistory,
    _ => ForecastStatus.noHistory,
  };
}

/// The forecast for one product over 7 or 30 days. An estimate, not a promise of sales.
class HorizonForecast {
  const HorizonForecast({
    required this.horizonDays,
    required this.status,
    required this.predicted,
    required this.lower,
    required this.upper,
    required this.historyDays,
    required this.suggestedReorder,
  });

  factory HorizonForecast.fromJson(Map<String, dynamic> json) => HorizonForecast(
    horizonDays: json['horizonDays'] as int,
    status: ForecastStatus.fromApi(json['status'] as String),
    predicted: (json['predicted'] as num?)?.toDouble(),
    lower: json['lower'] as int?,
    upper: json['upper'] as int?,
    historyDays: json['historyDays'] as int,
    suggestedReorder: json['suggestedReorder'] as int?,
  );

  final int horizonDays;
  final ForecastStatus status;
  final double? predicted;

  /// A rough 80% range.
  final int? lower;
  final int? upper;

  /// Days of dispatch history the forecast had.
  final int historyDays;

  /// Packs to receive to cover the forecast plus safety stock.
  final int? suggestedReorder;
}

class ForecastComparison {
  const ForecastComparison({
    required this.forecastStart,
    required this.predicted,
    required this.actual,
  });

  factory ForecastComparison.fromJson(Map<String, dynamic> json) => ForecastComparison(
    forecastStart: json['forecastStart'] as String,
    predicted: (json['predicted'] as num).toDouble(),
    actual: json['actual'] as int,
  );

  final String forecastStart;
  final double predicted;
  final int actual;
}

class ProductForecast {
  const ProductForecast({
    required this.productId,
    required this.sku,
    required this.description,
    required this.onHand,
    required this.safetyStock,
    required this.week,
    required this.month,
    required this.mae,
    required this.weeksCompared,
    required this.weeksNeeded,
    required this.recent,
  });

  factory ProductForecast.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    final accuracy = json['accuracy'] as Map<String, dynamic>;
    return ProductForecast(
      productId: product['id'] as String,
      sku: product['sku'] as String,
      description: product['description'] as String,
      onHand: json['onHand'] as int,
      safetyStock: json['safetyStock'] as int,
      week: HorizonForecast.fromJson(json['week'] as Map<String, dynamic>),
      month: HorizonForecast.fromJson(json['month'] as Map<String, dynamic>),
      mae: (accuracy['mae'] as num?)?.toDouble(),
      weeksCompared: accuracy['weeksCompared'] as int,
      weeksNeeded: accuracy['needed'] as int,
      recent: [
        for (final item in accuracy['recent'] as List)
          ForecastComparison.fromJson(item as Map<String, dynamic>),
      ],
    );
  }

  final String productId;
  final String sku;
  final String description;
  final int onHand;
  final int safetyStock;
  final HorizonForecast week;
  final HorizonForecast month;

  /// Average error of past weekly forecasts, in packs; null until enough weeks have passed.
  final double? mae;
  final int weeksCompared;
  final int weeksNeeded;

  /// Past weekly forecasts against what was actually dispatched, newest first.
  final List<ForecastComparison> recent;
}

class ForecastRun {
  const ForecastRun({
    required this.forecastStart,
    required this.method,
    required this.createdAt,
    required this.createdBy,
  });

  final String forecastStart;
  final String method;
  final DateTime createdAt;
  final String createdBy;
}

class ForecastView {
  const ForecastView({required this.run, required this.products});

  factory ForecastView.fromJson(Map<String, dynamic> json) {
    final run = json['run'] as Map<String, dynamic>?;
    return ForecastView(
      run: run == null
          ? null
          : ForecastRun(
              forecastStart: run['forecastStart'] as String,
              method: run['method'] as String,
              createdAt: DateTime.parse(run['createdAt'] as String).toLocal(),
              createdBy: run['createdBy'] as String,
            ),
      products: [
        for (final item in json['products'] as List)
          ProductForecast.fromJson(item as Map<String, dynamic>),
      ],
    );
  }

  /// Null until the first forecast has been run.
  final ForecastRun? run;
  final List<ProductForecast> products;
}
