import 'package:flutter/material.dart';

import '../../../core/formatting/money.dart';
import '../domain/payment_models.dart';

/// "USD 13.00", or "In credit USD 2.00" for a negative balance.
String formatBalance(String balance) => balance.startsWith('-')
    ? 'In credit ${withCurrency(balance.substring(1))}'
    : withCurrency(balance);

/// What a customer (or every customer) owes, each measure on its own labelled line.
class BalanceSummaryCard extends StatelessWidget {
  const BalanceSummaryCard({super.key, required this.measures, this.title = 'Balance'});

  final BalanceMeasures measures;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    Widget row(String label, String value, {Color? color, String? hint}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: color)),
                if (hint != null) Text(hint, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              style: TextStyle(color: color),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            Text(
              formatBalance(measures.balance),
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Divider(height: 24),
            row(
              'Overdue',
              withCurrency(measures.overdue),
              color: measures.hasOverdue ? colorScheme.error : null,
              hint: 'Unpaid invoices past their due date',
            ),
            row('Unpaid invoices', withCurrency(measures.invoicedUnpaid)),
            row(
              'Not yet invoiced',
              withCurrency(measures.notYetInvoiced),
              hint: 'Confirmed dispatches waiting for the weekly invoice',
            ),
            row(
              'Credit',
              '− ${withCurrency(measures.unallocatedCredit)}',
              hint: 'Payments not yet applied to an invoice',
            ),
          ],
        ),
      ),
    );
  }
}
