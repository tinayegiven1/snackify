import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/formatting/dates.dart';
import '../../../core/formatting/money.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/request_id.dart';
import '../../../shared/widgets/message_view.dart';
import '../../customers/data/customers_repository.dart';
import '../../customers/presentation/customer_picker.dart';
import '../data/payments_repository.dart';
import '../domain/payment_models.dart';
import 'allocation_editor.dart';

/// A customer chosen in advance, e.g. from their account.
typedef ChosenCustomer = ({String id, String code, String name});

/// Records money received from a customer and applies it to their open invoices, oldest first
/// unless changed. Whatever is not applied stays as credit on the account.
///
/// Pops with the recorded [Payment].
class RecordPaymentScreen extends StatefulWidget {
  const RecordPaymentScreen({
    super.key,
    required this.payments,
    required this.customers,
    this.customer,
  });

  final PaymentsRepository payments;
  final CustomersRepository customers;
  final ChosenCustomer? customer;

  @override
  State<RecordPaymentScreen> createState() => _RecordPaymentScreenState();
}

class _RecordPaymentScreenState extends State<RecordPaymentScreen> {
  /// One id for this payment, however many times it is sent: the server records it once.
  final _requestId = newRequestId();
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  ChosenCustomer? _customer;
  DateTime _date = today();
  PaymentMethod _method = PaymentMethod.cash;

  AllocationController? _allocation;
  bool _loadingInvoices = false;
  String? _invoicesError;

  /// Amounts follow the payment amount until the user changes one.
  bool _autoFill = true;
  bool _saving = false;
  String? _error;
  Map<String, String> _fieldErrors = const {};

  @override
  void initState() {
    super.initState();
    _amount.addListener(_amountChanged);
    final customer = widget.customer;
    if (customer != null) _setCustomer(customer);
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _notes.dispose();
    _allocation?.dispose();
    super.dispose();
  }

  void _amountChanged() {
    final cents = parseCents(_amount.text);
    if (_autoFill && cents != null) _allocation?.fillOldestFirst(cents);
    setState(() {});
  }

  Future<void> _chooseCustomer() async {
    final customer = await pickCustomer(context, widget.customers);
    if (customer == null || !mounted) return;
    _setCustomer((id: customer.id, code: customer.code, name: customer.name));
  }

  Future<void> _setCustomer(ChosenCustomer customer) async {
    _allocation?.dispose();
    setState(() {
      _customer = customer;
      _allocation = null;
      _loadingInvoices = true;
      _invoicesError = null;
      _autoFill = true;
    });
    try {
      final account = await widget.payments.account(customer.id);
      if (!mounted || _customer?.id != customer.id) return;
      final allocation = AllocationController(account.openInvoices);
      final cents = parseCents(_amount.text);
      if (cents != null) allocation.fillOldestFirst(cents);
      setState(() {
        _allocation = allocation;
        _loadingInvoices = false;
      });
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _invoicesError = error.message;
          _loadingInvoices = false;
        });
      }
    }
  }

  Future<void> _chooseDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today().subtract(const Duration(days: 730)),
      lastDate: today(),
      helpText: 'Date received',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final valid = _formKey.currentState!.validate();
    final allocation = _allocation;
    if (_customer == null) {
      setState(() => _error = 'Choose the customer who paid.');
      return;
    }
    if (!valid || allocation == null || allocation.hasErrors || _overAllocated) return;

    setState(() {
      _saving = true;
      _error = null;
      _fieldErrors = const {};
    });
    try {
      final payment = await widget.payments.record(
        requestId: _requestId,
        customerId: _customer!.id,
        paymentDate: toApiDate(_date),
        amount: formatCents(parseCents(_amount.text)!),
        method: _method,
        reference: _reference.text.trim().isEmpty ? null : _reference.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        allocations: allocation.allocations,
      );
      if (mounted) Navigator.of(context).pop(payment);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _fieldErrors = error.fieldErrors;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _overAllocated {
    final cents = parseCents(_amount.text);
    final allocation = _allocation;
    return cents != null && allocation != null && allocation.totalCents > cents;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Record payment')),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: _saving || widget.customer != null ? null : _chooseCustomer,
                    icon: const Icon(Icons.store_outlined),
                    label: Text(
                      _customer == null
                          ? 'Choose a customer'
                          : '${_customer!.name} (${_customer!.code})',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Amount received',
                      prefixText: '${AppConfig.currencyCode} ',
                      border: const OutlineInputBorder(),
                      errorText: _fieldErrors['amount'],
                    ),
                    validator: (value) {
                      final cents = parseCents(value ?? '');
                      if (cents == null) return 'Enter an amount like 25.00';
                      if (cents == 0) return 'Must be more than 0';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Date received',
                            border: const OutlineInputBorder(),
                            errorText: _fieldErrors['paymentDate'],
                          ),
                          child: InkWell(
                            onTap: _saving ? null : _chooseDate,
                            child: Text(formatApiDate(toApiDate(_date))),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<PaymentMethod>(
                          initialValue: _method,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Method',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final method in PaymentMethod.values)
                              DropdownMenuItem(value: method, child: Text(method.label)),
                          ],
                          onChanged: (method) =>
                              setState(() => _method = method ?? PaymentMethod.cash),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _reference,
                    maxLength: 100,
                    decoration: InputDecoration(
                      labelText: 'Reference (optional)',
                      helperText: 'Bank reference, mobile money transaction id, cheque number…',
                      border: const OutlineInputBorder(),
                      counterText: '',
                      errorText: _fieldErrors['reference'],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _notes,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Apply to invoices', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  _buildAllocation(),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    ErrorBanner(message: _error!),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: const Text('Record payment'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAllocation() {
    final theme = Theme.of(context);
    if (_customer == null) {
      return Text(
        'Choose a customer to see their unpaid invoices.',
        style: theme.textTheme.bodyMedium,
      );
    }
    if (_loadingInvoices) return const LinearProgressIndicator();
    if (_invoicesError != null) {
      return ErrorBanner(message: 'Could not load their invoices: $_invoicesError');
    }
    final allocation = _allocation!;
    final amount = parseCents(_amount.text);
    return ListenableBuilder(
      listenable: allocation,
      builder: (context, _) {
        final applied = allocation.totalCents;
        final credit = amount == null ? null : amount - applied;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (allocation.invoices.isEmpty)
              Text(
                'No unpaid invoices: the whole payment is kept as credit on the account.',
                style: theme.textTheme.bodyMedium,
              )
            else
              AllocationEditor(
                controller: allocation,
                onEdited: () => setState(() => _autoFill = false),
              ),
            const SizedBox(height: 8),
            if (credit != null && credit < 0)
              ErrorBanner(
                message:
                    'The invoices add up to ${withCurrency(formatCents(applied))}, more than '
                    'the ${withCurrency(formatCents(amount!))} received.',
              )
            else if (credit != null)
              Text(
                'Applied to invoices: ${withCurrency(formatCents(applied))} · '
                'kept as credit: ${withCurrency(formatCents(credit))}',
                style: theme.textTheme.bodyMedium,
              ),
          ],
        );
      },
    );
  }
}
