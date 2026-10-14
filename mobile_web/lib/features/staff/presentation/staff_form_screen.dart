import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/password_field.dart';
import '../../auth/domain/app_user.dart';
import '../data/staff_repository.dart';
import '../domain/staff_member.dart';

/// Adds a staff account, or edits [member] when it is given. Pops with a short note saying
/// what was done, for the staff list to show.
class StaffFormScreen extends StatefulWidget {
  const StaffFormScreen({super.key, required this.repository, this.member, this.isSelf = false});

  final StaffRepository repository;
  final StaffMember? member;

  /// Admins cannot change their own role, deactivate themselves or reset their own password
  /// here (the server refuses too), so the business always keeps an admin.
  final bool isSelf;

  @override
  State<StaffFormScreen> createState() => _StaffFormScreenState();
}

class _StaffFormScreenState extends State<StaffFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _fullName = TextEditingController(text: widget.member?.fullName);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  late StaffRole? _role = widget.member?.role;
  late bool _isActive = widget.member?.isActive ?? true;

  bool _saving = false;
  String? _error;
  String? _passwordNote;
  Map<String, String> _serverErrors = {};

  bool get _isNew => widget.member == null;

  @override
  void dispose() {
    for (final controller in [_fullName, _username, _password, _repeat]) {
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

    final member = widget.member;
    final deactivating = member != null && member.isActive && !_isActive;
    if (deactivating && !await _confirmDeactivate(member)) return;

    setState(() => _saving = true);
    try {
      final String note;
      if (member == null) {
        final added = await widget.repository.create(
          username: _username.text.trim().toLowerCase(),
          fullName: _fullName.text.trim(),
          role: _role!,
          password: _password.text,
        );
        note =
            'Added ${added.fullName} as ${added.role.label}. They sign in as '
            '"${added.username}" with the password you chose: give it to them privately.';
      } else {
        final fullName = _fullName.text.trim();
        final nameChanged = fullName != member.fullName;
        final roleChanged = _role != member.role;
        final activeChanged = _isActive != member.isActive;
        if (!nameChanged && !roleChanged && !activeChanged) {
          if (mounted) Navigator.of(context).pop();
          return;
        }
        final saved = await widget.repository.update(
          member.id,
          fullName: nameChanged ? fullName : null,
          role: roleChanged ? _role : null,
          isActive: activeChanged ? _isActive : null,
        );
        note = deactivating
            ? 'Deactivated ${saved.fullName}. They were signed out and can no longer sign in.'
            : activeChanged
            ? 'Reactivated ${saved.fullName}. They can sign in again.'
            : 'Saved changes to ${saved.fullName}.';
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

  Future<bool> _confirmDeactivate(StaffMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Deactivate ${member.fullName}?'),
        content: const Text(
          'They are signed out on every phone and computer at once and can no longer sign in. '
          'Everything they recorded is kept. You can reactivate the account later.',
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

  Future<void> _resetPassword(StaffMember member) async {
    final reset = await showDialog<bool>(
      context: context,
      builder: (_) => _ResetPasswordDialog(repository: widget.repository, member: member),
    );
    if (reset == true && mounted) {
      setState(
        () => _passwordNote =
            'New password set for ${member.fullName}. They were signed out everywhere; give '
            'them the new password privately.',
      );
    }
  }

  void _clearServerError(String field) {
    if (_serverErrors.containsKey(field)) {
      setState(() => _serverErrors = {..._serverErrors}..remove(field));
    }
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'Add staff member' : 'Edit staff member')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null) ...[
                        ErrorBanner(message: _error!),
                        const SizedBox(height: 16),
                      ],
                      if (member != null) ...[
                        Text(
                          'Signs in as "${member.username}"',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 16),
                      ],
                      _textField(
                        'fullName',
                        _fullName,
                        'Full name',
                        hint: 'e.g. Tendai Moyo',
                        capitalization: TextCapitalization.words,
                        maxLength: 100,
                        validator: (value) => value.isEmpty ? 'Required' : null,
                      ),
                      if (_isNew)
                        _textField(
                          'username',
                          _username,
                          'Username',
                          hint: 'e.g. tendai.moyo',
                          helper: 'What they type to sign in. It cannot be changed later.',
                          validator: (value) {
                            if (value.isEmpty) return 'Required';
                            return usernameFormat.hasMatch(value.toLowerCase())
                                ? null
                                : 'Use 3–32 letters, digits, dots, dashes or underscores, '
                                      'starting with a letter or digit';
                          },
                        ),
                      _roleField(),
                      const SizedBox(height: 16),
                      if (_isNew) ..._newPasswordFields(),
                      if (!_isNew)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Active'),
                          subtitle: Text(
                            widget.isSelf
                                ? 'You cannot deactivate your own account.'
                                : 'Deactivated staff cannot sign in. Everything they recorded '
                                      'is kept.',
                          ),
                          value: _isActive,
                          onChanged: _saving || widget.isSelf
                              ? null
                              : (value) => setState(() => _isActive = value),
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
                            : Text(_isNew ? 'Add staff member' : 'Save changes'),
                      ),
                      if (member != null) ..._passwordSection(member),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _roleField() {
    final role = _role;
    return DropdownButtonFormField<StaffRole>(
      initialValue: role,
      isExpanded: true,
      // Clears "Choose a role" as soon as one is chosen, revealing what the role may do.
      autovalidateMode: AutovalidateMode.onUserInteraction,
      decoration: InputDecoration(
        labelText: 'Role',
        border: const OutlineInputBorder(),
        helperText: widget.isSelf
            ? 'You cannot change your own role. Ask another admin.'
            : role == null
            ? 'Decides what they can see and do.'
            : roleDescription(role),
        helperMaxLines: 3,
        errorText: _serverErrors['role'],
      ),
      items: [
        for (final option in StaffRole.values)
          DropdownMenuItem(value: option, child: Text(option.label)),
      ],
      onChanged: _saving || widget.isSelf ? null : (value) => setState(() => _role = value),
      validator: (value) => value == null ? 'Choose a role' : null,
    );
  }

  List<Widget> _newPasswordFields() => [
    PasswordField(
      controller: _password,
      label: 'Password',
      helper:
          'At least $minPasswordLength characters. Give it to them privately (not in a group '
          'chat); they can change it after signing in, under Change password in the menu.',
      isNew: true,
      enabled: !_saving,
      errorText: _serverErrors['password'],
      onChanged: (_) => _clearServerError('password'),
      validator: checkNewPassword,
    ),
    const SizedBox(height: 16),
    PasswordField(
      controller: _repeat,
      label: 'Password again',
      isNew: true,
      enabled: !_saving,
      validator: (value) => value == _password.text ? null : 'The two passwords differ',
    ),
  ];

  List<Widget> _passwordSection(StaffMember member) => [
    const Divider(height: 48),
    Text('Password', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 8),
    if (_passwordNote != null) ...[
      SuccessBanner(message: _passwordNote!),
      const SizedBox(height: 8),
    ],
    if (widget.isSelf)
      const Text('To change your own password, use Change password in the menu.')
    else ...[
      Text(
        'If ${member.fullName} has forgotten their password, set a new one and give it to them '
        'privately.',
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _saving ? null : () => _resetPassword(member),
          icon: const Icon(Icons.lock_reset),
          label: const Text('Set a new password'),
        ),
      ),
    ],
  ];

  Widget _textField(
    String field,
    TextEditingController controller,
    String label, {
    String? hint,
    String? helper,
    int? maxLength,
    TextCapitalization capitalization = TextCapitalization.none,
    String? Function(String value)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        enabled: !_saving,
        textCapitalization: capitalization,
        autocorrect: false,
        maxLength: maxLength,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
          errorText: _serverErrors[field],
          errorMaxLines: 2,
          counterText: '',
        ),
        onChanged: (_) => _clearServerError(field),
        validator: (raw) => validator?.call((raw ?? '').trim()),
      ),
    );
  }
}

/// Asks for a new password (twice) and sets it. Pops with true once it is set.
class _ResetPasswordDialog extends StatefulWidget {
  const _ResetPasswordDialog({required this.repository, required this.member});

  final StaffRepository repository;
  final StaffMember member;

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.repository.resetPassword(widget.member.id, _password.text);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.fieldErrors['newPassword'] ?? error.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('New password for ${widget.member.fullName}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[ErrorBanner(message: _error!), const SizedBox(height: 16)],
                Text(
                  'They are signed out on every phone and computer, and sign in again with the '
                  'new password.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                PasswordField(
                  controller: _password,
                  label: 'New password',
                  helper: 'At least $minPasswordLength characters.',
                  isNew: true,
                  enabled: !_saving,
                  validator: checkNewPassword,
                ),
                const SizedBox(height: 16),
                PasswordField(
                  controller: _repeat,
                  label: 'New password again',
                  isNew: true,
                  enabled: !_saving,
                  validator: (value) => value == _password.text ? null : 'The two passwords differ',
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _saving ? null : _submit, child: const Text('Set password')),
      ],
    );
  }
}
