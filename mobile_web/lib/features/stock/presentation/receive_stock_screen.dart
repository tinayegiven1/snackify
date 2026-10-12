import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../products/data/products_repository.dart';
import '../../products/domain/product.dart';
import '../../products/presentation/product_picker.dart';
import '../data/stock_repository.dart';
import '../domain/stock_models.dart';
import '../../../shared/widgets/message_view.dart';

/// The result of recording a receipt, for the confirmation message.
typedef ReceivedStock = ({StockReceipt receipt, int quantityOnHand});

/// Records stock that has arrived. Pops with [ReceivedStock] when saved.
class ReceiveStockScreen extends StatefulWidget {
  const ReceiveStockScreen({
    super.key,
    required this.stock,
    required this.products,
    required this.canRecordOpeningBalance,
  });

  final StockRepository stock;
  final ProductsRepository products;

  /// Only admins may record opening balances; the server enforces this too.
  final bool canRecordOpeningBalance;

  @override
  State<ReceiveStockScreen> createState() => _ReceiveStockScreenState();
}

class _ReceiveStockScreenState extends State<ReceiveStockScreen> {
  final _formKey = GlobalKey<FormState>();
  final _quantity = TextEditingController();
  final _batchNumber = TextEditingController();
  final _supplierReference = TextEditingController();
  Product? _product;
  DateTime _receivedDate = today();
  DateTime? _expiryDate;
  bool _isOpeningBalance = false;

  bool _saving = false;
  String? _error;
  Map<String, String> _serverErrors = {};

  @override
  void dispose() {
    _quantity.dispose();
    _batchNumber.dispose();
    _supplierReference.dispose();
    super.dispose();
  }

  Future<void> _chooseProduct() async {
    final product = await pickProduct(context, widget.products);
    if (product != null) {
      setState(() {
        _product = product;
        _serverErrors = {..._serverErrors}..remove('productId');
      });
    }
  }

  Future<void> _chooseReceivedDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _receivedDate,
      firstDate: today().subtract(const Duration(days: 366)),
      lastDate: today(),
      helpText: 'Date the stock arrived',
    );
    if (picked != null) {
      setState(() {
        _receivedDate = picked;
        if (_expiryDate != null && _expiryDate!.isBefore(picked)) _expiryDate = null;
      });
    }
  }

  Future<void> _chooseExpiryDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiryDate ?? _receivedDate.add(const Duration(days: 90)),
      firstDate: _receivedDate,
      lastDate: _receivedDate.add(const Duration(days: 3650)),
      helpText: 'Expiry date',
    );
    if (picked != null) setState(() => _expiryDate = picked);
  }

  Future<void> _save() async {
    setState(() {
      _serverErrors = {};
      _error = null;
    });
    if (_saving || !_formKey.currentState!.validate()) return;

    final input = ReceiptInput(
      productId: _product!.id,
      quantity: int.parse(_quantity.text.trim()),
      receivedDate: toApiDate(_receivedDate),
      batchNumber: _batchNumber.text.trim().isEmpty ? null : _batchNumber.text.trim(),
      expiryDate: _expiryDate == null ? null : toApiDate(_expiryDate!),
      supplierReference: _supplierReference.text.trim().isEmpty
          ? null
          : _supplierReference.text.trim(),
      isOpeningBalance: _isOpeningBalance,
    );

    setState(() => _saving = true);
    try {
      final result = await widget.stock.receive(input);
      if (mounted) Navigator.of(context).pop<ReceivedStock>(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _serverErrors = error.fieldErrors;
        _error = error.fieldErrors.isEmpty ? error.message : null;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive stock')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) ...[
                      ErrorBanner(message: _error!),
                      const SizedBox(height: 16),
                    ],
                    _PickerField(
                      label: 'Product',
                      value: _product?.description,
                      placeholder: 'Choose or scan a product',
                      icon: Icons.inventory_2_outlined,
                      errorText: _serverErrors['productId'],
                      onTap: _saving ? null : _chooseProduct,
                      validator: () => _product == null ? 'Choose a product' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _quantity,
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: 'Quantity received (packs)',
                        border: const OutlineInputBorder(),
                        errorText: _serverErrors['quantity'],
                      ),
                      validator: (value) {
                        final quantity = int.tryParse((value ?? '').trim());
                        if (quantity == null) return 'Required';
                        if (quantity < 1) return 'Must be at least 1';
                        if (quantity > 1000000) return 'Must be at most 1,000,000';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    _PickerField(
                      label: 'Date received',
                      value: formatApiDate(toApiDate(_receivedDate)),
                      icon: Icons.event_outlined,
                      errorText: _serverErrors['receivedDate'],
                      onTap: _saving ? null : _chooseReceivedDate,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _batchNumber,
                      enabled: !_saving,
                      maxLength: 60,
                      decoration: InputDecoration(
                        labelText: 'Batch or lot number (optional)',
                        border: const OutlineInputBorder(),
                        counterText: '',
                        errorText: _serverErrors['batchNumber'],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _PickerField(
                      label: 'Expiry date (optional)',
                      value: _expiryDate == null ? null : formatApiDate(toApiDate(_expiryDate!)),
                      placeholder: 'No expiry date',
                      icon: Icons.event_busy_outlined,
                      errorText: _serverErrors['expiryDate'],
                      onTap: _saving ? null : _chooseExpiryDate,
                      onClear: _expiryDate == null || _saving
                          ? null
                          : () => setState(() => _expiryDate = null),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _supplierReference,
                      enabled: !_saving,
                      maxLength: 120,
                      decoration: InputDecoration(
                        labelText: 'Supplier or delivery note (optional)',
                        border: const OutlineInputBorder(),
                        counterText: '',
                        errorText: _serverErrors['supplierReference'],
                      ),
                    ),
                    if (widget.canRecordOpeningBalance)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Opening balance'),
                        subtitle: const Text(
                          'Stock that was already on the shelf before Snackify was used. '
                          'Only allowed while the product has no stock records.',
                        ),
                        value: _isOpeningBalance,
                        onChanged: _saving
                            ? null
                            : (value) => setState(() => _isOpeningBalance = value),
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: _saving
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Record receipt'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A form field that opens a picker (product, date) when tapped.
class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.placeholder,
    this.errorText,
    this.validator,
    this.onClear,
  });

  final String label;
  final String? value;
  final String? placeholder;
  final IconData icon;
  final String? errorText;
  final VoidCallback? onTap;
  final VoidCallback? onClear;
  final String? Function()? validator;

  @override
  Widget build(BuildContext context) {
    return FormField<void>(
      validator: validator == null ? null : (_) => validator!(),
      builder: (field) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          isEmpty: value == null,
          decoration: InputDecoration(
            labelText: label,
            hintText: placeholder,
            prefixIcon: Icon(icon),
            border: const OutlineInputBorder(),
            errorText: field.errorText ?? errorText,
            enabled: onTap != null,
            suffixIcon: onClear == null
                ? const Icon(Icons.arrow_drop_down)
                : IconButton(
                    tooltip: 'Clear $label',
                    icon: const Icon(Icons.clear),
                    onPressed: onClear,
                  ),
          ),
          child: value == null ? null : Text(value!),
        ),
      ),
    );
  }
}
