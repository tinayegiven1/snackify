import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../shared/widgets/message_view.dart';
import 'manual_barcode_dialog.dart';

/// Full-screen camera view that closes with the first barcode it reads, so one scan can never
/// be added twice. Offers typing the barcode instead when the camera cannot read it.
class CameraScanScreen extends StatefulWidget {
  const CameraScanScreen({super.key});

  @override
  State<CameraScanScreen> createState() => _CameraScanScreenState();
}

class _CameraScanScreenState extends State<CameraScanScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    // The 1D codes found on snack packs, shelf labels and outer cartons (ITF-14).
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.itf14,
    ],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final code = capture.barcodes
        .map((barcode) => barcode.rawValue?.trim())
        .firstWhere((value) => value != null && value.isNotEmpty, orElse: () => null);
    if (code == null) return;
    _done = true;
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(code);
  }

  Future<void> _typeInstead() async {
    await _controller.stop();
    if (!mounted) return;
    final code = await askForBarcode(context);
    if (!mounted) return;
    if (code != null) {
      _done = true;
      Navigator.of(context).pop(code);
    } else {
      await _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan a barcode'),
        actions: [
          IconButton(
            tooltip: 'Torch',
            onPressed: _controller.toggleTorch,
            icon: const Icon(Icons.flashlight_on_outlined),
          ),
          TextButton(onPressed: _typeInstead, child: const Text('Type it')),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: MessageView(
                icon: Icons.no_photography_outlined,
                title: error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Camera access is off'
                    : 'The camera is not available',
                message: error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Allow Snackify to use the camera in your phone\'s settings, or type the '
                          'barcode instead.'
                    : 'Type the barcode instead.',
                action: FilledButton.icon(
                  onPressed: _typeInstead,
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Type the barcode'),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 280,
                height: 160,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: IgnorePointer(
              child: Text(
                'Hold the barcode inside the frame',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  shadows: [Shadow(blurRadius: 4)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
