import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A PIN box: digits only (a number keypad on phones), hidden with a show/hide button.
/// [isNew] tells password managers to offer a new PIN instead of filling in the saved one.
class PinField extends StatefulWidget {
  const PinField({
    super.key,
    required this.controller,
    required this.label,
    this.helper,
    this.errorText,
    this.isNew = false,
    this.enabled = true,
    this.autofocus = false,
    this.validator,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? helper;
  final String? errorText;
  final bool isNew;
  final bool enabled;
  final bool autofocus;
  final String? Function(String value)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PinField> createState() => _PinFieldState();
}

class _PinFieldState extends State<PinField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: !_visible,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(8),
      ],
      autofillHints: [widget.isNew ? AutofillHints.newPassword : AutofillHints.password],
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        helperMaxLines: 3,
        errorText: widget.errorText,
        errorMaxLines: 2,
        prefixIcon: const Icon(Icons.pin_outlined),
        border: const OutlineInputBorder(),
        // Left out of the Tab order, so Tab goes straight to the next box.
        suffixIcon: ExcludeFocus(
          child: IconButton(
            tooltip: _visible ? 'Hide PIN' : 'Show PIN',
            icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _visible = !_visible),
          ),
        ),
      ),
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      validator: widget.validator == null ? null : (raw) => widget.validator!(raw ?? ''),
    );
  }
}
