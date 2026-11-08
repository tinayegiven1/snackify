import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/files/document_picker.dart';

/// A small picture of a supplier document for the start of its row: the photo itself, or a
/// PDF icon. [bytes] is null while the document is still downloading.
class DocumentThumbnail extends StatelessWidget {
  const DocumentThumbnail({super.key, required this.isPdf, this.bytes, this.loading = false});

  final bool isPdf;
  final Uint8List? bytes;
  final bool loading;

  static const double size = 56;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget child;
    final data = bytes;
    if (isPdf || (data != null && !isPicture(data))) {
      child = Icon(Icons.picture_as_pdf_outlined, color: colors.onSurfaceVariant);
    } else if (data == null) {
      child = loading
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(Icons.image_outlined, color: colors.onSurfaceVariant);
    } else {
      child = Image.memory(
        data,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            Icon(Icons.broken_image_outlined, color: colors.onSurfaceVariant),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: size,
        height: size,
        color: colors.surfaceContainerHighest,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// Shows a document photo full screen; pinch or scroll to zoom.
Future<void> showDocumentPreview(BuildContext context, String name, Uint8List bytes) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Image.memory(
                  bytes,
                  key: const ValueKey('document-preview-image'),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Text(
                    'This picture cannot be shown.',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Material(
                color: Colors.black54,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close preview',
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Downloads saved documents' pictures once and remembers them, so rows can show thumbnails.
class DocumentPictureCache {
  DocumentPictureCache(this._download);

  final Future<Uint8List> Function(String documentId) _download;
  final Map<String, Uint8List> _bytes = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};

  Uint8List? bytesOf(String documentId) => _bytes[documentId];
  bool isLoading(String documentId) => _loading.contains(documentId);

  /// Starts downloading [documentId] unless it is already here; [changed] runs when it lands.
  void ensure(String documentId, VoidCallback changed) {
    if (_bytes.containsKey(documentId) ||
        _loading.contains(documentId) ||
        _failed.contains(documentId)) {
      return;
    }
    _loading.add(documentId);
    _download(documentId)
        .then((bytes) => _bytes[documentId] = bytes)
        .catchError((Object _) {
          _failed.add(documentId);
          return Uint8List(0);
        })
        .whenComplete(() {
          _loading.remove(documentId);
          changed();
        });
  }
}
