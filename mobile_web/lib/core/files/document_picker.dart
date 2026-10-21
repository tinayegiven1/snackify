import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// A file the user chose to attach, e.g. a supplier invoice.
typedef PickedDocument = ({String name, Uint8List bytes});

/// Lets the user choose documents to attach: PDFs and photos (JPEG, PNG). Returns an empty
/// list when they cancel. The server checks each file's real type, whatever its name says.
typedef DocumentPicker = Future<List<PickedDocument>> Function();

Future<List<PickedDocument>> pickDocumentsWithDevice() async {
  final files = await FilePicker.pickFiles(
    dialogTitle: 'Choose the supplier invoice or delivery note',
    type: FileType.custom,
    allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
  );
  return [for (final file in files) (name: file.name, bytes: await file.readAsBytes())];
}
