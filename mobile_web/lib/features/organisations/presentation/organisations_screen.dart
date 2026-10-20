import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../customers/data/customers_repository.dart';
import '../data/organisations_repository.dart';
import '../domain/organisation.dart';
import 'organisation_form_screen.dart';

/// The Head Office and its subsidiaries. Head Office staff see all of them; a subsidiary's staff
/// see their own. Admins (organisation.manage) add subsidiaries and change details.
class OrganisationsScreen extends StatefulWidget {
  const OrganisationsScreen({
    super.key,
    required this.repository,
    required this.customers,
    required this.canManage,
  });

  final OrganisationsRepository repository;
  final CustomersRepository customers;
  final bool canManage;

  @override
  State<OrganisationsScreen> createState() => _OrganisationsScreenState();
}

class _OrganisationsScreenState extends State<OrganisationsScreen> {
  bool _includeInactive = false;
  bool _loading = true;
  String? _error;
  List<Organisation>? _organisations;
  String? _note;

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
      final organisations = await widget.repository.list(includeInactive: _includeInactive);
      if (!mounted) return;
      setState(() {
        _organisations = organisations;
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

  Future<void> _open([Organisation? organisation]) async {
    final note = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => OrganisationFormScreen(
          repository: widget.repository,
          customers: widget.customers,
          organisation: organisation,
          canEdit: widget.canManage,
        ),
      ),
    );
    if (!mounted) return;
    if (note != null) setState(() => _note = note);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: widget.canManage
          ? FloatingActionButton.extended(
              onPressed: _open,
              icon: const Icon(Icons.add_business_outlined),
              label: const Text('Add subsidiary'),
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
          if (_loading && _organisations != null) const LinearProgressIndicator(),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load organisations',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final organisations = _organisations;
    if (organisations == null) return const Center(child: CircularProgressIndicator());

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
          children: [
            if (_note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SuccessBanner(message: _note!),
              ),
            for (final organisation in organisations) ...[
              ListTile(
                leading: CircleAvatar(
                  child: Icon(organisation.isHeadOffice ? Icons.domain : Icons.storefront_outlined),
                ),
                title: Text(organisation.name),
                subtitle: Text(
                  [
                    '${organisation.code} · ${organisation.typeLabel}',
                    ?organisation.contactPhone,
                    ?organisation.address,
                  ].join('\n'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: organisation.contactPhone != null || organisation.address != null,
                trailing: organisation.isActive ? null : const StatusBadge('Deactivated'),
                onTap: () => _open(organisation),
              ),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}
