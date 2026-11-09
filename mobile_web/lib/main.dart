import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_services.dart';
import 'core/config/app_config.dart';
import 'core/files/document_picker.dart';
import 'core/files/pdf_sharer.dart';
import 'core/network/api_client.dart';
import 'core/scanning/barcode_reader.dart';
import 'core/network/backend_health_service.dart';
import 'core/network/response_cache.dart';
import 'core/network/sync_service.dart';
import 'features/catalogue/domain/catalogue_models.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/data/token_store.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/audit/data/audit_repository.dart';
import 'features/catalogue/data/catalogue_repository.dart';
import 'features/dispatches/data/dispatches_repository.dart';
import 'features/forecasts/data/forecasts_repository.dart';
import 'features/invoices/data/invoices_repository.dart';
import 'features/orders/data/orders_repository.dart';
import 'features/organisations/data/organisations_repository.dart';
import 'features/payments/data/payments_repository.dart';
import 'features/products/data/products_repository.dart';
import 'features/purchases/data/purchases_repository.dart';
import 'features/receipts/data/receipts_repository.dart';
import 'features/reports/data/reports_repository.dart';
import 'features/staff/data/staff_repository.dart';
import 'features/stock/data/stock_repository.dart';

void main() {
  final api = ApiClient(baseUrl: AppConfig.apiBaseUrl, cache: ResponseCache.forDevice());
  final auth = AuthController(AuthRepository(api: api, tokenStore: deviceTokenStore()))..restore();
  final health = BackendHealthService(api).isHealthy;
  final products = ProductsRepository(api);
  final stock = StockRepository(api);
  final organisations = OrganisationsRepository(api);
  final receipts = ReceiptsRepository(api);
  final purchases = PurchasesRepository(api);
  final catalogue = CatalogueRepository(api);
  final reports = ReportsRepository(api);
  final services = AppServices(
    checkBackendHealth: health,
    products: products,
    stock: stock,
    dispatches: DispatchesRepository(api),
    invoices: InvoicesRepository(api),
    payments: PaymentsRepository(api),
    reports: reports,
    forecasts: ForecastsRepository(api),
    staff: StaffRepository(api),
    organisations: organisations,
    audit: AuditRepository(api),
    receipts: receipts,
    purchases: purchases,
    catalogue: catalogue,
    orders: OrdersRepository(api),
    sharePdf: sharePdfWithDevice,
    readBarcode: readBarcodeWithDevice,
    pickDocuments: pickDocumentsWithDevice,
    takePhoto: takePhotoWithDevice,
    connection: api.connection,
    sync: SyncService(
      api: api,
      checkHealth: health,
      // What the main screens show first, fetched the same way so the saved copies match.
      refreshers: [
        () => api.getJson('/api/v1/auth/me'),
        reports.dashboard,
        products.list,
        stock.balances,
        organisations.list,
        purchases.list,
        receipts.list,
        () => catalogue.list(CatalogueKind.warehouses),
        () => catalogue.list(CatalogueKind.suppliers),
        () => catalogue.list(CatalogueKind.units),
      ],
    ),
  );
  runApp(SnackifyApp(auth: auth, services: services));
}
