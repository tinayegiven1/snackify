import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/forecasts_repository.dart';
import '../domain/forecast_models.dart';

/// An en dash that never starts or ends a line, so a range like "40–60" stays together.
const _noBreakDash = '\u2060\u2013\u2060'; // word joiner, en dash, word joiner

/// "about 12 packs".
String aboutPacks(double packs) {
  final rounded = packs.round();
  return 'about $rounded pack${rounded == 1 ? '' : 's'}';
}

/// One line for a forecast: the estimate and its range, or why there is none.
String describeForecast(HorizonForecast forecast) => switch (forecast.status) {
  ForecastStatus.ok =>
    forecast.lower == forecast.upper
        ? aboutPacks(forecast.predicted!)
        : '${aboutPacks(forecast.predicted!)} (${forecast.lower}$_noBreakDash${forecast.upper})',
  ForecastStatus.insufficientHistory =>
    'not enough history yet (${forecast.historyDays} days of dispatches; needs 28)',
  ForecastStatus.noHistory => 'never dispatched, so nothing to forecast from',
};

/// Sales forecasts (spec 6.11): expected demand for the next week and month for each product,
/// clearly labelled as estimates, with how much stock to receive.
class ForecastsScreen extends StatefulWidget {
  const ForecastsScreen({super.key, required this.forecasts});

  final ForecastsRepository forecasts;

  @override
  State<ForecastsScreen> createState() => _ForecastsScreenState();
}

class _ForecastsScreenState extends State<ForecastsScreen> {
  ForecastView? _view;
  String? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final view = await widget.forecasts.latest();
      if (mounted) setState(() => _view = view);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final view = await widget.forecasts.run();
      if (mounted) setState(() => _view = view);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _open(ProductForecast forecast) => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => ProductForecastScreen(forecast: forecast)));

  @override
  Widget build(BuildContext context) {
    final view = _view;
    if (view == null) {
      return _error != null
          ? MessageView(
              icon: Icons.cloud_off_outlined,
              title: 'Could not load forecasts',
              message: _error!,
              action: RetryButton(onPressed: _load),
            )
          : const Center(child: CircularProgressIndicator());
    }

    final theme = Theme.of(context);
    final run = view.run;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _EstimateNotice(),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Text(
                      run == null
                          ? 'No forecast has been made yet.'
                          : 'Made ${formatApiDate(toApiDate(run.createdAt))} at '
                                '${run.createdAt.hour.toString().padLeft(2, '0')}:'
                                '${run.createdAt.minute.toString().padLeft(2, '0')} '
                                'by ${run.createdBy}, from ${formatApiDate(run.forecastStart)}.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    FilledButton.icon(
                      onPressed: _running ? null : _run,
                      icon: _running
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(run == null ? 'Make the first forecast' : 'Make a new forecast'),
                    ),
                  ],
                ),
                if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(message: _error!)],
                const SizedBox(height: 12),
                if (run != null && view.products.isEmpty)
                  const Card(child: ListTile(title: Text('There are no active products.'))),
                for (final forecast in view.products)
                  Card(
                    child: ListTile(
                      title: Text(forecast.description),
                      subtitle: Text(
                        'Next 7 days: ${describeForecast(forecast.week)}\n'
                        'Next 30 days: ${describeForecast(forecast.month)}',
                      ),
                      isThreeLine: true,
                      trailing: _RestockBadge(forecast: forecast),
                      onTap: () => _open(forecast),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EstimateNotice extends StatelessWidget {
  const _EstimateNotice();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.insights, color: colorScheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Estimates, not guaranteed sales. Each product\'s demand is the average of its '
              'confirmed dispatches on the same weekday over the last 8 weeks. Returns, damage '
              'and stock corrections do not count as demand.',
              style: TextStyle(color: colorScheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Receive 10" when stock will not cover the next 7 days plus the safety stock.
class _RestockBadge extends StatelessWidget {
  const _RestockBadge({required this.forecast});

  final ProductForecast forecast;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final reorder = forecast.week.suggestedReorder;
    if (reorder == null) return const SizedBox.shrink();
    if (reorder == 0) {
      return Text('Enough stock', style: Theme.of(context).textTheme.bodySmall);
    }
    return StatusBadge(
      'Receive $reorder',
      color: colorScheme.tertiaryContainer,
      textColor: colorScheme.onTertiaryContainer,
    );
  }
}

/// One product's forecast: the estimates, how much to receive, and how accurate past
/// forecasts were.
class ProductForecastScreen extends StatelessWidget {
  const ProductForecastScreen({super.key, required this.forecast});

  final ProductForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget section(String title, List<Widget> children) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );

    String estimate(HorizonForecast f) => switch (f.status) {
      ForecastStatus.ok =>
        f.lower == f.upper
            ? '${aboutPacks(f.predicted!)[0].toUpperCase()}${aboutPacks(f.predicted!).substring(1)}.'
            : 'About ${f.predicted!.round()} packs, probably between ${f.lower} and ${f.upper}.',
      _ => '${describeForecast(f)[0].toUpperCase()}${describeForecast(f).substring(1)}.',
    };

    String restock(HorizonForecast f) {
      final reorder = f.suggestedReorder;
      if (reorder == null) return 'No suggestion without a forecast.';
      final days = f.horizonDays;
      // Stock is planned in whole packs, so a part pack is rounded up; say so.
      final predicted = f.predicted!;
      final packs = predicted == predicted.ceilToDouble()
          ? '${predicted.ceil()}'
          : '${predicted.toStringAsFixed(1)}, rounded up to ${predicted.ceil()}';
      final working =
          '(forecast $packs + safety stock ${forecast.safetyStock} − on hand ${forecast.onHand})';
      return reorder == 0
          ? 'Enough stock for the next $days days $working.'
          : 'Receive $reorder packs to cover the next $days days $working.';
    }

    return Scaffold(
      appBar: AppBar(title: Text(forecast.description)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _EstimateNotice(),
          const SizedBox(height: 12),
          section('Next 7 days', [Text(estimate(forecast.week))]),
          section('Next 30 days', [Text(estimate(forecast.month))]),
          section('Restocking', [
            Text('On hand now: ${forecast.onHand} packs'),
            Text('Safety stock: ${forecast.safetyStock} packs (set by an admin in Products)'),
            const SizedBox(height: 8),
            Text(restock(forecast.week)),
            Text(restock(forecast.month)),
          ]),
          section('How accurate it has been', [
            Text(
              forecast.mae != null
                  ? 'Weekly forecasts were ${forecast.mae!.toStringAsFixed(1)} packs off on '
                        'average (mean absolute error over the last ${forecast.weeksCompared} '
                        'weeks).'
                  : 'Shown once ${forecast.weeksNeeded} forecast weeks have passed '
                        '(${forecast.weeksCompared} so far).',
            ),
            if (forecast.recent.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final week in forecast.recent)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Week from ${formatApiDate(week.forecastStart)}'),
                  trailing: Text('forecast ${week.predicted.round()} · actual ${week.actual}'),
                ),
            ],
          ]),
        ],
      ),
    );
  }
}
