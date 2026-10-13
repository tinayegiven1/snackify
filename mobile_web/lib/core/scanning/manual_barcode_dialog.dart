import 'package:flutter/material.dart';

final _barcodeCharacters = RegExp(r'^[A-Za-z0-9-]+$');

/// Asks for a barcode to be typed, or scanned with a USB or Bluetooth scanner (which types the
/// number and presses Enter). Spaces are ignored. Returns null if cancelled.
Future<String?> askForBarcode(BuildContext context) {
  return showDialog<String>(context: context, builder: (_) => const _ManualBarcodeDialog());
}

class _ManualBarcodeDialog extends StatefulWidget {
  const _ManualBarcodeDialog();

  @override
  State<_ManualBarcodeDialog> createState() => _ManualBarcodeDialogState();
}

class _ManualBarcodeDialogState extends State<_ManualBarcodeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _barcode = TextEditingController();

  @override
  void dispose() {
    _barcode.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_barcode.text.replaceAll(RegExp(r'\s+'), ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter a barcode'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _barcode,
          autofocus: true,
          maxLength: 60,
          textInputAction: TextInputAction.search,
          onFieldSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: 'Barcode',
            helperText: 'Type the number under the bars, or scan with a USB scanner.',
            helperMaxLines: 2,
            border: OutlineInputBorder(),
            counterText: '',
          ),
          validator: (value) {
            final barcode = (value ?? '').replaceAll(RegExp(r'\s+'), '');
            if (barcode.isEmpty) return 'Enter the barcode';
            if (!_barcodeCharacters.hasMatch(barcode)) {
              return 'A barcode has only letters, digits and dashes';
            }
            return null;
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Find product')),
      ],
    );
  }
}
