import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { addDays } from '../../utils/dates.js';
import { fromCents, toCents } from '../../utils/money.js';
import { recordAudit } from '../audit/audit.js';
import type { PublicUser } from '../auth/roles.js';

export type InvoiceStatus = 'draft' | 'issued' | 'voided';

export interface InvoiceLine {
  dispatchItemId: string;
  dispatchNumber: string;
  dispatchDate: string;
  product: { id: string; sku: string; description: string };
  quantity: number;
  unitPrice: string;
  lineTotal: string;
}

export interface InvoiceCustomer {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  address: string | null;
}

export interface Invoice {
  id: string;
  /** Given when the invoice is issued; null for drafts and voided drafts. */
  invoiceNumber: string | null;
  status: InvoiceStatus;
  /** For an issued invoice, the details as printed; otherwise the customer's current details. */
  customer: InvoiceCustomer;
  periodFrom: string;
  periodTo: string;
  issueDate: string | null;
  currency: string;
  lines: InvoiceLine[];
  subtotal: string;
  total: string;
  /** Set when the invoice is issued: the issue date plus the payment terms. */
  dueDate: string | null;
  /** Allocations from payments that have not been voided. */
  amountPaid: string;
  /** What is still owed: total minus amount paid (0.00 for a voided draft). */
  balanceDue: string;
  /** For issued invoices only; null for drafts and voided drafts. */
  paymentStatus: PaymentStatus | null;
  /** Issued, not fully paid, and past its due date. */
  overdue: boolean;
  /** The payments that paid this invoice, oldest first. */
  payments: InvoicePayment[];
  createdBy: string;
  createdAt: Date;
  issuedBy: string | null;
  issuedAt: Date | null;
  voidReason: string | null;
}

export type PaymentStatus = 'unpaid' | 'part_paid' | 'paid';

export interface InvoicePayment {
  paymentId: string;
  paymentNumber: string;
  paymentDate: string;
  method: string;
  amount: string;
}

const invoiceNotFound = () => new AppError(404, 'INVOICE_NOT_FOUND', 'No invoice has that id.');

/** Whether an invoice has been paid, and whether it is overdue on `today` (if given). */
export function paymentState(
  invoice: { status: InvoiceStatus; total: string; amountPaid: string; dueDate: string | null },
  today: string | undefined,
): { paymentStatus: PaymentStatus | null; overdue: boolean } {
  if (invoice.status !== 'issued') return { paymentStatus: null, overdue: false };
  const paid = toCents(invoice.amountPaid);
  const paymentStatus = paid >= toCents(invoice.total) ? 'paid' : paid > 0 ? 'part_paid' : 'unpaid';
  const overdue =
    paymentStatus !== 'paid' &&
    today !== undefined &&
    invoice.dueDate !== null &&
    invoice.dueDate < today;
  return { paymentStatus, overdue };
}

// ---------------------------------------------------------------- What can be billed

interface EligibleRow {
  dispatch_item_id: string;
  dispatch_number: string;
  dispatch_date: string;
  product_id: string;
  sku: string;
  description: string;
  quantity: number;
  unit_price: string;
  line_total: string;
}

/**
 * Confirmed dispatch lines for this customer and period that are not on any invoice yet.
 * Draft, cancelled and reversed dispatches are never billed.
 */
async function eligibleLines(
  db: Queryable,
  customerId: string,
  from: string,
  to: string,
  lockDispatches = false,
): Promise<EligibleRow[]> {
  const { rows } = await db.query<EligibleRow>(
    `SELECT i.id AS dispatch_item_id, d.dispatch_number, d.dispatch_date, p.id AS product_id,
            p.sku, p.name || ' — ' || p.flavour || ' — ' || p.size AS description,
            i.quantity, i.unit_price, (i.quantity * i.unit_price)::numeric(14, 2)::text AS line_total
     FROM dispatch_items i
     JOIN dispatches d ON d.id = i.dispatch_id
     JOIN products p ON p.id = i.product_id
     WHERE d.customer_id = $1
       AND d.status = 'confirmed'
       AND d.dispatch_date BETWEEN $2 AND $3
       AND NOT EXISTS (SELECT 1 FROM invoice_items ii WHERE ii.dispatch_item_id = i.id)
     ORDER BY d.dispatch_date, d.dispatch_number, description
     ${
       // While invoicing, hold the dispatches so they cannot be reversed at the same moment.
       lockDispatches ? 'FOR SHARE OF d' : ''
     }`,
    [customerId, from, to],
  );
  return rows;
}

const toLine = (row: EligibleRow): InvoiceLine => ({
  dispatchItemId: row.dispatch_item_id,
  dispatchNumber: row.dispatch_number,
  dispatchDate: row.dispatch_date,
  product: { id: row.product_id, sku: row.sku, description: row.description },
  quantity: row.quantity,
  unitPrice: row.unit_price,
  lineTotal: row.line_total,
});

async function sumOf(db: Queryable, amounts: string[]): Promise<string> {
  // Added up in the database, as exact decimals.
  const { rows } = await db.query<{ total: string }>(
    'SELECT COALESCE(sum(amount), 0)::numeric(14, 2)::text AS total FROM unnest($1::numeric[]) AS amount',
    [amounts],
  );
  return (rows[0] as { total: string }).total;
}

async function loadCustomer(db: Queryable, customerId: string, lock = false) {
  const { rows } = await db.query<{
    id: string;
    code: string;
    name: string;
    phone: string | null;
    address: string | null;
  }>(
    `SELECT id, code, name, phone, address FROM customers WHERE id = $1${lock ? ' FOR UPDATE' : ''}`,
    [customerId],
  );
  if (!rows[0]) throw new AppError(404, 'CUSTOMER_NOT_FOUND', 'No customer has that id.');
  return rows[0];
}

export interface InvoicePreview {
  customer: InvoiceCustomer;
  periodFrom: string;
  periodTo: string;
  currency: string;
  lines: InvoiceLine[];
  subtotal: string;
}

export interface UnbilledCustomer {
  customer: { id: string; code: string; name: string };
  dispatchCount: number;
  lineCount: number;
  subtotal: string;
}

/**
 * Customers with confirmed, unbilled dispatches in the period, with what a draft invoice for
 * each would come to. Changes nothing.
 */
export async function listUnbilledCustomers(
  db: Queryable,
  period: { from: string; to: string },
): Promise<UnbilledCustomer[]> {
  const { rows } = await db.query<{
    id: string;
    code: string;
    name: string;
    dispatch_count: number;
    line_count: number;
    subtotal: string;
  }>(
    `SELECT c.id, c.code, c.name, count(DISTINCT d.id)::integer AS dispatch_count,
            count(*)::integer AS line_count,
            sum(i.quantity * i.unit_price)::numeric(14, 2)::text AS subtotal
     FROM dispatch_items i
     JOIN dispatches d ON d.id = i.dispatch_id
     JOIN customers c ON c.id = d.customer_id
     WHERE d.status = 'confirmed'
       AND d.dispatch_date BETWEEN $1 AND $2
       AND NOT EXISTS (SELECT 1 FROM invoice_items ii WHERE ii.dispatch_item_id = i.id)
     GROUP BY c.id
     ORDER BY c.name, c.code`,
    [period.from, period.to],
  );
  return rows.map((row) => ({
    customer: { id: row.id, code: row.code, name: row.name },
    dispatchCount: row.dispatch_count,
    lineCount: row.line_count,
    subtotal: row.subtotal,
  }));
}

/** What an invoice for this customer and period would contain. Changes nothing. */
export async function previewInvoice(
  db: Queryable,
  customerId: string,
  period: { from: string; to: string },
  currency: string,
): Promise<InvoicePreview> {
  const customer = await loadCustomer(db, customerId);
  const rows = await eligibleLines(db, customerId, period.from, period.to);
  return {
    customer,
    periodFrom: period.from,
    periodTo: period.to,
    currency,
    lines: rows.map(toLine),
    subtotal: await sumOf(
      db,
      rows.map((row) => row.line_total),
    ),
  };
}

// ---------------------------------------------------------------- Reading invoices

/** One invoice with its lines and payments. Without `today`, it is never reported overdue. */
export async function getInvoice(db: Queryable, id: string, today?: string): Promise<Invoice> {
  const { rows } = await db.query<{
    id: string;
    invoice_number: string | null;
    status: InvoiceStatus;
    customer_id: string;
    customer_code: string | null;
    customer_name: string | null;
    customer_phone: string | null;
    customer_address: string | null;
    current_code: string;
    current_name: string;
    current_phone: string | null;
    current_address: string | null;
    period_from: string;
    period_to: string;
    issue_date: string | null;
    due_date: string | null;
    currency: string;
    subtotal: string;
    total: string;
    amount_paid: string;
    created_by_name: string;
    created_at: Date;
    issued_by_name: string | null;
    issued_at: Date | null;
    void_reason: string | null;
  }>(
    `SELECT v.id, v.invoice_number, v.status, v.customer_id,
            v.customer_code, v.customer_name, v.customer_phone, v.customer_address,
            c.code AS current_code, c.name AS current_name, c.phone AS current_phone,
            c.address AS current_address,
            v.period_from, v.period_to, v.issue_date, v.due_date, v.currency, v.subtotal, v.total,
            COALESCE(paid.amount_paid, 0)::numeric(14, 2)::text AS amount_paid,
            cb.full_name AS created_by_name, v.created_at,
            ib.full_name AS issued_by_name, v.issued_at, v.void_reason
     FROM invoices v
     JOIN customers c ON c.id = v.customer_id
     JOIN users cb ON cb.id = v.created_by
     LEFT JOIN users ib ON ib.id = v.issued_by
     LEFT JOIN invoice_amounts_paid paid ON paid.invoice_id = v.id
     WHERE v.id = $1`,
    [id],
  );
  const v = rows[0];
  if (!v) throw invoiceNotFound();

  const { rows: lines } = await db.query<EligibleRow>(
    `SELECT dispatch_item_id, dispatch_number, dispatch_date, product_id, sku, description,
            quantity, unit_price, line_total::text AS line_total
     FROM invoice_items WHERE invoice_id = $1
     ORDER BY dispatch_date, dispatch_number, description`,
    [id],
  );

  const { rows: payments } = await db.query<{
    id: string;
    payment_number: string;
    payment_date: string;
    method: string;
    amount: string;
  }>(
    `SELECT p.id, p.payment_number, p.payment_date, p.method, a.amount::text AS amount
     FROM payment_allocations a
     JOIN payments p ON p.id = a.payment_id
     WHERE a.invoice_id = $1 AND p.status = 'recorded'
     ORDER BY p.payment_date, p.payment_number, a.created_at`,
    [id],
  );

  const issued = v.status === 'issued';
  const balanceDue = v.status === 'voided' ? 0 : toCents(v.total) - toCents(v.amount_paid);
  return {
    id: v.id,
    invoiceNumber: v.invoice_number,
    status: v.status,
    customer: {
      id: v.customer_id,
      code: issued ? (v.customer_code as string) : v.current_code,
      name: issued ? (v.customer_name as string) : v.current_name,
      phone: issued ? v.customer_phone : v.current_phone,
      address: issued ? v.customer_address : v.current_address,
    },
    periodFrom: v.period_from,
    periodTo: v.period_to,
    issueDate: v.issue_date,
    currency: v.currency,
    lines: lines.map(toLine),
    subtotal: v.subtotal,
    total: v.total,
    dueDate: v.due_date,
    amountPaid: v.amount_paid,
    balanceDue: fromCents(balanceDue),
    ...paymentState(
      { status: v.status, total: v.total, amountPaid: v.amount_paid, dueDate: v.due_date },
      today,
    ),
    payments: payments.map((p) => ({
      paymentId: p.id,
      paymentNumber: p.payment_number,
      paymentDate: p.payment_date,
      method: p.method,
      amount: p.amount,
    })),
    createdBy: v.created_by_name,
    createdAt: v.created_at,
    issuedBy: v.issued_by_name,
    issuedAt: v.issued_at,
    voidReason: v.void_reason,
  };
}

export interface InvoiceSummary {
  id: string;
  invoiceNumber: string | null;
  status: InvoiceStatus;
  customer: { id: string; code: string; name: string };
  periodFrom: string;
  periodTo: string;
  issueDate: string | null;
  dueDate: string | null;
  total: string;
  amountPaid: string;
  balanceDue: string;
  paymentStatus: PaymentStatus | null;
  overdue: boolean;
  currency: string;
  lineCount: number;
}

export async function listInvoices(
  db: Queryable,
  search: {
    status?: InvoiceStatus | undefined;
    /** unpaid: issued and not fully paid; overdue: also past the due date. */
    payment?: 'unpaid' | 'overdue' | undefined;
    customerId?: string | undefined;
    q?: string | undefined;
    limit: number;
    offset: number;
  },
  today: string,
): Promise<{ invoices: InvoiceSummary[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  const add = (condition: string, value: unknown) => {
    params.push(value);
    conditions.push(condition.replaceAll('?', `$${params.length}`));
  };
  if (search.status) add('v.status = ?', search.status);
  if (search.payment) {
    conditions.push(`v.status = 'issued' AND v.total > COALESCE(paid.amount_paid, 0)`);
    if (search.payment === 'overdue') add('v.due_date < ?', today);
  }
  if (search.customerId) add('v.customer_id = ?', search.customerId);
  if (search.q) add('(v.invoice_number ILIKE ? OR c.name ILIKE ?)', `%${escapeLike(search.q)}%`);
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows } = await db.query<{
    id: string;
    invoice_number: string | null;
    status: InvoiceStatus;
    customer_id: string;
    code: string;
    name: string;
    period_from: string;
    period_to: string;
    issue_date: string | null;
    due_date: string | null;
    total: string;
    amount_paid: string;
    currency: string;
    line_count: number;
    total_count: number;
  }>(
    `SELECT v.id, v.invoice_number, v.status, c.id AS customer_id,
            COALESCE(v.customer_code, c.code) AS code, COALESCE(v.customer_name, c.name) AS name,
            v.period_from, v.period_to, v.issue_date, v.due_date, v.total, v.currency,
            COALESCE(paid.amount_paid, 0)::numeric(14, 2)::text AS amount_paid,
            (SELECT count(*) FROM invoice_items ii WHERE ii.invoice_id = v.id)::integer AS line_count,
            count(*) OVER ()::integer AS total_count
     FROM invoices v
     JOIN customers c ON c.id = v.customer_id
     LEFT JOIN invoice_amounts_paid paid ON paid.invoice_id = v.id
     ${where}
     ORDER BY v.created_at DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, search.limit, search.offset],
  );
  return {
    invoices: rows.map((row) => ({
      id: row.id,
      invoiceNumber: row.invoice_number,
      status: row.status,
      customer: { id: row.customer_id, code: row.code, name: row.name },
      periodFrom: row.period_from,
      periodTo: row.period_to,
      issueDate: row.issue_date,
      dueDate: row.due_date,
      total: row.total,
      amountPaid: row.amount_paid,
      balanceDue: fromCents(
        row.status === 'voided' ? 0 : toCents(row.total) - toCents(row.amount_paid),
      ),
      ...paymentState(
        {
          status: row.status,
          total: row.total,
          amountPaid: row.amount_paid,
          dueDate: row.due_date,
        },
        today,
      ),
      currency: row.currency,
      lineCount: row.line_count,
    })),
    total: rows[0]?.total_count ?? 0,
  };
}

// ---------------------------------------------------------------- Drafts

/**
 * Creates a draft invoice holding every unbilled confirmed dispatch line for the customer
 * and period. The lines are claimed at once (a dispatch line can be on only one invoice), so
 * two people invoicing the same customer at the same moment cannot bill anything twice.
 */
export async function createDraftInvoice(
  pool: pg.Pool,
  input: { customerId: string; from: string; to: string },
  actor: PublicUser,
  currency: string,
): Promise<Invoice> {
  try {
    return await withTransaction(pool, async (client) => {
      await loadCustomer(client, input.customerId, true);
      const rows = await eligibleLines(client, input.customerId, input.from, input.to, true);
      if (rows.length === 0) {
        throw new AppError(
          409,
          'NOTHING_TO_INVOICE',
          'This customer has no confirmed, unbilled dispatches in that period.',
        );
      }
      const subtotal = await sumOf(
        client,
        rows.map((row) => row.line_total),
      );

      const { rows: created } = await client.query<{ id: string }>(
        `INSERT INTO invoices (customer_id, period_from, period_to, currency, subtotal, total, created_by)
         VALUES ($1, $2, $3, $4, $5, $5, $6) RETURNING id`,
        [input.customerId, input.from, input.to, currency, subtotal, actor.id],
      );
      const invoiceId = (created[0] as { id: string }).id;

      for (const row of rows) {
        await client.query(
          `INSERT INTO invoice_items (invoice_id, dispatch_item_id, dispatch_number, dispatch_date,
                                      product_id, sku, description, quantity, unit_price, line_total)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
          [
            invoiceId,
            row.dispatch_item_id,
            row.dispatch_number,
            row.dispatch_date,
            row.product_id,
            row.sku,
            row.description,
            row.quantity,
            row.unit_price,
            row.line_total,
          ],
        );
      }
      return getInvoice(client, invoiceId);
    });
  } catch (error) {
    if (isUniqueViolation(error, 'invoice_items_dispatch_item_key')) {
      throw new AppError(
        409,
        'ALREADY_INVOICED',
        'Someone has just invoiced some of these dispatches. Refresh the preview and try again.',
      );
    }
    throw error;
  }
}

/**
 * Creates draft invoices for every customer with unbilled confirmed dispatches in the period
 * (the weekly invoicing run). Each customer is handled in its own transaction.
 */
export async function createDraftInvoicesForPeriod(
  pool: pg.Pool,
  period: { from: string; to: string },
  actor: PublicUser,
  currency: string,
): Promise<Invoice[]> {
  const invoices: Invoice[] = [];
  for (const { customer } of await listUnbilledCustomers(pool, period)) {
    try {
      invoices.push(
        await createDraftInvoice(pool, { customerId: customer.id, ...period }, actor, currency),
      );
    } catch (error) {
      // Someone else invoiced this customer meanwhile: nothing left to do for them.
      if (
        error instanceof AppError &&
        ['NOTHING_TO_INVOICE', 'ALREADY_INVOICED'].includes(error.code)
      ) {
        continue;
      }
      throw error;
    }
  }
  return invoices;
}

async function lockInvoice(client: pg.PoolClient, id: string) {
  const { rows } = await client.query<{
    status: InvoiceStatus;
    customer_id: string;
    total: string;
  }>('SELECT status, customer_id, total FROM invoices WHERE id = $1 FOR UPDATE', [id]);
  if (!rows[0]) throw invoiceNotFound();
  return rows[0];
}

/**
 * Issues a draft: gives it the next invoice number, today's date and a due date
 * `paymentTermsDays` later, and freezes the customer details printed on it. Issuing an invoice
 * that is already issued changes nothing.
 */
export async function issueInvoice(
  pool: pg.Pool,
  id: string,
  actor: PublicUser,
  today: string,
  paymentTermsDays: number,
): Promise<Invoice> {
  return withTransaction(pool, async (client) => {
    const current = await lockInvoice(client, id);
    if (current.status === 'issued') return getInvoice(client, id, today);
    if (current.status !== 'draft') {
      throw new AppError(409, 'INVOICE_VOIDED', 'This draft invoice was voided.');
    }

    const customer = await loadCustomer(client, current.customer_id);
    const { rows } = await client.query<{ invoice_number: string }>(
      `UPDATE invoices
       SET status = 'issued',
           invoice_number = 'INV-' || lpad(nextval('invoice_number_seq')::text, 6, '0'),
           issue_date = $2, due_date = $8, issued_by = $3, issued_at = now(),
           customer_code = $4, customer_name = $5, customer_phone = $6, customer_address = $7
       WHERE id = $1
       RETURNING invoice_number`,
      [
        id,
        today,
        actor.id,
        customer.code,
        customer.name,
        customer.phone,
        customer.address,
        addDays(today, paymentTermsDays),
      ],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'invoice.issued',
      entityType: 'invoice',
      entityId: id,
      details: { invoiceNumber: rows[0]?.invoice_number, total: current.total },
    });
    return getInvoice(client, id, today);
  });
}

/** Voids a draft, releasing its dispatch lines so they can be invoiced again. */
export async function voidDraftInvoice(
  pool: pg.Pool,
  id: string,
  reason: string,
  actor: PublicUser,
): Promise<Invoice> {
  return withTransaction(pool, async (client) => {
    const current = await lockInvoice(client, id);
    if (current.status === 'issued') {
      throw new AppError(
        409,
        'INVOICE_ISSUED',
        'An issued invoice cannot be voided. Corrections will be made with credit notes.',
      );
    }
    if (current.status === 'voided') return getInvoice(client, id);

    await client.query('DELETE FROM invoice_items WHERE invoice_id = $1', [id]);
    await client.query(
      `UPDATE invoices SET status = 'voided', voided_by = $2, voided_at = now(), void_reason = $3
       WHERE id = $1`,
      [id, actor.id, reason],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'invoice.voided',
      entityType: 'invoice',
      entityId: id,
      details: { total: current.total, reason },
    });
    return getInvoice(client, id);
  });
}
