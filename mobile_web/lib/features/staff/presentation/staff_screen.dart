import 'package:flutter/material.dart';

import '../../../core/formatting/dates.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../auth/domain/app_user.dart';
import '../../organisations/data/organisations_repository.dart';
import '../data/staff_repository.dart';
import '../domain/staff_member.dart';
import 'staff_form_screen.dart';

/// Users & Roles (permission user.manage): who can sign in, for which organisation, with
/// which roles.
class StaffScreen extends StatefulWidget {
  const StaffScreen({
    super.key,
    required this.repository,
    required this.organisations,
    required this.currentUser,
  });

  final StaffRepository repository;
  final OrganisationsRepository organisations;

  /// The signed-in admin, who may not change their own roles or deactivate themselves.
  final AppUser currentUser;

  String get currentUserId => currentUser.id;

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  bool _loading = true;
  String? _error;
  List<StaffMember>? _staff;

  /// Confirms the last change in place, e.g. "Added Tendai Moyo".
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
      final staff = await widget.repository.list();
      if (!mounted) return;
      setState(() {
        _staff = staff;
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

  Future<void> _openForm([StaffMember? member]) async {
    final note = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => StaffFormScreen(
          repository: widget.repository,
          organisations: widget.organisations,
          defaultOrganisationId: widget.currentUser.organisation.id,
          member: member,
          isSelf: member?.id == widget.currentUserId,
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openForm,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add staff'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading && _staff != null) const LinearProgressIndicator(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return MessageView(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load staff',
        message: _error!,
        action: RetryButton(onPressed: _load),
      );
    }
    final staff = _staff;
    if (staff == null) return const Center(child: CircularProgressIndicator());

    final active = staff.where((member) => member.isActive).length;
    final summary =
        '$active active ${active == 1 ? 'account' : 'accounts'}'
        '${staff.length > active ? ', ${staff.length - active} deactivated' : ''}';

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 88),
          children: [
            if (_note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SuccessBanner(message: _note!),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(summary, style: Theme.of(context).textTheme.bodySmall),
            ),
            for (final member in staff) ...[
              _StaffTile(
                member: member,
                isSelf: member.id == widget.currentUserId,
                onTap: () => _openForm(member),
              ),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile({required this.member, required this.isSelf, required this.onTap});

  final StaffMember member;
  final bool isSelf;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lastSignIn = member.lastSignInAt;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: member.isActive
            ? null
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(initialsOf(member.fullName)),
      ),
      title: Text(isSelf ? '${member.fullName} (you)' : member.fullName),
      subtitle: Text(
        '${member.username} · ${member.roleNames}\n'
        '${member.organisation.name} · '
        '${lastSignIn == null ? 'Never signed in' : 'Last signed in ${formatApiDate(toApiDate(lastSignIn))}'}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: member.isActive ? null : const StatusBadge('Deactivated'),
      onTap: onTap,
    );
  }
}
