import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { recordAudit } from '../audit/audit.js';
import { allocateFirstExpiring, headOfficeDefaults, insertMovement } from '../stock/ledger.js';
import type { PublicUser } from '../auth/roles.js';

export type DispatchStatus = 'draft' | 'confirmed' | 'cancelled' | 'reversed';

interface Person {
  id: string;
  fullName: string;
}

export interface DispatchLine {
  id: string;
  product: { id: string; sku: string; name: string; flavour: string; size: string };
  quantity: number;
  /** Price agreed for this dispatch (a snapshot), as an exact decimal string. */
  unitPrice: string;
  lineTotal: string;
  /** Stock on hand now; shown on drafts so shortages are visible before confirming. */
  quantityOnHand: number;
}

/**
 * What confirming would do to the customer's unpaid balance: the value of their confirmed
 * dispatches (invoiced or not) less the payments received from them.
 */
export interface CreditCheck {
  creditLimit: string | null;
  balanceBefore: string;
  dispatchTotal: string;
  balanceAfter: string;
  exceedsLimit: boolean;
}

export interface Dispatch {
  id: string;
  dispatchNumber: string;
  status: DispatchStatus;
  dispatchDate: string;
  notes: string | null;
  customer: { id: string; code: string; name: string; creditLimit: string | null };
  items: DispatchLine[];
  totalQuantity: number;
  totalValue: string;
  createdBy: Person;
  createdAt: Date;
  confirmedBy: Person | null;
  confirmedAt: Date | null;
  confirmedOverCreditLimit: boolean;
  cancelledBy: Person | null;
  cancelledAt: Date | null;
  cancelReason: string | null;
  reversedBy: Person | null;
  reversedAt: Date | null;
  reversalReason: string | null;
  /** Only for drafts: the credit check that confirming would apply. */
  creditCheck: CreditCheck | null;
}

const dispatchNotFound = () => new AppError(404, 'DISPATCH_NOT_FOUND', 'No dispatch has that id.');

const person = (id: string | null, fullName: string | null): Person | null =>
  id && fullName ? { id, fullName } : null;

// ---------------------------------------------------------------- Reading

interface HeaderRow {
  id: string;
  dispatch_number: string;
  status: DispatchStatus;
  dispatch_date: string;
  notes: string | null;
  customer_id: string;
  customer_code: string;
  customer_name: string;
  credit_limit: string | null;
  created_by: string;
  created_by_name: string;
  created_at: Date;
  confirmed_by: string | null;
  confirmed_by_name: string | null;
  confirmed_at: Date | null;
  confirmed_over_credit_limit: boolean;
  cancelled_by: string | null;
  cancelled_by_name: string | null;
  cancelled_at: Date | null;
  cancel_reason: string | null;
  reversed_by: string | null;
  reversed_by_name: string | null;
  reversed_at: Date | null;
  reversal_reason: string | null;
}

/**
 * The customer's unpaid balance (confirmed dispatches less payments that have not been voided)
 * and the effect of adding `amount`.
 */
async function creditCheck(
  db: Queryable,
  customerId: string,
  creditLimit: string | null,
  amount: string,
): Promise<CreditCheck> {
  const { rows } = await db.query<{ before: string; after: string; exceeds: boolean }>(
    `WITH balance AS (
       SELECT
         (SELECT COALESCE(sum(i.quantity * i.unit_price), 0)
          FROM dispatches d JOIN dispatch_items i ON i.dispatch_id = d.id
          WHERE d.customer_id = $1 AND d.status = 'confirmed')
         - (SELECT COALESCE(sum(p.amount), 0)
            FROM payments p
            WHERE p.customer_id = $1 AND p.status = 'recorded') AS before
     )
     SELECT before::numeric(14, 2)::text AS before,
            (before + $2::numeric)::numeric(14, 2)::text AS after,
            ($3::numeric IS NOT NULL AND before + $2::numeric > $3::numeric) AS exceeds
     FROM balance`,
    [customerId, amount, creditLimit],
  );
  const row = rows[0] as { before: string; after: string; exceeds: boolean };
  return {
    creditLimit,
    balanceBefore: row.before,
    dispatchTotal: amount,
    balanceAfter: row.after,
    exceedsLimit: row.exceeds,
  };
}

export async function getDispatch(db: Queryable, id: string): Promise<Dispatch> {
  const { rows } = await db.query<HeaderRow>(
    `SELECT d.id, d.dispatch_number, d.status, d.dispatch_date, d.notes,
            c.id AS customer_id, c.code AS customer_code, c.name AS customer_name, c.credit_limit,
            d.created_by, cb.full_name AS created_by_name, d.created_at,
            d.confirmed_by, fb.full_name AS confirmed_by_name, d.confirmed_at,
            d.confirmed_over_credit_limit,
            d.cancelled_by, xb.full_name AS cancelled_by_name, d.cancelled_at, d.cancel_reason,
            d.reversed_by, rb.full_name AS reversed_by_name, d.reversed_at, d.reversal_reason
     FROM dispatches d
     JOIN customers c ON c.id = d.customer_id
     JOIN users cb ON cb.id = d.created_by
     LEFT JOIN users fb ON fb.id = d.confirmed_by
     LEFT JOIN users xb ON xb.id = d.cancelled_by
     LEFT JOIN users rb ON rb.id = d.reversed_by
     WHERE d.id = $1`,
    [id],
  );
  const h = rows[0];
  if (!h) throw dispatchNotFound();

  const { rows: lines } = await db.query<{
    id: string;
    product_id: string;
    sku: string;
    name: string;
    flavour: string;
    size: string;
    quantity: number;
    unit_price: string;
    line_total: string;
    quantity_on_hand: number;
  }>(
    `SELECT i.id, i.product_id, p.sku, p.name, p.flavour, p.size, i.quantity, i.unit_price,
            (i.quantity * i.unit_price)::numeric(14, 2)::text AS line_total, b.quantity_on_hand
     FROM dispatch_items i
     JOIN products p ON p.id = i.product_id
     JOIN hq_stock_on_hand b ON b.product_id = i.product_id
     WHERE i.dispatch_id = $1
     ORDER BY p.name, p.flavour, p.size`,
    [id],
  );
  const { rows: totals } = await db.query<{ total_quantity: number; total_value: string }>(
    `SELECT COALESCE(sum(quantity), 0)::integer AS total_quantity,
            COALESCE(sum(quantity * unit_price), 0)::numeric(14, 2)::text AS total_value
     FROM dispatch_items WHERE dispatch_id = $1`,
    [id],
  );
  const { total_quantity, total_value } = totals[0] as {
    total_quantity: number;
    total_value: string;
  };

  return {
    id: h.id,
    dispatchNumber: h.dispatch_number,
    status: h.status,
    dispatchDate: h.dispatch_date,
    notes: h.notes,
    customer: {
      id: h.customer_id,
      code: h.customer_code,
      name: h.customer_name,
      creditLimit: h.credit_limit,
    },
    items: lines.map((line) => ({
      id: line.id,
      product: {
        id: line.product_id,
        sku: line.sku,
        name: line.name,
        flavour: line.flavour,
        size: line.size,
      },
      quantity: line.quantity,
      unitPrice: line.unit_price,
      lineTotal: line.line_total,
      quantityOnHand: line.quantity_on_hand,
    })),
    totalQuantity: total_quantity,
    totalValue: total_value,
    createdBy: { id: h.created_by, fullName: h.created_by_name },
    createdAt: h.created_at,
    confirmedBy: person(h.confirmed_by, h.confirmed_by_name),
    confirmedAt: h.confirmed_at,
    confirmedOverCreditLimit: h.confirmed_over_credit_limit,
    cancelledBy: person(h.cancelled_by, h.cancelled_by_name),
    cancelledAt: h.cancelled_at,
    cancelReason: h.cancel_reason,
    reversedBy: person(h.reversed_by, h.reversed_by_name),
    reversedAt: h.reversed_at,
    reversalReason: h.reversal_reason,
    creditCheck:
      h.status === 'draft'
        ? await creditCheck(db, h.customer_id, h.credit_limit, total_value)
        : null,
  };
}

export interface DispatchSummary {
  id: string;
  dispatchNumber: string;
  status: DispatchStatus;
  dispatchDate: string;
  customer: { id: string; code: string; name: string };
  lineCount: number;
  totalQuantity: number;
  totalValue: string;
  createdBy: string;
}

export interface DispatchSearch {
  status?: DispatchStatus | undefined;
  customerId?: string | undefined;
  from?: string | undefined;
  to?: string | undefined;
  /** Part of the dispatch number or customer name. */
  q?: string | undefined;
  limit: number;
  offset: number;
}

export async function listDispatches(
  db: Queryable,
  search: DispatchSearch,
): Promise<{ dispatches: DispatchSummary[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  const add = (condition: string, value: unknown) => {
    params.push(value);
    conditions.push(condition.replaceAll('?', `$${params.length}`));
  };
  if (search.status) add('d.status = ?', search.status);
  if (search.customerId) add('d.customer_id = ?', search.customerId);
  if (search.from) add('d.dispatch_date >= ?', search.from);
  if (search.to) add('d.dispatch_date <= ?', search.to);
  if (search.q) add('(d.dispatch_number ILIKE ? OR c.name ILIKE ?)', `%${escapeLike(search.q)}%`);
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows } = await db.query<{
    id: string;
    dispatch_number: string;
    status: DispatchStatus;
    dispatch_date: string;
    customer_id: string;
    customer_code: string;
    customer_name: string;
    line_count: number;
    total_quantity: number;
    total_value: string;
    created_by_name: string;
    total: number;
  }>(
    `SELECT d.id, d.dispatch_number, d.status, d.dispatch_date,
            c.id AS customer_id, c.code AS customer_code, c.name AS customer_name,
            count(i.id)::integer AS line_count,
            COALESCE(sum(i.quantity), 0)::integer AS total_quantity,
            COALESCE(sum(i.quantity * i.unit_price), 0)::numeric(14, 2)::text AS total_value,
            u.full_name AS created_by_name,
            count(*) OVER ()::integer AS total
     FROM dispatches d
     JOIN customers c ON c.id = d.customer_id
     JOIN users u ON u.id = d.created_by
     LEFT JOIN dispatch_items i ON i.dispatch_id = d.id
     ${where}
     GROUP BY d.id, c.id, u.id
     ORDER BY d.dispatch_date DESC, d.created_at DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, search.limit, search.offset],
  );
  return {
    dispatches: rows.map((row) => ({
      id: row.id,
      dispatchNumber: row.dispatch_number,
      status: row.status,
      dispatchDate: row.dispatch_date,
      customer: { id: row.customer_id, code: row.customer_code, name: row.customer_name },
      lineCount: row.line_count,
      totalQuantity: row.total_quantity,
      totalValue: row.total_value,
      createdBy: row.created_by_name,
    })),
    total: rows[0]?.total ?? 0,
  };
}

// ---------------------------------------------------------------- Drafts

export interface DraftInput {
  customerId: string;
  dispatchDate: string;
  notes: string | null;
  /** unitPrice left out = the product's current default price. */
  items: { productId: string; quantity: number; unitPrice?: string | undefined }[];
}

/** Checks the customer and products are active and fills in default prices. */
async function prepareLines(client: pg.PoolClient, input: DraftInput) {
  const { rows: customers } = await client.query<{ is_active: boolean }>(
    'SELECT is_active FROM customers WHERE id = $1',
    [input.customerId],
  );
  if (!customers[0]) {
    throw new AppError(404, 'CUSTOMER_NOT_FOUND', 'No customer has that id.');
  }
  if (!customers[0].is_active) {
    throw new AppError(409, 'CUSTOMER_INACTIVE', 'This customer is inactive.', [
      { field: 'customerId', message: 'This customer is inactive' },
    ]);
  }

  const { rows: products } = await client.query<{
    id: string;
    is_active: boolean;
    default_price: string;
  }>('SELECT id, is_active, default_price FROM products WHERE id = ANY($1::uuid[])', [
    input.items.map((item) => item.productId),
  ]);
  const byId = new Map(products.map((p) => [p.id, p]));

  return input.items.map((item, index) => {
    const product = byId.get(item.productId);
    if (!product || !product.is_active) {
      throw new AppError(
        409,
        'PRODUCT_INACTIVE',
        product ? 'An inactive product cannot be dispatched.' : 'No product has that id.',
        [
          {
            field: `items.${index}.productId`,
            message: product ? 'Inactive product' : 'Unknown product',
          },
        ],
      );
    }
    return { ...item, unitPrice: item.unitPrice ?? product.default_price };
  });
}

async function writeLines(
  client: pg.PoolClient,
  dispatchId: string,
  lines: { productId: string; quantity: number; unitPrice: string }[],
) {
  for (const line of lines) {
    await client.query(
      `INSERT INTO dispatch_items (dispatch_id, product_id, quantity, unit_price)
       VALUES ($1, $2, $3, $4)`,
      [dispatchId, line.productId, line.quantity, line.unitPrice],
    );
  }
}

export async function createDraft(
  pool: pg.Pool,
  input: DraftInput,
  actor: PublicUser,
): Promise<Dispatch> {
  return withTransaction(pool, async (client) => {
    const lines = await prepareLines(client, input);
    const { rows } = await client.query<{ id: string }>(
      `INSERT INTO dispatches (customer_id, dispatch_date, notes, created_by)
       VALUES ($1, $2, $3, $4) RETURNING id`,
      [input.customerId, input.dispatchDate, input.notes, actor.id],
    );
    const id = (rows[0] as { id: string }).id;
    await writeLines(client, id, lines);
    return getDispatch(client, id);
  });
}

/** Locks the dispatch row until the transaction ends, so two people cannot change it at once. */
async function lockDispatch(client: pg.PoolClient, id: string) {
  const { rows } = await client.query<{
    status: DispatchStatus;
    dispatch_number: string;
    customer_id: string;
    dispatch_date: string;
  }>(
    'SELECT status, dispatch_number, customer_id, dispatch_date FROM dispatches WHERE id = $1 FOR UPDATE',
    [id],
  );
  if (!rows[0]) throw dispatchNotFound();
  return rows[0];
}

const notDraft = (status: DispatchStatus) =>
  new AppError(
    409,
    'DISPATCH_NOT_DRAFT',
    `This dispatch is ${status}, so it can no longer be changed.`,
  );

/** Replaces a draft's customer, date, notes and lines. */
export async function updateDraft(pool: pg.Pool, id: string, input: DraftInput): Promise<Dispatch> {
  return withTransaction(pool, async (client) => {
    const current = await lockDispatch(client, id);
    if (current.status !== 'draft') throw notDraft(current.status);

    const lines = await prepareLines(client, input);
    await client.query(
      'UPDATE dispatches SET customer_id = $2, dispatch_date = $3, notes = $4 WHERE id = $1',
      [id, input.customerId, input.dispatchDate, input.notes],
    );
    await client.query('DELETE FROM dispatch_items WHERE dispatch_id = $1', [id]);
    await writeLines(client, id, lines);
    return getDispatch(client, id);
  });
}

export async function cancelDraft(
  pool: pg.Pool,
  id: string,
  reason: string,
  actor: PublicUser,
): Promise<Dispatch> {
  return withTransaction(pool, async (client) => {
    const current = await lockDispatch(client, id);
    if (current.status !== 'draft') throw notDraft(current.status);

    await client.query(
      `UPDATE dispatches
       SET status = 'cancelled', cancelled_by = $2, cancelled_at = now(), cancel_reason = $3
       WHERE id = $1`,
      [id, actor.id, reason],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'dispatch.cancelled',
      entityType: 'dispatch',
      entityId: id,
      details: { dispatchNumber: current.dispatch_number, reason },
    });
    return getDispatch(client, id);
  });
}

// ---------------------------------------------------------------- Confirming

/**
 * Confirms a draft: checks stock and deducts it, all in one transaction (spec 6.6).
 *
 * - Confirming an already-confirmed dispatch changes nothing and returns it (safe to retry).
 * - Product rows are locked in a fixed order, so concurrent confirmations (and stock
 *   adjustments, which lock the same rows) run one after another and cannot oversell.
 * - If the dispatch would take the customer over their credit limit, it is refused with
 *   CREDIT_LIMIT_EXCEEDED unless `acknowledgeCreditLimit` is true; an override is recorded.
 */
export async function confirmDispatch(
  pool: pg.Pool,
  id: string,
  actor: PublicUser,
  options: { acknowledgeCreditLimit: boolean; today: string },
): Promise<{ dispatch: Dispatch; alreadyConfirmed: boolean }> {
  return withTransaction(pool, async (client) => {
    const current = await lockDispatch(client, id);
    if (current.status === 'confirmed') {
      return { dispatch: await getDispatch(client, id), alreadyConfirmed: true };
    }
    if (current.status !== 'draft') throw notDraft(current.status);
    if (current.dispatch_date > options.today) {
      throw new AppError(
        409,
        'DISPATCH_DATE_IN_FUTURE',
        'This dispatch is dated in the future. Change its date, or confirm it on the day.',
      );
    }

    const { rows: customers } = await client.query<{
      is_active: boolean;
      name: string;
      credit_limit: string | null;
    }>('SELECT is_active, name, credit_limit FROM customers WHERE id = $1 FOR UPDATE', [
      current.customer_id,
    ]);
    const customer = customers[0] as {
      is_active: boolean;
      name: string;
      credit_limit: string | null;
    };
    if (!customer.is_active) {
      throw new AppError(409, 'CUSTOMER_INACTIVE', 'This customer is inactive.');
    }

    // Lock every product on the dispatch, always in the same order to avoid deadlocks.
    const { rows: lines } = await client.query<{
      item_id: string;
      product_id: string;
      quantity: number;
      is_active: boolean;
      description: string;
    }>(
      `SELECT i.id AS item_id, i.product_id, i.quantity, p.is_active,
              p.name || ' — ' || p.flavour || ' — ' || p.size AS description
       FROM dispatch_items i
       JOIN products p ON p.id = i.product_id
       WHERE i.dispatch_id = $1
       ORDER BY i.product_id
       FOR UPDATE OF p`,
      [id],
    );
    if (lines.length === 0) {
      throw new AppError(409, 'DISPATCH_EMPTY', 'A dispatch needs at least one line.');
    }

    const inactive = lines.filter((line) => !line.is_active);
    if (inactive.length > 0) {
      throw new AppError(
        409,
        'PRODUCT_INACTIVE',
        `These products are inactive: ${inactive.map((l) => l.description).join(', ')}.`,
      );
    }

    // The Head Office's own stock, less anything reserved for approved orders.
    const { rows: balances } = await client.query<{ product_id: string; available: number }>(
      `SELECT product_id, quantity_on_hand - quantity_reserved AS available
       FROM hq_stock_on_hand WHERE product_id = ANY($1::uuid[])`,
      [lines.map((line) => line.product_id)],
    );
    const onHand = new Map(balances.map((b) => [b.product_id, b.available]));
    const shortages = lines
      .map((line) => ({ ...line, available: onHand.get(line.product_id) ?? 0 }))
      .filter((line) => line.quantity > line.available);
    if (shortages.length > 0) {
      throw new AppError(
        409,
        'INSUFFICIENT_STOCK',
        `Not enough stock for: ${shortages
          .map((s) => `${s.description} (need ${s.quantity}, have ${s.available})`)
          .join('; ')}.`,
        shortages.map((s) => ({
          productId: s.product_id,
          requested: s.quantity,
          available: s.available,
        })),
      );
    }

    const { rows: totals } = await client.query<{ total: string }>(
      `SELECT COALESCE(sum(quantity * unit_price), 0)::numeric(14, 2)::text AS total
       FROM dispatch_items WHERE dispatch_id = $1`,
      [id],
    );
    const credit = await creditCheck(
      client,
      current.customer_id,
      customer.credit_limit,
      (totals[0] as { total: string }).total,
    );
    if (credit.exceedsLimit && !options.acknowledgeCreditLimit) {
      throw new AppError(
        409,
        'CREDIT_LIMIT_EXCEEDED',
        `This dispatch (${credit.dispatchTotal}) would take ${customer.name}'s unpaid balance to ` +
          `${credit.balanceAfter}, over their credit limit of ${credit.creditLimit}. ` +
          'Confirm again with acknowledgeCreditLimit to go ahead.',
        credit,
      );
    }

    // Each line takes the Head Office's batches that expire first; one ledger entry per batch.
    const headOffice = await headOfficeDefaults(client);
    for (const line of lines) {
      const { allocations } = await allocateFirstExpiring(client, {
        productId: line.product_id,
        ownerOrganisationId: headOffice.organisationId,
        quantity: line.quantity,
      });
      for (const allocation of allocations) {
        await insertMovement(client, {
          productId: line.product_id,
          ownerOrganisationId: headOffice.organisationId,
          warehouseId: allocation.warehouseId,
          batchId: allocation.batchId,
          type: 'dispatch',
          quantityDelta: -allocation.quantity,
          businessDate: current.dispatch_date,
          createdBy: actor.id,
          reference: current.dispatch_number,
          dispatchItemId: line.item_id,
        });
      }
    }

    await client.query(
      `UPDATE dispatches
       SET status = 'confirmed', confirmed_by = $2, confirmed_at = now(),
           confirmed_over_credit_limit = $3
       WHERE id = $1`,
      [id, actor.id, credit.exceedsLimit],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'dispatch.confirmed',
      entityType: 'dispatch',
      entityId: id,
      details: {
        dispatchNumber: current.dispatch_number,
        totalValue: credit.dispatchTotal,
        overCreditLimit: credit.exceedsLimit,
        ...(credit.exceedsLimit
          ? { creditLimit: credit.creditLimit, balanceAfter: credit.balanceAfter }
          : {}),
      },
    });
    return { dispatch: await getDispatch(client, id), alreadyConfirmed: false };
  });
}

// ---------------------------------------------------------------- Reversing

/**
 * Undoes a confirmed dispatch (a controlled correction, spec 6.6): adds every line's stock
 * back with "reversal" movements that point at the originals, and marks it reversed.
 * Nothing is deleted or edited, so the history shows both the dispatch and its reversal.
 */
export async function reverseDispatch(
  pool: pg.Pool,
  id: string,
  reason: string,
  actor: PublicUser,
  today: string,
): Promise<Dispatch> {
  return withTransaction(pool, async (client) => {
    const current = await lockDispatch(client, id);
    if (current.status !== 'confirmed') {
      throw new AppError(
        409,
        'DISPATCH_NOT_CONFIRMED',
        `Only a confirmed dispatch can be reversed; this one is ${current.status}.`,
      );
    }

    // A dispatch that has been invoiced cannot simply be reversed: the bill would disagree.
    const { rows: invoiced } = await client.query<{
      invoice_number: string | null;
      status: string;
    }>(
      `SELECT v.invoice_number, v.status
       FROM invoice_items ii
       JOIN invoices v ON v.id = ii.invoice_id
       JOIN dispatch_items i ON i.id = ii.dispatch_item_id
       WHERE i.dispatch_id = $1
       LIMIT 1`,
      [id],
    );
    if (invoiced[0]) {
      throw new AppError(
        409,
        'DISPATCH_INVOICED',
        invoiced[0].status === 'issued'
          ? `This dispatch is on invoice ${invoiced[0].invoice_number}, so it cannot be reversed. ` +
              'Corrections to issued invoices will be made with credit notes.'
          : 'This dispatch is on a draft invoice. Void the draft invoice first, then reverse it.',
      );
    }

    const { rows: movements } = await client.query<{
      id: string;
      product_id: string;
      quantity_delta: number;
      owner_organisation_id: string;
      warehouse_id: string;
      batch_id: string | null;
    }>(
      `SELECT m.id, m.product_id, m.quantity_delta, m.owner_organisation_id, m.warehouse_id,
              m.batch_id
       FROM stock_movements m
       JOIN dispatch_items i ON i.id = m.dispatch_item_id
       WHERE i.dispatch_id = $1 AND m.movement_type = 'dispatch'
       ORDER BY m.product_id`,
      [id],
    );
    // Lock the products too, like every other stock change.
    await client.query('SELECT 1 FROM products WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE', [
      movements.map((m) => m.product_id),
    ]);

    // The goods go back to exactly where they came from: same owner, warehouse and batch.
    for (const movement of movements) {
      await insertMovement(client, {
        productId: movement.product_id,
        ownerOrganisationId: movement.owner_organisation_id,
        warehouseId: movement.warehouse_id,
        batchId: movement.batch_id,
        type: 'reversal',
        quantityDelta: -movement.quantity_delta,
        businessDate: today,
        createdBy: actor.id,
        reference: current.dispatch_number,
        reason,
        reversesMovementId: movement.id,
      });
    }

    await client.query(
      `UPDATE dispatches
       SET status = 'reversed', reversed_by = $2, reversed_at = now(), reversal_reason = $3
       WHERE id = $1`,
      [id, actor.id, reason],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'dispatch.reversed',
      entityType: 'dispatch',
      entityId: id,
      details: { dispatchNumber: current.dispatch_number, reason },
    });
    return getDispatch(client, id);
  });
}
