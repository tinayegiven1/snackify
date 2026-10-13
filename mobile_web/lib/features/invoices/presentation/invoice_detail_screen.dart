import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/invoices_repository.dart';
import '../domain/invoice_models.dart';
import 'invoice_widgets.dart';

/// One invoice: its lines and totals, and issuing, voiding and the PDF.
class InvoiceDetailScreen extends StatefulWidget {
  const InvoiceDetailScreen({
    super.key,
    required this.invoiceId,
    required this.invoices,
    required this.sharePdf,
  });

  final String invoiceId;
  final InvoicesRepository invoices;
  final PdfSharer sharePdf;

  @override
  State<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends State<InvoiceDetailScreen> {
  Invoice? _invoice;
  String? _loadError;
  bool _busy = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final invoice = await widget.invoices.get(widget.invoiceId);
      if (mounted) setState(() => _invoice = invoice);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  /// Runs an action, showing progress and any error.
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) setState(() => _actionError = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _issue(Invoice invoice) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Issue this invoice?'),
        content: Text(
          'It will get the next invoice number and today\'s date, for '
          '${money(invoice.currency, invoice.total)}. An issued invoice cannot be changed '
          'or voided; mistakes are corrected later with a credit note.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Issue'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await _run(() async {
      final issued = await widget.invoices.issue(invoice.id);
      if (!mounted) return;
      // No snackbar: on phones it would cover the PDF button, which is usually next.
      setState(() => _invoice = issued);
    });
  }

  Future<void> _void(Invoice invoice) async {
    final reason = await _askReason();
    if (reason == null) return;
    await _run(() async {
      final voided = await widget.invoices.voidDraft(invoice.id, reason);
      if (!mounted) return;
      setState(() => _invoice = voided);
    });
  }

  Future<void> _sharePdf(Invoice invoice) async {
    await _run(() async {
      final bytes = await widget.invoices.pdf(invoice.id);
      await widget.sharePdf(bytes, invoice.pdfFileName);
    });
  }

  Future<String?> _askReason() {
    final reason = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void this draft?'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: reason,
            autofocus: true,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Reason',
              border: OutlineInputBorder(),
              counterText: '',
            ),
            validator: (value) =>
                (value ?? '').trim().length < 3 ? 'Explain the reason in a few words' : null,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Go back')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(context).pop(reason.text.trim());
              }
            },
            child: const Text('Void draft'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final invoice = _invoice;
    return Scaffold(
      appBar: AppBar(title: Text(invoice?.title ?? 'Invoice')),
      body: _loadError != null
          ? MessageView(
              icon: Icons.cloud_off_outlined,
              title: 'Could not load the invoice',
              message: _loadError!,
              action: RetryButton(onPressed: _load),
            )
          : invoice == null
          ? const Center(child: CircularProgressIndicator())
          : _buildDetail(invoice),
    );
  }

  Widget _buildDetail(Invoice invoice) {
    final theme = Theme.of(context);
    final isDraft = invoice.status == InvoiceStatus.draft;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  InvoiceStatusBadge(invoice.status),
                  if (invoice.paymentStatus case final paymentStatus?)
                    InvoicePaymentBadge(paymentStatus, overdue: invoice.overdue),
                  if (invoice.issueDate != null)
                    Text('Issued ${formatApiDate(invoice.issueDate!)}')
                  else if (isDraft)
                    const Text('Not issued yet'),
                  if (invoice.dueDate != null)
                    Text(
                      'Due ${formatApiDate(invoice.dueDate!)}',
                      style: invoice.overdue ? TextStyle(color: theme.colorScheme.error) : null,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              InvoiceHeading(customer: invoice.customer, period: invoice.period),
              const SizedBox(height: 16),
              if (isDraft)
                const InvoiceNotice(
                  icon: Icons.edit_note,
                  message:
                      'Draft: check the lines, then issue it. Issuing gives the invoice its '
                      'number and today\'s date, and then it can no longer be changed. While '
                      'on a draft, these dispatches cannot be reversed.',
                ),
              if (invoice.status == InvoiceStatus.issued)
                const InvoiceNotice(
                  icon: Icons.verified_outlined,
                  message:
                      'Issued: this invoice is final and cannot be changed or voided. Mistakes '
                      'will be corrected with credit notes.',
                ),
              if (invoice.status == InvoiceStatus.voided)
                InvoiceNotice(
                  icon: Icons.block,
                  message: 'Voided: ${invoice.voidReason}. Its dispatches can be invoiced again.',
                ),
              InvoiceLinesCard(
                currency: invoice.currency,
                lines: invoice.lines,
                totals: [
                  ('Subtotal', invoice.subtotal, false),
                  ('Total', invoice.total, true),
                  ('Amount paid', invoice.amountPaid, false),
                  ('Balance due', invoice.balanceDue, true),
                ],
              ),
              if (invoice.payments.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Payments', style: theme.textTheme.titleMedium),
                Card(
                  child: Column(
                    children: [
                      for (final payment in invoice.payments)
                        ListTile(
                          dense: true,
                          title: Text(payment.paymentNumber),
                          subtitle: Text(
                            '${formatApiDate(payment.paymentDate)} · ${payment.method.label}',
                          ),
                          trailing: Text(money(invoice.currency, payment.amount)),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text('Created by ${invoice.createdBy}', style: theme.textTheme.bodySmall),
              if (invoice.issuedBy != null)
                Text('Issued by ${invoice.issuedBy}', style: theme.textTheme.bodySmall),
              if (_actionError != null) ...[
                const SizedBox(height: 16),
                ErrorBanner(message: _actionError!),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _sharePdf(invoice),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text(sharePdfLabel),
                  ),
                  if (isDraft)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _void(invoice),
                      icon: const Icon(Icons.close),
                      label: const Text('Void draft'),
                    ),
                  if (isDraft)
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _issue(invoice),
                      icon: const Icon(Icons.check),
                      label: const Text('Issue invoice'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
