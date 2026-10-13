import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'camera_scan_screen.dart';
import 'manual_barcode_dialog.dart';

/// Reads one barcode, or returns null if the user gives up. Screens receive this as a
/// dependency, so tests can scan pretend barcodes.
typedef BarcodeReader = Future<String?> Function(BuildContext context);

/// Phones scan with their camera. In a web browser the barcode is typed, or comes from a USB or
/// Bluetooth scanner, which types it like a keyboard (spec 6.7: manual entry when the camera
/// is not available).
bool get cameraScanningAvailable =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Reads a barcode with the camera where there is one, otherwise asks for it to be typed.
Future<String?> readBarcodeWithDevice(BuildContext context) {
  if (cameraScanningAvailable) {
    return Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const CameraScanScreen()));
  }
  return askForBarcode(context);
}
