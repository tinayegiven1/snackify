import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';

/// Hands a PDF to the device: in a web browser it is downloaded; on a phone the share sheet
/// opens, to save, print or send it (for example to the customer).
typedef PdfSharer = Future<void> Function(Uint8List bytes, String filename);

Future<void> sharePdfWithDevice(Uint8List bytes, String filename) async {
  await Printing.sharePdf(bytes: bytes, filename: filename);
}

/// The button label for [sharePdfWithDevice] on this platform.
const String sharePdfLabel = kIsWeb ? 'Download PDF' : 'Share PDF';
