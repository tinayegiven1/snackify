import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/bar_chart.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/reports_repository.dart';
import '../domain/report_models.dart';
import 'report_widgets.dart';

/// Content width at which lists become tables.
const double _tableBreakpoint = 640;

enum _Preset {
  last7('Last 7 days'),
  last30('Last 30 days'),
  thisMonth('This month'),
  lastMonth('Last month'),
  last3Months('Last 3 months'),
  thisYear('This year'),
  custom('Choose dates…');

  const _Preset(this.label);

  final String label;

  ReportRange? range() {
    final now = today();
    final todayText = toApiDate(now);
    switch (this) {
      case _Preset.last7:
        return ReportRange(toApiDate(now.subtract(const Duration(days: 6))), todayText);
      case _Preset.last30:
        return ReportRange(toApiDate(now.subtract(const Duration(days: 29))), todayText);
      case _Preset.thisMonth:
        return ReportRange(toApiDate(DateTime(now.year, now.month)), todayText);
      case _Preset.lastMonth:
        return ReportRange(
          toApiDate(DateTime(now.year, now.month - 1)),
          toApiDate(DateTime(now.year, now.month, 0)),
        );
      case _Preset.last3Months:
        return ReportRange(toApiDate(DateTime(now.year, now.month - 2)), todayText);
      case _Preset.thisYear:
        return ReportRange(toApiDate(DateTime(now.year)), todayText);
      case _Preset.custom:
        return null;
    }
  }
}

/// Reports (spec 6.10) for a chosen period. Admins and accounts staff see sales, products,
/// customers and stock; storekeepers see stock.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.reports, required this.financial});

  final ReportsRepository reports;

  /// Whether the sales, products and customers reports are shown.
  final bool financial;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  _Preset _preset = _Preset.last30;
  ReportRange _range = _Preset.last30.range()!;

  Future<void> _choose(_Preset? preset) async {
    if (preset == null) return;
    var range = preset.range();
    if (range == null) {
      final picked = await showDateRangePicker(
        context: context,
        firstDate: today().subtract(const Duration(days: 730)),
        lastDate: today(),
        initialDateRange: DateTimeRange(
          start: DateTime.parse(_range.from),
          end: DateTime.parse(_range.to),
        ),
        helpText: 'Report period',
      );
      if (picked == null) return;
      range = ReportRange(toApiDate(picked.start), toApiDate(picked.end));
    }
    setState(() {
      _preset = preset;
      _range = range!;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      if (widget.financial) ...[
        (
          'Sales',
          _SalesTab(key: ValueKey(('sales', _range)), reports: widget.reports, range: _range),
        ),
        (
          'Products',
          _ProductsTab(key: ValueKey(('products', _range)), reports: widget.reports, range: _range),
        ),
        (
          'Customers',
          _CustomersTab(
            key: ValueKey(('customers', _range)),
            reports: widget.reports,
            range: _range,
          ),
        ),
      ],
      (
        'Stock',
        _StockTab(key: ValueKey(('stock', _range)), reports: widget.reports, range: _range),
      ),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<_Preset>(
                  value: _preset,
                  onChanged: _choose,
                  items: [
                    for (final preset in _Preset.values)
                      DropdownMenuItem(value: preset, child: Text(preset.label)),
                  ],
                ),
                Text(
                  formatApiPeriod(_range.from, _range.to),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          if (tabs.length > 1)
            TabBar(
              // Narrow padding, so four tabs fit across a phone without cutting a label.
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              tabs: [for (final (label, _) in tabs) Tab(text: label)],
            ),
          Expanded(child: TabBarView(children: [for (final (_, tab) in tabs) tab])),
        ],
      ),
    );
  }
}

/// Loads a report and shows loading, error and empty states around it.
class _ReportLoader<T> extends StatefulWidget {
  const _ReportLoader({required this.load, required this.builder, required this.title});

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;

  /// For the error message, e.g. "the sales report".
  final String title;

  @override
  State<_ReportLoader<T>> createState() => _ReportLoaderState<T>();
}

class _ReportLoaderState<T> extends State<_ReportLoader<T>> {
  T? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didUpdateWidget(covariant _ReportLoader<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.load != widget.load) _run();
  }

  Future<void> _run() async {
    setState(() => _error = null);
    try {
      final data = await widget.load();
      if (mounted) setState(() => _data = data);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.fieldErrors.values.firstOrNull ?? error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load ${widget.title}',
        message: _error!,
        action: RetryButton(onPressed: _run),
      );
    }
    final data = _data;
    if (data == null) return const Center(child: CircularProgressIndicator());
    return widget.builder(context, data);
  }
}

Widget _page(List<Widget> children) => ListView(
  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
  children: [
    Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    ),
  ],
);

Widget _heading(BuildContext context, String title, [String? note]) => Padding(
  padding: const EdgeInsets.only(top: 20, bottom: 8),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      if (note != null) Text(note, style: Theme.of(context).textTheme.bodySmall),
    ],
  ),
);

String _count(int n, String singular, String plural) => '$n ${n == 1 ? singular : plural}';

// ------------------------------------------------------------------------------- Sales

class _SalesTab extends StatefulWidget {
  const _SalesTab({super.key, required this.reports, required this.range});

  final ReportsRepository reports;
  final ReportRange range;

  @override
  State<_SalesTab> createState() => _SalesTabState();
}

class _SalesTabState extends State<_SalesTab> {
  late GroupBy _groupBy =
      DateTime.parse(widget.range.to).difference(DateTime.parse(widget.range.from)).inDays > 62
      ? GroupBy.week
      : GroupBy.day;
  late Future<SalesReport> Function() _load = _loader();

  Future<SalesReport> Function() _loader() {
    final groupBy = _groupBy;
    return () => widget.reports.sales(widget.range, groupBy);
  }

  String _periodLabel(SalesPeriod period, GroupBy groupBy) => switch (groupBy) {
    GroupBy.day => formatApiDate(period.start),
    GroupBy.week => formatApiPeriod(period.start, period.end),
    GroupBy.month => formatApiPeriod(period.start, period.end),
  };

  String _axisLabel(SalesPeriod period, GroupBy groupBy) {
    final start = DateTime.parse(period.start);
    if (groupBy == GroupBy.month) {
      return formatApiDate(period.start).split(' ')[1];
    }
    return '${start.day}/${start.month}';
  }

  @override
  Widget build(BuildContext context) {
    return _ReportLoader<SalesReport>(
      title: 'the sales report',
      load: _load,
      builder: (context, report) {
        final totals = report.totals;
        return _page([
          SegmentedButton<GroupBy>(
            segments: [
              for (final g in GroupBy.values)
                ButtonSegment(value: g, label: Text('By ${g.label.toLowerCase()}')),
            ],
            selected: {_groupBy},
            onSelectionChanged: (selection) => setState(() {
              _groupBy = selection.first;
              _load = _loader();
            }),
          ),
          const SizedBox(height: 12),
          MetricGrid(
            children: [
              MetricTile(
                icon: Icons.sell_outlined,
                label: 'Sales value',
                value: withCurrency(totals.salesValue),
                caption: 'Confirmed dispatches at their agreed prices',
              ),
              MetricTile(
                icon: Icons.local_shipping_outlined,
                label: 'Packs dispatched',
                value: '${totals.packs}',
                caption: _count(totals.dispatches, 'confirmed dispatch', 'confirmed dispatches'),
              ),
              MetricTile(
                icon: Icons.receipt_long_outlined,
                label: 'Invoiced',
                value: withCurrency(totals.invoiced),
                caption: 'Invoices issued in the period',
              ),
              MetricTile(
                icon: Icons.payments_outlined,
                label: 'Payments received',
                value: withCurrency(totals.paymentsReceived),
                caption: 'Money received in the period',
              ),
            ],
          ),
          _heading(
            context,
            'Sales value by ${report.groupBy.label.toLowerCase()}',
            'Confirmed dispatches at their agreed prices. The table below has every figure.',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
              child: BarChart(
                bars: [
                  for (final period in report.periods)
                    BarDatum(
                      value: (parseCents(period.measures.salesValue) ?? 0) / 100,
                      label: _axisLabel(period, report.groupBy),
                      tooltip:
                          '${_periodLabel(period, report.groupBy)}: '
                          '${withCurrency(period.measures.salesValue)}, '
                          '${period.measures.packs} packs',
                    ),
                ],
                formatValue: (v) => v.toStringAsFixed(2),
              ),
            ),
          ),
          _heading(context, 'Figures by ${report.groupBy.label.toLowerCase()}'),
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= _tableBreakpoint
                ? Card(
                    clipBehavior: Clip.antiAlias,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Period')),
                          DataColumn(label: Text('Sales value'), numeric: true),
                          DataColumn(label: Text('Packs'), numeric: true),
                          DataColumn(label: Text('Invoiced'), numeric: true),
                          DataColumn(label: Text('Payments received'), numeric: true),
                        ],
                        rows: [
                          for (final p in report.periods)
                            DataRow(
                              cells: [
                                DataCell(Text(_periodLabel(p, report.groupBy))),
                                DataCell(Text(withCurrency(p.measures.salesValue))),
                                DataCell(Text('${p.measures.packs}')),
                                DataCell(Text(withCurrency(p.measures.invoiced))),
                                DataCell(Text(withCurrency(p.measures.paymentsReceived))),
                              ],
                            ),
                        ],
                      ),
                    ),
                  )
                : Card(
                    child: Column(
                      children: [
                        for (final p in report.periods)
                          ListTile(
                            dense: true,
                            title: Text(_periodLabel(p, report.groupBy)),
                            subtitle: Text(
                              '${p.measures.packs} packs · invoiced '
                              '${withCurrency(p.measures.invoiced)} · paid '
                              '${withCurrency(p.measures.paymentsReceived)}',
                            ),
                            trailing: Text(withCurrency(p.measures.salesValue)),
                          ),
                      ],
                    ),
                  ),
          ),
        ]);
      },
    );
  }
}

// ---------------------------------------------------------------------------- Products

class _ProductsTab extends StatefulWidget {
  const _ProductsTab({super.key, required this.reports, required this.range});

  final ReportsRepository reports;
  final ReportRange range;

  @override
  State<_ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends State<_ProductsTab> {
  bool _byPacks = false;
  late Future<List<ProductSales>> Function() _load = _loader();

  Future<List<ProductSales>> Function() _loader() {
    final byPacks = _byPacks;
    return () => widget.reports.products(widget.range, byPacks: byPacks);
  }

  @override
  Widget build(BuildContext context) {
    return _ReportLoader<List<ProductSales>>(
      title: 'the products report',
      load: _load,
      builder: (context, products) {
        final theme = Theme.of(context);
        final top = products.isEmpty
            ? 1.0
            : products
                  .map((p) => _byPacks ? p.packs.toDouble() : (parseCents(p.salesValue) ?? 0) / 100)
                  .reduce((a, b) => a > b ? a : b);
        return _page([
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('By value')),
              ButtonSegment(value: true, label: Text('By packs')),
            ],
            selected: {_byPacks},
            onSelectionChanged: (selection) => setState(() {
              _byPacks = selection.first;
              _load = _loader();
            }),
          ),
          _heading(
            context,
            'Best-selling products',
            'Confirmed dispatches in the period, ${_byPacks ? 'most packs' : 'highest value'} first.',
          ),
          if (products.isEmpty)
            const Card(child: ListTile(title: Text('Nothing was dispatched in this period.')))
          else
            Card(
              child: Column(
                children: [
                  for (final (index, p) in products.indexed)
                    ListTile(
                      leading: CircleAvatar(radius: 14, child: Text('${index + 1}')),
                      title: Text(p.description),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${p.packs} packs · '
                            '${_count(p.dispatches, 'dispatch', 'dispatches')} · ${p.sku}',
                          ),
                          const SizedBox(height: 4),
                          // The share of the best seller, as a thin bar.
                          LayoutBuilder(
                            builder: (context, constraints) => Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                height: 6,
                                width:
                                    constraints.maxWidth *
                                    ((_byPacks
                                                ? p.packs.toDouble()
                                                : (parseCents(p.salesValue) ?? 0) / 100) /
                                            (top == 0 ? 1 : top))
                                        .clamp(0.0, 1.0),
                                decoration: const BoxDecoration(
                                  color: SnackifyColors.chart,
                                  borderRadius: BorderRadius.horizontal(right: Radius.circular(4)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      trailing: Text(withCurrency(p.salesValue), style: theme.textTheme.titleSmall),
                    ),
                ],
              ),
            ),
        ]);
      },
    );
  }
}

// --------------------------------------------------------------------------- Customers

class _CustomersTab extends StatelessWidget {
  const _CustomersTab({super.key, required this.reports, required this.range});

  final ReportsRepository reports;
  final ReportRange range;

  @override
  Widget build(BuildContext context) {
    return _ReportLoader<List<CustomerSummary>>(
      title: 'the customers report',
      load: () => reports.customers(range),
      builder: (context, customers) => _page([
        _heading(
          context,
          'Customer sales',
          'Sales value (confirmed dispatches), invoiced and paid are counted in the period; '
              '"owes now" is today\'s balance, whatever the period.',
        ),
        if (customers.isEmpty)
          const Card(child: ListTile(title: Text('No customer activity in this period.')))
        else
          Card(
            child: Column(
              children: [
                for (final c in customers)
                  ListTile(
                    title: Text('${c.name} (${c.code})'),
                    subtitle: Text(
                      '${c.packs} packs · invoiced ${withCurrency(c.invoiced)} · paid '
                      '${withCurrency(c.paymentsReceived)} · '
                      '${c.balanceNow.startsWith('-') ? 'in credit ${withCurrency(c.balanceNow.substring(1))}' : 'owes now ${withCurrency(c.balanceNow)}'}',
                    ),
                    trailing: Text(withCurrency(c.salesValue)),
                  ),
              ],
            ),
          ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------- Stock

class _StockTab extends StatefulWidget {
  const _StockTab({super.key, required this.reports, required this.range});

  final ReportsRepository reports;
  final ReportRange range;

  @override
  State<_StockTab> createState() => _StockTabState();
}

class _StockTabState extends State<_StockTab> {
  int _expiryDays = 30;
  late Future<_StockData> Function() _load = _loader();

  Future<_StockData> Function() _loader() {
    final days = _expiryDays;
    return () async => (
      received: await widget.reports.stockReceived(widget.range),
      expiring: await widget.reports.expiring(days: days),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _ReportLoader<_StockData>(
      title: 'the stock report',
      load: _load,
      builder: (context, data) {
        final received = data.received;
        return _page([
          _heading(
            context,
            'Stock received',
            'Deliveries in the period (opening balances are not deliveries): '
                '${_count(received.receipts, 'delivery', 'deliveries')}, ${received.packs} packs.',
          ),
          if (received.products.isEmpty)
            const Card(child: ListTile(title: Text('No stock was received in this period.')))
          else
            Card(
              child: Column(
                children: [
                  for (final p in received.products)
                    ListTile(
                      title: Text(p.description),
                      subtitle: Text('${p.sku} · ${_count(p.receipts, 'delivery', 'deliveries')}'),
                      trailing: Text('${p.packs} packs'),
                    ),
                ],
              ),
            ),
          _heading(context, 'Expiring stock'),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 30, label: Text('30 days')),
              ButtonSegment(value: 60, label: Text('60 days')),
              ButtonSegment(value: 90, label: Text('90 days')),
            ],
            selected: {_expiryDays},
            onSelectionChanged: (selection) => setState(() {
              _expiryDays = selection.first;
              _load = _loader();
            }),
          ),
          const SizedBox(height: 8),
          ExpiringList(batches: data.expiring, withinDays: _expiryDays),
        ]);
      },
    );
  }
}

typedef _StockData = ({
  ({List<ProductReceived> products, int receipts, int packs}) received,
  List<ExpiringBatch> expiring,
});
