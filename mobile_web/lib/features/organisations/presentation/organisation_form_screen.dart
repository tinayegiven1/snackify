import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../customers/data/customers_repository.dart';
import '../../customers/domain/customer.dart';
import '../data/organisations_repository.dart';
import '../domain/organisation.dart';

// The same rules the server applies.
final _codeFormat = RegExp(r'^[A-Z0-9][A-Z0-9_-]{1,19}$');
final _phoneFormat = RegExp(r'^\+?[0-9][0-9 ()-]{5,22}$');
final _emailFormat = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Adds a subsidiary, or shows (and, with [canEdit], changes) [organisation]. Pops with a short
/// note for the list.
class OrganisationFormScreen extends StatefulWidget {
  const OrganisationFormScreen({
    super.key,
    required this.repository,
    required this.customers,
    required this.canEdit,
    this.organisation,
  });

  final OrganisationsRepository repository;
  final CustomersRepository customers;
  final bool canEdit;
  final Organisation? organisation;

  @override
  State<OrganisationFormScreen> createState() => _OrganisationFormScreenState();
}

class _OrganisationFormScreenState extends State<OrganisationFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields = {
    'code': TextEditingController(text: widget.organisation?.code),
    'name': TextEditingController(text: widget.organisation?.name),
    'contactName': TextEditingController(text: widget.organisation?.contactName),
    'contactPhone': TextEditingController(text: widget.organisation?.contactPhone),
    'contactEmail': TextEditingController(text: widget.organisation?.contactEmail),
    'address': TextEditingController(text: widget.organisation?.address),
    'billingName': TextEditingController(text: widget.organisation?.billingName),
    'billingAddress': TextEditingController(text: widget.organisation?.billingAddress),
    'taxNumber': TextEditingController(text: widget.organisation?.taxNumber),
  };
  late bool _isActive = widget.organisation?.isActive ?? true;

  /// For a new subsidiary: an existing customer record to reuse, or null to create one.
  String? _existingCustomerId;
  List<Customer> _unlinkedCustomers = const [];

  bool _saving = false;
  String? _error;
  Map<String, String> _serverErrors = {};

  bool get _isNew => widget.organisation == null;
  bool get _editable => widget.canEdit && !_saving;

  @override
  void initState() {
    super.initState();
    if (_isNew) _loadUnlinkedCustomers();
  }

  Future<void> _loadUnlinkedCustomers() async {
    try {
      final page = await widget.customers.list();
      if (!mounted) return;
      setState(() {
        _unlinkedCustomers = page.customers.where((c) => c.organisationId == null).toList();
      });
    } on ApiException {
      // Without customer access the choice is simply not offered: a new record is created.
    }
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _valueOf(String field) {
    final text = _fields[field]!.text.trim();
    return text.isEmpty ? null : text;
  }

  Future<bool> _confirmDeactivate(Organisation organisation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Deactivate ${organisation.name}?'),
        content: const Text(
          'Its staff are signed out at once and can no longer sign in, and its customer record '
          'is deactivated. Everything recorded so far is kept. You can reactivate it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _save() async {
    setState(() {
      _serverErrors = {};
      _error = null;
    });
    if (_saving || !_formKey.currentState!.validate()) return;
    final organisation = widget.organisation;
    if (organisation != null && organisation.isActive && !_isActive) {
      if (!await _confirmDeactivate(organisation)) return;
    }

    final details = <String, Object?>{
      for (final field in _fields.keys)
        field: field == 'code' ? _valueOf(field)?.toUpperCase() : _valueOf(field),
    };
    setState(() => _saving = true);
    try {
      final String note;
      if (organisation == null) {
        final added = await widget.repository.create({
          ...details,
          'existingCustomerId': _existingCustomerId,
        });
        note = 'Added ${added.name} (${added.code}). Add its staff under Users & Roles.';
      } else {
        final saved = await widget.repository.update(organisation.id, {
          ...details,
          if (!organisation.isHeadOffice) 'isActive': _isActive,
        });
        note = organisation.isActive && !saved.isActive
            ? 'Deactivated ${saved.name}. Its staff can no longer sign in.'
            : 'Saved ${saved.name}.';
      }
      if (mounted) Navigator.of(context).pop(note);
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
    final organisation = widget.organisation;
    final title = _isNew
        ? 'Add subsidiary'
        : widget.canEdit
        ? 'Edit ${organisation!.typeLabel.toLowerCase()}'
        : organisation!.name;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
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
                      'Name',
                      hint: 'e.g. Bulawayo Branch',
                      validator: (value) => value.isEmpty ? 'Required' : null,
                    ),
                    _field(
                      'code',
                      'Code',
                      hint: 'e.g. BUL-01',
                      helper: _isNew
                          ? 'Short and unique. Also used as its customer code when free.'
                          : null,
                      capitalization: TextCapitalization.characters,
                      validator: (value) => _codeFormat.hasMatch(value.toUpperCase())
                          ? null
                          : 'Use 2–20 letters, digits, dashes or underscores',
                    ),
                    Text('Contact', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    _field('contactName', 'Contact person (optional)'),
                    _field(
                      'contactPhone',
                      'Phone (optional)',
                      keyboardType: TextInputType.phone,
                      validator: (value) => value.isEmpty || _phoneFormat.hasMatch(value)
                          ? null
                          : 'Use digits, spaces, brackets or dashes',
                    ),
                    _field(
                      'contactEmail',
                      'Email (optional)',
                      keyboardType: TextInputType.emailAddress,
                      capitalization: TextCapitalization.none,
                      validator: (value) => value.isEmpty || _emailFormat.hasMatch(value)
                          ? null
                          : 'Use an email address like orders@example.co.zw',
                    ),
                    _field('address', 'Address (optional)', maxLines: 2),
                    Text('Billing', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    _field('billingName', 'Billing name (optional)'),
                    _field('billingAddress', 'Billing address (optional)', maxLines: 2),
                    _field('taxNumber', 'Tax number (optional)'),
                    if (_isNew && _unlinkedCustomers.isNotEmpty) _customerChoice(),
                    if (organisation != null && !organisation.isHeadOffice)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active'),
                        subtitle: const Text(
                          'A deactivated subsidiary\'s staff cannot sign in. Its history is kept.',
                        ),
                        value: _isActive,
                        onChanged: _editable ? (value) => setState(() => _isActive = value) : null,
                      ),
                    if (widget.canEdit) ...[
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        child: _saving
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_isNew ? 'Add subsidiary' : 'Save changes'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _customerChoice() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownButtonFormField<String?>(
        initialValue: _existingCustomerId,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: 'Customer record',
          border: const OutlineInputBorder(),
          helperText: 'Dispatches and invoices use this record for the subsidiary.',
          helperMaxLines: 2,
          errorText: _serverErrors['existingCustomerId'],
        ),
        items: [
          const DropdownMenuItem(value: null, child: Text('Create a new one')),
          for (final customer in _unlinkedCustomers)
            DropdownMenuItem(
              value: customer.id,
              child: Text(
                'Use ${customer.name} (${customer.code})',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: _saving ? null : (value) => setState(() => _existingCustomerId = value),
      ),
    );
  }

  Widget _field(
    String field,
    String label, {
    String? hint,
    String? helper,
    int maxLines = 1,
    TextCapitalization capitalization = TextCapitalization.words,
    TextInputType? keyboardType,
    String? Function(String value)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: _fields[field],
        enabled: _editable,
        maxLines: maxLines,
        textCapitalization: capitalization,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
          errorText: _serverErrors[field],
          errorMaxLines: 2,
        ),
        onChanged: (_) {
          if (_serverErrors.containsKey(field)) {
            setState(() => _serverErrors = {..._serverErrors}..remove(field));
          }
        },
        validator: widget.canEdit ? (raw) => validator?.call((raw ?? '').trim()) : null,
      ),
    );
  }
}
