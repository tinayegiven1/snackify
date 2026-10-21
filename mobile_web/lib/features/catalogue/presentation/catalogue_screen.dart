import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../auth/domain/app_user.dart';
import '../data/catalogue_repository.dart';
import '../domain/catalogue_models.dart';

/// Suppliers, categories, warehouses and units, one tab each. Everyone may look; adding and
/// changing entries needs the list's permission (suppliers: warehouse staff and admins; the
/// others: admins).
class CatalogueScreen extends StatelessWidget {
  const CatalogueScreen({super.key, required this.repository, required this.user});

  final CatalogueRepository repository;
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: CatalogueKind.values.length,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [for (final kind in CatalogueKind.values) Tab(text: kind.title)],
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final kind in CatalogueKind.values)
                  _CatalogueList(
                    kind: kind,
                    repository: repository,
                    canManage: user.can(kind.permission),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CatalogueList extends StatefulWidget {
  const _CatalogueList({required this.kind, required this.repository, required this.canManage});

  final CatalogueKind kind;
  final CatalogueRepository repository;
  final bool canManage;

  @override
  State<_CatalogueList> createState() => _CatalogueListState();
}

class _CatalogueListState extends State<_CatalogueList> with AutomaticKeepAliveClientMixin {
  bool _includeInactive = false;
  String? _error;
  List<CatalogueItem>? _items;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await widget.repository.list(widget.kind, includeInactive: _includeInactive);
      if (mounted) setState(() => _items = items);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _edit([CatalogueItem? item]) async {
    final saved = await showDialog<CatalogueItem>(
      context: context,
      builder: (_) =>
          _CatalogueItemDialog(kind: widget.kind, repository: widget.repository, item: item),
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          item == null
              ? 'Added ${widget.kind.singular} ${saved.label}.'
              : 'Saved ${widget.kind.singular} ${saved.label}.',
        ),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      floatingActionButton: widget.canManage
          ? FloatingActionButton.extended(
              heroTag: 'add-${widget.kind.path}',
              onPressed: _edit,
              icon: const Icon(Icons.add),
              label: Text('Add ${widget.kind.singular}'),
            )
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.canManage)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  label: const Text('Show deactivated'),
                  selected: _includeInactive,
                  onSelected: (value) {
                    setState(() => _includeInactive = value);
                    _load();
                  },
                ),
              ),
            ),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load ${widget.kind.title.toLowerCase()}',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return MessageView(
        icon: Icons.list_alt_outlined,
        title: 'No ${widget.kind.title.toLowerCase()} yet',
        message: widget.canManage
            ? 'Add the first ${widget.kind.singular} with the button below.'
            : 'An administrator adds these.',
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
          children: [
            for (final item in items) ...[
              ListTile(
                title: Text(item.name),
                subtitle: Text(
                  [
                    ?item.code,
                    for (final key in ['contactName', 'phone', 'email', 'address'])
                      if (item.values[key] case final String value) value,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: item.isDefault
                    ? const StatusBadge('Default')
                    : item.isActive
                    ? null
                    : const StatusBadge('Deactivated'),
                onTap: widget.canManage ? () => _edit(item) : null,
              ),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}

/// Adds or edits one entry; pops with the saved entry.
class _CatalogueItemDialog extends StatefulWidget {
  const _CatalogueItemDialog({required this.kind, required this.repository, this.item});

  final CatalogueKind kind;
  final CatalogueRepository repository;
  final CatalogueItem? item;

  @override
  State<_CatalogueItemDialog> createState() => _CatalogueItemDialogState();
}

class _CatalogueItemDialogState extends State<_CatalogueItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers = {
    for (final field in widget.kind.fields)
      field.key: TextEditingController(text: widget.item?.values[field.key] as String? ?? ''),
  };
  late bool _isActive = widget.item?.isActive ?? true;
  bool _saving = false;
  String? _error;
  Map<String, String> _serverErrors = {};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _validate(CatalogueField field, String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return field.required ? 'Required' : null;
    if (field.email && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)) {
      return 'Use an email address like sales@example.co.zw';
    }
    if (field.phone && !RegExp(r'^\+?[0-9][0-9 ()-]{5,22}$').hasMatch(text)) {
      return 'Use digits, spaces, brackets or dashes';
    }
    return null;
  }

  Future<void> _save() async {
    setState(() {
      _serverErrors = {};
      _error = null;
    });
    if (_saving || !_formKey.currentState!.validate()) return;
    final fields = <String, Object?>{
      for (final field in widget.kind.fields)
        field.key: _controllers[field.key]!.text.trim().isEmpty
            ? null
            : _controllers[field.key]!.text.trim(),
      if (widget.item != null) 'isActive': _isActive,
    };
    setState(() => _saving = true);
    try {
      final item = widget.item;
      final saved = item == null
          ? await widget.repository.create(widget.kind, fields)
          : await widget.repository.update(widget.kind, item.id, fields);
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
    final item = widget.item;
    return AlertDialog(
      title: Text(item == null ? 'Add ${widget.kind.singular}' : 'Edit ${widget.kind.singular}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[ErrorBanner(message: _error!), const SizedBox(height: 12)],
                for (final field in widget.kind.fields) ...[
                  TextFormField(
                    controller: _controllers[field.key],
                    enabled: !_saving,
                    maxLength: field.maxLength,
                    textCapitalization: field.upperCase
                        ? TextCapitalization.characters
                        : TextCapitalization.sentences,
                    keyboardType: field.phone
                        ? TextInputType.phone
                        : field.email
                        ? TextInputType.emailAddress
                        : TextInputType.text,
                    decoration: InputDecoration(
                      labelText: field.required ? field.label : '${field.label} (optional)',
                      border: const OutlineInputBorder(),
                      counterText: '',
                      errorText: _serverErrors[field.key],
                    ),
                    validator: (value) => _validate(field, value),
                  ),
                  const SizedBox(height: 12),
                ],
                if (item != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    subtitle: Text(
                      _serverErrors['isActive'] ??
                          (item.isDefault
                              ? 'The default warehouse stays active.'
                              : 'Deactivated entries cannot be chosen on new records.'),
                    ),
                    value: _isActive,
                    onChanged: _saving || item.isDefault
                        ? null
                        : (value) => setState(() => _isActive = value),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
