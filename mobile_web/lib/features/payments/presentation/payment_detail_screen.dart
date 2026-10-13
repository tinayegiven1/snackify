import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/payments_repository.dart';
import '../domain/payment_models.dart';
import 'allocation_editor.dart';

/// One payment: what it paid, credit left, and allocating or voiding it.
class PaymentDetailScreen extends StatefulWidget {
  const PaymentDetailScreen({
    super.key,
    required this.paymentId,
    required this.payments,
    required this.canVoid,
  });

  final String paymentId;
  final PaymentsRepository payments;

  /// Admins only.
  final bool canVoid;

  @override
  State<PaymentDetailScreen> createState() => _PaymentDetailScreenState();
}

class _PaymentDetailScreenState extends State<PaymentDetailScreen> {
  Payment? _payment;
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
      final payment = await widget.payments.get(widget.paymentId);
      if (mounted) setState(() => _payment = payment);
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _allocate(Payment payment) async {
    final updated = await Navigator.of(context).push<Payment>(
      MaterialPageRoute(
        builder: (_) => AllocateCreditScreen(payment: payment, payments: widget.payments),
      ),
    );
    if (updated != null && mounted) setState(() => _payment = updated);
  }

  Future<void> _void(Payment payment) async {
    final reason = await _askReason(payment);
    if (reason == null) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final voided = await widget.payments.voidPayment(payment.id, reason);
      if (mounted) setState(() => _payment = voided);
    } on ApiException catch (error) {
      if (mounted) setState(() => _actionError = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askReason(Payment payment) {
    final reason = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Void ${payment.paymentNumber}?'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Only for a payment recorded by mistake. The invoices it paid will be owed '
                'again. To correct it, record the payment again with the right details.',
              ),
              const SizedBox(height: 16),
              TextFormField(
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
            ],
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
            child: const Text('Void payment'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final payment = _payment;
    return Scaffold(
      appBar: AppBar(title: Text(payment?.paymentNumber ?? 'Payment')),
      body: _loadError != null
          ? MessageView(
              icon: Icons.cloud_off_outlined,
              title: 'Could not load the payment',
              message: _loadError!,
              action: RetryButton(onPressed: _load),
            )
          : payment == null
          ? const Center(child: CircularProgressIndicator())
          : _buildDetail(payment),
    );
  }

  Widget _buildDetail(Payment payment) {
    final theme = Theme.of(context);
    final voided = payment.status == PaymentStatus.voided;
    final hasCredit = !voided && payment.unallocatedAmount != '0.00';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${payment.currency} ${payment.amount}',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      decoration: voided ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (voided) const StatusBadge('Voided'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${payment.customerName} (${payment.customerCode})',
                style: theme.textTheme.titleMedium,
              ),
              Text(
                [
                  'Received ${formatApiDate(payment.paymentDate)}',
                  payment.method.label,
                  if (payment.reference != null) 'ref ${payment.reference}',
                ].join(' · '),
              ),
              if (payment.notes != null) ...[const SizedBox(height: 4), Text(payment.notes!)],
              const SizedBox(height: 16),
              if (voided)
                _Notice(
                  'Voided by ${payment.voidedBy}: ${payment.voidReason}. It no longer pays any '
                  'invoice.',
                ),
              Card(
                child: Column(
                  children: [
                    if (payment.allocations.isEmpty)
                      const ListTile(title: Text('Not applied to any invoice')),
                    for (final allocation in payment.allocations)
                      ListTile(
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: Text(allocation.invoiceNumber),
                        trailing: Text(withCurrency(allocation.amount)),
                      ),
                    const Divider(height: 1),
                    ListTile(
                      dense: true,
                      title: const Text('Applied to invoices'),
                      trailing: Text(withCurrency(payment.allocatedAmount)),
                    ),
                    ListTile(
                      dense: true,
                      title: const Text(
                        'Credit left',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      trailing: Text(
                        withCurrency(payment.unallocatedAmount),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text('Recorded by ${payment.recordedBy}', style: theme.textTheme.bodySmall),
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
                  if (!voided && widget.canVoid)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _void(payment),
                      icon: const Icon(Icons.block),
                      label: const Text('Void payment'),
                    ),
                  if (hasCredit)
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _allocate(payment),
                      icon: const Icon(Icons.call_split),
                      label: const Text('Allocate credit'),
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

class _Notice extends StatelessWidget {
  const _Notice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message),
    );
  }
}

/// Applies a payment's credit to the customer's open invoices. Pops with the updated payment.
class AllocateCreditScreen extends StatefulWidget {
  const AllocateCreditScreen({super.key, required this.payment, required this.payments});

  final Payment payment;
  final PaymentsRepository payments;

  @override
  State<AllocateCreditScreen> createState() => _AllocateCreditScreenState();
}

class _AllocateCreditScreenState extends State<AllocateCreditScreen> {
  AllocationController? _allocation;
  String? _loadError;
  bool _saving = false;
  String? _error;

  int get _creditCents => parseCents(widget.payment.unallocatedAmount)!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _allocation?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final account = await widget.payments.account(widget.payment.customerId);
      if (!mounted) return;
      setState(
        () =>
            _allocation = AllocationController(account.openInvoices)..fillOldestFirst(_creditCents),
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _loadError = error.message);
    }
  }

  Future<void> _save(AllocationController allocation) async {
    if (allocation.hasErrors || allocation.allocations.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await widget.payments.allocate(widget.payment.id, allocation.allocations);
      if (mounted) Navigator.of(context).pop(updated);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allocation = _allocation;
    return Scaffold(
      appBar: AppBar(title: const Text('Allocate credit')),
      body: _loadError != null
          ? MessageView(
              icon: Icons.cloud_off_outlined,
              title: 'Could not load the invoices',
              message: _loadError!,
              action: RetryButton(onPressed: _load),
            )
          : allocation == null
          ? const Center(child: CircularProgressIndicator())
          : _buildEditor(allocation),
    );
  }

  Widget _buildEditor(AllocationController allocation) {
    final theme = Theme.of(context);
    if (allocation.invoices.isEmpty) {
      return MessageView(
        icon: Icons.task_alt,
        title: 'No unpaid invoices',
        message:
            '${widget.payment.customerName} has no unpaid invoices. The credit stays on '
            'their account until a new invoice is issued.',
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListenableBuilder(
            listenable: allocation,
            builder: (context, _) {
              final left = _creditCents - allocation.totalCents;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${widget.payment.paymentNumber} has '
                    '${withCurrency(widget.payment.unallocatedAmount)} of credit to apply.',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  AllocationEditor(controller: allocation),
                  const SizedBox(height: 8),
                  if (left < 0)
                    ErrorBanner(
                      message:
                          'That is ${withCurrency(formatCents(-left))} more than the credit '
                          'available.',
                    )
                  else
                    Text('Credit still left after this: ${withCurrency(formatCents(left))}'),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    ErrorBanner(message: _error!),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed:
                        _saving ||
                            left < 0 ||
                            allocation.hasErrors ||
                            allocation.allocations.isEmpty
                        ? null
                        : () => _save(allocation),
                    icon: const Icon(Icons.check),
                    label: const Text('Apply credit'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
