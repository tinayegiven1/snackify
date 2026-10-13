import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../domain/payment_models.dart';

/// How much of a payment goes to each of a customer's open invoices.
class AllocationController extends ChangeNotifier {
  AllocationController(this.invoices)
    : _fields = {for (final invoice in invoices) invoice.id: TextEditingController()} {
    for (final field in _fields.values) {
      field.addListener(notifyListeners);
    }
  }

  /// Oldest due date first.
  final List<OpenInvoice> invoices;
  final Map<String, TextEditingController> _fields;

  TextEditingController fieldFor(OpenInvoice invoice) => _fields[invoice.id]!;

  /// Spreads [cents] over the invoices, paying off the oldest first.
  void fillOldestFirst(int cents) {
    var left = cents;
    for (final invoice in invoices) {
      final due = parseCents(invoice.balanceDue)!;
      final take = left < due ? left : due;
      _fields[invoice.id]!.text = take > 0 ? formatCents(take) : '';
      if (take > 0) left -= take;
    }
  }

  /// A problem with the amount entered for [invoice], if any.
  String? errorFor(OpenInvoice invoice) {
    final text = _fields[invoice.id]!.text.trim();
    if (text.isEmpty) return null;
    final cents = parseCents(text);
    if (cents == null) return 'Enter an amount like 4.50';
    if (cents > parseCents(invoice.balanceDue)!) {
      return 'At most ${withCurrency(invoice.balanceDue)}';
    }
    return null;
  }

  bool get hasErrors => invoices.any((invoice) => errorFor(invoice) != null);

  /// Total entered, in cents (amounts that are not valid count as 0).
  int get totalCents =>
      invoices.fold(0, (sum, invoice) => sum + (parseCents(_fields[invoice.id]!.text.trim()) ?? 0));

  /// The invoices with an amount above zero.
  List<AllocationInput> get allocations => [
    for (final invoice in invoices)
      if ((parseCents(_fields[invoice.id]!.text.trim()) ?? 0) > 0)
        AllocationInput(invoice.id, formatCents(parseCents(_fields[invoice.id]!.text.trim())!)),
  ];

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }
}

/// One row per open invoice, with the amount to apply to it.
class AllocationEditor extends StatelessWidget {
  const AllocationEditor({super.key, required this.controller, this.onEdited});

  final AllocationController controller;

  /// Called when the user types in an amount (not when amounts are filled in for them).
  final VoidCallback? onEdited;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final invoice in controller.invoices)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(invoice.invoiceNumber, style: theme.textTheme.titleSmall),
                        Text(
                          '${withCurrency(invoice.balanceDue)} left · '
                          '${invoice.overdue ? 'overdue ${invoice.daysOverdue} '
                                    'day${invoice.daysOverdue == 1 ? '' : 's'}' : 'due ${formatApiDate(invoice.dueDate)}'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: invoice.overdue ? theme.colorScheme.error : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 130,
                    child: TextField(
                      key: ValueKey('allocation-${invoice.id}'),
                      controller: controller.fieldFor(invoice),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.end,
                      onChanged: (_) => onEdited?.call(),
                      decoration: InputDecoration(
                        prefixText: '${AppConfig.currencyCode} ',
                        hintText: '0.00',
                        isDense: true,
                        border: const OutlineInputBorder(),
                        errorText: controller.errorFor(invoice),
                        errorMaxLines: 2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
