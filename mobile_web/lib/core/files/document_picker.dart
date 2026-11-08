import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// A file the user chose to attach, e.g. a supplier invoice.
typedef PickedDocument = ({String name, Uint8List bytes});

/// Lets the user choose documents to attach: PDFs and photos (JPEG, PNG). Returns an empty
/// list when they cancel. The server checks each file's real type, whatever its name says.
typedef DocumentPicker = Future<List<PickedDocument>> Function();

/// Takes a photo of a document with the camera; null when the user cancels.
typedef PhotoTaker = Future<PickedDocument?> Function();

Future<List<PickedDocument>> pickDocumentsWithDevice() async {
  final files = await FilePicker.pickFiles(
    dialogTitle: 'Choose the supplier invoice or delivery note',
    type: FileType.custom,
    allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
  );
  return [for (final file in files) (name: file.name, bytes: await file.readAsBytes())];
}

/// Opens the camera (phones; on a computer's browser, the file chooser) and returns the photo,
/// made smaller so it uploads quickly but stays readable.
Future<PickedDocument?> takePhotoWithDevice() async {
  final photo = await ImagePicker().pickImage(
    source: ImageSource.camera,
    maxWidth: 2400,
    maxHeight: 2400,
    imageQuality: 85,
  );
  if (photo == null) return null;
  final bytes = await photo.readAsBytes();
  return (name: photoFileName(DateTime.now(), bytes), bytes: bytes);
}

/// e.g. "photo-20261108-143005.jpg" (".png" when the picture is a PNG).
String photoFileName(DateTime time, Uint8List bytes) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${time.year}${two(time.month)}${two(time.day)}-'
      '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  return 'photo-$stamp.${isPng(bytes) ? 'png' : 'jpg'}';
}

bool isPng(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

bool isJpeg(Uint8List bytes) =>
    bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;

/// True when [bytes] are a picture that can be previewed (JPEG or PNG), whatever the name says.
bool isPicture(Uint8List bytes) => isJpeg(bytes) || isPng(bytes);
