import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../domain/report_models.dart';

/// A labelled figure: what it is, the number, and a caption saying exactly what it counts
/// (spec 6.10: label each metric clearly).
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.caption,
    this.alert = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String caption;

  /// Shows the figure in the error colour (e.g. overdue money).
  final bool alert;

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
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
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
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: alert ? theme.colorScheme.error : null,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              caption,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Metric tiles in a responsive grid: 2 columns on phones, up to 4 on wide screens.
class MetricGrid extends StatelessWidget {
  const MetricGrid({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 900 ? 4 : (width >= 560 ? 3 : 2);
        const spacing = 12.0;
        final tileWidth = ((width - spacing * (columns - 1)) / columns).floorToDouble();
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [for (final child in children) SizedBox(width: tileWidth, child: child)],
        );
      },
    );
  }
}

/// "15 Oct 2026 (in 3 days)", "expired 1 day ago".
String describeExpiry(ExpiringBatch batch) {
  final date = formatApiDate(batch.expiryDate);
  final days = batch.daysToExpiry;
  if (days < 0) return 'expired $date (${-days} day${days == -1 ? '' : 's'} ago)';
  if (days == 0) return 'expires today';
  return 'expires $date (in $days day${days == 1 ? '' : 's'})';
}

/// One row per batch near or past its expiry date, with the estimate explained.
class ExpiringList extends StatelessWidget {
  const ExpiringList({super.key, required this.batches, required this.withinDays});

  final List<ExpiringBatch> batches;
  final int withinDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Packs left are estimated: dispatches do not record which delivery they came from, '
              'so the oldest stock is assumed to go first.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (batches.isEmpty)
            ListTile(title: Text('Nothing expires in the next $withinDays days.')),
          for (final batch in batches)
            ListTile(
              leading: Icon(
                batch.expired ? Icons.error_outline : Icons.schedule,
                color: batch.expired ? theme.colorScheme.error : theme.colorScheme.tertiary,
              ),
              title: Text(batch.description),
              subtitle: Text(
                [
                  if (batch.batchNumber != null) 'Batch ${batch.batchNumber}',
                  describeExpiry(batch),
                ].join(' · '),
              ),
              trailing: Text(
                'about ${batch.estimatedPacksLeft} left',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
