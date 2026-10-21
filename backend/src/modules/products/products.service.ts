import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { internalEan13 } from '../../utils/ean13.js';
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
  /** Packs to keep on top of forecast demand when suggesting how much to receive. */
  safetyStock: number;
  isActive: boolean;
  description: string | null;
  category: { id: string; name: string } | null;
  /** The unit stock is counted in (usually pack). */
  baseUnit: UnitRef;
  /** Other units and how many base units each holds, e.g. 1 carton = 24 packs. */
  conversions: { unit: UnitRef; baseQuantity: number }[];
  createdAt: Date;
  updatedAt: Date;
}

export interface UnitRef {
  id: string;
  code: string;
  name: string;
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
  safety_stock: number;
  is_active: boolean;
  description: string | null;
  category_id: string | null;
  category_name: string | null;
  base_unit: UnitRef;
  conversions: { unit: UnitRef; baseQuantity: number }[];
  created_at: Date;
  updated_at: Date;
}

// The category, base unit and conversions come with every product (StockFlow Stage 4.1).
const PRODUCT_COLUMNS = `
  id, sku, name, flavour, size, barcode, default_price, reorder_level, safety_stock, is_active,
  description, category_id,
  (SELECT c.name FROM product_categories c WHERE c.id = products.category_id) AS category_name,
  (SELECT json_build_object('id', u.id, 'code', u.code, 'name', u.name)
   FROM units u WHERE u.id = products.base_unit_id) AS base_unit,
  COALESCE((SELECT json_agg(json_build_object(
                     'unit', json_build_object('id', u.id, 'code', u.code, 'name', u.name),
                     'baseQuantity', uc.base_quantity) ORDER BY uc.base_quantity)
            FROM unit_conversions uc JOIN units u ON u.id = uc.unit_id
            WHERE uc.product_id = products.id), '[]'::json) AS conversions,
  created_at, updated_at`;

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
    safetyStock: row.safety_stock,
    isActive: row.is_active,
    description: row.description,
    category:
      row.category_id === null ? null : { id: row.category_id, name: row.category_name ?? '' },
    baseUnit: row.base_unit,
    conversions: row.conversions,
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
  safetyStock: number;
  description?: string | null;
  categoryId?: string | null;
  /** Defaults to pack. */
  baseUnitId?: string;
}

export async function createProduct(
  pool: pg.Pool,
  input: NewProductInput,
  actorUserId: string,
): Promise<Product> {
  try {
    return await withTransaction(pool, async (client) => {
      const { rows } = await client.query<ProductRow>(
        `INSERT INTO products (sku, name, flavour, size, barcode, default_price, reorder_level,
                               safety_stock, description, category_id, base_unit_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, COALESCE($11, pack_unit_id()))
         RETURNING ${PRODUCT_COLUMNS}`,
        [
          input.sku,
          input.name,
          input.flavour,
          input.size,
          input.barcode,
          input.defaultPrice,
          input.reorderLevel,
          input.safetyStock,
          input.description ?? null,
          input.categoryId ?? null,
          input.baseUnitId ?? null,
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

      // Stock is counted in the base unit, so it cannot change once stock has been recorded.
      if (changes.baseUnitId !== undefined && changes.baseUnitId !== before.baseUnit.id) {
        const { rowCount } = await client.query(
          'SELECT 1 FROM stock_movements WHERE product_id = $1 LIMIT 1',
          [id],
        );
        if (rowCount) {
          throw new AppError(
            409,
            'BASE_UNIT_IN_USE',
            'Stock of this product has been recorded, so its base unit cannot change.',
            [{ field: 'baseUnitId', message: 'Cannot change once stock is recorded' }],
          );
        }
      }

      const { rows: updated } = await client.query<ProductRow>(
        `UPDATE products
         SET sku = $2, name = $3, flavour = $4, size = $5, barcode = $6,
             default_price = $7, is_active = $8, reorder_level = $9, safety_stock = $10,
             description = $11, category_id = $12, base_unit_id = $13
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
          changes.safetyStock ?? before.safetyStock,
          changes.description === undefined ? before.description : changes.description,
          changes.categoryId === undefined ? (before.category?.id ?? null) : changes.categoryId,
          changes.baseUnitId ?? before.baseUnit.id,
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
        safetyStock: p.safetyStock,
        isActive: p.isActive,
        description: p.description,
        categoryId: p.category?.id ?? null,
        baseUnit: p.baseUnit.code,
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

/**
 * Replaces a product's unit conversions, e.g. [{ unit: carton, 24 }]: one carton holds 24 of
 * the base unit. Only whole numbers of the base unit, never the base unit itself.
 */
export async function setConversions(
  pool: pg.Pool,
  id: string,
  conversions: { unitId: string; baseQuantity: number }[],
  actorUserId: string,
): Promise<Product> {
  return withTransaction(pool, async (client) => {
    const { rows } = await client.query<ProductRow>(
      `SELECT ${PRODUCT_COLUMNS} FROM products WHERE id = $1 FOR UPDATE`,
      [id],
    );
    if (!rows[0]) throw productNotFound();
    const before = toProduct(rows[0]);
    if (conversions.some((c) => c.unitId === before.baseUnit.id)) {
      throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
        {
          field: 'conversions',
          message: `${before.baseUnit.name} is the base unit: it needs none`,
        },
      ]);
    }
    const { rows: units } = await client.query<{ id: string }>(
      'SELECT id FROM units WHERE id = ANY($1::uuid[]) AND is_active',
      [conversions.map((c) => c.unitId)],
    );
    if (units.length !== new Set(conversions.map((c) => c.unitId)).size) {
      throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
        { field: 'conversions', message: 'Unknown or inactive unit' },
      ]);
    }
    await client.query('DELETE FROM unit_conversions WHERE product_id = $1', [id]);
    for (const conversion of conversions) {
      await client.query(
        'INSERT INTO unit_conversions (product_id, unit_id, base_quantity) VALUES ($1, $2, $3)',
        [id, conversion.unitId, conversion.baseQuantity],
      );
    }
    const after = await getProduct(client, id);
    await recordAudit(client, {
      actorUserId,
      action: 'product.updated',
      entityType: 'product',
      entityId: id,
      details: {
        conversions: {
          from: before.conversions.map((c) => `${c.unit.code}=${c.baseQuantity}`),
          to: after.conversions.map((c) => `${c.unit.code}=${c.baseQuantity}`),
        },
      },
    });
    return after;
  });
}

/**
 * Converts a quantity entered in `unitId` into the product's base unit. Throws a field error
 * for a unit the product has no conversion for: incompatible units are never mixed silently.
 */
export async function toBaseQuantity(
  db: Queryable,
  productId: string,
  unitId: string,
  quantity: number,
  field = 'unitId',
): Promise<number> {
  const { rows } = await db.query<{ base_quantity: number }>(
    `SELECT 1 AS base_quantity FROM products WHERE id = $1 AND base_unit_id = $2
     UNION ALL
     SELECT base_quantity FROM unit_conversions WHERE product_id = $1 AND unit_id = $2`,
    [productId, unitId],
  );
  const factor = rows[0]?.base_quantity;
  if (factor === undefined) {
    throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
      { field, message: 'This product has no conversion for that unit' },
    ]);
  }
  return quantity * factor;
}

// ---------------------------------------------------------------- Barcodes (spec 6.7)

/** The product with exactly this barcode, active or not. */
export async function findProductByBarcode(db: Queryable, barcode: string): Promise<Product> {
  const { rows } = await db.query<ProductRow>(
    `SELECT ${PRODUCT_COLUMNS} FROM products WHERE barcode = $1`,
    [barcode],
  );
  if (!rows[0]) {
    throw new AppError(404, 'BARCODE_NOT_FOUND', `No product has the barcode ${barcode}.`);
  }
  return toProduct(rows[0]);
}

/**
 * Gives a product without a barcode one of Snackify's own EAN-13 barcodes (20...), for packs
 * without a manufacturer barcode. A number that another product already uses is skipped.
 */
export async function assignInternalBarcode(
  pool: pg.Pool,
  id: string,
  actorUserId: string,
): Promise<Product> {
  try {
    return await withTransaction(pool, async (client) => {
      const { rows } = await client.query<ProductRow>(
        `SELECT ${PRODUCT_COLUMNS} FROM products WHERE id = $1 FOR UPDATE`,
        [id],
      );
      if (!rows[0]) throw productNotFound();
      if (rows[0].barcode) {
        throw new AppError(
          409,
          'PRODUCT_HAS_BARCODE',
          `This product already has the barcode ${rows[0].barcode}.`,
        );
      }

      let barcode: string;
      for (;;) {
        const { rows: next } = await client.query<{ n: string }>(
          "SELECT nextval('internal_barcode_seq')::text AS n",
        );
        barcode = internalEan13(Number((next[0] as { n: string }).n));
        const taken = await client.query('SELECT 1 FROM products WHERE barcode = $1', [barcode]);
        if (taken.rowCount === 0) break;
      }

      const { rows: updated } = await client.query<ProductRow>(
        `UPDATE products SET barcode = $2 WHERE id = $1 RETURNING ${PRODUCT_COLUMNS}`,
        [id, barcode],
      );
      await recordAudit(client, {
        actorUserId,
        action: 'product.barcode_assigned',
        entityType: 'product',
        entityId: id,
        details: { barcode },
      });
      return toProduct(updated[0] as ProductRow);
    });
  } catch (error) {
    throw conflictError(error, {}) ?? error;
  }
}
