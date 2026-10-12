import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../data/products_repository.dart';
import '../domain/product.dart';
import '../../../shared/widgets/message_view.dart';

// The same rules the server applies, so most mistakes are caught before sending.
final _skuFormat = RegExp(r'^[A-Z0-9][A-Z0-9._-]{0,39}$');
final _barcodeFormat = RegExp(r'^[A-Za-z0-9-]{4,48}$');
final _priceFormat = RegExp(r'^\d{1,10}(\.\d{1,2})?$');

/// Adds a product, or edits [product] when it is given. Pops with the saved product.
class ProductFormScreen extends StatefulWidget {
  const ProductFormScreen({super.key, required this.repository, this.product});

  final ProductsRepository repository;
  final Product? product;

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?.name);
  late final _flavour = TextEditingController(text: widget.product?.flavour);
  late final _size = TextEditingController(text: widget.product?.size);
  late final _sku = TextEditingController(text: widget.product?.sku);
  late final _barcode = TextEditingController(text: widget.product?.barcode);
  late final _price = TextEditingController(text: widget.product?.defaultPrice);
  late final _reorderLevel = TextEditingController(text: widget.product?.reorderLevel?.toString());
  late bool _isActive = widget.product?.isActive ?? true;

  bool _saving = false;
  String? _error;

  /// Messages from the server for individual fields, e.g. a SKU that is already used.
  Map<String, String> _serverErrors = {};

  bool get _isNew => widget.product == null;

  @override
  void dispose() {
    for (final controller in [_name, _flavour, _size, _sku, _barcode, _price, _reorderLevel]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _serverErrors = {};
      _error = null;
    });
    if (_saving || !_formKey.currentState!.validate()) return;

    final input = ProductInput(
      sku: _sku.text.trim().toUpperCase(),
      name: _name.text.trim(),
      flavour: _flavour.text.trim(),
      size: _size.text.trim(),
      barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      defaultPrice: _price.text.trim(),
      reorderLevel: int.tryParse(_reorderLevel.text.trim()),
      isActive: _isActive,
    );

    setState(() => _saving = true);
    try {
      final saved = _isNew
          ? await widget.repository.create(input)
          : await widget.repository.update(widget.product!.id, input);
      if (mounted) Navigator.of(context).pop(saved);
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
      appBar: AppBar(title: Text(_isNew ? 'Add product' : 'Edit product')),
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
                    _textField(
                      'name',
                      _name,
                      'Product name',
                      hint: 'e.g. Potato Crisps',
                      maxLength: 100,
                    ),
                    _textField('flavour', _flavour, 'Flavour', hint: 'e.g. BBQ', maxLength: 60),
                    _textField('size', _size, 'Size', hint: 'e.g. Small or 50 g', maxLength: 40),
                    _textField(
                      'sku',
                      _sku,
                      'SKU (product code)',
                      hint: 'e.g. PC-BBQ-S',
                      capitalization: TextCapitalization.characters,
                      validator: (value) => _skuFormat.hasMatch(value.toUpperCase())
                          ? null
                          : 'Use up to 40 letters, digits, dots, dashes or underscores',
                    ),
                    _textField(
                      'barcode',
                      _barcode,
                      'Barcode (optional)',
                      helper: 'Leave empty if the product has no barcode',
                      required: false,
                      validator: (value) => value.isEmpty || _barcodeFormat.hasMatch(value)
                          ? null
                          : 'Use 4–48 letters, digits or dashes',
                    ),
                    _textField(
                      'defaultPrice',
                      _price,
                      'Default selling price',
                      prefix: '${AppConfig.currencyCode} ',
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      validator: (value) => _priceFormat.hasMatch(value)
                          ? null
                          : 'Use an amount like 0.50 (up to 2 decimal places)',
                    ),
                    _textField(
                      'reorderLevel',
                      _reorderLevel,
                      'Reorder level (optional)',
                      helper:
                          'Warn when stock falls to this many packs. Leave empty for no warning.',
                      required: false,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) => (int.tryParse(value) ?? 1000001) <= 1000000
                          ? null
                          : 'Use a whole number up to 1,000,000',
                    ),
                    if (!_isNew)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active'),
                        subtitle: const Text(
                          'Inactive products are hidden from lists and cannot be used in new '
                          'transactions. Their history is kept.',
                        ),
                        value: _isActive,
                        onChanged: _saving ? null : (value) => setState(() => _isActive = value),
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
                          : const Text('Save product'),
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

  /// A text field that is required by default, trims input before checking it, and shows
  /// the server's message for [field] if saving failed because of it.
  Widget _textField(
    String field,
    TextEditingController controller,
    String label, {
    String? hint,
    String? helper,
    String? prefix,
    int? maxLength,
    bool required = true,
    TextCapitalization capitalization = TextCapitalization.sentences,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String value)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        enabled: !_saving,
        textCapitalization: capitalization,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        maxLength: maxLength,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          prefixText: prefix,
          border: const OutlineInputBorder(),
          errorText: _serverErrors[field],
          counterText: '',
        ),
        onChanged: (_) {
          if (_serverErrors.containsKey(field)) {
            setState(() => _serverErrors = {..._serverErrors}..remove(field));
          }
        },
        validator: (raw) {
          final value = (raw ?? '').trim();
          if (value.isEmpty) return required ? 'Required' : null;
          return validator?.call(value);
        },
      ),
    );
  }
}
