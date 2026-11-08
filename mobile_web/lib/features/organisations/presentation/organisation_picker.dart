import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../data/organisations_repository.dart';
import '../domain/organisation.dart';

/// Shows a searchable list of active subsidiaries (the customers that dispatches, invoices and
/// payments are for) and returns the one chosen (or null).
Future<Organisation?> pickOrganisation(BuildContext context, OrganisationsRepository repository) {
  return showDialog<Organisation>(
    context: context,
    builder: (_) => _OrganisationPickerDialog(repository: repository),
  );
}

class _OrganisationPickerDialog extends StatefulWidget {
  const _OrganisationPickerDialog({required this.repository});

  final OrganisationsRepository repository;

  @override
  State<_OrganisationPickerDialog> createState() => _OrganisationPickerDialogState();
}

class _OrganisationPickerDialogState extends State<_OrganisationPickerDialog> {
  final _search = TextEditingController();
  bool _loading = true;
  String? _error;
  List<Organisation> _organisations = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The server has no search, so the whole (short) list is loaded once and filtered here.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final organisations = await widget.repository.list(subsidiariesOnly: true);
      if (!mounted) return;
      setState(() {
        // Only active subsidiaries can receive new dispatches and payments.
        _organisations = organisations
            .where((organisation) => organisation.isActive && !organisation.isHeadOffice)
            .toList();
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  List<Organisation> get _matches {
    final search = _search.text.trim().toLowerCase();
    if (search.isEmpty) return _organisations;
    return _organisations
        .where(
          (organisation) =>
              organisation.name.toLowerCase().contains(search) ||
              organisation.code.toLowerCase().contains(search),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Choose a customer', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search name or code',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load customers',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final matches = _matches;
    if (matches.isEmpty) {
      return const MessageView(
        icon: Icons.search_off,
        title: 'No matching customers',
        message:
            'Customers are the subsidiaries. Check the spelling, or ask an admin to add the '
            'subsidiary under Organisations first.',
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final organisation = matches[index];
        return ListTile(
          leading: const Icon(Icons.storefront_outlined),
          title: Text(organisation.name),
          subtitle: Text([organisation.code, ?organisation.contactPhone].join(' · ')),
          onTap: () => Navigator.of(context).pop(organisation),
        );
      },
    );
  }
}
