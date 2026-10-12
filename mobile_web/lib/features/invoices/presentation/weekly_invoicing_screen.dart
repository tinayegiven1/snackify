import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/invoices_repository.dart';
import '../domain/invoice_models.dart';
import 'invoice_detail_screen.dart';
import 'invoice_preview_screen.dart';

/// The weekly invoicing run: who still has confirmed dispatches to invoice in a period, and
/// creating their draft invoices, one customer at a time or all at once.
///
/// Pops with the number of drafts created.
class WeeklyInvoicingScreen extends StatefulWidget {
  const WeeklyInvoicingScreen({super.key, required this.invoices, required this.sharePdf});

  final InvoicesRepository invoices;
  final PdfSharer sharePdf;

  @override
  State<WeeklyInvoicingScreen> createState() => _WeeklyInvoicingScreenState();
}

class _WeeklyInvoicingScreenState extends State<WeeklyInvoicingScreen> {
  /// Null until the server has said which week was the last complete one.
  BillingPeriod? _period;
  List<UnbilledCustomer>? _customers;
  int _latestRequest = 0;
  bool _loading = true;
  String? _error;
  bool _busy = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([BillingPeriod? period]) async {
    final request = ++_latestRequest;
    setState(() {
      _loading = true;
      _error = null;
      _actionError = null;
    });
    try {
      final result = await widget.invoices.unbilled(period ?? _period);
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _period = result.period;
        _customers = result.customers;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || request != _latestRequest) return;
      setState(() {
        // Keep showing the last good period; explain why the new one was refused.
        _error = error.fieldErrors.values.firstOrNull ?? error.message;
        _loading = false;
      });
    }
  }

  Future<void> _chooseDates(BillingPeriod current) async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: today().subtract(const Duration(days: 730)),
      lastDate: today(),
      initialDateRange: DateTimeRange(
        start: DateTime.parse(current.from),
        end: DateTime.parse(current.to),
      ),
      helpText: 'Billing period',
    );
    if (range == null) return;
    await _load(BillingPeriod(toApiDate(range.start), toApiDate(range.end)));
  }

  Future<void> _openPreview(UnbilledCustomer customer, BillingPeriod period) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final draft = await Navigator.of(context).push<Invoice>(
      MaterialPageRoute(
        builder: (_) => InvoicePreviewScreen(
          customerId: customer.customerId,
          period: period,
          invoices: widget.invoices,
        ),
      ),
    );
    if (draft != null && mounted) {
      // Open the new draft to check and issue it.
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => InvoiceDetailScreen(
            invoiceId: draft.id,
            invoices: widget.invoices,
            sharePdf: widget.sharePdf,
          ),
        ),
      );
    }
    // Drafts may have been created, issued or voided meanwhile.
    if (mounted) _load();
  }

  Future<void> _createAll(BillingPeriod period, int count) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Create $count draft invoice${count == 1 ? '' : 's'}?'),
        content: Text(
          'One draft per customer for ${period.label}. You can check each draft, then issue '
          'it or void it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Create drafts'),
          ),
        ],
      ),
    );
    if (go != true) return;

    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final drafts = await widget.invoices.createDraftsForAll(period);
      if (!mounted) return;
      Navigator.of(context).pop(drafts.length);
    } on ApiException catch (error) {
      if (mounted) setState(() => _actionError = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final period = _period;
    final customers = _customers;
    return Scaffold(
      appBar: AppBar(title: const Text('Weekly invoicing')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (period != null)
            _PeriodBar(
              period: period,
              enabled: !_loading && !_busy,
              onPrevious: () => _load(period.shiftedByWeeks(-1)),
              onNext: () => _load(period.shiftedByWeeks(1)),
              onChoose: () => _chooseDates(period),
            ),
          if (_loading && customers != null) const LinearProgressIndicator(),
          if (_error != null && customers != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: ErrorBanner(message: _error!),
            ),
          Expanded(child: _buildContent(period, customers)),
          if (period != null && customers != null && customers.isNotEmpty)
            _buildFooter(period, customers),
        ],
      ),
    );
  }

  Widget _buildContent(BillingPeriod? period, List<UnbilledCustomer>? customers) {
    if (customers == null || period == null) {
      if (_error != null) {
        return MessageView(
          icon: Icons.cloud_off_outlined,
          title: 'Could not load what is left to invoice',
          message: _error!,
          action: RetryButton(onPressed: _load),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (customers.isEmpty) {
      return const MessageView(
        icon: Icons.task_alt,
        title: 'Nothing to invoice',
        message:
            'No confirmed dispatches in this period are waiting to be invoiced. '
            'Choose another period to check.',
      );
    }
    return ListView.separated(
      itemCount: customers.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final customer = customers[index];
        return ListTile(
          title: Text('${customer.name} (${customer.code})'),
          subtitle: Text(
            '${customer.dispatchCount} dispatch${customer.dispatchCount == 1 ? '' : 'es'} · '
            '${customer.lineCount} line${customer.lineCount == 1 ? '' : 's'}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [Text(withCurrency(customer.subtotal)), const Icon(Icons.chevron_right)],
          ),
          onTap: _busy ? null : () => _openPreview(customer, period),
        );
      },
    );
  }

  Widget _buildFooter(BillingPeriod period, List<UnbilledCustomer> customers) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_actionError != null) ...[
              ErrorBanner(message: _actionError!),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _busy || _loading ? null : () => _createAll(period, customers.length),
              icon: const Icon(Icons.playlist_add_check),
              label: Text(
                'Create draft invoices for all ${customers.length} '
                'customer${customers.length == 1 ? '' : 's'}',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar({
    required this.period,
    required this.enabled,
    required this.onPrevious,
    required this.onNext,
    required this.onChoose,
  });

  final BillingPeriod period;
  final bool enabled;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous week',
            onPressed: enabled ? onPrevious : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Column(
              children: [
                Text('Billing period', style: theme.textTheme.labelMedium),
                Text(period.label, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Next week',
            // A period that has not ended yet cannot be invoiced.
            onPressed: enabled && !DateTime.parse(period.shiftedByWeeks(1).to).isAfter(today())
                ? onNext
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
          IconButton(
            tooltip: 'Choose dates',
            onPressed: enabled ? onChoose : null,
            icon: const Icon(Icons.date_range),
          ),
        ],
      ),
    );
  }
}
