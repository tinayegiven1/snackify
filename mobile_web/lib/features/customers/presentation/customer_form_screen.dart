import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/customers_repository.dart';
import '../domain/customer.dart';

// The same rules the server applies.
final _codeFormat = RegExp(r'^[A-Z0-9][A-Z0-9._-]{0,19}$');
final _phoneFormat = RegExp(r'^\+?[0-9][0-9 ()-]{5,22}$');
final _moneyFormat = RegExp(r'^\d{1,10}(\.\d{1,2})?$');

/// Adds a customer, or edits [customer] when it is given. Fields the user's role may not
/// change are shown but locked. Pops with the saved customer.
class CustomerFormScreen extends StatefulWidget {
  const CustomerFormScreen({
    super.key,
    required this.repository,
    required this.permissions,
    this.customer,
  });

  final CustomersRepository repository;
  final CustomerPermissions permissions;
  final Customer? customer;

  @override
  State<CustomerFormScreen> createState() => _CustomerFormScreenState();
}

class _CustomerFormScreenState extends State<CustomerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.customer?.code);
  late final _name = TextEditingController(text: widget.customer?.name);
  late final _phone = TextEditingController(text: widget.customer?.phone);
  late final _address = TextEditingController(text: widget.customer?.address);
  late final _creditLimit = TextEditingController(text: widget.customer?.creditLimit);
  late bool _isActive = widget.customer?.isActive ?? true;

  bool _saving = false;
  String? _error;
  Map<String, String> _serverErrors = {};

  bool get _isNew => widget.customer == null;
  CustomerPermissions get _can => widget.permissions;

  @override
  void dispose() {
    for (final controller in [_code, _name, _phone, _address, _creditLimit]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _textOrNull(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
  }

  /// Only the fields this user may change are sent.
  Map<String, Object?> _fieldsToSend() => {
    if (_can.canEditDetails) ...{
      if (!_isNew || _textOrNull(_code) != null) 'code': _code.text.trim().toUpperCase(),
      'name': _name.text.trim(),
      'phone': _textOrNull(_phone),
      'address': _textOrNull(_address),
    },
    if (_can.canEditCreditLimit && (!_isNew || _textOrNull(_creditLimit) != null))
      'creditLimit': _textOrNull(_creditLimit),
    if (_can.canChangeActive && !_isNew) 'isActive': _isActive,
  };

  Future<void> _save() async {
    setState(() {
      _serverErrors = {};
      _error = null;
    });
    if (_saving || !_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final saved = _isNew
          ? await widget.repository.create(_fieldsToSend())
          : await widget.repository.update(widget.customer!.id, _fieldsToSend());
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
      appBar: AppBar(title: Text(_isNew ? 'Add customer' : 'Edit customer')),
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
                    _field(
                      'name',
                      _name,
                      'Customer name',
                      hint: 'e.g. Avondale Tuckshop',
                      enabled: _can.canEditDetails,
                      maxLength: 120,
                      validator: (value) => value.isEmpty ? 'Required' : null,
                    ),
                    _field(
                      'code',
                      _code,
                      _isNew ? 'Customer code (optional)' : 'Customer code',
                      helper: _isNew ? 'Leave empty to number it automatically (C0001, ...)' : null,
                      enabled: _can.canEditDetails,
                      capitalization: TextCapitalization.characters,
                      validator: (value) {
                        if (value.isEmpty) return _isNew ? null : 'Required';
                        return _codeFormat.hasMatch(value.toUpperCase())
                            ? null
                            : 'Use up to 20 letters, digits, dots, dashes or underscores';
                      },
                    ),
                    _field(
                      'phone',
                      _phone,
                      'Phone (optional)',
                      hint: 'e.g. +263 77 123 4567',
                      enabled: _can.canEditDetails,
                      keyboardType: TextInputType.phone,
                      validator: (value) => value.isEmpty || _phoneFormat.hasMatch(value)
                          ? null
                          : 'Use digits, spaces, brackets or dashes',
                    ),
                    _field(
                      'address',
                      _address,
                      'Delivery address (optional)',
                      enabled: _can.canEditDetails,
                      maxLength: 300,
                      maxLines: 3,
                    ),
                    _field(
                      'creditLimit',
                      _creditLimit,
                      'Credit limit (optional)',
                      prefix: '${AppConfig.currencyCode} ',
                      helper: _can.canEditCreditLimit
                          ? 'Most the customer may owe at once. Leave empty for no limit.'
                          : 'Only accounts staff and admins can change this.',
                      enabled: _can.canEditCreditLimit,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      validator: (value) => value.isEmpty || _moneyFormat.hasMatch(value)
                          ? null
                          : 'Use an amount like 500.00 (up to 2 decimal places)',
                    ),
                    if (!_isNew && _can.canChangeActive)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active'),
                        subtitle: const Text(
                          'Inactive customers are hidden from lists and cannot receive new '
                          'dispatches. Their history is kept.',
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
                          : const Text('Save customer'),
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

  Widget _field(
    String field,
    TextEditingController controller,
    String label, {
    required bool enabled,
    String? hint,
    String? helper,
    String? prefix,
    int? maxLength,
    int maxLines = 1,
    TextCapitalization capitalization = TextCapitalization.sentences,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String value)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        enabled: enabled && !_saving,
        textCapitalization: capitalization,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        maxLength: maxLength,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 2,
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
        // Locked fields are not checked: the user cannot fix them.
        validator: enabled ? (raw) => validator?.call((raw ?? '').trim()) : null,
      ),
    );
  }
}
