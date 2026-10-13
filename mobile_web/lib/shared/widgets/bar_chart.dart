import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// One bar: its value, the label under it, and what its tooltip says.
class BarDatum {
  const BarDatum({required this.value, required this.label, required this.tooltip});

  final double value;
  final String label;
  final String tooltip;
}

/// The smallest "clean" number (1, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 × a power of ten) at or above
/// [value], so the tallest column fills most of the chart and the half-way tick is clean too.
double niceCeiling(double value) {
  if (value <= 0) return 1;
  final magnitude = pow(10, (log(value) / ln10).floor()).toDouble();
  for (final step in [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) {
    if (step * magnitude >= value) return step * magnitude;
  }
  return 10 * magnitude;
}

/// A single-series column chart for a trend over time (spec 6.10). One series, so no legend: the
/// title says what is plotted. Columns are at most 24 px wide with a 4 px rounded top on a
/// hairline baseline; gridlines are recessive; only the highest column is labelled, and every
/// column shows its exact value in a tooltip (hover, or long-press on a phone). Always pair it
/// with a table of the same numbers.
class BarChart extends StatelessWidget {
  const BarChart({super.key, required this.bars, required this.formatValue, this.height = 180});

  final List<BarDatum> bars;

  /// Formats axis ticks and the direct label, e.g. 1234.5 -> "1,234.50".
  final String Function(double value) formatValue;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final gridColor = theme.colorScheme.outlineVariant;
    final top = niceCeiling(bars.fold(0, (m, b) => max(m, b.value)));
    final highest = bars.isEmpty
        ? -1
        : bars.indexWhere((b) => b.value == bars.map((b) => b.value).reduce(max));

    return Semantics(
      label: 'Chart. The values are also listed in the table below.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          const axisWidth = 56.0;
          const labelRow = 18.0;
          const capLabel = 16.0;
          final plotWidth = max(0.0, constraints.maxWidth - axisWidth);
          final slot = bars.isEmpty ? 0.0 : plotWidth / bars.length;
          // At most 24 px and 60% of the slot, so there is always air between columns.
          final barWidth = min(24.0, max(2.0, slot * 0.6));
          final plotHeight = height - labelRow - capLabel;
          // Label every n-th column so the dates never collide.
          final every = max(1, (56 / max(slot, 1)).ceil());

          return SizedBox(
            height: height,
            child: Stack(
              children: [
                // Gridlines and tick values: 0, half and the top.
                for (final fraction in const [0.0, 0.5, 1.0])
                  Positioned(
                    left: 0,
                    right: 0,
                    top: capLabel + plotHeight * (1 - fraction) - 7,
                    child: Row(
                      children: [
                        SizedBox(
                          width: axisWidth - 6,
                          child: Text(
                            formatValue(top * fraction),
                            style: muted,
                            textAlign: TextAlign.right,
                            maxLines: 1,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Container(height: 1, color: gridColor)),
                      ],
                    ),
                  ),
                Positioned(
                  left: axisWidth,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, bar) in bars.indexed)
                        Expanded(
                          child: Tooltip(
                            message: bar.tooltip,
                            // The whole column is the hit area, not just the bar.
                            child: Column(
                              children: [
                                SizedBox(
                                  height: capLabel + plotHeight,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      if (index == highest && bar.value > 0)
                                        Text(
                                          formatValue(bar.value),
                                          style: muted?.copyWith(
                                            color: theme.colorScheme.onSurface,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.visible,
                                          softWrap: false,
                                        ),
                                      Container(
                                        key: ValueKey('bar-$index'),
                                        width: barWidth,
                                        height: plotHeight * (bar.value / top),
                                        decoration: const BoxDecoration(
                                          color: SnackifyColors.chart,
                                          borderRadius: BorderRadius.vertical(
                                            top: Radius.circular(4),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  height: labelRow,
                                  child: index % every == 0
                                      ? Text(
                                          bar.label,
                                          style: muted,
                                          maxLines: 1,
                                          overflow: TextOverflow.visible,
                                          softWrap: false,
                                        )
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
