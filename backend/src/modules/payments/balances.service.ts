import type { Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { daysBetween } from '../../utils/dates.js';
import { fromCents, toCents } from '../../utils/money.js';
import type { PaymentMethod } from './payments.service.js';

/**
 * What a customer owes, split into clearly separate measures (spec 6.10: never mix dispatch
 * value, invoiced sales and cash received).
 */
export interface BalanceMeasures {
  /** Confirmed dispatches not yet on an issued invoice (including those on draft invoices). */
  notYetInvoiced: string;
  /** Still owed on issued invoices. */
  invoicedUnpaid: string;
  /** The part of invoicedUnpaid that is past its due date. */
  overdue: string;
  /** Payments received but not yet allocated to an invoice. */
  unallocatedCredit: string;
  /**
   * notYetInvoiced + invoicedUnpaid - unallocatedCredit, which equals confirmed dispatches less
   * payments received. Negative when the customer has paid in advance.
   */
  balance: string;
}

export interface CustomerBalance extends BalanceMeasures {
  customer: { id: string; code: string; name: string; creditLimit: string | null };
  /** Due date of the oldest overdue invoice, if any. */
  oldestOverdueDueDate: string | null;
}

interface BalanceRow {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  address: string | null;
  credit_limit: string | null;
  not_yet_invoiced: string;
  invoiced_unpaid: string;
  overdue: string;
  unallocated_credit: string;
  oldest_overdue: string | null;
}

/** Balances of every customer with dispatches or payments, or just one customer. */
async function balanceRows(
  db: Queryable,
  today: string,
  customerId?: string,
): Promise<BalanceRow[]> {
  const { rows } = await db.query<BalanceRow>(
    `WITH not_invoiced AS (
       SELECT d.customer_id, sum(i.quantity * i.unit_price) AS amount
       FROM dispatches d
       JOIN dispatch_items i ON i.dispatch_id = d.id
       WHERE d.status = 'confirmed'
         AND NOT EXISTS (
           SELECT 1 FROM invoice_items ii JOIN invoices v ON v.id = ii.invoice_id
           WHERE ii.dispatch_item_id = i.id AND v.status = 'issued'
         )
       GROUP BY d.customer_id
     ),
     invoiced AS (
       SELECT v.customer_id,
              sum(v.total - COALESCE(paid.amount_paid, 0)) AS unpaid,
              sum(v.total - COALESCE(paid.amount_paid, 0)) FILTER (WHERE v.due_date < $1)
                AS overdue,
              min(v.due_date) FILTER (
                WHERE v.due_date < $1 AND v.total > COALESCE(paid.amount_paid, 0)
              ) AS oldest_overdue
       FROM invoices v
       LEFT JOIN invoice_amounts_paid paid ON paid.invoice_id = v.id
       WHERE v.status = 'issued'
       GROUP BY v.customer_id
     ),
     credit AS (
       SELECT p.customer_id, sum(p.amount - COALESCE(a.amount_allocated, 0)) AS unallocated
       FROM payments p
       LEFT JOIN payment_amounts_allocated a ON a.payment_id = p.id
       WHERE p.status = 'recorded'
       GROUP BY p.customer_id
     )
     SELECT c.id, c.code, c.name, c.phone, c.address, c.credit_limit,
            COALESCE(n.amount, 0)::numeric(14, 2)::text AS not_yet_invoiced,
            COALESCE(i.unpaid, 0)::numeric(14, 2)::text AS invoiced_unpaid,
            COALESCE(i.overdue, 0)::numeric(14, 2)::text AS overdue,
            COALESCE(cr.unallocated, 0)::numeric(14, 2)::text AS unallocated_credit,
            i.oldest_overdue
     FROM customers c
     LEFT JOIN not_invoiced n ON n.customer_id = c.id
     LEFT JOIN invoiced i ON i.customer_id = c.id
     LEFT JOIN credit cr ON cr.customer_id = c.id
     WHERE ${customerId ? 'c.id = $2' : 'n.customer_id IS NOT NULL OR i.customer_id IS NOT NULL OR cr.customer_id IS NOT NULL'}`,
    customerId ? [today, customerId] : [today],
  );
  return rows;
}

function measures(row: BalanceRow): BalanceMeasures {
  const balance =
    toCents(row.not_yet_invoiced) + toCents(row.invoiced_unpaid) - toCents(row.unallocated_credit);
  return {
    notYetInvoiced: row.not_yet_invoiced,
    invoicedUnpaid: row.invoiced_unpaid,
    overdue: row.overdue,
    unallocatedCredit: row.unallocated_credit,
    balance: fromCents(balance),
  };
}

/**
 * Every customer with dispatches or payments: most overdue first, then largest balance.
 * Totals add up each measure across customers.
 */
export async function listCustomerBalances(
  db: Queryable,
  today: string,
): Promise<{ customers: CustomerBalance[]; totals: BalanceMeasures }> {
  const customers = (await balanceRows(db, today)).map((row) => ({
    customer: { id: row.id, code: row.code, name: row.name, creditLimit: row.credit_limit },
    ...measures(row),
    oldestOverdueDueDate: row.oldest_overdue,
  }));
  customers.sort(
    (a, b) =>
      toCents(b.overdue) - toCents(a.overdue) ||
      toCents(b.balance) - toCents(a.balance) ||
      a.customer.name.localeCompare(b.customer.name),
  );

  const sum = (key: keyof BalanceMeasures) =>
    fromCents(customers.reduce((total, c) => total + toCents(c[key]), 0));
  return {
    customers,
    totals: {
      notYetInvoiced: sum('notYetInvoiced'),
      invoicedUnpaid: sum('invoicedUnpaid'),
      overdue: sum('overdue'),
      unallocatedCredit: sum('unallocatedCredit'),
      balance: sum('balance'),
    },
  };
}

export interface OpenInvoice {
  id: string;
  invoiceNumber: string;
  issueDate: string;
  dueDate: string;
  total: string;
  amountPaid: string;
  balanceDue: string;
  overdue: boolean;
  /** Days past the due date; 0 when not overdue. */
  daysOverdue: number;
}

export interface CreditPayment {
  id: string;
  paymentNumber: string;
  paymentDate: string;
  amount: string;
  unallocatedAmount: string;
}

export interface StatementEntry {
  date: string;
  type: 'invoice' | 'payment';
  id: string;
  /** Invoice or receipt number. */
  reference: string;
  /** Invoices: the period billed. */
  periodFrom: string | null;
  periodTo: string | null;
  /** Payments: how they paid and their reference. */
  method: PaymentMethod | null;
  paymentReference: string | null;
  /** Invoice total (what the customer was billed). */
  debit: string | null;
  /** Payment amount (what the customer paid). */
  credit: string | null;
  /** Running statement balance after this entry. */
  balance: string;
}

export interface CustomerAccount {
  customer: {
    id: string;
    code: string;
    name: string;
    phone: string | null;
    address: string | null;
    creditLimit: string | null;
  };
  currency: string;
  /** As of today. */
  summary: BalanceMeasures & { oldestOverdueDueDate: string | null };
  /** Issued invoices not fully paid, oldest due date first. */
  openInvoices: OpenInvoice[];
  /** Payments with credit left to allocate, oldest first. */
  creditPayments: CreditPayment[];
  /**
   * Issued invoices (debits) and payments (credits) in the period, with the balance carried in
   * from before it. Voided payments and draft invoices are not part of a statement.
   */
  statement: {
    from: string;
    to: string;
    openingBalance: string;
    entries: StatementEntry[];
    closingBalance: string;
  };
}

/** One customer's account: balances, open invoices, credit and a statement for the period. */
export async function getCustomerAccount(
  db: Queryable,
  customerId: string,
  period: { from: string; to: string },
  today: string,
  currency: string,
): Promise<CustomerAccount> {
  const row = (await balanceRows(db, today, customerId))[0];
  if (!row) throw new AppError(404, 'CUSTOMER_NOT_FOUND', 'No customer has that id.');

  const { rows: invoices } = await db.query<{
    id: string;
    invoice_number: string;
    issue_date: string;
    due_date: string;
    total: string;
    amount_paid: string;
  }>(
    `SELECT v.id, v.invoice_number, v.issue_date, v.due_date, v.total,
            COALESCE(paid.amount_paid, 0)::numeric(14, 2)::text AS amount_paid
     FROM invoices v
     LEFT JOIN invoice_amounts_paid paid ON paid.invoice_id = v.id
     WHERE v.customer_id = $1 AND v.status = 'issued' AND v.total > COALESCE(paid.amount_paid, 0)
     ORDER BY v.due_date, v.invoice_number`,
    [customerId],
  );

  const { rows: credit } = await db.query<{
    id: string;
    payment_number: string;
    payment_date: string;
    amount: string;
    unallocated: string;
  }>(
    `SELECT p.id, p.payment_number, p.payment_date, p.amount,
            (p.amount - COALESCE(a.amount_allocated, 0))::numeric(14, 2)::text AS unallocated
     FROM payments p
     LEFT JOIN payment_amounts_allocated a ON a.payment_id = p.id
     WHERE p.customer_id = $1 AND p.status = 'recorded'
       AND p.amount > COALESCE(a.amount_allocated, 0)
     ORDER BY p.payment_date, p.payment_number`,
    [customerId],
  );

  const { rows: opening } = await db.query<{ opening: string }>(
    `SELECT ((SELECT COALESCE(sum(total), 0) FROM invoices
              WHERE customer_id = $1 AND status = 'issued' AND issue_date < $2)
           - (SELECT COALESCE(sum(amount), 0) FROM payments
              WHERE customer_id = $1 AND status = 'recorded' AND payment_date < $2)
            )::numeric(14, 2)::text AS opening`,
    [customerId, period.from],
  );

  const { rows: entries } = await db.query<{
    type: 'invoice' | 'payment';
    id: string;
    date: string;
    reference: string;
    period_from: string | null;
    period_to: string | null;
    method: PaymentMethod | null;
    payment_reference: string | null;
    debit: string | null;
    credit: string | null;
  }>(
    `SELECT * FROM (
       SELECT 'invoice' AS type, v.id, v.issue_date AS date, v.invoice_number AS reference,
              v.period_from, v.period_to, NULL AS method, NULL AS payment_reference,
              v.total::text AS debit, NULL AS credit, v.issued_at AS at
       FROM invoices v
       WHERE v.customer_id = $1 AND v.status = 'issued' AND v.issue_date BETWEEN $2 AND $3
       UNION ALL
       SELECT 'payment', p.id, p.payment_date, p.payment_number,
              NULL, NULL, p.method, p.reference,
              NULL, p.amount::text, p.created_at
       FROM payments p
       WHERE p.customer_id = $1 AND p.status = 'recorded' AND p.payment_date BETWEEN $2 AND $3
     ) e
     ORDER BY date, at`,
    [customerId, period.from, period.to],
  );

  let running = toCents((opening[0] as { opening: string }).opening);
  const statementEntries = entries.map((entry) => {
    running += toCents(entry.debit ?? '0') - toCents(entry.credit ?? '0');
    return {
      date: entry.date,
      type: entry.type,
      id: entry.id,
      reference: entry.reference,
      periodFrom: entry.period_from,
      periodTo: entry.period_to,
      method: entry.method,
      paymentReference: entry.payment_reference,
      debit: entry.debit,
      credit: entry.credit,
      balance: fromCents(running),
    };
  });

  return {
    customer: {
      id: row.id,
      code: row.code,
      name: row.name,
      phone: row.phone,
      address: row.address,
      creditLimit: row.credit_limit,
    },
    currency,
    summary: { ...measures(row), oldestOverdueDueDate: row.oldest_overdue },
    openInvoices: invoices.map((v) => {
      const daysOverdue = Math.max(0, daysBetween(v.due_date, today));
      return {
        id: v.id,
        invoiceNumber: v.invoice_number,
        issueDate: v.issue_date,
        dueDate: v.due_date,
        total: v.total,
        amountPaid: v.amount_paid,
        balanceDue: fromCents(toCents(v.total) - toCents(v.amount_paid)),
        overdue: daysOverdue > 0,
        daysOverdue,
      };
    }),
    creditPayments: credit.map((p) => ({
      id: p.id,
      paymentNumber: p.payment_number,
      paymentDate: p.payment_date,
      amount: p.amount,
      unallocatedAmount: p.unallocated,
    })),
    statement: {
      from: period.from,
      to: period.to,
      openingBalance: (opening[0] as { opening: string }).opening,
      entries: statementEntries,
      closingBalance: fromCents(running),
    },
  };
}
