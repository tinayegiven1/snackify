import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/invoices_repository.dart';
import '../domain/invoice_models.dart';
import 'invoice_widgets.dart';

/// What one customer's invoice for the period would contain, before anything is saved.
///
/// Pops with the draft invoice when one is created.
class InvoicePreviewScreen extends StatefulWidget {
  const InvoicePreviewScreen({
    super.key,
    required this.customerId,
    required this.period,
    required this.invoices,
  });

  final String customerId;
  final BillingPeriod period;
  final InvoicesRepository invoices;

  @override
  State<InvoicePreviewScreen> createState() => _InvoicePreviewScreenState();
}

class _InvoicePreviewScreenState extends State<InvoicePreviewScreen> {
  InvoicePreview? _preview;
  String? _loadError;
  bool _busy = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _actionError = null;
    });
    try {
      final preview = await widget.invoices.preview(widget.customerId, widget.period);
      if (mounted) setState(() => _preview = preview);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _createDraft() async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final draft = await widget.invoices.createDraft(widget.customerId, widget.period);
      if (mounted) Navigator.of(context).pop(draft);
    } on ApiException catch (error) {
      if (mounted) setState(() => _actionError = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Invoice preview')),
      body: _loadError != null
          ? MessageView(
              icon: Icons.cloud_off_outlined,
              title: 'Could not load the preview',
              message: _loadError!,
              action: RetryButton(onPressed: _load),
            )
          : preview == null
          ? const Center(child: CircularProgressIndicator())
          : _buildPreview(preview),
    );
  }

  Widget _buildPreview(InvoicePreview preview) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InvoiceHeading(customer: preview.customer, period: preview.period),
              const SizedBox(height: 16),
              if (preview.lines.isEmpty)
                const InvoiceNotice(
                  icon: Icons.check_circle_outline,
                  message:
                      'Nothing to invoice: every confirmed dispatch for this customer in the '
                      'period is already on an invoice.',
                )
              else ...[
                const InvoiceNotice(
                  icon: Icons.visibility_outlined,
                  message:
                      'Preview only: nothing is saved yet. Creating the draft reserves these '
                      'dispatch lines so they cannot be billed twice.',
                ),
                InvoiceLinesCard(
                  currency: preview.currency,
                  lines: preview.lines,
                  totals: [('Total', preview.subtotal, true)],
                ),
              ],
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
                  if (_actionError != null)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh preview'),
                    ),
                  if (preview.lines.isNotEmpty)
                    FilledButton.icon(
                      onPressed: _busy ? null : _createDraft,
                      icon: const Icon(Icons.note_add_outlined),
                      label: const Text('Create draft invoice'),
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
