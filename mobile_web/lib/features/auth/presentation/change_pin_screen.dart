import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/pin_field.dart';
import '../../staff/domain/staff_member.dart';

/// Lets the signed-in person choose a new PIN. Normally they prove their current PIN; afterwards
/// this device stays signed in and every other one is signed out.
///
/// With [firstPin] the account is still on the default PIN (1234): this is the only screen it
/// may use, it asks for the new PIN only, and offers signing out instead of going back.
class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({
    super.key,
    required this.changePin,
    this.firstPin = false,
    this.onSignOut,
  });

  final Future<void> Function(String currentPin, String newPin) changePin;
  final bool firstPin;
  final Future<void> Function()? onSignOut;

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
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
      await widget.changePin(widget.firstPin ? defaultPin : _current.text, _new.text);
      if (!mounted) return;
      for (final controller in [_current, _new, _repeat]) {
        controller.clear();
      }
      // After the first PIN, the app itself moves on to the main screens.
      if (!widget.firstPin) setState(() => _done = true);
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
      appBar: AppBar(
        title: Text(widget.firstPin ? 'Choose your PIN' : 'Change PIN'),
        automaticallyImplyLeading: !widget.firstPin,
        actions: [
          if (widget.firstPin && widget.onSignOut != null)
            TextButton(onPressed: widget.onSignOut, child: const Text('Sign out')),
        ],
      ),
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
              'Your PIN has been changed. You are still signed in here; any other phones or '
              'computers you were signed in on have been signed out.',
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
            if (widget.firstPin) ...[
              const Text(
                'You signed in with the starting PIN 1234, which everyone knows. Choose your '
                'own PIN to continue, and keep it to yourself.',
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[ErrorBanner(message: _error!), const SizedBox(height: 16)],
            if (!widget.firstPin) ...[
              PinField(
                controller: _current,
                label: 'Current PIN',
                enabled: !_saving,
                errorText: _serverErrors['currentPin'],
                onChanged: (_) => _clearServerError('currentPin'),
                validator: (value) => value.isEmpty ? 'Enter your current PIN' : null,
              ),
              const SizedBox(height: 16),
            ],
            PinField(
              controller: _new,
              label: 'New PIN',
              helper: '$minPinLength to $maxPinLength digits. Not 1234, 0000, 4321 or the like.',
              isNew: true,
              autofocus: widget.firstPin,
              enabled: !_saving,
              errorText: _serverErrors['newPin'],
              onChanged: (_) => _clearServerError('newPin'),
              validator: (value) {
                final problem = checkNewPin(value);
                if (problem != null) return problem;
                return !widget.firstPin && value == _current.text
                    ? 'Must be different from the current PIN'
                    : null;
              },
            ),
            const SizedBox(height: 16),
            PinField(
              controller: _repeat,
              label: 'New PIN again',
              isNew: true,
              enabled: !_saving,
              onSubmitted: (_) => _save(),
              validator: (value) => value == _new.text ? null : 'The two PINs differ',
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
                  : Text(widget.firstPin ? 'Save my PIN' : 'Change PIN'),
            ),
          ],
        ),
      ),
    );
  }
}
