import '../../auth/domain/app_user.dart';

/// Accounts staff and admins record payments and see balances (spec section 5). The server
/// enforces this too.
bool canUsePayments(StaffRole role) => role == StaffRole.admin || role == StaffRole.accounts;

/// Only admins void a payment recorded by mistake.
bool canVoidPayments(StaffRole role) => role == StaffRole.admin;

enum PaymentMethod {
  cash('cash', 'Cash'),
  bankTransfer('bank_transfer', 'Bank transfer'),
  mobileMoney('mobile_money', 'Mobile money'),
  card('card', 'Card'),
  cheque('cheque', 'Cheque'),
  other('other', 'Other');

  const PaymentMethod(this.apiName, this.label);

  final String apiName;
  final String label;

  static PaymentMethod fromApi(String value) =>
      PaymentMethod.values.firstWhere((method) => method.apiName == value);
}

enum PaymentStatus {
  recorded('Recorded'),
  voided('Voided');

  const PaymentStatus(this.label);

  final String label;

  static PaymentStatus fromApi(String value) => PaymentStatus.values.byName(value);
}

/// Part of a payment applied to one invoice.
class PaymentAllocationLine {
  const PaymentAllocationLine({
    required this.invoiceId,
    required this.invoiceNumber,
    required this.amount,
  });

  factory PaymentAllocationLine.fromJson(Map<String, dynamic> json) => PaymentAllocationLine(
    invoiceId: json['invoiceId'] as String,
    invoiceNumber: json['invoiceNumber'] as String,
    amount: json['amount'] as String,
  );

  final String invoiceId;
  final String invoiceNumber;
  final String amount;
}

class Payment {
  const Payment({
    required this.id,
    required this.paymentNumber,
    required this.status,
    required this.customerId,
    required this.customerCode,
    required this.customerName,
    required this.paymentDate,
    required this.amount,
    required this.currency,
    required this.method,
    required this.reference,
    required this.notes,
    required this.allocations,
    required this.allocatedAmount,
    required this.unallocatedAmount,
    required this.recordedBy,
    required this.voidedBy,
    required this.voidReason,
  });

  factory Payment.fromJson(Map<String, dynamic> json) {
    final customer = json['customer'] as Map<String, dynamic>;
    return Payment(
      id: json['id'] as String,
      paymentNumber: json['paymentNumber'] as String,
      status: PaymentStatus.fromApi(json['status'] as String),
      customerId: customer['id'] as String,
      customerCode: customer['code'] as String,
      customerName: customer['name'] as String,
      paymentDate: json['paymentDate'] as String,
      amount: json['amount'] as String,
      currency: json['currency'] as String,
      method: PaymentMethod.fromApi(json['method'] as String),
      reference: json['reference'] as String?,
      notes: json['notes'] as String?,
      allocations: [
        for (final item in json['allocations'] as List)
          PaymentAllocationLine.fromJson(item as Map<String, dynamic>),
      ],
      allocatedAmount: json['allocatedAmount'] as String,
      unallocatedAmount: json['unallocatedAmount'] as String,
      recordedBy: json['recordedBy'] as String,
      voidedBy: json['voidedBy'] as String?,
      voidReason: json['voidReason'] as String?,
    );
  }

  final String id;

  /// Receipt number, e.g. P000001.
  final String paymentNumber;
  final PaymentStatus status;
  final String customerId;
  final String customerCode;
  final String customerName;
  final String paymentDate;
  final String amount;
  final String currency;
  final PaymentMethod method;
  final String? reference;
  final String? notes;

  /// Kept as history after the payment is voided, when they no longer count.
  final List<PaymentAllocationLine> allocations;
  final String allocatedAmount;

  /// Credit left on the customer's account from this payment (0.00 once voided).
  final String unallocatedAmount;
  final String recordedBy;
  final String? voidedBy;
  final String? voidReason;
}

class PaymentSummary {
  const PaymentSummary({
    required this.id,
    required this.paymentNumber,
    required this.status,
    required this.customerName,
    required this.paymentDate,
    required this.amount,
    required this.method,
    required this.reference,
    required this.unallocatedAmount,
  });

  factory PaymentSummary.fromJson(Map<String, dynamic> json) => PaymentSummary(
    id: json['id'] as String,
    paymentNumber: json['paymentNumber'] as String,
    status: PaymentStatus.fromApi(json['status'] as String),
    customerName: (json['customer'] as Map<String, dynamic>)['name'] as String,
    paymentDate: json['paymentDate'] as String,
    amount: json['amount'] as String,
    method: PaymentMethod.fromApi(json['method'] as String),
    reference: json['reference'] as String?,
    unallocatedAmount: json['unallocatedAmount'] as String,
  );

  final String id;
  final String paymentNumber;
  final PaymentStatus status;
  final String customerName;
  final String paymentDate;
  final String amount;
  final PaymentMethod method;
  final String? reference;
  final String unallocatedAmount;
}

/// What a customer owes, as separate measures that are never mixed up (spec 6.10).
class BalanceMeasures {
  const BalanceMeasures({
    required this.notYetInvoiced,
    required this.invoicedUnpaid,
    required this.overdue,
    required this.unallocatedCredit,
    required this.balance,
  });

  factory BalanceMeasures.fromJson(Map<String, dynamic> json) => BalanceMeasures(
    notYetInvoiced: json['notYetInvoiced'] as String,
    invoicedUnpaid: json['invoicedUnpaid'] as String,
    overdue: json['overdue'] as String,
    unallocatedCredit: json['unallocatedCredit'] as String,
    balance: json['balance'] as String,
  );

  /// Confirmed dispatches not yet on an issued invoice.
  final String notYetInvoiced;

  /// Still owed on issued invoices.
  final String invoicedUnpaid;

  /// The part of [invoicedUnpaid] past its due date.
  final String overdue;

  /// Payments received but not yet allocated to an invoice.
  final String unallocatedCredit;

  /// Everything owed: dispatched less paid. Negative when the customer paid in advance.
  final String balance;

  bool get inCredit => balance.startsWith('-');
  bool get hasOverdue => overdue != '0.00';
}

class CustomerBalance {
  const CustomerBalance({
    required this.customerId,
    required this.code,
    required this.name,
    required this.measures,
    required this.oldestOverdueDueDate,
  });

  factory CustomerBalance.fromJson(Map<String, dynamic> json) {
    final customer = json['customer'] as Map<String, dynamic>;
    return CustomerBalance(
      customerId: customer['id'] as String,
      code: customer['code'] as String,
      name: customer['name'] as String,
      measures: BalanceMeasures.fromJson(json),
      oldestOverdueDueDate: json['oldestOverdueDueDate'] as String?,
    );
  }

  final String customerId;
  final String code;
  final String name;
  final BalanceMeasures measures;
  final String? oldestOverdueDueDate;
}

/// An issued invoice that is not fully paid.
class OpenInvoice {
  const OpenInvoice({
    required this.id,
    required this.invoiceNumber,
    required this.issueDate,
    required this.dueDate,
    required this.total,
    required this.balanceDue,
    required this.daysOverdue,
  });

  factory OpenInvoice.fromJson(Map<String, dynamic> json) => OpenInvoice(
    id: json['id'] as String,
    invoiceNumber: json['invoiceNumber'] as String,
    issueDate: json['issueDate'] as String,
    dueDate: json['dueDate'] as String,
    total: json['total'] as String,
    balanceDue: json['balanceDue'] as String,
    daysOverdue: json['daysOverdue'] as int,
  );

  final String id;
  final String invoiceNumber;
  final String issueDate;
  final String dueDate;
  final String total;
  final String balanceDue;
  final int daysOverdue;

  bool get overdue => daysOverdue > 0;
}

/// A payment with credit left to allocate.
class CreditPayment {
  const CreditPayment({
    required this.id,
    required this.paymentNumber,
    required this.paymentDate,
    required this.unallocatedAmount,
  });

  factory CreditPayment.fromJson(Map<String, dynamic> json) => CreditPayment(
    id: json['id'] as String,
    paymentNumber: json['paymentNumber'] as String,
    paymentDate: json['paymentDate'] as String,
    unallocatedAmount: json['unallocatedAmount'] as String,
  );

  final String id;
  final String paymentNumber;
  final String paymentDate;
  final String unallocatedAmount;
}

/// An invoice (debit) or payment (credit) on a statement.
class StatementEntry {
  const StatementEntry({
    required this.date,
    required this.isInvoice,
    required this.id,
    required this.reference,
    required this.periodFrom,
    required this.periodTo,
    required this.method,
    required this.paymentReference,
    required this.debit,
    required this.credit,
    required this.balance,
  });

  factory StatementEntry.fromJson(Map<String, dynamic> json) => StatementEntry(
    date: json['date'] as String,
    isInvoice: json['type'] == 'invoice',
    id: json['id'] as String,
    reference: json['reference'] as String,
    periodFrom: json['periodFrom'] as String?,
    periodTo: json['periodTo'] as String?,
    method: json['method'] == null ? null : PaymentMethod.fromApi(json['method'] as String),
    paymentReference: json['paymentReference'] as String?,
    debit: json['debit'] as String?,
    credit: json['credit'] as String?,
    balance: json['balance'] as String,
  );

  final String date;
  final bool isInvoice;
  final String id;
  final String reference;
  final String? periodFrom;
  final String? periodTo;
  final PaymentMethod? method;
  final String? paymentReference;
  final String? debit;
  final String? credit;
  final String balance;
}

class Statement {
  const Statement({
    required this.from,
    required this.to,
    required this.openingBalance,
    required this.entries,
    required this.closingBalance,
  });

  factory Statement.fromJson(Map<String, dynamic> json) => Statement(
    from: json['from'] as String,
    to: json['to'] as String,
    openingBalance: json['openingBalance'] as String,
    entries: [
      for (final item in json['entries'] as List)
        StatementEntry.fromJson(item as Map<String, dynamic>),
    ],
    closingBalance: json['closingBalance'] as String,
  );

  final String from;
  final String to;
  final String openingBalance;
  final List<StatementEntry> entries;
  final String closingBalance;
}

/// One customer's account: what they owe, open invoices, credit, and a statement.
class CustomerAccount {
  const CustomerAccount({
    required this.customerId,
    required this.code,
    required this.name,
    required this.phone,
    required this.currency,
    required this.summary,
    required this.openInvoices,
    required this.creditPayments,
    required this.statement,
  });

  factory CustomerAccount.fromJson(Map<String, dynamic> json) {
    final customer = json['customer'] as Map<String, dynamic>;
    return CustomerAccount(
      customerId: customer['id'] as String,
      code: customer['code'] as String,
      name: customer['name'] as String,
      phone: customer['phone'] as String?,
      currency: json['currency'] as String,
      summary: BalanceMeasures.fromJson(json['summary'] as Map<String, dynamic>),
      openInvoices: [
        for (final item in json['openInvoices'] as List)
          OpenInvoice.fromJson(item as Map<String, dynamic>),
      ],
      creditPayments: [
        for (final item in json['creditPayments'] as List)
          CreditPayment.fromJson(item as Map<String, dynamic>),
      ],
      statement: Statement.fromJson(json['statement'] as Map<String, dynamic>),
    );
  }

  final String customerId;
  final String code;
  final String name;
  final String? phone;
  final String currency;
  final BalanceMeasures summary;

  /// Oldest due date first.
  final List<OpenInvoice> openInvoices;
  final List<CreditPayment> creditPayments;
  final Statement statement;
}

/// An amount of a payment to apply to one invoice.
class AllocationInput {
  const AllocationInput(this.invoiceId, this.amount);

  final String invoiceId;

  /// e.g. "4.50".
  final String amount;

  Map<String, Object?> toJson() => {'invoiceId': invoiceId, 'amount': amount};
}
