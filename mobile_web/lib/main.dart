import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_services.dart';
import 'core/config/app_config.dart';
import 'core/files/document_picker.dart';
import 'core/files/pdf_sharer.dart';
import 'core/network/api_client.dart';
import 'core/scanning/barcode_reader.dart';
import 'core/network/backend_health_service.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/data/token_store.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/audit/data/audit_repository.dart';
import 'features/catalogue/data/catalogue_repository.dart';
import 'features/customers/data/customers_repository.dart';
import 'features/dispatches/data/dispatches_repository.dart';
import 'features/forecasts/data/forecasts_repository.dart';
import 'features/invoices/data/invoices_repository.dart';
import 'features/orders/data/orders_repository.dart';
import 'features/organisations/data/organisations_repository.dart';
import 'features/payments/data/payments_repository.dart';
import 'features/products/data/products_repository.dart';
import 'features/receipts/data/receipts_repository.dart';
import 'features/reports/data/reports_repository.dart';
import 'features/staff/data/staff_repository.dart';
import 'features/stock/data/stock_repository.dart';

void main() {
  final api = ApiClient(baseUrl: AppConfig.apiBaseUrl);
  final auth = AuthController(AuthRepository(api: api, tokenStore: deviceTokenStore()))..restore();
  final services = AppServices(
    checkBackendHealth: BackendHealthService(api).isHealthy,
    products: ProductsRepository(api),
    stock: StockRepository(api),
    customers: CustomersRepository(api),
    dispatches: DispatchesRepository(api),
    invoices: InvoicesRepository(api),
    payments: PaymentsRepository(api),
    reports: ReportsRepository(api),
    forecasts: ForecastsRepository(api),
    staff: StaffRepository(api),
    organisations: OrganisationsRepository(api),
    audit: AuditRepository(api),
    receipts: ReceiptsRepository(api),
    catalogue: CatalogueRepository(api),
    orders: OrdersRepository(api),
    sharePdf: sharePdfWithDevice,
    readBarcode: readBarcodeWithDevice,
    pickDocuments: pickDocumentsWithDevice,
  );
  runApp(SnackifyApp(auth: auth, services: services));
}
