import '../features/customers/data/customers_repository.dart';
import '../features/dispatches/data/dispatches_repository.dart';
import '../features/invoices/data/invoices_repository.dart';
import '../features/products/data/products_repository.dart';
import '../features/stock/data/stock_repository.dart';
import 'files/pdf_sharer.dart';

/// The backend services that screens use. Created once in main.dart; tests pass fakes.
class AppServices {
  const AppServices({
    required this.checkBackendHealth,
    required this.products,
    required this.stock,
    required this.customers,
    required this.dispatches,
    required this.invoices,
    required this.sharePdf,
  });

  /// Returns true when the Snackify API is reachable.
  final Future<bool> Function() checkBackendHealth;
  final ProductsRepository products;
  final StockRepository stock;
  final CustomersRepository customers;
  final DispatchesRepository dispatches;
  final InvoicesRepository invoices;

  /// Downloads (web) or shares (phones) a PDF such as an invoice.
  final PdfSharer sharePdf;
}
