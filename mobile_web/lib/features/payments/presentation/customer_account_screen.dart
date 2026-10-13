import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../customers/data/customers_repository.dart';
import '../../invoices/data/invoices_repository.dart';
import '../../invoices/presentation/invoice_detail_screen.dart';
import '../data/payments_repository.dart';
import '../domain/payment_models.dart';
import 'payment_detail_screen.dart';
import 'payment_widgets.dart';
import 'record_payment_screen.dart';

/// One customer's account: what they owe and why, open invoices, credit, and a statement.
class CustomerAccountScreen extends StatefulWidget {
  const CustomerAccountScreen({
    super.key,
    required this.customerId,
    required this.payments,
    required this.customers,
    required this.invoices,
    required this.sharePdf,
    required this.canVoidPayments,
  });

  final String customerId;
  final PaymentsRepository payments;
  final CustomersRepository customers;
  final InvoicesRepository invoices;
  final PdfSharer sharePdf;
  final bool canVoidPayments;

  @override
  State<CustomerAccountScreen> createState() => _CustomerAccountScreenState();
}

class _CustomerAccountScreenState extends State<CustomerAccountScreen> {
  CustomerAccount? _account;
  ({String from, String to})? _period;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final account = await widget.payments.account(
        widget.customerId,
        from: _period?.from,
        to: _period?.to,
      );
      if (mounted) {
        setState(() {
          _account = account;
          _loading = false;
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.fieldErrors.values.firstOrNull ?? error.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _chooseDates(Statement statement) async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: today().subtract(const Duration(days: 3650)),
      lastDate: today(),
      initialDateRange: DateTimeRange(
        start: DateTime.parse(statement.from),
        end: DateTime.parse(statement.to),
      ),
      helpText: 'Statement period',
    );
    if (range == null) return;
    _period = (from: toApiDate(range.start), to: toApiDate(range.end));
    await _load();
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  Future<void> _recordPayment(CustomerAccount account) async {
    final payment = await Navigator.of(context).push<Payment>(
      MaterialPageRoute(
        builder: (_) => RecordPaymentScreen(
          payments: widget.payments,
          customers: widget.customers,
          customer: (id: account.customerId, code: account.code, name: account.name),
        ),
      ),
    );
    if (payment == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Payment ${payment.paymentNumber} recorded.')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    return Scaffold(
      appBar: AppBar(title: Text(account?.name ?? 'Customer account')),
      floatingActionButton: account == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _recordPayment(account),
              icon: const Icon(Icons.add),
              label: const Text('Record payment'),
            ),
      body: account == null
          ? (_error != null
                ? MessageView(
                    icon: Icons.cloud_off_outlined,
                    title: 'Could not load the account',
                    message: _error!,
                    action: RetryButton(onPressed: _load),
                  )
                : const Center(child: CircularProgressIndicator()))
          : _buildAccount(account),
    );
  }

  Widget _buildAccount(CustomerAccount account) {
    final theme = Theme.of(context);
    final summary = account.summary;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) ...[ErrorBanner(message: _error!), const SizedBox(height: 12)],
        BalanceSummaryCard(measures: summary),
        const SizedBox(height: 24),
        Text('Unpaid invoices', style: theme.textTheme.titleMedium),
        if (account.openInvoices.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('None.')),
        for (final invoice in account.openInvoices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(invoice.invoiceNumber),
            subtitle: Text(
              invoice.overdue
                  ? 'Overdue ${invoice.daysOverdue} day${invoice.daysOverdue == 1 ? '' : 's'} '
                        '(due ${formatApiDate(invoice.dueDate)})'
                  : 'Due ${formatApiDate(invoice.dueDate)}',
              style: invoice.overdue ? TextStyle(color: theme.colorScheme.error) : null,
            ),
            trailing: Text(withCurrency(invoice.balanceDue)),
            onTap: () => _open(
              InvoiceDetailScreen(
                invoiceId: invoice.id,
                invoices: widget.invoices,
                sharePdf: widget.sharePdf,
              ),
            ),
          ),
        if (account.creditPayments.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Credit to allocate', style: theme.textTheme.titleMedium),
          for (final payment in account.creditPayments)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(payment.paymentNumber),
              subtitle: Text('Received ${formatApiDate(payment.paymentDate)}'),
              trailing: Text(withCurrency(payment.unallocatedAmount)),
              onTap: () => _open(
                PaymentDetailScreen(
                  paymentId: payment.id,
                  payments: widget.payments,
                  canVoid: widget.canVoidPayments,
                ),
              ),
            ),
        ],
        const SizedBox(height: 24),
        _buildStatement(account.statement),
      ],
    );
  }

  Widget _buildStatement(Statement statement) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Statement', style: theme.textTheme.titleMedium),
                  Text(formatApiPeriod(statement.from, statement.to)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Choose dates',
              onPressed: _loading ? null : () => _chooseDates(statement),
              icon: const Icon(Icons.date_range),
            ),
          ],
        ),
        Text(
          'Issued invoices and payments received. Dispatches not yet invoiced are not on the '
          'statement.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                dense: true,
                title: const Text('Brought forward'),
                trailing: Text(withCurrency(statement.openingBalance)),
              ),
              for (final entry in statement.entries) ...[
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  title: Text(_describe(entry)),
                  subtitle: Text(
                    '${formatApiDate(entry.date)} · balance ${withCurrency(entry.balance)}',
                  ),
                  trailing: Text(
                    entry.isInvoice
                        ? withCurrency(entry.debit!)
                        : '− ${withCurrency(entry.credit!)}',
                  ),
                ),
              ],
              const Divider(height: 1),
              ListTile(
                dense: true,
                title: const Text(
                  'Balance at the end',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                trailing: Text(
                  withCurrency(statement.closingBalance),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _describe(StatementEntry entry) {
    if (entry.isInvoice) {
      return 'Invoice ${entry.reference} (${formatApiPeriod(entry.periodFrom!, entry.periodTo!)})';
    }
    return [
      'Payment ${entry.reference}',
      entry.method!.label,
      if (entry.paymentReference != null) 'ref ${entry.paymentReference}',
    ].join(' · ');
  }
}
