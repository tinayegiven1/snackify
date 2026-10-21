import '../features/audit/data/audit_repository.dart';
import '../features/catalogue/data/catalogue_repository.dart';
import '../features/customers/data/customers_repository.dart';
import '../features/dispatches/data/dispatches_repository.dart';
import '../features/forecasts/data/forecasts_repository.dart';
import '../features/invoices/data/invoices_repository.dart';
import '../features/organisations/data/organisations_repository.dart';
import '../features/payments/data/payments_repository.dart';
import '../features/products/data/products_repository.dart';
import '../features/receipts/data/receipts_repository.dart';
import '../features/reports/data/reports_repository.dart';
import '../features/staff/data/staff_repository.dart';
import '../features/stock/data/stock_repository.dart';
import 'files/document_picker.dart';
import 'files/pdf_sharer.dart';
import 'scanning/barcode_reader.dart';

/// The backend services that screens use. Created once in main.dart; tests pass fakes.
class AppServices {
  const AppServices({
    required this.checkBackendHealth,
    required this.products,
    required this.stock,
    required this.customers,
    required this.dispatches,
    required this.invoices,
    required this.payments,
    required this.reports,
    required this.forecasts,
    required this.staff,
    required this.organisations,
    required this.audit,
    required this.receipts,
    required this.catalogue,
    required this.sharePdf,
    required this.readBarcode,
    required this.pickDocuments,
  });

  /// Returns true when the Snackify API is reachable.
  final Future<bool> Function() checkBackendHealth;
  final ProductsRepository products;
  final StockRepository stock;
  final CustomersRepository customers;
  final DispatchesRepository dispatches;
  final InvoicesRepository invoices;
  final PaymentsRepository payments;
  final ReportsRepository reports;
  final ForecastsRepository forecasts;

  /// Staff accounts and roles (user.manage).
  final StaffRepository staff;
  final OrganisationsRepository organisations;
  final AuditRepository audit;

  /// Goods-received notes and their documents (StockFlow Stage 4).
  final ReceiptsRepository receipts;

  /// Suppliers, categories, warehouses and units.
  final CatalogueRepository catalogue;

  /// Downloads (web) or shares (phones) a PDF such as an invoice.
  final PdfSharer sharePdf;

  /// Reads a barcode: the camera on phones, typed (or a USB scanner) on the web.
  final BarcodeReader readBarcode;

  /// Lets the user choose supplier documents (PDFs, photos) to attach.
  final DocumentPicker pickDocuments;
}
