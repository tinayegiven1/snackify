import '../../../core/files/document_picker.dart';
import '../../../core/files/pdf_sharer.dart';
import '../../../core/scanning/barcode_reader.dart';
import '../../auth/domain/app_user.dart';
import '../../catalogue/data/catalogue_repository.dart';
import '../../organisations/data/organisations_repository.dart';
import '../../products/data/products_repository.dart';
import '../data/receipts_repository.dart';

/// What the goods-received screens need, passed along together.
class ReceiptServices {
  const ReceiptServices({
    required this.receipts,
    required this.catalogue,
    required this.organisations,
    required this.products,
    required this.user,
    required this.pickDocuments,
    required this.sharePdf,
    required this.readBarcode,
  });

  final ReceiptsRepository receipts;
  final CatalogueRepository catalogue;
  final OrganisationsRepository organisations;
  final ProductsRepository products;
  final AppUser user;
  final DocumentPicker pickDocuments;

  /// Downloads (web) or shares (phones) a file: the GRN PDF or a supplier document.
  final PdfSharer sharePdf;

  /// Scans a pack's barcode to choose the product.
  final BarcodeReader readBarcode;

  /// Records deliveries (warehouse staff).
  bool get canReceive => user.can('stock.receive');

  /// Checks documents and accepts or rejects receipts (finance).
  bool get canVerify => user.can('receipt.verify');

  /// Cancels a posted receipt, taking its stock back out (administrators).
  bool get canReverse => user.can('receipt.reverse');

  /// May submit without a supplier document, giving a reason (administrators).
  bool get canSkipDocument => user.can('receipt.no_document');

  /// Head Office staff may record deliveries for a subsidiary.
  bool get canChooseOwner => user.seesAllOrganisations;
}
