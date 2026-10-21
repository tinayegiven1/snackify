import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { recordAudit } from '../audit/audit.js';
import type { PublicUser } from '../auth/roles.js';
import {
  allocateFirstExpiring,
  headOfficeDefaults,
  insertMovement,
  ownedQuantity,
  type Allocation,
} from './ledger.js';

/** The product a stock record belongs to. */
export interface ProductSummary {
  id: string;
  sku: string;
  name: string;
  flavour: string;
  size: string;
}

interface ProductColumns {
  product_id: string;
  sku: string;
  name: string;
  flavour: string;
  size: string;
}

const productSummary = (row: ProductColumns): ProductSummary => ({
  id: row.product_id,
  sku: row.sku,
  name: row.name,
  flavour: row.flavour,
  size: row.size,
});

const productNotFound = () => new AppError(404, 'PRODUCT_NOT_FOUND', 'No product has that id.');

/**
 * Locks the product row until the transaction ends and returns whether it is active.
 * Every operation that changes stock does this first, so two people changing the same
 * product's stock at once are handled one after the other and the balance check stays true.
 */
async function lockProduct(
  client: pg.PoolClient,
  productId: string,
): Promise<{ isActive: boolean }> {
  const { rows } = await client.query<{ is_active: boolean }>(
    'SELECT is_active FROM products WHERE id = $1 FOR UPDATE',
    [productId],
  );
  if (!rows[0]) throw productNotFound();
  return { isActive: rows[0].is_active };
}

/** The Head Office's own stock of a product (all its warehouses). */
async function quantityOnHand(db: Queryable, productId: string): Promise<number> {
  const { rows } = await db.query<{ quantity_on_hand: number }>(
    'SELECT quantity_on_hand FROM hq_stock_on_hand WHERE product_id = $1',
    [productId],
  );
  return rows[0]?.quantity_on_hand ?? 0;
}

// ---------------------------------------------------------------- Receipts

export interface StockReceipt {
  id: string;
  product: ProductSummary;
  quantity: number;
  receivedDate: string;
  batchNumber: string | null;
  expiryDate: string | null;
  supplierReference: string | null;
  isOpeningBalance: boolean;
  receivedBy: { id: string; fullName: string };
  createdAt: Date;
}

interface ReceiptRow extends ProductColumns {
  id: string;
  quantity_received: number;
  received_date: string;
  batch_number: string | null;
  expiry_date: string | null;
  supplier_reference: string | null;
  is_opening_balance: boolean;
  received_by: string;
  received_by_name: string;
  created_at: Date;
}

const RECEIPT_SELECT = `
  SELECT b.id, b.product_id, p.sku, p.name, p.flavour, p.size, b.quantity_received,
         b.received_date, b.batch_number, b.expiry_date, b.supplier_reference,
         b.is_opening_balance, b.received_by, u.full_name AS received_by_name, b.created_at
  FROM stock_batches b
  JOIN products p ON p.id = b.product_id
  JOIN users u ON u.id = b.received_by`;

const toReceipt = (row: ReceiptRow): StockReceipt => ({
  id: row.id,
  product: productSummary(row),
  quantity: row.quantity_received,
  receivedDate: row.received_date,
  batchNumber: row.batch_number,
  expiryDate: row.expiry_date,
  supplierReference: row.supplier_reference,
  isOpeningBalance: row.is_opening_balance,
  receivedBy: { id: row.received_by, fullName: row.received_by_name },
  createdAt: row.created_at,
});

export interface ReceiptInput {
  productId: string;
  quantity: number;
  receivedDate: string;
  batchNumber: string | null;
  expiryDate: string | null;
  supplierReference: string | null;
  isOpeningBalance: boolean;
}

/**
 * Records stock received: a batch row plus a matching positive ledger entry, saved together.
 * An opening balance is only allowed while the product has no stock history at all.
 */
export async function receiveStock(
  pool: pg.Pool,
  input: ReceiptInput,
  actor: PublicUser,
): Promise<{ receipt: StockReceipt; quantityOnHand: number }> {
  return withTransaction(pool, async (client) => {
    const product = await lockProduct(client, input.productId);
    if (!product.isActive) {
      throw new AppError(
        409,
        'PRODUCT_INACTIVE',
        'This product is inactive. An admin must reactivate it before stock can be received.',
      );
    }

    if (input.isOpeningBalance) {
      const { rowCount } = await client.query(
        'SELECT 1 FROM stock_movements WHERE product_id = $1 LIMIT 1',
        [input.productId],
      );
      if (rowCount) {
        throw new AppError(
          409,
          'OPENING_BALANCE_NOT_ALLOWED',
          'This product already has stock records. Use a stock adjustment to correct its balance.',
        );
      }
    }

    const { rows } = await client.query<{ id: string }>(
      `INSERT INTO stock_batches (product_id, quantity_received, received_date, batch_number,
                                  expiry_date, supplier_reference, is_opening_balance, received_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING id`,
      [
        input.productId,
        input.quantity,
        input.receivedDate,
        input.batchNumber,
        input.expiryDate,
        input.supplierReference,
        input.isOpeningBalance,
        actor.id,
      ],
    );
    const batchId = (rows[0] as { id: string }).id;

    await client.query(
      `INSERT INTO stock_movements (product_id, batch_id, movement_type, quantity_delta,
                                    business_date, created_by, reference)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [
        input.productId,
        batchId,
        input.isOpeningBalance ? 'opening_balance' : 'receipt',
        input.quantity,
        input.receivedDate,
        actor.id,
        input.supplierReference,
      ],
    );

    if (input.isOpeningBalance) {
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'stock.opening_balance',
        entityType: 'product',
        entityId: input.productId,
        details: { quantity: input.quantity, date: input.receivedDate },
      });
    }

    const { rows: receiptRows } = await client.query<ReceiptRow>(
      `${RECEIPT_SELECT} WHERE b.id = $1`,
      [batchId],
    );
    return {
      receipt: toReceipt(receiptRows[0] as ReceiptRow),
      quantityOnHand: await quantityOnHand(client, input.productId),
    };
  });
}

/** Receipts of stock owned by `ownerOrganisationId` (callers check the user may see it). */
export async function listReceipts(
  db: Queryable,
  filter: { ownerOrganisationId: string; from: string; to: string; productId?: string | undefined },
): Promise<{ receipts: StockReceipt[]; totalQuantity: number }> {
  const params: unknown[] = [filter.ownerOrganisationId, filter.from, filter.to];
  let productCondition = '';
  if (filter.productId) {
    params.push(filter.productId);
    productCondition = 'AND b.product_id = $4';
  }
  const { rows } = await db.query<ReceiptRow>(
    `${RECEIPT_SELECT}
     WHERE b.owner_organisation_id = $1 AND b.received_date BETWEEN $2 AND $3 ${productCondition}
     ORDER BY b.received_date DESC, b.created_at DESC`,
    params,
  );
  const receipts = rows.map(toReceipt);
  return { receipts, totalQuantity: receipts.reduce((sum, r) => sum + r.quantity, 0) };
}

// ---------------------------------------------------------------- Adjustments

export interface AdjustmentInput {
  productId: string;
  /** "damage" removes stock; "adjustment" corrects a count either way. */
  type: 'damage' | 'adjustment';
  quantityDelta: number;
  reason: string;
  businessDate: string;
  /** Whose stock (default: the Head Office). Callers check the user may act for it. */
  ownerOrganisationId?: string | undefined;
  /** Where (default: any warehouse when removing, the default warehouse when adding). */
  warehouseId?: string | undefined;
  /** Which delivery (default: the batches that expire first when removing; none when adding). */
  batchId?: string | undefined;
}

/**
 * Changes stock by hand, with a reason. Refused if it would leave less than zero in stock.
 * Stock removed without naming a batch comes from the batches that expire first. The movements
 * and their audit entry are saved together.
 */
export async function adjustStock(
  pool: pg.Pool,
  input: AdjustmentInput,
  actor: PublicUser,
): Promise<{ movement: StockMovement; movements: StockMovement[]; quantityOnHand: number }> {
  return withTransaction(pool, async (client) => {
    await lockProduct(client, input.productId);
    const defaults = await headOfficeDefaults(client);
    const owner = input.ownerOrganisationId ?? defaults.organisationId;

    if (input.batchId) {
      const { rowCount } = await client.query(
        'SELECT 1 FROM stock_batches WHERE id = $1 AND product_id = $2 AND owner_organisation_id = $3',
        [input.batchId, input.productId, owner],
      );
      if (!rowCount) {
        throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
          { field: 'batchId', message: "Not a delivery of this product's stock" },
        ]);
      }
    }

    const before = (await ownedQuantity(client, input.productId, owner)).onHand;
    let parts: Allocation[];
    if (input.quantityDelta < 0) {
      const { allocations, available } = await allocateFirstExpiring(client, {
        productId: input.productId,
        ownerOrganisationId: owner,
        warehouseId: input.warehouseId ?? null,
        batchId: input.batchId ?? null,
        quantity: -input.quantityDelta,
      });
      if (allocations.length === 0) {
        throw new AppError(
          409,
          'INSUFFICIENT_STOCK',
          `Only ${available} in stock, so ${-input.quantityDelta} cannot be removed.`,
        );
      }
      parts = allocations.map((part) => ({ ...part, quantity: -part.quantity }));
    } else {
      parts = [
        {
          batchId: input.batchId ?? null,
          warehouseId: input.warehouseId ?? defaults.warehouseId,
          quantity: input.quantityDelta,
        },
      ];
    }

    const movementIds: string[] = [];
    for (const part of parts) {
      const { id } = await insertMovement(client, {
        productId: input.productId,
        ownerOrganisationId: owner,
        warehouseId: part.warehouseId,
        batchId: part.batchId,
        type: input.type,
        quantityDelta: part.quantity,
        businessDate: input.businessDate,
        createdBy: actor.id,
        reason: input.reason,
      });
      movementIds.push(id);
    }
    const after = before + input.quantityDelta;

    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'stock.adjusted',
      entityType: 'product',
      entityId: input.productId,
      organisationId: owner,
      details: {
        type: input.type,
        quantityDelta: input.quantityDelta,
        reason: input.reason,
        balanceBefore: before,
        balanceAfter: after,
        parts: parts.map((part) => ({
          batchId: part.batchId,
          warehouseId: part.warehouseId,
          quantity: part.quantity,
        })),
      },
    });

    const movements: StockMovement[] = [];
    for (const movementId of movementIds) {
      const found = await listMovements(client, {
        ownerOrganisationId: owner,
        productId: input.productId,
        movementId,
        limit: 1,
        offset: 0,
      });
      movements.push(found.movements[0] as StockMovement);
    }
    return { movement: movements[0] as StockMovement, movements, quantityOnHand: after };
  });
}

// ---------------------------------------------------------------- Balances

export interface StockBalance {
  product: ProductSummary & { isActive: boolean };
  quantityOnHand: number;
  /** Set aside for approved orders; available = on hand - reserved. */
  quantityReserved: number;
  quantityAvailable: number;
  reorderLevel: number | null;
  /** True when a reorder level is set and stock is at or below it. */
  isLowStock: boolean;
}

/** The Head Office's organisation id. */
export async function headOfficeId(db: Queryable): Promise<string> {
  const { rows } = await db.query<{ id: string }>('SELECT hq_organisation_id() AS id');
  return (rows[0] as { id: string }).id;
}

/**
 * Every product with the stock that `ownerOrganisationId` owns of it (callers check the user
 * may see that organisation). Physical location is not ownership: only the owner's ledger
 * entries count.
 */
export async function listBalances(
  db: Queryable,
  filter: {
    ownerOrganisationId: string;
    q?: string | undefined;
    lowStockOnly: boolean;
    includeInactive: boolean;
  },
): Promise<StockBalance[]> {
  const conditions: string[] = [];
  const params: unknown[] = [filter.ownerOrganisationId];
  if (!filter.includeInactive) conditions.push('p.is_active');
  if (filter.lowStockOnly) {
    conditions.push('p.reorder_level IS NOT NULL AND b.quantity_on_hand <= p.reorder_level');
  }
  if (filter.q) {
    params.push(`%${escapeLike(filter.q)}%`, filter.q);
    conditions.push(
      '(p.sku ILIKE $2 OR p.name ILIKE $2 OR p.flavour ILIKE $2 OR p.size ILIKE $2 OR p.barcode = $3)',
    );
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows } = await db.query<
    ProductColumns & {
      is_active: boolean;
      reorder_level: number | null;
      quantity_on_hand: number;
      quantity_reserved: number;
    }
  >(
    `SELECT p.id AS product_id, p.sku, p.name, p.flavour, p.size, p.is_active, p.reorder_level,
            b.quantity_on_hand, b.quantity_reserved
     FROM products p
     CROSS JOIN LATERAL (
       SELECT COALESCE(sum(sb.quantity_on_hand), 0)::integer AS quantity_on_hand,
              COALESCE(sum(sb.quantity_reserved), 0)::integer AS quantity_reserved
       FROM stock_balances sb
       WHERE sb.product_id = p.id AND sb.owner_organisation_id = $1
     ) b
     ${where}
     ORDER BY p.name, p.flavour, p.size, p.sku`,
    params,
  );
  return rows.map((row) => ({
    product: { ...productSummary(row), isActive: row.is_active },
    quantityOnHand: row.quantity_on_hand,
    quantityReserved: row.quantity_reserved,
    quantityAvailable: row.quantity_on_hand - row.quantity_reserved,
    reorderLevel: row.reorder_level,
    isLowStock: row.reorder_level !== null && row.quantity_on_hand <= row.reorder_level,
  }));
}

// ---------------------------------------------------------------- Movements (the ledger)

export interface StockMovement {
  id: string;
  /** The movement's own unique reference, e.g. M0000042. */
  movementNumber: string;
  product: ProductSummary;
  warehouse: { id: string; code: string };
  /** As entered, when not counted in the base unit (e.g. 2 cartons). */
  entered: { unit: string; quantity: number } | null;
  /** The document behind it, e.g. a goods-received note. */
  relatedDocument: { type: string; id: string } | null;
  type: string;
  quantityDelta: number;
  businessDate: string;
  occurredAt: Date;
  reference: string | null;
  reason: string | null;
  batchNumber: string | null;
  createdBy: { id: string; fullName: string };
  /** The product's stock on hand straight after this movement was recorded. */
  balanceAfter: number;
}

interface MovementRow extends ProductColumns {
  id: string;
  movement_number: string;
  warehouse_id: string;
  warehouse_code: string;
  unit_code: string | null;
  entered_quantity: number | null;
  related_document_type: string | null;
  related_document_id: string | null;
  movement_type: string;
  quantity_delta: number;
  business_date: string;
  occurred_at: Date;
  reference: string | null;
  reason: string | null;
  batch_number: string | null;
  created_by: string;
  created_by_name: string;
  balance_after: number;
  total: number;
}

/** The ledger of stock owned by `ownerOrganisationId` (callers check the user may see it). */
export async function listMovements(
  db: Queryable,
  filter: {
    ownerOrganisationId: string;
    productId?: string | undefined;
    movementId?: string;
    from?: string | undefined;
    to?: string | undefined;
    limit: number;
    offset: number;
  },
): Promise<{ movements: StockMovement[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  const add = (condition: string, value: unknown) => {
    params.push(value);
    conditions.push(condition.replace('?', `$${params.length}`));
  };
  add('l.owner_organisation_id = ?', filter.ownerOrganisationId);
  if (filter.productId) add('l.product_id = ?', filter.productId);
  if (filter.movementId) add('l.id = ?', filter.movementId);
  if (filter.from) add('l.business_date >= ?', filter.from);
  if (filter.to) add('l.business_date <= ?', filter.to);
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

  // The running balance is worked out over each owner's whole ledger of each product, in the
  // order the movements were recorded, before any filtering.
  const { rows } = await db.query<MovementRow>(
    `WITH ledger AS (
       SELECT m.*,
              sum(m.quantity_delta) OVER (
                PARTITION BY m.owner_organisation_id, m.product_id ORDER BY m.occurred_at, m.id
              )::integer AS balance_after
       FROM stock_movements m
     )
     SELECT l.id, l.movement_number, l.warehouse_id, w.code AS warehouse_code,
            un.code AS unit_code, l.entered_quantity, l.related_document_type,
            l.related_document_id, l.product_id, p.sku, p.name, p.flavour, p.size, l.movement_type,
            l.quantity_delta, l.business_date, l.occurred_at, l.reference, l.reason,
            b.batch_number, l.created_by, u.full_name AS created_by_name, l.balance_after,
            count(*) OVER ()::integer AS total
     FROM ledger l
     JOIN products p ON p.id = l.product_id
     JOIN users u ON u.id = l.created_by
     JOIN warehouses w ON w.id = l.warehouse_id
     LEFT JOIN units un ON un.id = l.unit_id
     LEFT JOIN stock_batches b ON b.id = l.batch_id
     ${where}
     ORDER BY l.occurred_at DESC, l.id DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, filter.limit, filter.offset],
  );

  return {
    movements: rows.map((row) => ({
      id: row.id,
      movementNumber: row.movement_number,
      product: productSummary(row),
      warehouse: { id: row.warehouse_id, code: row.warehouse_code },
      entered:
        row.unit_code === null || row.entered_quantity === null
          ? null
          : { unit: row.unit_code, quantity: row.entered_quantity },
      relatedDocument:
        row.related_document_type === null || row.related_document_id === null
          ? null
          : { type: row.related_document_type, id: row.related_document_id },
      type: row.movement_type,
      quantityDelta: row.quantity_delta,
      businessDate: row.business_date,
      occurredAt: row.occurred_at,
      reference: row.reference,
      reason: row.reason,
      batchNumber: row.batch_number,
      createdBy: { id: row.created_by, fullName: row.created_by_name },
      balanceAfter: row.balance_after,
    })),
    total: rows[0]?.total ?? 0,
  };
}
