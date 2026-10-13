import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/bar_chart.dart';
import '../../../shared/widgets/message_view.dart';
import '../../reports/data/reports_repository.dart';
import '../../reports/domain/report_models.dart';
import '../../reports/presentation/report_widgets.dart';

/// Content width at which the low-stock list becomes a table.
const double _tableBreakpoint = 600;

/// Today at a glance (spec 6.10): dispatches, deliveries, low and expiring stock for everyone;
/// money for admins and accounts staff (the server leaves it out for other roles).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.reports});

  final ReportsRepository reports;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardSummary? _summary;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final summary = await widget.reports.dashboard();
      if (mounted) setState(() => _summary = summary);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    if (summary == null) {
      return _error != null
          ? MessageView(
              icon: Icons.cloud_off_outlined,
              title: 'Could not load the dashboard',
              message: _error!,
              action: RetryButton(onPressed: _load),
            )
          : const Center(child: CircularProgressIndicator());
    }

    final screenWidth = MediaQuery.sizeOf(context).width;
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    final money = summary.money;

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(screenWidth >= 600 ? 24 : 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null) ...[
                    ErrorBanner(message: _error!),
                    const SizedBox(height: 12),
                  ],
                  Text('Today at a glance', style: titleStyle),
                  Text(formatApiDate(summary.today), style: theme.textTheme.bodySmall),
                  const SizedBox(height: 12),
                  MetricGrid(
                    children: [
                      MetricTile(
                        icon: Icons.local_shipping_outlined,
                        label: 'Dispatched today',
                        value: '${summary.packsToday} packs',
                        caption: [
                          _count(
                            summary.dispatchesToday,
                            'confirmed dispatch',
                            'confirmed dispatches',
                          ),
                          if (summary.salesValueToday != null)
                            withCurrency(summary.salesValueToday!),
                        ].join(' · '),
                      ),
                      MetricTile(
                        icon: Icons.date_range,
                        label: 'Dispatched this week',
                        value: '${summary.packsThisWeek} packs',
                        caption: [
                          _count(
                            summary.dispatchesThisWeek,
                            'confirmed dispatch',
                            'confirmed dispatches',
                          ),
                          if (summary.salesValueThisWeek != null)
                            withCurrency(summary.salesValueThisWeek!),
                        ].join(' · '),
                      ),
                      MetricTile(
                        icon: Icons.move_to_inbox_outlined,
                        label: 'Received today',
                        value: '${summary.packsReceivedToday} packs',
                        caption: _count(summary.receiptsToday, 'delivery', 'deliveries'),
                      ),
                      MetricTile(
                        icon: Icons.inventory_2_outlined,
                        label: 'Low stock',
                        value: _count(summary.lowStockCount, 'product'),
                        caption: 'At or below their reorder level',
                        alert: summary.lowStockCount > 0,
                      ),
                      MetricTile(
                        icon: Icons.schedule,
                        label: 'Expiring soon',
                        value: _count(summary.expiringCount, 'batch', 'batches'),
                        caption: 'Expire within ${summary.expiringWithinDays} days (estimated)',
                        alert: summary.expiringCount > 0,
                      ),
                    ],
                  ),
                  if (money != null) ...[
                    const SizedBox(height: 28),
                    Text('Money', style: titleStyle),
                    Text(
                      'Each figure is counted separately: what was sold, billed and paid are '
                      'not the same thing.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    MetricGrid(
                      children: [
                        MetricTile(
                          icon: Icons.sell_outlined,
                          label: 'Sales value this month',
                          value: withCurrency(money.salesThisMonth),
                          caption: 'Confirmed dispatches at their agreed prices',
                        ),
                        MetricTile(
                          icon: Icons.receipt_long_outlined,
                          label: 'Invoiced this month',
                          value: withCurrency(money.invoicedThisMonth),
                          caption: 'Invoices issued this month',
                        ),
                        MetricTile(
                          icon: Icons.payments_outlined,
                          label: 'Payments received this month',
                          value: withCurrency(money.paymentsThisMonth),
                          caption: 'Money actually received',
                        ),
                        MetricTile(
                          icon: Icons.account_balance_wallet_outlined,
                          label: 'Owed by customers now',
                          value: withCurrency(money.owedByCustomers),
                          caption: 'Confirmed dispatches less payments, all customers',
                        ),
                        MetricTile(
                          icon: Icons.warning_amber_rounded,
                          label: 'Overdue now',
                          value: withCurrency(money.overdue),
                          caption: 'Unpaid invoices past their due date',
                          alert: money.overdue != '0.00',
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 28),
                  _TrendSection(summary: summary),
                  const SizedBox(height: 28),
                  Text('Low-stock products', style: titleStyle),
                  const SizedBox(height: 12),
                  if (summary.lowStock.isEmpty)
                    const Card(child: ListTile(title: Text('No products are low on stock.')))
                  else if (constraints.maxWidth >= _tableBreakpoint)
                    _LowStockTable(items: summary.lowStock)
                  else
                    _LowStockList(items: summary.lowStock),
                  const SizedBox(height: 28),
                  Text('Expiring soon', style: titleStyle),
                  const SizedBox(height: 12),
                  ExpiringList(batches: summary.expiring, withinDays: summary.expiringWithinDays),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "1 product", "3 products" (or the [plural] given).
  static String _count(int n, String singular, [String? plural]) =>
      '$n ${n == 1 ? singular : (plural ?? '${singular}s')}';
}

/// The last 14 days as a chart, with the same numbers available as a table.
class _TrendSection extends StatelessWidget {
  const _TrendSection({required this.summary});

  final DashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showMoney = summary.money != null;
    final days = summary.trend;
    String dayLabel(String date) {
      final d = DateTime.parse(date);
      return '${d.day}/${d.month}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          showMoney ? 'Sales value, last 14 days' : 'Packs dispatched, last 14 days',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(
          showMoney
              ? 'Confirmed dispatches at their agreed prices, in ${AppConfig.currencyCode}.'
              : 'Confirmed dispatches.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: Column(
              children: [
                BarChart(
                  bars: [
                    for (final day in days)
                      BarDatum(
                        value: showMoney
                            ? (parseCents(day.salesValue!) ?? 0) / 100
                            : day.packs.toDouble(),
                        label: dayLabel(day.date),
                        tooltip:
                            '${formatApiDate(day.date)}: ${day.packs} packs'
                            '${showMoney ? ', ${withCurrency(day.salesValue!)}' : ''}',
                      ),
                  ],
                  formatValue: (v) => showMoney ? v.toStringAsFixed(2) : v.round().toString(),
                ),
                ExpansionTile(
                  title: const Text('Show the numbers'),
                  tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final day in days.reversed)
                      ListTile(
                        dense: true,
                        title: Text(formatApiDate(day.date)),
                        trailing: Text(
                          [
                            '${day.packs} packs',
                            if (showMoney) withCurrency(day.salesValue!),
                          ].join(' · '),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Wide screens (web/desktop): a table.
class _LowStockTable extends StatelessWidget {
  const _LowStockTable({required this.items});

  final List<LowStockItem> items;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Product')),
              DataColumn(label: Text('SKU')),
              DataColumn(label: Text('On hand'), numeric: true),
              DataColumn(label: Text('Reorder level'), numeric: true),
            ],
            rows: [
              for (final item in items)
                DataRow(
                  cells: [
                    DataCell(Text(item.description)),
                    DataCell(Text(item.sku)),
                    DataCell(Text('${item.quantityOnHand}')),
                    DataCell(Text('${item.reorderLevel}')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Narrow screens (phones): touch-friendly list rows.
class _LowStockList extends StatelessWidget {
  const _LowStockList({required this.items});

  final List<LowStockItem> items;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        children: [
          for (final item in items)
            ListTile(
              title: Text(item.description),
              subtitle: Text('${item.sku} · reorder at ${item.reorderLevel}'),
              trailing: Text(
                '${item.quantityOnHand} left',
                style: TextStyle(color: colorScheme.error, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
