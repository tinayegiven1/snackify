import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../shared/widgets/message_view.dart';
import '../domain/invoice_models.dart';

/// "USD 7.25".
String money(String currency, String amount) => '$currency $amount';

/// A coloured label for an invoice's status.
class InvoiceStatusBadge extends StatelessWidget {
  const InvoiceStatusBadge(this.status, {super.key});

  final InvoiceStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (status) {
      InvoiceStatus.draft => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      InvoiceStatus.issued => (Colors.green.shade100, Colors.green.shade900),
      InvoiceStatus.voided => (colorScheme.surfaceContainerHighest, colorScheme.onSurfaceVariant),
    };
    return StatusBadge(status.label, color: background, textColor: foreground);
  }
}

/// Who the invoice is for, and the period it covers.
class InvoiceHeading extends StatelessWidget {
  const InvoiceHeading({super.key, required this.customer, required this.period});

  final InvoiceCustomer customer;
  final BillingPeriod period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${customer.name} (${customer.code})', style: theme.textTheme.titleLarge),
        if (customer.address != null) Text(customer.address!),
        if (customer.phone != null) Text(customer.phone!),
        const SizedBox(height: 4),
        Text('Period: ${period.label}', style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// The billed dispatch lines, followed by the totals.
class InvoiceLinesCard extends StatelessWidget {
  const InvoiceLinesCard({
    super.key,
    required this.currency,
    required this.lines,
    required this.totals,
  });

  final String currency;
  final List<InvoiceLine> lines;

  /// Label, amount, and whether to show it in bold.
  final List<(String, String, bool)> totals;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          for (final line in lines)
            ListTile(
              title: Text(line.description),
              subtitle: Text(
                '${line.dispatchNumber} · ${formatApiDate(line.dispatchDate)} · '
                '${line.quantity} × ${money(currency, line.unitPrice)}',
              ),
              trailing: Text(money(currency, line.lineTotal)),
            ),
          const Divider(height: 1),
          for (final (label, amount, bold) in totals)
            ListTile(
              dense: true,
              title: Text(label, style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
              trailing: Text(
                money(currency, amount),
                style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// A coloured box with an icon and a message.
class InvoiceNotice extends StatelessWidget {
  const InvoiceNotice({super.key, required this.icon, required this.message, this.warning = false});

  final IconData icon;
  final String message;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = warning ? colorScheme.tertiaryContainer : colorScheme.secondaryContainer;
    final foreground = warning ? colorScheme.onTertiaryContainer : colorScheme.onSecondaryContainer;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(color: foreground)),
          ),
        ],
      ),
    );
  }
}
