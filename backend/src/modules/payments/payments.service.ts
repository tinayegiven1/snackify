import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { fromCents, toCents } from '../../utils/money.js';
import { recordAudit } from '../audit/audit.js';
import type { PublicUser } from '../auth/roles.js';

export const PAYMENT_METHODS = [
  'cash',
  'bank_transfer',
  'mobile_money',
  'card',
  'cheque',
  'other',
] as const;
export type PaymentMethod = (typeof PAYMENT_METHODS)[number];
export type PaymentRecordStatus = 'recorded' | 'voided';

export interface PaymentAllocation {
  invoiceId: string;
  invoiceNumber: string;
  amount: string;
  allocatedBy: string;
  allocatedAt: Date;
}

export interface Payment {
  id: string;
  /** Receipt number, e.g. P000001. */
  paymentNumber: string;
  status: PaymentRecordStatus;
  customer: { id: string; code: string; name: string };
  paymentDate: string;
  amount: string;
  currency: string;
  method: PaymentMethod;
  reference: string | null;
  notes: string | null;
  /** Kept as history when the payment is voided, but then they no longer count. */
  allocations: PaymentAllocation[];
  allocatedAmount: string;
  /** Credit on the customer's account; 0.00 once the payment is voided. */
  unallocatedAmount: string;
  recordedBy: string;
  recordedAt: Date;
  voidedBy: string | null;
  voidedAt: Date | null;
  voidReason: string | null;
}

export interface PaymentSummary {
  id: string;
  paymentNumber: string;
  status: PaymentRecordStatus;
  customer: { id: string; code: string; name: string };
  paymentDate: string;
  amount: string;
  currency: string;
  method: PaymentMethod;
  reference: string | null;
  allocatedAmount: string;
  unallocatedAmount: string;
}

export interface AllocationInput {
  invoiceId: string;
  amount: string;
}

export interface PaymentInput {
  customerId: string;
  paymentDate: string;
  amount: string;
  method: PaymentMethod;
  reference: string | null;
  notes: string | null;
  /** Chosen by the app for each new payment; repeating a request with it records nothing new. */
  idempotencyKey: string | null;
  allocations: AllocationInput[];
}

const paymentNotFound = () => new AppError(404, 'PAYMENT_NOT_FOUND', 'No payment has that id.');

const unallocated = (status: PaymentRecordStatus, amount: string, allocated: string) =>
  status === 'voided' ? '0.00' : fromCents(toCents(amount) - toCents(allocated));

// ---------------------------------------------------------------- Reading payments

export async function getPayment(db: Queryable, id: string): Promise<Payment> {
  const { rows } = await db.query<{
    id: string;
    payment_number: string;
    status: PaymentRecordStatus;
    customer_id: string;
    code: string;
    name: string;
    payment_date: string;
    amount: string;
    currency: string;
    method: PaymentMethod;
    reference: string | null;
    notes: string | null;
    allocated: string;
    recorded_by_name: string;
    created_at: Date;
    voided_by_name: string | null;
    voided_at: Date | null;
    void_reason: string | null;
  }>(
    `SELECT p.id, p.payment_number, p.status, p.customer_id, c.code, c.name, p.payment_date,
            p.amount, p.currency, p.method, p.reference, p.notes,
            COALESCE(a.amount_allocated, 0)::numeric(14, 2)::text AS allocated,
            rb.full_name AS recorded_by_name, p.created_at,
            vb.full_name AS voided_by_name, p.voided_at, p.void_reason
     FROM payments p
     JOIN customers c ON c.id = p.customer_id
     JOIN users rb ON rb.id = p.recorded_by
     LEFT JOIN users vb ON vb.id = p.voided_by
     LEFT JOIN payment_amounts_allocated a ON a.payment_id = p.id
     WHERE p.id = $1`,
    [id],
  );
  const p = rows[0];
  if (!p) throw paymentNotFound();

  const { rows: allocations } = await db.query<{
    invoice_id: string;
    invoice_number: string;
    amount: string;
    full_name: string;
    created_at: Date;
  }>(
    `SELECT a.invoice_id, v.invoice_number, a.amount, u.full_name, a.created_at
     FROM payment_allocations a
     JOIN invoices v ON v.id = a.invoice_id
     JOIN users u ON u.id = a.created_by
     WHERE a.payment_id = $1
     ORDER BY a.created_at, v.invoice_number`,
    [id],
  );

  return {
    id: p.id,
    paymentNumber: p.payment_number,
    status: p.status,
    customer: { id: p.customer_id, code: p.code, name: p.name },
    paymentDate: p.payment_date,
    amount: p.amount,
    currency: p.currency,
    method: p.method,
    reference: p.reference,
    notes: p.notes,
    allocations: allocations.map((a) => ({
      invoiceId: a.invoice_id,
      invoiceNumber: a.invoice_number,
      amount: a.amount,
      allocatedBy: a.full_name,
      allocatedAt: a.created_at,
    })),
    allocatedAmount: p.allocated,
    unallocatedAmount: unallocated(p.status, p.amount, p.allocated),
    recordedBy: p.recorded_by_name,
    recordedAt: p.created_at,
    voidedBy: p.voided_by_name,
    voidedAt: p.voided_at,
    voidReason: p.void_reason,
  };
}

export async function listPayments(
  db: Queryable,
  search: {
    customerId?: string | undefined;
    status?: PaymentRecordStatus | undefined;
    from?: string | undefined;
    to?: string | undefined;
    q?: string | undefined;
    limit: number;
    offset: number;
  },
): Promise<{ payments: PaymentSummary[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  const add = (condition: string, value: unknown) => {
    params.push(value);
    conditions.push(condition.replaceAll('?', `$${params.length}`));
  };
  if (search.customerId) add('p.customer_id = ?', search.customerId);
  if (search.status) add('p.status = ?', search.status);
  if (search.from) add('p.payment_date >= ?', search.from);
  if (search.to) add('p.payment_date <= ?', search.to);
  if (search.q) {
    add(
      '(p.payment_number ILIKE ? OR p.reference ILIKE ? OR c.name ILIKE ?)',
      `%${escapeLike(search.q)}%`,
    );
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows } = await db.query<{
    id: string;
    payment_number: string;
    status: PaymentRecordStatus;
    customer_id: string;
    code: string;
    name: string;
    payment_date: string;
    amount: string;
    currency: string;
    method: PaymentMethod;
    reference: string | null;
    allocated: string;
    total_count: number;
  }>(
    `SELECT p.id, p.payment_number, p.status, p.customer_id, c.code, c.name, p.payment_date,
            p.amount, p.currency, p.method, p.reference,
            COALESCE(a.amount_allocated, 0)::numeric(14, 2)::text AS allocated,
            count(*) OVER ()::integer AS total_count
     FROM payments p
     JOIN customers c ON c.id = p.customer_id
     LEFT JOIN payment_amounts_allocated a ON a.payment_id = p.id
     ${where}
     ORDER BY p.payment_date DESC, p.payment_number DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, search.limit, search.offset],
  );
  return {
    payments: rows.map((row) => ({
      id: row.id,
      paymentNumber: row.payment_number,
      status: row.status,
      customer: { id: row.customer_id, code: row.code, name: row.name },
      paymentDate: row.payment_date,
      amount: row.amount,
      currency: row.currency,
      method: row.method,
      reference: row.reference,
      allocatedAmount: row.allocated,
      unallocatedAmount: unallocated(row.status, row.amount, row.allocated),
    })),
    total: rows[0]?.total_count ?? 0,
  };
}

// ---------------------------------------------------------------- Allocating

interface LockedPayment {
  id: string;
  payment_number: string;
  customer_id: string;
  amount: string;
  currency: string;
  status: PaymentRecordStatus;
}

async function lockPayment(client: pg.PoolClient, id: string): Promise<LockedPayment> {
  const { rows } = await client.query<LockedPayment>(
    `SELECT id, payment_number, customer_id, amount, currency, status
     FROM payments WHERE id = $1 FOR UPDATE`,
    [id],
  );
  if (!rows[0]) throw paymentNotFound();
  return rows[0];
}

/**
 * Applies part of a locked payment to issued invoices of the same customer. Each invoice is
 * locked first (always in the same order, so two allocations cannot deadlock), and only then
 * are the amounts already paid and allocated read, so allocations made at the same moment are
 * checked one after the other: no invoice is paid beyond its total and no payment is allocated
 * beyond its amount. The database checks the same rules again.
 */
async function allocate(
  client: pg.PoolClient,
  payment: LockedPayment,
  allocations: AllocationInput[],
  actor: PublicUser,
): Promise<void> {
  if (allocations.length === 0) return;
  const ids = allocations.map((a) => a.invoiceId);
  if (new Set(ids).size !== ids.length) {
    throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
      { field: 'allocations', message: 'List each invoice only once' },
    ]);
  }

  await client.query('SELECT 1 FROM invoices WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE', [
    ids,
  ]);
  const { rows: invoices } = await client.query<{
    id: string;
    invoice_number: string | null;
    status: string;
    customer_id: string;
    currency: string;
    total: string;
    amount_paid: string;
  }>(
    `SELECT v.id, v.invoice_number, v.status, v.customer_id, v.currency, v.total,
            COALESCE(paid.amount_paid, 0)::numeric(14, 2)::text AS amount_paid
     FROM invoices v
     LEFT JOIN invoice_amounts_paid paid ON paid.invoice_id = v.id
     WHERE v.id = ANY($1::uuid[])`,
    [ids],
  );
  const byId = new Map(invoices.map((invoice) => [invoice.id, invoice]));

  let requested = 0;
  for (const allocation of allocations) {
    const invoice = byId.get(allocation.invoiceId);
    if (!invoice) throw new AppError(404, 'INVOICE_NOT_FOUND', 'No invoice has that id.');
    if (invoice.status !== 'issued') {
      throw new AppError(
        409,
        'INVOICE_NOT_ISSUED',
        `Only issued invoices can be paid; this one is ${invoice.status}.`,
      );
    }
    if (invoice.customer_id !== payment.customer_id) {
      throw new AppError(
        409,
        'INVOICE_OTHER_CUSTOMER',
        `Invoice ${invoice.invoice_number} belongs to another customer.`,
      );
    }
    if (invoice.currency !== payment.currency) {
      throw new AppError(
        409,
        'CURRENCY_MISMATCH',
        `Invoice ${invoice.invoice_number} is in ${invoice.currency}, but the payment is in ${payment.currency}.`,
      );
    }
    const balanceDue = toCents(invoice.total) - toCents(invoice.amount_paid);
    if (toCents(allocation.amount) > balanceDue) {
      throw new AppError(
        409,
        'ALLOCATION_EXCEEDS_BALANCE',
        `Invoice ${invoice.invoice_number} has only ${invoice.currency} ${fromCents(balanceDue)} left to pay.`,
        { invoiceId: invoice.id, balanceDue: fromCents(balanceDue) },
      );
    }
    requested += toCents(allocation.amount);
  }

  const { rows: done } = await client.query<{ allocated: string }>(
    `SELECT COALESCE(sum(amount), 0)::numeric(14, 2)::text AS allocated
     FROM payment_allocations WHERE payment_id = $1`,
    [payment.id],
  );
  const available = toCents(payment.amount) - toCents((done[0] as { allocated: string }).allocated);
  if (requested > available) {
    throw new AppError(
      409,
      'ALLOCATION_EXCEEDS_PAYMENT',
      `Only ${payment.currency} ${fromCents(available)} of payment ${payment.payment_number} is left to allocate.`,
      { unallocatedAmount: fromCents(available) },
    );
  }

  for (const allocation of allocations) {
    await client.query(
      `INSERT INTO payment_allocations (payment_id, invoice_id, amount, created_by)
       VALUES ($1, $2, $3, $4)`,
      [payment.id, allocation.invoiceId, allocation.amount, actor.id],
    );
  }
}

// ---------------------------------------------------------------- Recording and voiding

/**
 * The payment already recorded with this idempotency key, if any. A key reused for a different
 * payment is refused rather than silently returning the wrong one.
 */
async function findRepeat(db: Queryable, input: PaymentInput): Promise<Payment | null> {
  if (!input.idempotencyKey) return null;
  const { rows } = await db.query<{
    id: string;
    customer_id: string;
    payment_date: string;
    amount: string;
    method: string;
  }>(
    `SELECT id, customer_id, payment_date, amount, method
     FROM payments WHERE idempotency_key = $1`,
    [input.idempotencyKey],
  );
  const existing = rows[0];
  if (!existing) return null;
  if (
    existing.customer_id !== input.customerId ||
    existing.payment_date !== input.paymentDate ||
    toCents(existing.amount) !== toCents(input.amount) ||
    existing.method !== input.method
  ) {
    throw new AppError(
      409,
      'IDEMPOTENCY_KEY_REUSED',
      'This request id was already used for a different payment.',
    );
  }
  return getPayment(db, existing.id);
}

/**
 * Records money received and, optionally, allocates it to the customer's issued invoices in
 * the same transaction. Whatever is not allocated stays as credit on the customer's account.
 * Repeating the request with the same idempotency key returns the first payment instead of
 * recording it twice (`duplicate: true`).
 */
export async function recordPayment(
  pool: pg.Pool,
  input: PaymentInput,
  actor: PublicUser,
  currency: string,
): Promise<{ payment: Payment; duplicate: boolean }> {
  const repeat = await findRepeat(pool, input);
  if (repeat) return { payment: repeat, duplicate: true };

  try {
    const payment = await withTransaction(pool, async (client) => {
      const { rows: customers } = await client.query('SELECT 1 FROM customers WHERE id = $1', [
        input.customerId,
      ]);
      if (!customers[0]) throw new AppError(404, 'CUSTOMER_NOT_FOUND', 'No customer has that id.');

      // The new row is locked by this transaction until it commits.
      const { rows } = await client.query<LockedPayment>(
        `INSERT INTO payments (customer_id, payment_date, amount, currency, method, reference,
                               notes, idempotency_key, recorded_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
         RETURNING id, payment_number, customer_id, amount, currency, status`,
        [
          input.customerId,
          input.paymentDate,
          input.amount,
          currency,
          input.method,
          input.reference,
          input.notes,
          input.idempotencyKey,
          actor.id,
        ],
      );
      const created = rows[0] as LockedPayment;
      await allocate(client, created, input.allocations, actor);
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'payment.recorded',
        entityType: 'payment',
        entityId: created.id,
        details: {
          paymentNumber: created.payment_number,
          amount: created.amount,
          currency,
          method: input.method,
          allocations: input.allocations,
        },
      });
      return getPayment(client, created.id);
    });
    return { payment, duplicate: false };
  } catch (error) {
    // The same request arrived twice at the same moment: the other one recorded it.
    if (isUniqueViolation(error, 'payments_idempotency_key_key')) {
      const first = await findRepeat(pool, input);
      if (first) return { payment: first, duplicate: true };
    }
    throw error;
  }
}

/** Allocates unallocated credit from an existing payment to issued invoices. */
export async function allocatePayment(
  pool: pg.Pool,
  id: string,
  allocations: AllocationInput[],
  actor: PublicUser,
): Promise<Payment> {
  return withTransaction(pool, async (client) => {
    const payment = await lockPayment(client, id);
    if (payment.status === 'voided') {
      throw new AppError(409, 'PAYMENT_VOIDED', 'This payment was voided and cannot be allocated.');
    }
    await allocate(client, payment, allocations, actor);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'payment.allocated',
      entityType: 'payment',
      entityId: id,
      details: { paymentNumber: payment.payment_number, allocations },
    });
    return getPayment(client, id);
  });
}

/**
 * Voids a payment recorded by mistake. Its allocations stay as history but no longer count, so
 * the invoices it paid are owed again. Voiding again changes nothing.
 */
export async function voidPayment(
  pool: pg.Pool,
  id: string,
  reason: string,
  actor: PublicUser,
): Promise<Payment> {
  return withTransaction(pool, async (client) => {
    const payment = await lockPayment(client, id);
    if (payment.status === 'voided') return getPayment(client, id);

    await client.query(
      `UPDATE payments SET status = 'voided', voided_by = $2, voided_at = now(), void_reason = $3
       WHERE id = $1`,
      [id, actor.id, reason],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'payment.voided',
      entityType: 'payment',
      entityId: id,
      details: {
        paymentNumber: payment.payment_number,
        amount: payment.amount,
        currency: payment.currency,
        reason,
      },
    });
    return getPayment(client, id);
  });
}
