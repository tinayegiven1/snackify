import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/invoices_repository.dart';
import '../domain/invoice_models.dart';
import 'invoice_detail_screen.dart';
import 'invoice_widgets.dart';
import 'weekly_invoicing_screen.dart';

/// All invoices, newest first, with a status filter and search.
class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key, required this.invoices, required this.sharePdf});

  final InvoicesRepository invoices;
  final PdfSharer sharePdf;

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  InvoiceStatus? _status;
  int _latestRequest = 0;
  bool _loading = true;
  String? _error;
  List<InvoiceSummary>? _invoices;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDelay?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_latestRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final invoices = await widget.invoices.list(status: _status, search: _search.text);
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _invoices = invoices;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _open(String invoiceId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => InvoiceDetailScreen(
          invoiceId: invoiceId,
          invoices: widget.invoices,
          sharePdf: widget.sharePdf,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _startWeeklyRun() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final created = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => WeeklyInvoicingScreen(invoices: widget.invoices, sharePdf: widget.sharePdf),
      ),
    );
    if (!mounted) return;
    if (created != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created == 0
                ? 'Nothing was left to invoice.'
                : 'Created $created draft invoice${created == 1 ? '' : 's'}. '
                      'Check each one, then issue it.',
          ),
        ),
      );
      _status = created == 0 ? _status : InvoiceStatus.draft;
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startWeeklyRun,
        icon: const Icon(Icons.playlist_add),
        label: const Text('Weekly invoicing'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) {
                _searchDelay?.cancel();
                _searchDelay = Timer(const Duration(milliseconds: 300), _load);
              },
              decoration: const InputDecoration(
                hintText: 'Search invoice number or customer',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (label, status) in [
                  ('All', null),
                  ('Drafts', InvoiceStatus.draft),
                  ('Issued', InvoiceStatus.issued),
                  ('Voided', InvoiceStatus.voided),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _status == status,
                    onSelected: (_) {
                      setState(() => _status = status);
                      _load();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_loading && _invoices != null) const LinearProgressIndicator(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load invoices',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final invoices = _invoices;
    if (invoices == null) return const Center(child: CircularProgressIndicator());
    if (invoices.isEmpty) {
      return const MessageView(
        icon: Icons.receipt_long_outlined,
        title: 'No invoices found',
        message: 'Use Weekly invoicing to bill confirmed dispatches.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: invoices.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final invoice = invoices[index];
        return ListTile(
          title: Text('${invoice.invoiceNumber ?? 'Draft'} · ${invoice.customerName}'),
          subtitle: Text(
            [
              invoice.period.label,
              if (invoice.issueDate != null) 'issued ${formatApiDate(invoice.issueDate!)}',
              '${invoice.lineCount} line${invoice.lineCount == 1 ? '' : 's'}',
            ].join(' · '),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [Text(withCurrency(invoice.total)), InvoiceStatusBadge(invoice.status)],
          ),
          onTap: () => _open(invoice.id),
        );
      },
    );
  }
}
