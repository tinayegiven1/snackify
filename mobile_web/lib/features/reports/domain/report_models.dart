import '../../auth/domain/app_user.dart';

/// Sales, product and customer reports: admins and accounts staff (spec section 5).
bool canSeeFinancialReports(StaffRole role) =>
    role == StaffRole.admin || role == StaffRole.accounts;

/// Stock reports (received, expiring): also storekeepers.
bool canSeeStockReports(StaffRole role) =>
    canSeeFinancialReports(role) || role == StaffRole.storekeeper;

enum GroupBy {
  day('Day'),
  week('Week'),
  month('Month');

  const GroupBy(this.label);

  final String label;
}

/// A date range, both dates included, as API dates ("2026-10-12").
class ReportRange {
  const ReportRange(this.from, this.to);

  final String from;
  final String to;

  Map<String, String> toQuery() => {'from': from, 'to': to};

  @override
  bool operator ==(Object other) => other is ReportRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// The separate money and quantity measures of the sales report (never added together).
class SalesMeasures {
  const SalesMeasures({
    required this.dispatches,
    required this.packs,
    required this.salesValue,
    required this.invoiced,
    required this.paymentsReceived,
  });

  factory SalesMeasures.fromJson(Map<String, dynamic> json) => SalesMeasures(
    dispatches: json['dispatches'] as int,
    packs: json['packs'] as int,
    salesValue: json['salesValue'] as String,
    invoiced: json['invoiced'] as String,
    paymentsReceived: json['paymentsReceived'] as String,
  );

  final int dispatches;
  final int packs;

  /// Confirmed dispatches at their agreed prices.
  final String salesValue;

  /// Issued invoices.
  final String invoiced;

  /// Payments that have not been voided.
  final String paymentsReceived;
}

class SalesPeriod {
  const SalesPeriod({required this.start, required this.end, required this.measures});

  factory SalesPeriod.fromJson(Map<String, dynamic> json) => SalesPeriod(
    start: json['start'] as String,
    end: json['end'] as String,
    measures: SalesMeasures.fromJson(json),
  );

  final String start;
  final String end;
  final SalesMeasures measures;
}

class SalesReport {
  const SalesReport({
    required this.range,
    required this.groupBy,
    required this.totals,
    required this.periods,
  });

  factory SalesReport.fromJson(Map<String, dynamic> json) => SalesReport(
    range: ReportRange(json['from'] as String, json['to'] as String),
    groupBy: GroupBy.values.byName(json['groupBy'] as String),
    totals: SalesMeasures.fromJson(json['totals'] as Map<String, dynamic>),
    periods: [
      for (final item in json['periods'] as List)
        SalesPeriod.fromJson(item as Map<String, dynamic>),
    ],
  );

  final ReportRange range;
  final GroupBy groupBy;
  final SalesMeasures totals;
  final List<SalesPeriod> periods;
}

class ProductSales {
  const ProductSales({
    required this.description,
    required this.sku,
    required this.dispatches,
    required this.packs,
    required this.salesValue,
  });

  factory ProductSales.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    return ProductSales(
      description: product['description'] as String,
      sku: product['sku'] as String,
      dispatches: json['dispatches'] as int,
      packs: json['packs'] as int,
      salesValue: json['salesValue'] as String,
    );
  }

  final String description;
  final String sku;
  final int dispatches;
  final int packs;
  final String salesValue;
}

class CustomerSummary {
  const CustomerSummary({
    required this.code,
    required this.name,
    required this.dispatches,
    required this.packs,
    required this.salesValue,
    required this.invoiced,
    required this.paymentsReceived,
    required this.balanceNow,
  });

  factory CustomerSummary.fromJson(Map<String, dynamic> json) {
    final customer = json['customer'] as Map<String, dynamic>;
    return CustomerSummary(
      code: customer['code'] as String,
      name: customer['name'] as String,
      dispatches: json['dispatches'] as int,
      packs: json['packs'] as int,
      salesValue: json['salesValue'] as String,
      invoiced: json['invoiced'] as String,
      paymentsReceived: json['paymentsReceived'] as String,
      balanceNow: json['balanceNow'] as String,
    );
  }

  final String code;
  final String name;
  final int dispatches;
  final int packs;
  final String salesValue;
  final String invoiced;
  final String paymentsReceived;

  /// What they owe now, whatever the period; negative when in credit.
  final String balanceNow;
}

class ProductReceived {
  const ProductReceived({
    required this.description,
    required this.sku,
    required this.receipts,
    required this.packs,
  });

  factory ProductReceived.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    return ProductReceived(
      description: product['description'] as String,
      sku: product['sku'] as String,
      receipts: json['receipts'] as int,
      packs: json['packs'] as int,
    );
  }

  final String description;
  final String sku;
  final int receipts;
  final int packs;
}

/// A delivery near or past its expiry date that probably still has packs on the shelf.
class ExpiringBatch {
  const ExpiringBatch({
    required this.description,
    required this.batchNumber,
    required this.expiryDate,
    required this.daysToExpiry,
    required this.estimatedPacksLeft,
  });

  factory ExpiringBatch.fromJson(Map<String, dynamic> json) => ExpiringBatch(
    description: (json['product'] as Map<String, dynamic>)['description'] as String,
    batchNumber: json['batchNumber'] as String?,
    expiryDate: json['expiryDate'] as String,
    daysToExpiry: json['daysToExpiry'] as int,
    estimatedPacksLeft: json['estimatedPacksLeft'] as int,
  );

  final String description;
  final String? batchNumber;
  final String expiryDate;

  /// Negative once expired.
  final int daysToExpiry;

  /// An estimate: stock is assumed to leave oldest first.
  final int estimatedPacksLeft;

  bool get expired => daysToExpiry < 0;
}

class LowStockItem {
  const LowStockItem({
    required this.description,
    required this.sku,
    required this.quantityOnHand,
    required this.reorderLevel,
  });

  factory LowStockItem.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    return LowStockItem(
      description: product['description'] as String,
      sku: product['sku'] as String,
      quantityOnHand: json['quantityOnHand'] as int,
      reorderLevel: json['reorderLevel'] as int,
    );
  }

  final String description;
  final String sku;
  final int quantityOnHand;
  final int reorderLevel;
}

/// Money measures on the dashboard (admins and accounts staff only).
class DashboardMoney {
  const DashboardMoney({
    required this.salesThisMonth,
    required this.invoicedThisMonth,
    required this.paymentsThisMonth,
    required this.owedByCustomers,
    required this.overdue,
  });

  factory DashboardMoney.fromJson(Map<String, dynamic> json) => DashboardMoney(
    salesThisMonth: json['salesThisMonth'] as String,
    invoicedThisMonth: json['invoicedThisMonth'] as String,
    paymentsThisMonth: json['paymentsThisMonth'] as String,
    owedByCustomers: json['owedByCustomers'] as String,
    overdue: json['overdue'] as String,
  );

  final String salesThisMonth;
  final String invoicedThisMonth;
  final String paymentsThisMonth;
  final String owedByCustomers;
  final String overdue;
}

class DashboardSummary {
  const DashboardSummary({
    required this.today,
    required this.dispatchesToday,
    required this.packsToday,
    required this.salesValueToday,
    required this.dispatchesThisWeek,
    required this.packsThisWeek,
    required this.salesValueThisWeek,
    required this.receiptsToday,
    required this.packsReceivedToday,
    required this.lowStockCount,
    required this.lowStock,
    required this.expiringWithinDays,
    required this.expiringCount,
    required this.expiring,
    required this.money,
    required this.trend,
  });

  factory DashboardSummary.fromJson(Map<String, dynamic> json) {
    final today = json['dispatchesToday'] as Map<String, dynamic>;
    final week = json['dispatchesThisWeek'] as Map<String, dynamic>;
    final received = json['receivedToday'] as Map<String, dynamic>;
    final low = json['lowStock'] as Map<String, dynamic>;
    final expiring = json['expiring'] as Map<String, dynamic>;
    return DashboardSummary(
      today: json['today'] as String,
      dispatchesToday: today['dispatches'] as int,
      packsToday: today['packs'] as int,
      salesValueToday: today['salesValue'] as String?,
      dispatchesThisWeek: week['dispatches'] as int,
      packsThisWeek: week['packs'] as int,
      salesValueThisWeek: week['salesValue'] as String?,
      receiptsToday: received['receipts'] as int,
      packsReceivedToday: received['packs'] as int,
      lowStockCount: low['count'] as int,
      lowStock: [
        for (final item in low['products'] as List)
          LowStockItem.fromJson(item as Map<String, dynamic>),
      ],
      expiringWithinDays: expiring['withinDays'] as int,
      expiringCount: expiring['count'] as int,
      expiring: [
        for (final item in expiring['batches'] as List)
          ExpiringBatch.fromJson(item as Map<String, dynamic>),
      ],
      money: json['money'] == null
          ? null
          : DashboardMoney.fromJson(json['money'] as Map<String, dynamic>),
      trend: [
        for (final item in json['trend'] as List)
          (
            date: (item as Map<String, dynamic>)['date'] as String,
            packs: item['packs'] as int,
            salesValue: item['salesValue'] as String?,
          ),
      ],
    );
  }

  final String today;
  final int dispatchesToday;
  final int packsToday;

  /// Null for roles that do not see money.
  final String? salesValueToday;
  final int dispatchesThisWeek;
  final int packsThisWeek;
  final String? salesValueThisWeek;
  final int receiptsToday;
  final int packsReceivedToday;
  final int lowStockCount;
  final List<LowStockItem> lowStock;
  final int expiringWithinDays;
  final int expiringCount;
  final List<ExpiringBatch> expiring;
  final DashboardMoney? money;

  /// The last 14 days, oldest first.
  final List<({String date, int packs, String? salesValue})> trend;
}
