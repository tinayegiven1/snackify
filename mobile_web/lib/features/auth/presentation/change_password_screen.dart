import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/password_field.dart';
import '../../staff/domain/staff_member.dart';

/// Lets the signed-in person change their own password. Proving the current password is
/// required; afterwards this device stays signed in and every other one is signed out.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key, required this.changePassword});

  final Future<void> Function(String currentPassword, String newPassword) changePassword;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _repeat = TextEditingController();

  bool _saving = false;
  bool _done = false;
  String? _error;
  Map<String, String> _serverErrors = {};

  @override
  void dispose() {
    for (final controller in [_current, _new, _repeat]) {
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

    setState(() => _saving = true);
    try {
      await widget.changePassword(_current.text, _new.text);
      if (!mounted) return;
      for (final controller in [_current, _new, _repeat]) {
        controller.clear();
      }
      setState(() => _done = true);
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

  void _clearServerError(String field) {
    if (_serverErrors.containsKey(field)) {
      setState(() => _serverErrors = {..._serverErrors}..remove(field));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: _done ? _doneView() : _form(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _doneView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SuccessBanner(
          message:
              'Your password has been changed. You are still signed in here; any other phones '
              'or computers you were signed in on have been signed out.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _form() {
    return AutofillGroup(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[ErrorBanner(message: _error!), const SizedBox(height: 16)],
            PasswordField(
              controller: _current,
              label: 'Current password',
              enabled: !_saving,
              errorText: _serverErrors['currentPassword'],
              onChanged: (_) => _clearServerError('currentPassword'),
              validator: (value) => value.isEmpty ? 'Enter your current password' : null,
            ),
            const SizedBox(height: 16),
            PasswordField(
              controller: _new,
              label: 'New password',
              helper:
                  'At least $minPasswordLength characters. A short sentence is easy to remember '
                  'and hard to guess.',
              isNew: true,
              enabled: !_saving,
              errorText: _serverErrors['newPassword'],
              onChanged: (_) => _clearServerError('newPassword'),
              validator: (value) {
                final problem = checkNewPassword(value);
                if (problem != null) return problem;
                return value == _current.text
                    ? 'Must be different from the current password'
                    : null;
              },
            ),
            const SizedBox(height: 16),
            PasswordField(
              controller: _repeat,
              label: 'New password again',
              isNew: true,
              enabled: !_saving,
              validator: (value) => value == _new.text ? null : 'The two new passwords differ',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: _saving
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Change password'),
            ),
          ],
        ),
      ),
    );
  }
}
