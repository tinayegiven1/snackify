import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/pin_field.dart';
import '../../../shared/widgets/snackify_logo.dart';
import 'auth_controller.dart';
import '../../../shared/widgets/message_view.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _pin = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.auth.signIn(_username.text.trim(), _pin.text);
      // On success the app replaces this screen with the dashboard.
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object catch (error) {
      // Anything else (for example the browser refusing to store the sign-in) must not leave
      // the person on this screen with no explanation.
      debugPrint('Sign-in could not be completed: $error');
      if (mounted) {
        setState(
          () => _error =
              'Signed in, but this device could not keep the sign-in. Try again, or open '
              'Snackify in another browser.',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = _error ?? widget.auth.notice;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: SnackifyLogo(size: 96)),
                      const SizedBox(height: 24),
                      Text(
                        'Sign in to Snackify',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: SnackifyColors.brandBlue,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (message != null) ...[
                        ErrorBanner(message: message),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        controller: _username,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        autofillHints: const [AutofillHints.username],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        enabled: !_submitting,
                        validator: (value) =>
                            (value ?? '').trim().isEmpty ? 'Enter your username' : null,
                      ),
                      const SizedBox(height: 16),
                      PinField(
                        controller: _pin,
                        label: 'PIN',
                        enabled: !_submitting,
                        onSubmitted: (_) => _submit(),
                        validator: (value) => value.isEmpty ? 'Enter your PIN' : null,
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        child: _submitting
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Sign in'),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'New here? Your first PIN is 1234. Forgot your PIN? Ask an admin to '
                        'reset it.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
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
}
