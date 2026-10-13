import '../../../core/formatting/dates.dart';
import '../../auth/domain/app_user.dart';
import '../../payments/domain/payment_models.dart';

enum InvoiceStatus {
  draft('Draft'),
  issued('Issued'),
  voided('Voided');

  const InvoiceStatus(this.label);

  final String label;

  static InvoiceStatus fromApi(String value) => InvoiceStatus.values.byName(value);
}

/// Accounts staff and admins work with invoices (spec section 5). The server enforces this too.
bool canUseInvoices(StaffRole role) => role == StaffRole.admin || role == StaffRole.accounts;

/// A billing period, both dates included, in the API's "2026-10-12" format.
class BillingPeriod {
  const BillingPeriod(this.from, this.to);

  final String from;
  final String to;

  /// "5 Oct – 11 Oct 2026".
  String get label => formatApiPeriod(from, to);

  /// The same length of time, [weeks] weeks earlier (negative) or later (positive).
  BillingPeriod shiftedByWeeks(int weeks) => BillingPeriod(
    toApiDate(DateTime.parse(from).add(Duration(days: 7 * weeks))),
    toApiDate(DateTime.parse(to).add(Duration(days: 7 * weeks))),
  );

  Map<String, String> toQuery() => {'from': from, 'to': to};

  @override
  bool operator ==(Object other) => other is BillingPeriod && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

class InvoiceCustomer {
  const InvoiceCustomer({
    required this.id,
    required this.code,
    required this.name,
    this.phone,
    this.address,
  });

  factory InvoiceCustomer.fromJson(Map<String, dynamic> json) => InvoiceCustomer(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    phone: json['phone'] as String?,
    address: json['address'] as String?,
  );

  final String id;
  final String code;
  final String name;
  final String? phone;
  final String? address;
}

/// One billed dispatch line.
class InvoiceLine {
  const InvoiceLine({
    required this.dispatchNumber,
    required this.dispatchDate,
    required this.description,
    required this.sku,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  factory InvoiceLine.fromJson(Map<String, dynamic> json) {
    final product = json['product'] as Map<String, dynamic>;
    return InvoiceLine(
      dispatchNumber: json['dispatchNumber'] as String,
      dispatchDate: json['dispatchDate'] as String,
      description: product['description'] as String,
      sku: product['sku'] as String,
      quantity: json['quantity'] as int,
      unitPrice: json['unitPrice'] as String,
      lineTotal: json['lineTotal'] as String,
    );
  }

  final String dispatchNumber;
  final String dispatchDate;

  /// Product, flavour and size, e.g. "Potato Crisps — BBQ — Small".
  final String description;
  final String sku;
  final int quantity;
  final String unitPrice;
  final String lineTotal;
}

/// What a draft invoice for one customer and period would contain. Nothing is saved yet.
class InvoicePreview {
  const InvoicePreview({
    required this.customer,
    required this.period,
    required this.currency,
    required this.lines,
    required this.subtotal,
  });

  factory InvoicePreview.fromJson(Map<String, dynamic> json) => InvoicePreview(
    customer: InvoiceCustomer.fromJson(json['customer'] as Map<String, dynamic>),
    period: BillingPeriod(json['periodFrom'] as String, json['periodTo'] as String),
    currency: json['currency'] as String,
    lines: [
      for (final line in json['lines'] as List) InvoiceLine.fromJson(line as Map<String, dynamic>),
    ],
    subtotal: json['subtotal'] as String,
  );

  final InvoiceCustomer customer;
  final BillingPeriod period;
  final String currency;
  final List<InvoiceLine> lines;
  final String subtotal;
}

class Invoice {
  const Invoice({
    required this.id,
    required this.invoiceNumber,
    required this.status,
    required this.customer,
    required this.period,
    required this.issueDate,
    required this.currency,
    required this.lines,
    required this.subtotal,
    required this.total,
    required this.dueDate,
    required this.amountPaid,
    required this.balanceDue,
    required this.paymentStatus,
    required this.overdue,
    required this.payments,
    required this.createdBy,
    required this.issuedBy,
    required this.voidReason,
  });

  factory Invoice.fromJson(Map<String, dynamic> json) => Invoice(
    id: json['id'] as String,
    invoiceNumber: json['invoiceNumber'] as String?,
    status: InvoiceStatus.fromApi(json['status'] as String),
    customer: InvoiceCustomer.fromJson(json['customer'] as Map<String, dynamic>),
    period: BillingPeriod(json['periodFrom'] as String, json['periodTo'] as String),
    issueDate: json['issueDate'] as String?,
    currency: json['currency'] as String,
    lines: [
      for (final line in json['lines'] as List) InvoiceLine.fromJson(line as Map<String, dynamic>),
    ],
    subtotal: json['subtotal'] as String,
    total: json['total'] as String,
    dueDate: json['dueDate'] as String?,
    amountPaid: json['amountPaid'] as String,
    balanceDue: json['balanceDue'] as String,
    paymentStatus: InvoicePaymentStatus.fromApi(json['paymentStatus'] as String?),
    overdue: json['overdue'] as bool,
    payments: [
      for (final payment in json['payments'] as List)
        InvoicePayment.fromJson(payment as Map<String, dynamic>),
    ],
    createdBy: json['createdBy'] as String,
    issuedBy: json['issuedBy'] as String?,
    voidReason: json['voidReason'] as String?,
  );

  final String id;

  /// Given when the invoice is issued.
  final String? invoiceNumber;
  final InvoiceStatus status;

  /// For an issued invoice, the details printed on it; otherwise the customer's current details.
  final InvoiceCustomer customer;
  final BillingPeriod period;
  final String? issueDate;
  final String currency;
  final List<InvoiceLine> lines;
  final String subtotal;
  final String total;

  /// Set when issued: the issue date plus the payment terms.
  final String? dueDate;
  final String amountPaid;
  final String balanceDue;

  /// Issued invoices only.
  final InvoicePaymentStatus? paymentStatus;

  /// Issued, not fully paid, and past the due date.
  final bool overdue;

  /// The payments that paid it, oldest first.
  final List<InvoicePayment> payments;
  final String createdBy;
  final String? issuedBy;
  final String? voidReason;

  /// "INV-000001", or "Draft invoice" before it is issued.
  String get title => invoiceNumber ?? 'Draft invoice';

  /// The PDF's file name, matching the server's.
  String get pdfFileName => '${invoiceNumber ?? 'draft-${customer.code}-${period.from}'}.pdf';
}

class InvoiceSummary {
  const InvoiceSummary({
    required this.id,
    required this.invoiceNumber,
    required this.status,
    required this.customerName,
    required this.period,
    required this.issueDate,
    required this.total,
    required this.balanceDue,
    required this.paymentStatus,
    required this.overdue,
    required this.lineCount,
  });

  factory InvoiceSummary.fromJson(Map<String, dynamic> json) => InvoiceSummary(
    id: json['id'] as String,
    invoiceNumber: json['invoiceNumber'] as String?,
    status: InvoiceStatus.fromApi(json['status'] as String),
    customerName: (json['customer'] as Map<String, dynamic>)['name'] as String,
    period: BillingPeriod(json['periodFrom'] as String, json['periodTo'] as String),
    issueDate: json['issueDate'] as String?,
    total: json['total'] as String,
    balanceDue: json['balanceDue'] as String,
    paymentStatus: InvoicePaymentStatus.fromApi(json['paymentStatus'] as String?),
    overdue: json['overdue'] as bool,
    lineCount: json['lineCount'] as int,
  );

  final String id;
  final String? invoiceNumber;
  final InvoiceStatus status;
  final String customerName;
  final BillingPeriod period;
  final String? issueDate;
  final String total;
  final String balanceDue;
  final InvoicePaymentStatus? paymentStatus;
  final bool overdue;
  final int lineCount;
}

/// How much of an issued invoice has been paid.
enum InvoicePaymentStatus {
  unpaid('unpaid', 'Unpaid'),
  partPaid('part_paid', 'Part paid'),
  paid('paid', 'Paid');

  const InvoicePaymentStatus(this.apiName, this.label);

  final String apiName;
  final String label;

  static InvoicePaymentStatus? fromApi(String? value) => value == null
      ? null
      : InvoicePaymentStatus.values.firstWhere((status) => status.apiName == value);
}

/// A payment (or part of one) applied to an invoice.
class InvoicePayment {
  const InvoicePayment({
    required this.paymentId,
    required this.paymentNumber,
    required this.paymentDate,
    required this.method,
    required this.amount,
  });

  factory InvoicePayment.fromJson(Map<String, dynamic> json) => InvoicePayment(
    paymentId: json['paymentId'] as String,
    paymentNumber: json['paymentNumber'] as String,
    paymentDate: json['paymentDate'] as String,
    method: PaymentMethod.fromApi(json['method'] as String),
    amount: json['amount'] as String,
  );

  final String paymentId;
  final String paymentNumber;
  final String paymentDate;
  final PaymentMethod method;
  final String amount;
}

/// Filters for the invoices list.
enum InvoiceFilter {
  all('All'),
  drafts('Drafts'),
  issued('Issued'),
  unpaid('Unpaid'),
  overdue('Overdue'),
  voided('Voided');

  const InvoiceFilter(this.label);

  final String label;
}

/// A customer with confirmed dispatches in the period that are not on any invoice yet.
class UnbilledCustomer {
  const UnbilledCustomer({
    required this.customerId,
    required this.code,
    required this.name,
    required this.dispatchCount,
    required this.lineCount,
    required this.subtotal,
  });

  factory UnbilledCustomer.fromJson(Map<String, dynamic> json) {
    final customer = json['customer'] as Map<String, dynamic>;
    return UnbilledCustomer(
      customerId: customer['id'] as String,
      code: customer['code'] as String,
      name: customer['name'] as String,
      dispatchCount: json['dispatchCount'] as int,
      lineCount: json['lineCount'] as int,
      subtotal: json['subtotal'] as String,
    );
  }

  final String customerId;
  final String code;
  final String name;
  final int dispatchCount;
  final int lineCount;
  final String subtotal;
}
