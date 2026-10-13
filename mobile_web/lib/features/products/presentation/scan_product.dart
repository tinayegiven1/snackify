import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/scanning/barcode_reader.dart';
import '../data/products_repository.dart';
import '../domain/product.dart';

/// Reads a barcode and finds its product (spec 6.7). An unknown barcode is explained clearly,
/// with the choice to scan again. Returns null if the user gives up.
Future<Product?> scanForProduct(
  BuildContext context, {
  required ProductsRepository products,
  required BarcodeReader readBarcode,
}) async {
  for (;;) {
    if (!context.mounted) return null;
    final barcode = await readBarcode(context);
    if (barcode == null || !context.mounted) return null;
    try {
      return await products.findByBarcode(barcode);
    } on ApiException catch (error) {
      if (!context.mounted) return null;
      final notFound = error.code == 'BARCODE_NOT_FOUND';
      final again = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Icon(notFound ? Icons.search_off : Icons.cloud_off_outlined),
          title: Text(notFound ? 'Barcode not found' : 'Could not look up the barcode'),
          content: Text(
            notFound
                ? '${error.message} Check that you scanned the right pack. An admin can add '
                      'the barcode to the product in Products.'
                : error.message,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Scan again'),
            ),
          ],
        ),
      );
      if (again != true) return null;
    }
  }
}
