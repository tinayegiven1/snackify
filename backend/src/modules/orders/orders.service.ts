import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { can } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { recordAudit } from '../audit/audit.js';
import type { PublicUser } from '../auth/roles.js';
import { canAccessOrganisation, type AccessScope } from '../organisations/access.js';
import { toBaseQuantity } from '../products/products.service.js';

// StockFlow Stage 5: orders from subsidiaries, with expected, maximum and actual prices.
// See the migration 20261021120000000_orders.sql for the statuses and the rules the database
// enforces itself.

export type OrderStatus =
  | 'DRAFT'
  | 'SUBMITTED'
  | 'UNDER_REVIEW'
  | 'APPROVED'
  | 'REJECTED'
  | 'CANCELLED'
  | 'PARTIALLY_DISPATCHED'
  | 'FULLY_DISPATCHED'
  | 'COMPLETED';

export interface OrderLineInput {
  productId: string;
  unitId: string;
  requestedQuantity: number;
  /** Exact decimal strings with up to 2 decimal places, in the order's currency. */
  expectedUnitPrice: string;
  maximumUnitPrice: string;
  notes: string | null;
}

export interface OrderInput {
  /** The ordering subsidiary; for a subsidiary's own staff it is always their organisation. */
  organisationId?: string | undefined;
  requiredDate: string | null;
  notes: string | null;
  lines: OrderLineInput[];
}

interface Ref {
  id: string;
  code: string;
  name: string;
}

interface Person {
  id: string;
  fullName: string;
}

export interface OrderSummary {
  id: string;
  orderNumber: string;
  status: OrderStatus;
  organisation: Ref;
  orderDate: string;
  requiredDate: string | null;
  currency: string;
  requestedBy: Person;
  lineCount: number;
  /** Sums of the lines (exact decimal strings), worked out by the database. */
  expectedTotal: string;
  maximumTotal: string;
  /** The total at actual prices, once every line has one; null before that. */
  actualTotal: string | null;
  /** Some line's actual price is above its maximum. */
  priceException: boolean;
  submittedAt: Date | null;
  createdAt: Date;
}

export interface OrderLine {
  id: string;
  lineNumber: number;
  product: { id: string; sku: string; description: string };
  unit: Ref;
  requestedQuantity: number;
  baseQuantity: number;
  expectedUnitPrice: string;
  maximumUnitPrice: string;
  actualUnitPrice: string | null;
  expectedLineTotal: string;
  maximumLineTotal: string;
  actualLineTotal: string | null;
  priceException: boolean;
  notes: string | null;
  /**
   * The Head Office's stock available for this product, in base units. Only shown to Head
   * Office staff; a subsidiary never sees another organisation's stock.
   */
  hqAvailable?: number;
}

export interface Order extends OrderSummary {
  notes: string | null;
  taxAmount: string;
  discountAmount: string;
  submittedBy: Person | null;
  decidedBy: Person | null;
  decidedAt: Date | null;
  decisionComment: string | null;
  priceExceptionApproved: boolean;
  cancelledBy: Person | null;
  cancelledAt: Date | null;
  cancelReason: string | null;
  lines: OrderLine[];
  history: {
    fromStatus: OrderStatus | null;
    toStatus: OrderStatus;
    changedBy: Person;
    changedAt: Date;
    comment: string | null;
  }[];
  changes: {
    lineNumber: number;
    field: string;
    oldValue: string | null;
    newValue: string | null;
    changedBy: Person;
    changedAt: Date;
    comment: string | null;
  }[];
}

const person = (alias: string) =>
  `CASE WHEN ${alias}.id IS NULL THEN NULL
        ELSE json_build_object('id', ${alias}.id, 'fullName', ${alias}.full_name) END`;

const SUMMARY_SELECT = `
  SELECT o.id, o.order_number, o.status, o.order_date, o.required_date, o.currency,
         o.submitted_at, o.created_at,
         json_build_object('id', g.id, 'code', g.code, 'name', g.name) AS organisation,
         json_build_object('id', rb.id, 'fullName', rb.full_name) AS requested_by,
         t.line_count, t.expected_total, t.maximum_total, t.actual_total, t.price_exception
  FROM orders o
  JOIN organisations g ON g.id = o.organisation_id
  JOIN users rb ON rb.id = o.requested_by
  CROSS JOIN LATERAL (
    SELECT count(*)::int AS line_count,
           COALESCE(sum(i.expected_line_total), 0)::numeric(14, 2)::text AS expected_total,
           COALESCE(sum(i.maximum_line_total), 0)::numeric(14, 2)::text AS maximum_total,
           CASE WHEN count(*) > 0 AND bool_and(i.actual_unit_price IS NOT NULL)
                THEN (sum(i.actual_line_total) + o.tax_amount - o.discount_amount)
                       ::numeric(14, 2)::text END AS actual_total,
           COALESCE(bool_or(i.price_exception), false) AS price_exception
    FROM order_items i WHERE i.order_id = o.id
  ) t`;

interface SummaryRow {
  id: string;
  order_number: string;
  status: OrderStatus;
  order_date: string;
  required_date: string | null;
  currency: string;
  submitted_at: Date | null;
  created_at: Date;
  organisation: Ref;
  requested_by: Person;
  line_count: number;
  expected_total: string;
  maximum_total: string;
  actual_total: string | null;
  price_exception: boolean;
}

const toSummary = (row: SummaryRow): OrderSummary => ({
  id: row.id,
  orderNumber: row.order_number,
  status: row.status,
  organisation: row.organisation,
  orderDate: row.order_date,
  requiredDate: row.required_date,
  currency: row.currency,
  requestedBy: row.requested_by,
  lineCount: row.line_count,
  expectedTotal: row.expected_total,
  maximumTotal: row.maximum_total,
  actualTotal: row.actual_total,
  priceException: row.price_exception,
  submittedAt: row.submitted_at,
  createdAt: row.created_at,
});

export const orderNotFound = () => new AppError(404, 'ORDER_NOT_FOUND', 'No order has that id.');

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

const STATUS_WORDS: Record<OrderStatus, string> = {
  DRAFT: 'a draft',
  SUBMITTED: 'submitted',
  UNDER_REVIEW: 'under review',
  APPROVED: 'approved',
  REJECTED: 'rejected',
  CANCELLED: 'cancelled',
  PARTIALLY_DISPATCHED: 'partly dispatched',
  FULLY_DISPATCHED: 'dispatched',
  COMPLETED: 'completed',
};

function wrongStatus(status: OrderStatus, action: string): AppError {
  return new AppError(
    409,
    'ORDER_WRONG_STATUS',
    `This order is ${STATUS_WORDS[status]}, so it cannot be ${action}.`,
  );
}

/** Reviewing, pricing and deciding are the Head Office's work, whatever the permissions say. */
function headOfficeOnly(scope: AccessScope): void {
  if (!scope.allOrganisations) {
    throw new AppError(403, 'FORBIDDEN', 'Only the Head Office reviews and decides orders.');
  }
}

export type OrderSort = 'newest' | 'oldest' | 'required';

export interface OrderFilter {
  status?: OrderStatus | undefined;
  organisationId?: string | undefined;
  priceException?: boolean | undefined;
  /** Part of the order number. */
  q?: string | undefined;
  from?: string | undefined;
  to?: string | undefined;
  sort: OrderSort;
  limit: number;
  offset: number;
}

const SORTS: Record<OrderSort, string> = {
  newest: 'created_at DESC',
  oldest: 'created_at ASC',
  required: 'required_date ASC NULLS LAST, created_at ASC',
};

/** Orders the user may see (a subsidiary: its own; the Head Office: all). */
export async function listOrders(
  db: Queryable,
  scope: AccessScope,
  filter: OrderFilter,
): Promise<{ orders: OrderSummary[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  const add = (condition: string, value: unknown) => {
    params.push(value);
    conditions.push(condition.replaceAll('?', `$${params.length}`));
  };
  if (!scope.allOrganisations) add("organisation->>'id' = ?", scope.organisationId);
  if (filter.organisationId) add("organisation->>'id' = ?", filter.organisationId);
  if (filter.status) add('status = ?', filter.status);
  if (filter.priceException !== undefined) add('price_exception = ?', filter.priceException);
  if (filter.q) add("order_number ILIKE ? ESCAPE '\\'", `%${escapeLike(filter.q)}%`);
  if (filter.from) add('order_date >= ?', filter.from);
  if (filter.to) add('order_date <= ?', filter.to);
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const { rows } = await db.query<SummaryRow & { full_count: number }>(
    `SELECT *, count(*) OVER ()::int AS full_count FROM (${SUMMARY_SELECT}) orders_list
     ${where}
     ORDER BY ${SORTS[filter.sort]}
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, filter.limit, filter.offset],
  );
  return { orders: rows.map(toSummary), total: rows[0]?.full_count ?? 0 };
}

/** One order with its lines, history and changes; 404 also outside the user's access. */
export async function getOrder(db: Queryable, scope: AccessScope, id: string): Promise<Order> {
  const { rows } = await db.query<
    SummaryRow & {
      organisation_id: string;
      notes: string | null;
      tax_amount: string;
      discount_amount: string;
      submitted_by: Person | null;
      decided_by: Person | null;
      decided_at: Date | null;
      decision_comment: string | null;
      price_exception_approved: boolean;
      cancelled_by: Person | null;
      cancelled_at: Date | null;
      cancel_reason: string | null;
    }
  >(
    `SELECT summary.*, o.organisation_id, o.notes, o.tax_amount::text, o.discount_amount::text,
            o.decided_at, o.decision_comment, o.price_exception_approved, o.cancelled_at,
            o.cancel_reason,
            ${person('sb')} AS submitted_by, ${person('db')} AS decided_by,
            ${person('cb')} AS cancelled_by
     FROM (${SUMMARY_SELECT} WHERE o.id = $1) summary
     JOIN orders o ON o.id = summary.id
     LEFT JOIN users sb ON sb.id = o.submitted_by
     LEFT JOIN users db ON db.id = o.decided_by
     LEFT JOIN users cb ON cb.id = o.cancelled_by`,
    [id],
  );
  const row = rows[0];
  if (!row || !canAccessOrganisation(scope, row.organisation_id)) throw orderNotFound();

  const { rows: lines } = await db.query<{
    id: string;
    line_number: number;
    product: { id: string; sku: string; description: string };
    unit: Ref;
    requested_quantity: number;
    base_quantity: number;
    expected_unit_price: string;
    maximum_unit_price: string;
    actual_unit_price: string | null;
    expected_line_total: string;
    maximum_line_total: string;
    actual_line_total: string | null;
    price_exception: boolean;
    notes: string | null;
    hq_available: number;
  }>(
    `SELECT i.id, i.line_number, i.requested_quantity, i.base_quantity,
            i.expected_unit_price::text, i.maximum_unit_price::text, i.actual_unit_price::text,
            i.expected_line_total::text, i.maximum_line_total::text, i.actual_line_total::text,
            i.price_exception, i.notes,
            json_build_object('id', p.id, 'sku', p.sku,
                              'description', p.name || ' — ' || p.flavour || ' — ' || p.size)
              AS product,
            json_build_object('id', u.id, 'code', u.code, 'name', u.name) AS unit,
            COALESCE(h.quantity_on_hand - h.quantity_reserved, 0)::int AS hq_available
     FROM order_items i
     JOIN products p ON p.id = i.product_id
     JOIN units u ON u.id = i.unit_id
     LEFT JOIN hq_stock_on_hand h ON h.product_id = i.product_id
     WHERE i.order_id = $1
     ORDER BY i.line_number`,
    [id],
  );
  const { rows: history } = await db.query<{
    from_status: OrderStatus | null;
    to_status: OrderStatus;
    changed_by: Person;
    changed_at: Date;
    comment: string | null;
  }>(
    `SELECT h.from_status, h.to_status, h.changed_at, h.comment,
            json_build_object('id', u.id, 'fullName', u.full_name) AS changed_by
     FROM order_status_history h JOIN users u ON u.id = h.changed_by
     WHERE h.order_id = $1 ORDER BY h.changed_at, h.id`,
    [id],
  );
  const { rows: changes } = await db.query<{
    line_number: number;
    field: string;
    old_value: string | null;
    new_value: string | null;
    changed_by: Person;
    changed_at: Date;
    comment: string | null;
  }>(
    `SELECT i.line_number, c.field, c.old_value, c.new_value, c.changed_at, c.comment,
            json_build_object('id', u.id, 'fullName', u.full_name) AS changed_by
     FROM order_item_changes c
     JOIN order_items i ON i.id = c.order_item_id
     JOIN users u ON u.id = c.changed_by
     WHERE c.order_id = $1 ORDER BY c.changed_at, c.id`,
    [id],
  );

  return {
    ...toSummary(row),
    notes: row.notes,
    taxAmount: row.tax_amount,
    discountAmount: row.discount_amount,
    submittedBy: row.submitted_by,
    decidedBy: row.decided_by,
    decidedAt: row.decided_at,
    decisionComment: row.decision_comment,
    priceExceptionApproved: row.price_exception_approved,
    cancelledBy: row.cancelled_by,
    cancelledAt: row.cancelled_at,
    cancelReason: row.cancel_reason,
    lines: lines.map((line) => ({
      id: line.id,
      lineNumber: line.line_number,
      product: line.product,
      unit: line.unit,
      requestedQuantity: line.requested_quantity,
      baseQuantity: line.base_quantity,
      expectedUnitPrice: line.expected_unit_price,
      maximumUnitPrice: line.maximum_unit_price,
      actualUnitPrice: line.actual_unit_price,
      expectedLineTotal: line.expected_line_total,
      maximumLineTotal: line.maximum_line_total,
      actualLineTotal: line.actual_line_total,
      priceException: line.price_exception,
      notes: line.notes,
      ...(scope.allOrganisations ? { hqAvailable: line.hq_available } : {}),
    })),
    history: history.map((entry) => ({
      fromStatus: entry.from_status,
      toStatus: entry.to_status,
      changedBy: entry.changed_by,
      changedAt: entry.changed_at,
      comment: entry.comment,
    })),
    changes: changes.map((change) => ({
      lineNumber: change.line_number,
      field: change.field,
      oldValue: change.old_value,
      newValue: change.new_value,
      changedBy: change.changed_by,
      changedAt: change.changed_at,
      comment: change.comment,
    })),
  };
}

/** Locks the order row and returns what the actions need. */
async function lockOrder(client: pg.PoolClient, scope: AccessScope, id: string) {
  const { rows } = await client.query<{
    status: OrderStatus;
    organisation_id: string;
    order_number: string;
  }>('SELECT status, organisation_id, order_number FROM orders WHERE id = $1 FOR UPDATE', [id]);
  const row = rows[0];
  if (!row || !canAccessOrganisation(scope, row.organisation_id)) throw orderNotFound();
  return row;
}

async function recordStatus(
  client: pg.PoolClient,
  id: string,
  from: OrderStatus | null,
  to: OrderStatus,
  actor: PublicUser,
  comment: string | null,
): Promise<void> {
  await client.query(
    `INSERT INTO order_status_history (order_id, from_status, to_status, changed_by, comment)
     VALUES ($1, $2, $3, $4, $5)`,
    [id, from, to, actor.id, comment],
  );
}

/**
 * The organisation an order is for: a subsidiary's staff always order for their own
 * organisation (another one answers 404); Head Office staff must name an active subsidiary.
 */
async function orderingOrganisation(
  client: pg.PoolClient,
  scope: AccessScope,
  requested: string | undefined,
): Promise<string> {
  let organisationId: string;
  if (scope.allOrganisations) {
    if (!requested) throw fieldError('organisationId', 'Choose the subsidiary that orders');
    organisationId = requested;
  } else {
    if (requested && requested !== scope.organisationId) {
      throw new AppError(404, 'ORGANISATION_NOT_FOUND', 'No organisation has that id.');
    }
    organisationId = scope.organisationId;
  }
  const { rows } = await client.query<{ organisation_type: string; is_active: boolean }>(
    'SELECT organisation_type, is_active FROM organisations WHERE id = $1',
    [organisationId],
  );
  const organisation = rows[0];
  if (!organisation || organisation.organisation_type !== 'SUBSIDIARY') {
    throw fieldError('organisationId', 'Only a subsidiary can place an order');
  }
  if (!organisation.is_active) {
    throw fieldError('organisationId', 'This organisation is deactivated');
  }
  return organisationId;
}

async function writeLines(
  client: pg.PoolClient,
  orderId: string,
  lines: OrderLineInput[],
): Promise<void> {
  const seen = new Set<string>();
  for (const [index, line] of lines.entries()) {
    const key = `${line.productId}/${line.unitId}`;
    if (seen.has(key)) {
      throw fieldError(`lines.${index}.productId`, 'This product and unit are already ordered');
    }
    seen.add(key);
    const { rows } = await client.query<{ is_active: boolean }>(
      'SELECT is_active FROM products WHERE id = $1',
      [line.productId],
    );
    if (!rows[0]) throw fieldError(`lines.${index}.productId`, 'No product has that id');
    if (!rows[0].is_active)
      throw fieldError(`lines.${index}.productId`, 'This product is inactive');
    const base = await toBaseQuantity(
      client,
      line.productId,
      line.unitId,
      line.requestedQuantity,
      `lines.${index}.unitId`,
    );
    // Totals are generated columns: the database multiplies the exact decimals itself.
    await client.query(
      `INSERT INTO order_items (order_id, line_number, product_id, unit_id, requested_quantity,
                                base_quantity, expected_unit_price, maximum_unit_price, notes)
       VALUES ($1, $2, $3, $4, $5, $6, $7::numeric, $8::numeric, $9)`,
      [
        orderId,
        index + 1,
        line.productId,
        line.unitId,
        line.requestedQuantity,
        base,
        line.expectedUnitPrice,
        line.maximumUnitPrice,
        line.notes,
      ],
    );
  }
}

/**
 * Starts an order (a draft). The same idempotency key from the same person returns the order
 * it created the first time (`replayed: true`) instead of creating another.
 */
export async function createOrder(
  pool: pg.Pool,
  scope: AccessScope,
  input: OrderInput & { idempotencyKey: string },
  actor: PublicUser,
  settings: { currency: string; today: string },
): Promise<{ order: Order; replayed: boolean }> {
  const existing = async () => {
    const { rows } = await pool.query<{ id: string }>(
      'SELECT id FROM orders WHERE requested_by = $1 AND idempotency_key = $2',
      [actor.id, input.idempotencyKey],
    );
    return rows[0]?.id;
  };
  const before = await existing();
  if (before) return { order: await getOrder(pool, scope, before), replayed: true };

  let id: string;
  try {
    id = await withTransaction(pool, async (client) => {
      const organisationId = await orderingOrganisation(client, scope, input.organisationId);
      if (input.requiredDate !== null && input.requiredDate < settings.today) {
        throw fieldError('requiredDate', 'Cannot be in the past');
      }
      const { rows } = await client.query<{ id: string; order_number: string }>(
        `INSERT INTO orders (organisation_id, order_date, required_date, requested_by, currency,
                             notes, idempotency_key)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING id, order_number`,
        [
          organisationId,
          settings.today,
          input.requiredDate,
          actor.id,
          settings.currency,
          input.notes,
          input.idempotencyKey,
        ],
      );
      const created = rows[0] as { id: string; order_number: string };
      await writeLines(client, created.id, input.lines);
      await recordStatus(client, created.id, null, 'DRAFT', actor, null);
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'order.created',
        entityType: 'order',
        entityId: created.id,
        organisationId,
        details: { orderNumber: created.order_number, lines: input.lines.length },
      });
      return created.id;
    });
  } catch (error) {
    // Two copies of the same request at the same moment: the second finds the first's order.
    if (isUniqueViolation(error, 'orders_idempotency_key')) {
      const winner = await existing();
      if (winner) return { order: await getOrder(pool, scope, winner), replayed: true };
    }
    throw error;
  }
  return { order: await getOrder(pool, scope, id), replayed: false };
}

/** Replaces a draft's details and lines. */
export async function updateDraft(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  input: OrderInput,
  actor: PublicUser,
  today: string,
): Promise<Order> {
  await withTransaction(pool, async (client) => {
    const current = await lockOrder(client, scope, id);
    if (current.status !== 'DRAFT') throw wrongStatus(current.status, 'changed');
    if (input.organisationId && input.organisationId !== current.organisation_id) {
      throw fieldError('organisationId', 'The ordering organisation cannot change');
    }
    if (input.requiredDate !== null && input.requiredDate < today) {
      throw fieldError('requiredDate', 'Cannot be in the past');
    }
    await client.query('UPDATE orders SET required_date = $2, notes = $3 WHERE id = $1', [
      id,
      input.requiredDate,
      input.notes,
    ]);
    await client.query('DELETE FROM order_items WHERE order_id = $1', [id]);
    await writeLines(client, id, input.lines);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'order.updated',
      entityType: 'order',
      entityId: id,
      organisationId: current.organisation_id,
      details: { orderNumber: current.order_number, lines: input.lines.length },
    });
  });
  return getOrder(pool, scope, id);
}

/**
 * Sends a draft to the Head Office. Submitting an order that is already submitted (a retry)
 * changes nothing and says so (`alreadySubmitted`).
 */
export async function submitOrder(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  actor: PublicUser,
): Promise<{ order: Order; alreadySubmitted: boolean }> {
  const alreadySubmitted = await withTransaction(pool, async (client) => {
    const current = await lockOrder(client, scope, id);
    if (current.status === 'SUBMITTED') return true;
    if (current.status !== 'DRAFT') throw wrongStatus(current.status, 'submitted');
    const { rows } = await client.query<{ lines: number }>(
      'SELECT count(*)::int AS lines FROM order_items WHERE order_id = $1',
      [id],
    );
    if (!rows[0]?.lines) throw fieldError('lines', 'Add at least one product');
    await client.query(
      `UPDATE orders SET status = 'SUBMITTED', submitted_by = $2, submitted_at = now()
       WHERE id = $1`,
      [id, actor.id],
    );
    await recordStatus(client, id, 'DRAFT', 'SUBMITTED', actor, null);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'order.submitted',
      entityType: 'order',
      entityId: id,
      organisationId: current.organisation_id,
      details: { orderNumber: current.order_number },
    });
    return false;
  });
  return { order: await getOrder(pool, scope, id), alreadySubmitted };
}

/** The ordering organisation withdraws a draft or a submitted order (not once under review). */
export async function cancelOrder(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  reason: string,
  actor: PublicUser,
): Promise<Order> {
  await withTransaction(pool, async (client) => {
    const current = await lockOrder(client, scope, id);
    if (current.status !== 'DRAFT' && current.status !== 'SUBMITTED') {
      throw wrongStatus(current.status, 'cancelled');
    }
    await client.query(
      `UPDATE orders SET status = 'CANCELLED', cancelled_by = $2, cancelled_at = now(),
              cancel_reason = $3
       WHERE id = $1`,
      [id, actor.id, reason],
    );
    await recordStatus(client, id, current.status, 'CANCELLED', actor, reason);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'order.cancelled',
      entityType: 'order',
      entityId: id,
      organisationId: current.organisation_id,
      details: { orderNumber: current.order_number, reason },
    });
  });
  return getOrder(pool, scope, id);
}

/** Moves a submitted order into review (in the caller's transaction). */
async function startReviewIn(
  client: pg.PoolClient,
  id: string,
  current: { status: OrderStatus; organisation_id: string; order_number: string },
  actor: PublicUser,
): Promise<void> {
  await client.query(`UPDATE orders SET status = 'UNDER_REVIEW' WHERE id = $1`, [id]);
  await recordStatus(client, id, 'SUBMITTED', 'UNDER_REVIEW', actor, null);
  await recordAudit(client, {
    actorUserId: actor.id,
    action: 'order.review_started',
    entityType: 'order',
    entityId: id,
    organisationId: current.organisation_id,
    details: { orderNumber: current.order_number },
  });
}

/** The Head Office takes a submitted order into review (the subsidiary can no longer cancel). */
export async function startReview(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  actor: PublicUser,
): Promise<Order> {
  headOfficeOnly(scope);
  await withTransaction(pool, async (client) => {
    const current = await lockOrder(client, scope, id);
    if (current.status !== 'SUBMITTED') throw wrongStatus(current.status, 'taken into review');
    await startReviewIn(client, id, current, actor);
  });
  return getOrder(pool, scope, id);
}

/**
 * The Head Office sets actual prices. The subsidiary's values stay as submitted; every change
 * of an actual price is logged with the old and new value. A submitted order goes into review.
 */
export async function setActualPrices(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  prices: { itemId: string; actualUnitPrice: string; comment: string | null }[],
  actor: PublicUser,
): Promise<Order> {
  headOfficeOnly(scope);
  await withTransaction(pool, async (client) => {
    const current = await lockOrder(client, scope, id);
    if (current.status !== 'SUBMITTED' && current.status !== 'UNDER_REVIEW') {
      throw wrongStatus(current.status, 'priced');
    }
    if (current.status === 'SUBMITTED') await startReviewIn(client, id, current, actor);
    const changed: { line: number; from: string | null; to: string }[] = [];
    for (const [index, price] of prices.entries()) {
      const { rows } = await client.query<{ line_number: number; old: string | null; new: string }>(
        `SELECT line_number, actual_unit_price::text AS old, $3::numeric(12, 2)::text AS new
         FROM order_items WHERE id = $1 AND order_id = $2 FOR UPDATE`,
        [price.itemId, id, price.actualUnitPrice],
      );
      const item = rows[0];
      if (!item) throw fieldError(`prices.${index}.itemId`, 'No line of this order has that id');
      if (item.old === item.new) continue;
      await client.query('UPDATE order_items SET actual_unit_price = $2::numeric WHERE id = $1', [
        price.itemId,
        price.actualUnitPrice,
      ]);
      await client.query(
        `INSERT INTO order_item_changes (order_id, order_item_id, field, old_value, new_value,
                                         changed_by, comment)
         VALUES ($1, $2, 'actual_unit_price', $3, $4, $5, $6)`,
        [id, price.itemId, item.old, item.new, actor.id, price.comment],
      );
      changed.push({ line: item.line_number, from: item.old, to: item.new });
    }
    if (changed.length > 0) {
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'order.prices_set',
        entityType: 'order',
        entityId: id,
        organisationId: current.organisation_id,
        details: { orderNumber: current.order_number, changes: changed },
      });
    }
  });
  return getOrder(pool, scope, id);
}

/**
 * Approves an order under review. Every line needs an actual price. A price above the maximum
 * (a price exception) needs price.exception.approve and a comment. Without backorders, the
 * Head Office must have enough stock for every line.
 */
export async function approveOrder(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  comment: string | null,
  actor: PublicUser,
  settings: { allowBackorders: boolean },
): Promise<Order> {
  headOfficeOnly(scope);
  await withTransaction(pool, async (client) => {
    const current = await lockOrder(client, scope, id);
    if (current.status !== 'UNDER_REVIEW') {
      throw current.status === 'SUBMITTED'
        ? new AppError(409, 'PRICES_MISSING', 'Set the actual prices before approving.')
        : wrongStatus(current.status, 'approved');
    }
    const { rows } = await client.query<{ unpriced: number; exceptions: number }>(
      `SELECT count(*) FILTER (WHERE actual_unit_price IS NULL)::int AS unpriced,
              count(*) FILTER (WHERE price_exception)::int AS exceptions
       FROM order_items WHERE order_id = $1`,
      [id],
    );
    const facts = rows[0] as { unpriced: number; exceptions: number };
    if (facts.unpriced > 0) {
      throw new AppError(409, 'PRICES_MISSING', 'Set the actual price of every line first.');
    }
    if (facts.exceptions > 0) {
      if (!can(actor, 'price.exception.approve')) {
        throw new AppError(
          403,
          'PRICE_EXCEPTION_NOT_ALLOWED',
          'An actual price is above the maximum the subsidiary accepts. Only someone allowed to ' +
            'approve price exceptions can approve this order.',
        );
      }
      if (!comment) {
        throw fieldError('comment', 'Explain why the price above the maximum is approved');
      }
    }
    if (!settings.allowBackorders) {
      const { rows: short } = await client.query<{
        sku: string;
        needed: number;
        available: number;
      }>(
        `SELECT p.sku, sum(i.base_quantity)::int AS needed,
                COALESCE(max(h.quantity_on_hand - h.quantity_reserved), 0)::int AS available
         FROM order_items i
         JOIN products p ON p.id = i.product_id
         LEFT JOIN hq_stock_on_hand h ON h.product_id = i.product_id
         WHERE i.order_id = $1
         GROUP BY p.sku
         HAVING sum(i.base_quantity) > COALESCE(max(h.quantity_on_hand - h.quantity_reserved), 0)`,
        [id],
      );
      if (short.length > 0) {
        throw new AppError(
          409,
          'INSUFFICIENT_STOCK',
          `Not enough stock to approve: ${short
            .map((s) => `${s.sku} (${s.available} of ${s.needed})`)
            .join(', ')}.`,
        );
      }
    }
    await client.query(
      `UPDATE orders SET status = 'APPROVED', decided_by = $2, decided_at = now(),
              decision_comment = $3, price_exception_approved = $4
       WHERE id = $1`,
      [id, actor.id, comment, facts.exceptions > 0],
    );
    await recordStatus(client, id, 'UNDER_REVIEW', 'APPROVED', actor, comment);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'order.approved',
      entityType: 'order',
      entityId: id,
      organisationId: current.organisation_id,
      details: {
        orderNumber: current.order_number,
        comment,
        priceExceptionApproved: facts.exceptions > 0,
      },
    });
  });
  return getOrder(pool, scope, id);
}

/** Refuses a submitted order or one under review; the comment is required. */
export async function rejectOrder(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  comment: string,
  actor: PublicUser,
): Promise<Order> {
  headOfficeOnly(scope);
  await withTransaction(pool, async (client) => {
    const current = await lockOrder(client, scope, id);
    if (current.status !== 'SUBMITTED' && current.status !== 'UNDER_REVIEW') {
      throw wrongStatus(current.status, 'rejected');
    }
    await client.query(
      `UPDATE orders SET status = 'REJECTED', decided_by = $2, decided_at = now(),
              decision_comment = $3
       WHERE id = $1`,
      [id, actor.id, comment],
    );
    await recordStatus(client, id, current.status, 'REJECTED', actor, comment);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'order.rejected',
      entityType: 'order',
      entityId: id,
      organisationId: current.organisation_id,
      details: { orderNumber: current.order_number, comment },
    });
  });
  return getOrder(pool, scope, id);
}
