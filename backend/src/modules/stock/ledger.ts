import type { Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';

/**
 * One ledger entry. The database trigger stock_movements_apply changes the matching balance row
 * (product + owner + warehouse + batch) in the same transaction, and refuses one that would go
 * below zero; nothing else may change a balance.
 */
export interface MovementInput {
  productId: string;
  /** Who owns the stock (not where it is). */
  ownerOrganisationId: string;
  warehouseId: string;
  batchId: string | null;
  type: 'opening_balance' | 'receipt' | 'dispatch' | 'damage' | 'adjustment' | 'reversal';
  /** In the product's base unit. Positive adds stock, negative removes it. */
  quantityDelta: number;
  businessDate: string;
  createdBy: string;
  reference?: string | null;
  reason?: string | null;
  dispatchItemId?: string | null;
  reversesMovementId?: string | null;
  /** The unit and quantity as entered, when not the base unit (e.g. 2 cartons). */
  entered?: { unitId: string; quantity: number } | null;
  relatedDocument?: { type: string; id: string } | null;
}

/** Writes a ledger entry (its balance follows by trigger). Returns its id and reference. */
export async function insertMovement(
  db: Queryable,
  movement: MovementInput,
): Promise<{ id: string; movementNumber: string }> {
  try {
    const { rows } = await db.query<{ id: string; movement_number: string }>(
      `INSERT INTO stock_movements
         (product_id, owner_organisation_id, warehouse_id, batch_id, movement_type, quantity_delta,
          business_date, created_by, reference, reason, dispatch_item_id, reverses_movement_id,
          unit_id, entered_quantity, related_document_type, related_document_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
       RETURNING id, movement_number`,
      [
        movement.productId,
        movement.ownerOrganisationId,
        movement.warehouseId,
        movement.batchId,
        movement.type,
        movement.quantityDelta,
        movement.businessDate,
        movement.createdBy,
        movement.reference ?? null,
        movement.reason ?? null,
        movement.dispatchItemId ?? null,
        movement.reversesMovementId ?? null,
        movement.entered?.unitId ?? null,
        movement.entered?.quantity ?? null,
        movement.relatedDocument?.type ?? null,
        movement.relatedDocument?.id ?? null,
      ],
    );
    const row = rows[0] as { id: string; movement_number: string };
    return { id: row.id, movementNumber: row.movement_number };
  } catch (error) {
    if ((error as { constraint?: string }).constraint === 'stock_balances_on_hand_not_negative') {
      throw new AppError(
        409,
        'INSUFFICIENT_STOCK',
        'There is not enough of this stock (it would go below zero).',
      );
    }
    throw error;
  }
}

/** A part of the stock to take from: one balance row. */
export interface Allocation {
  batchId: string | null;
  warehouseId: string;
  quantity: number;
}

/**
 * Chooses which stock to take `quantity` from: the owner's batches that expire first (then the
 * oldest deliveries), with stock that has no batch last. Callers must lock the product row
 * first (SELECT ... FOR UPDATE), like every other stock change: that makes changes to one
 * product's stock happen one at a time, so the balances read here cannot change underneath.
 * Reserved stock (for approved orders) is never taken.
 */
export async function allocateFirstExpiring(
  db: Queryable,
  request: {
    productId: string;
    ownerOrganisationId: string;
    warehouseId?: string | null;
    /** Only this delivery's stock. */
    batchId?: string | null;
    quantity: number;
  },
): Promise<{ allocations: Allocation[]; available: number }> {
  const { rows } = await db.query<{
    batch_id: string | null;
    warehouse_id: string;
    available: number;
  }>(
    `SELECT sb.batch_id, sb.warehouse_id, sb.quantity_on_hand - sb.quantity_reserved AS available
     FROM stock_balances sb
     LEFT JOIN stock_batches b ON b.id = sb.batch_id
     WHERE sb.product_id = $1 AND sb.owner_organisation_id = $2
       AND ($3::uuid IS NULL OR sb.warehouse_id = $3)
       AND ($4::uuid IS NULL OR sb.batch_id = $4)
       AND sb.quantity_on_hand - sb.quantity_reserved > 0
     ORDER BY sb.batch_id IS NULL, b.expiry_date NULLS LAST, b.received_date, b.created_at, b.id`,
    [
      request.productId,
      request.ownerOrganisationId,
      request.warehouseId ?? null,
      request.batchId ?? null,
    ],
  );
  const available = rows.reduce((sum, row) => sum + row.available, 0);
  const allocations: Allocation[] = [];
  let remaining = request.quantity;
  for (const row of rows) {
    if (remaining <= 0) break;
    const take = Math.min(remaining, row.available);
    allocations.push({ batchId: row.batch_id, warehouseId: row.warehouse_id, quantity: take });
    remaining -= take;
  }
  return { allocations: remaining > 0 ? [] : allocations, available };
}

/** Stock on hand of a product owned by `ownerOrganisationId` (optionally in one warehouse). */
export async function ownedQuantity(
  db: Queryable,
  productId: string,
  ownerOrganisationId: string,
  warehouseId?: string | null,
): Promise<{ onHand: number; available: number }> {
  const { rows } = await db.query<{ on_hand: number; available: number }>(
    `SELECT COALESCE(sum(quantity_on_hand), 0)::integer AS on_hand,
            COALESCE(sum(quantity_on_hand - quantity_reserved), 0)::integer AS available
     FROM stock_balances
     WHERE product_id = $1 AND owner_organisation_id = $2
       AND ($3::uuid IS NULL OR warehouse_id = $3)`,
    [productId, ownerOrganisationId, warehouseId ?? null],
  );
  return { onHand: rows[0]?.on_hand ?? 0, available: rows[0]?.available ?? 0 };
}

/** The Head Office's id and its default warehouse, where today's screens keep stock. */
export async function headOfficeDefaults(
  db: Queryable,
): Promise<{ organisationId: string; warehouseId: string }> {
  const { rows } = await db.query<{ organisation_id: string; warehouse_id: string }>(
    'SELECT hq_organisation_id() AS organisation_id, default_warehouse_id() AS warehouse_id',
  );
  const row = rows[0] as { organisation_id: string; warehouse_id: string };
  return { organisationId: row.organisation_id, warehouseId: row.warehouse_id };
}
