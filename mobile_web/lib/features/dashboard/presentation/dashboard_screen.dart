import 'package:flutter/material.dart';

import '../data/placeholder_dashboard_data.dart';

/// Content width at which the low-stock list becomes a table.
const double _tableBreakpoint = 600;

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);

    return SingleChildScrollView(
      padding: EdgeInsets.all(screenWidth >= 600 ? 24 : 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final columns = width >= 900 ? 4 : (width >= 560 ? 3 : 2);
              const spacing = 12.0;
              final cardWidth = ((width - spacing * (columns - 1)) / columns).floorToDouble();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SampleDataNotice(),
                  const SizedBox(height: 20),
                  Text('Today at a glance', style: titleStyle),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final metric in placeholderMetrics)
                        SizedBox(
                          width: cardWidth,
                          child: _MetricCard(metric: metric),
                        ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Text('Low-stock products', style: titleStyle),
                  const SizedBox(height: 12),
                  if (width >= _tableBreakpoint) const _LowStockTable() else const _LowStockList(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SampleDataNotice extends StatelessWidget {
  const _SampleDataNotice();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colorScheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Sample data only. This dashboard is not connected to the database yet.',
              style: TextStyle(color: colorScheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric});

  final DashboardMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(metric.icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    metric.label,
                    style: theme.textTheme.labelLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                metric.value,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              metric.caption,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Wide screens (web/desktop): a table.
class _LowStockTable extends StatelessWidget {
  const _LowStockTable();

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
              DataColumn(label: Text('Flavour')),
              DataColumn(label: Text('Size')),
              DataColumn(label: Text('On hand'), numeric: true),
              DataColumn(label: Text('Reorder level'), numeric: true),
            ],
            rows: [
              for (final item in placeholderLowStock)
                DataRow(
                  cells: [
                    DataCell(Text(item.product)),
                    DataCell(Text(item.flavour)),
                    DataCell(Text(item.size)),
                    DataCell(Text('${item.onHand}')),
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
  const _LowStockList();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        children: [
          for (final item in placeholderLowStock)
            ListTile(
              title: Text('${item.product} — ${item.flavour}'),
              subtitle: Text('${item.size} · reorder at ${item.reorderLevel}'),
              trailing: Text(
                '${item.onHand} left',
                style: TextStyle(color: colorScheme.error, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
