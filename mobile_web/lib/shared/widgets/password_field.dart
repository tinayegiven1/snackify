import 'package:flutter/material.dart';

/// A password box with a show/hide button. [isNew] tells password managers to offer a new
/// password instead of filling in the saved one.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.helper,
    this.errorText,
    this.isNew = false,
    this.enabled = true,
    this.validator,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? helper;
  final String? errorText;
  final bool isNew;
  final bool enabled;
  final String? Function(String value)? validator;
  final ValueChanged<String>? onChanged;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: !_visible,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: [widget.isNew ? AutofillHints.newPassword : AutofillHints.password],
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        helperMaxLines: 3,
        errorText: widget.errorText,
        errorMaxLines: 2,
        prefixIcon: const Icon(Icons.lock_outline),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _visible ? 'Hide password' : 'Show password',
          icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _visible = !_visible),
        ),
      ),
      onChanged: widget.onChanged,
      validator: widget.validator == null ? null : (raw) => widget.validator!(raw ?? ''),
    );
  }
}
