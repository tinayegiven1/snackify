import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../domain/invoice_models.dart';

/// Invoices through the backend: previews, drafts, issuing, voiding and PDFs.
class InvoicesRepository {
  InvoicesRepository(this._api);

  final ApiClient _api;

  Future<List<InvoiceSummary>> list({
    InvoiceFilter filter = InvoiceFilter.all,
    String search = '',
  }) async {
    final query = Uri(
      queryParameters: {
        ...switch (filter) {
          InvoiceFilter.all => const <String, String>{},
          InvoiceFilter.drafts => {'status': 'draft'},
          InvoiceFilter.issued => {'status': 'issued'},
          InvoiceFilter.unpaid => {'payment': 'unpaid'},
          InvoiceFilter.overdue => {'payment': 'overdue'},
          InvoiceFilter.voided => {'status': 'voided'},
        },
        if (search.trim().isNotEmpty) 'q': search.trim(),
        'limit': '200',
      },
    ).query;
    final body = await _api.getJson('/api/v1/invoices?$query');
    return [
      for (final item in body['invoices'] as List)
        InvoiceSummary.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// Customers still to invoice for [period]; without one, the last complete billing week
  /// (the server decides which week that is).
  Future<({BillingPeriod period, List<UnbilledCustomer> customers})> unbilled([
    BillingPeriod? period,
  ]) async {
    final query = period == null ? '' : '?${Uri(queryParameters: period.toQuery()).query}';
    final body = await _api.getJson('/api/v1/invoices/unbilled$query');
    return (
      period: BillingPeriod(body['from'] as String, body['to'] as String),
      customers: [
        for (final item in body['customers'] as List)
          UnbilledCustomer.fromJson(item as Map<String, dynamic>),
      ],
    );
  }

  Future<InvoicePreview> preview(String customerId, BillingPeriod period) async {
    final query = Uri(queryParameters: {'customerId': customerId, ...period.toQuery()}).query;
    final body = await _api.getJson('/api/v1/invoices/preview?$query');
    return InvoicePreview.fromJson(body['preview'] as Map<String, dynamic>);
  }

  Future<Invoice> get(String id) async {
    final body = await _api.getJson('/api/v1/invoices/$id');
    return Invoice.fromJson(body['invoice'] as Map<String, dynamic>);
  }

  /// A draft invoice with every unbilled confirmed dispatch line of the customer in [period].
  /// Throws [ApiException] with code NOTHING_TO_INVOICE when there is nothing left to bill.
  Future<Invoice> createDraft(String customerId, BillingPeriod period) async {
    final body = await _api.postJson('/api/v1/invoices', {
      'customerId': customerId,
      ...period.toQuery(),
    });
    return Invoice.fromJson(body['invoice'] as Map<String, dynamic>);
  }

  /// Draft invoices for every customer with unbilled dispatches in [period].
  Future<List<Invoice>> createDraftsForAll(BillingPeriod period) async {
    final body = await _api.postJson('/api/v1/invoices/generate', period.toQuery());
    return [
      for (final item in body['invoices'] as List) Invoice.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<Invoice> issue(String id) async {
    final body = await _api.postJson('/api/v1/invoices/$id/issue');
    return Invoice.fromJson(body['invoice'] as Map<String, dynamic>);
  }

  Future<Invoice> voidDraft(String id, String reason) async {
    final body = await _api.postJson('/api/v1/invoices/$id/void', {'reason': reason});
    return Invoice.fromJson(body['invoice'] as Map<String, dynamic>);
  }

  Future<Uint8List> pdf(String id) =>
      _api.getBytes('/api/v1/invoices/$id/pdf', accept: 'application/pdf');
}
