import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { changedFields, recordAudit } from '../audit/audit.js';

/** A sellable variation, e.g. "Potato Crisps — BBQ — Small" (spec 6.2). */
export interface Product {
  id: string;
  sku: string;
  name: string;
  flavour: string;
  size: string;
  barcode: string | null;
  /** Exact decimal string such as "0.50", in the business's base currency. */
  defaultPrice: string;
  /** Stock level at or below which the product counts as low on stock; null for no alert. */
  reorderLevel: number | null;
  isActive: boolean;
  createdAt: Date;
  updatedAt: Date;
}

interface ProductRow {
  id: string;
  sku: string;
  name: string;
  flavour: string;
  size: string;
  barcode: string | null;
  default_price: string;
  reorder_level: number | null;
  is_active: boolean;
  created_at: Date;
  updated_at: Date;
}

const PRODUCT_COLUMNS =
  'id, sku, name, flavour, size, barcode, default_price, reorder_level, is_active, created_at, updated_at';

function toProduct(row: ProductRow): Product {
  return {
    id: row.id,
    sku: row.sku,
    name: row.name,
    flavour: row.flavour,
    size: row.size,
    barcode: row.barcode,
    defaultPrice: row.default_price,
    reorderLevel: row.reorder_level,
    isActive: row.is_active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

const productNotFound = () => new AppError(404, 'PRODUCT_NOT_FOUND', 'No product has that id.');

/** Turns a duplicate SKU, barcode or variation into a clear 409, or returns null. */
function conflictError(error: unknown, input: { sku?: string; barcode?: string | null }) {
  if (isUniqueViolation(error, 'products_sku_key')) {
    return new AppError(409, 'SKU_TAKEN', `Another product already uses the SKU "${input.sku}".`, [
      { field: 'sku', message: 'Already used by another product' },
    ]);
  }
  if (isUniqueViolation(error, 'products_barcode_key')) {
    return new AppError(
      409,
      'BARCODE_TAKEN',
      `Another product already uses the barcode "${input.barcode}".`,
      [{ field: 'barcode', message: 'Already used by another product' }],
    );
  }
  if (isUniqueViolation(error, 'products_variation_key')) {
    return new AppError(
      409,
      'PRODUCT_EXISTS',
      'A product with this name, flavour and size already exists.',
    );
  }
  return null;
}

export interface ProductSearch {
  /** Matches part of the SKU, name, flavour or size (ignoring case), or the exact barcode. */
  q?: string | undefined;
  includeInactive: boolean;
  limit: number;
  offset: number;
}

export async function listProducts(
  db: Queryable,
  search: ProductSearch,
): Promise<{ products: Product[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];

  if (!search.includeInactive) {
    conditions.push('is_active');
  }
  if (search.q) {
    params.push(`%${escapeLike(search.q)}%`, search.q);
    conditions.push(
      `(sku ILIKE $1 OR name ILIKE $1 OR flavour ILIKE $1 OR size ILIKE $1 OR barcode = $2)`,
    );
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows: countRows } = await db.query<{ total: number }>(
    `SELECT count(*)::int AS total FROM products ${where}`,
    params,
  );
  const { rows } = await db.query<ProductRow>(
    `SELECT ${PRODUCT_COLUMNS} FROM products ${where}
     ORDER BY name, flavour, size, sku
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, search.limit, search.offset],
  );
  return { products: rows.map(toProduct), total: countRows[0]?.total ?? 0 };
}

export async function getProduct(db: Queryable, id: string): Promise<Product> {
  const { rows } = await db.query<ProductRow>(
    `SELECT ${PRODUCT_COLUMNS} FROM products WHERE id = $1`,
    [id],
  );
  if (!rows[0]) throw productNotFound();
  return toProduct(rows[0]);
}

export interface NewProductInput {
  sku: string;
  name: string;
  flavour: string;
  size: string;
  barcode: string | null;
  defaultPrice: string;
  reorderLevel: number | null;
}

export async function createProduct(
  pool: pg.Pool,
  input: NewProductInput,
  actorUserId: string,
): Promise<Product> {
  try {
    return await withTransaction(pool, async (client) => {
      const { rows } = await client.query<ProductRow>(
        `INSERT INTO products (sku, name, flavour, size, barcode, default_price, reorder_level)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         RETURNING ${PRODUCT_COLUMNS}`,
        [
          input.sku,
          input.name,
          input.flavour,
          input.size,
          input.barcode,
          input.defaultPrice,
          input.reorderLevel,
        ],
      );
      const product = toProduct(rows[0] as ProductRow);
      await recordAudit(client, {
        actorUserId,
        action: 'product.created',
        entityType: 'product',
        entityId: product.id,
        details: { ...input, defaultPrice: product.defaultPrice },
      });
      return product;
    });
  } catch (error) {
    throw conflictError(error, input) ?? error;
  }
}

export type ProductChanges = Partial<NewProductInput & { isActive: boolean }>;

/**
 * Changes any product details. Deactivating (isActive: false) hides the product from normal
 * lists and new transactions while keeping its history; products are never deleted.
 */
export async function updateProduct(
  pool: pg.Pool,
  id: string,
  changes: ProductChanges,
  actorUserId: string,
): Promise<Product> {
  try {
    return await withTransaction(pool, async (client) => {
      const { rows } = await client.query<ProductRow>(
        `SELECT ${PRODUCT_COLUMNS} FROM products WHERE id = $1 FOR UPDATE`,
        [id],
      );
      if (!rows[0]) throw productNotFound();
      const before = toProduct(rows[0]);

      const { rows: updated } = await client.query<ProductRow>(
        `UPDATE products
         SET sku = $2, name = $3, flavour = $4, size = $5, barcode = $6,
             default_price = $7, is_active = $8, reorder_level = $9
         WHERE id = $1
         RETURNING ${PRODUCT_COLUMNS}`,
        [
          id,
          changes.sku ?? before.sku,
          changes.name ?? before.name,
          changes.flavour ?? before.flavour,
          changes.size ?? before.size,
          changes.barcode === undefined ? before.barcode : changes.barcode,
          changes.defaultPrice ?? before.defaultPrice,
          changes.isActive ?? before.isActive,
          changes.reorderLevel === undefined ? before.reorderLevel : changes.reorderLevel,
        ],
      );
      const after = toProduct(updated[0] as ProductRow);

      const editable = (p: Product) => ({
        sku: p.sku,
        name: p.name,
        flavour: p.flavour,
        size: p.size,
        barcode: p.barcode,
        defaultPrice: p.defaultPrice,
        reorderLevel: p.reorderLevel,
        isActive: p.isActive,
      });
      await recordAudit(client, {
        actorUserId,
        action: 'product.updated',
        entityType: 'product',
        entityId: id,
        details: { changes: changedFields(editable(before), editable(after)) },
      });
      return after;
    });
  } catch (error) {
    throw conflictError(error, changes) ?? error;
  }
}
