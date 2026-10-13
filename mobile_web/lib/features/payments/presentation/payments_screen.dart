import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/files/pdf_sharer.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../customers/data/customers_repository.dart';
import '../../invoices/data/invoices_repository.dart';
import '../data/payments_repository.dart';
import '../domain/payment_models.dart';
import 'customer_account_screen.dart';
import 'payment_detail_screen.dart';
import 'payment_widgets.dart';
import 'record_payment_screen.dart';

/// Balances (who owes what) and the payments received.
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({
    super.key,
    required this.payments,
    required this.customers,
    required this.invoices,
    required this.sharePdf,
    required this.canVoid,
  });

  final PaymentsRepository payments;
  final CustomersRepository customers;
  final InvoicesRepository invoices;
  final PdfSharer sharePdf;

  /// Admins may void payments.
  final bool canVoid;

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  /// Changed after a payment is recorded, so both tabs load again.
  int _version = 0;

  Future<void> _record() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final payment = await Navigator.of(context).push<Payment>(
      MaterialPageRoute(
        builder: (_) => RecordPaymentScreen(payments: widget.payments, customers: widget.customers),
      ),
    );
    if (payment == null || !mounted) return;
    setState(() => _version++);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PaymentDetailScreen(
          paymentId: payment.id,
          payments: widget.payments,
          canVoid: widget.canVoid,
        ),
      ),
    );
    if (mounted) setState(() => _version++);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _record,
          icon: const Icon(Icons.add),
          label: const Text('Record payment'),
        ),
        body: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Balances'),
                Tab(text: 'Payments'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _BalancesTab(key: ValueKey('balances-$_version'), parent: widget),
                  _PaymentsTab(key: ValueKey('payments-$_version'), parent: widget),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalancesTab extends StatefulWidget {
  const _BalancesTab({super.key, required this.parent});

  final PaymentsScreen parent;

  @override
  State<_BalancesTab> createState() => _BalancesTabState();
}

class _BalancesTabState extends State<_BalancesTab> with AutomaticKeepAliveClientMixin {
  ({List<CustomerBalance> customers, BalanceMeasures totals})? _balances;
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

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
      final balances = await widget.parent.payments.balances();
      if (mounted) {
        setState(() {
          _balances = balances;
          _loading = false;
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _openAccount(CustomerBalance balance) async {
    final parent = widget.parent;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CustomerAccountScreen(
          customerId: balance.customerId,
          payments: parent.payments,
          customers: parent.customers,
          invoices: parent.invoices,
          sharePdf: parent.sharePdf,
          canVoidPayments: parent.canVoid,
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load balances',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final balances = _balances;
    if (balances == null) return const Center(child: CircularProgressIndicator());
    if (balances.customers.isEmpty) {
      return const MessageView(
        icon: Icons.account_balance_wallet_outlined,
        title: 'Nothing owed yet',
        message: 'Balances appear once dispatches are confirmed or payments are recorded.',
      );
    }
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        children: [
          if (_loading) const LinearProgressIndicator(),
          BalanceSummaryCard(measures: balances.totals, title: 'All customers'),
          const SizedBox(height: 16),
          for (final balance in balances.customers) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${balance.name} (${balance.code})'),
              subtitle: Text(
                balance.measures.hasOverdue
                    ? 'Overdue ${withCurrency(balance.measures.overdue)} since '
                          '${formatApiDate(balance.oldestOverdueDueDate!)}'
                    : 'Nothing overdue',
                style: balance.measures.hasOverdue
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
              trailing: Text(formatBalance(balance.measures.balance)),
              onTap: () => _openAccount(balance),
            ),
            const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class _PaymentsTab extends StatefulWidget {
  const _PaymentsTab({super.key, required this.parent});

  final PaymentsScreen parent;

  @override
  State<_PaymentsTab> createState() => _PaymentsTabState();
}

class _PaymentsTabState extends State<_PaymentsTab> with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  Timer? _searchDelay;
  int _latestRequest = 0;
  bool _loading = true;
  String? _error;
  List<PaymentSummary>? _payments;

  @override
  bool get wantKeepAlive => true;

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
      final payments = await widget.parent.payments.list(search: _search.text);
      if (!mounted || request != _latestRequest) return;
      setState(() {
        _payments = payments;
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

  Future<void> _open(PaymentSummary payment) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PaymentDetailScreen(
          paymentId: payment.id,
          payments: widget.parent.payments,
          canVoid: widget.parent.canVoid,
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
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
              hintText: 'Search receipt number, reference or customer',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        if (_loading && _payments != null) const LinearProgressIndicator(),
        Expanded(child: _buildContent()),
      ],
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load payments',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final payments = _payments;
    if (payments == null) return const Center(child: CircularProgressIndicator());
    if (payments.isEmpty) {
      return const MessageView(
        icon: Icons.payments_outlined,
        title: 'No payments found',
        message: 'Use Record payment when a customer pays.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: payments.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final payment = payments[index];
        final voided = payment.status == PaymentStatus.voided;
        return ListTile(
          title: Text('${payment.paymentNumber} · ${payment.customerName}'),
          subtitle: Text(
            [
              formatApiDate(payment.paymentDate),
              payment.method.label,
              if (payment.reference != null) payment.reference!,
            ].join(' · '),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                withCurrency(payment.amount),
                style: voided ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
              ),
              if (voided)
                const StatusBadge('Voided')
              else if (payment.unallocatedAmount != '0.00')
                StatusBadge('Credit ${withCurrency(payment.unallocatedAmount)}'),
            ],
          ),
          onTap: () => _open(payment),
        );
      },
    );
  }
}
