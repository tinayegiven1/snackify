import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { createTestPools, PG, pgErrorOf, resetDatabase } from './db-test-helpers.js';

const pools = createTestPools();

interface ProductRow {
  id: string;
  sku: string;
  name: string;
  flavour: string;
  size: string;
  barcode: string | null;
  default_price: string;
  is_active: boolean;
  created_at: Date;
  updated_at: Date;
}

const potatoCrispsBbqSmall = {
  sku: 'PC-BBQ-S',
  name: 'Potato Crisps',
  flavour: 'BBQ',
  size: 'Small',
  barcode: '2000000000015' as string | null,
  defaultPrice: '0.50',
};

/** Inserts a product as the API role, starting from a valid product. */
function insertProduct(overrides: Partial<typeof potatoCrispsBbqSmall> = {}) {
  const p = { ...potatoCrispsBbqSmall, ...overrides };
  return pools.app.query<ProductRow>(
    `INSERT INTO products (sku, name, flavour, size, barcode, default_price)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [p.sku, p.name, p.flavour, p.size, p.barcode, p.defaultPrice],
  );
}

describe('products table', () => {
  beforeEach(() => resetDatabase(pools.owner));
  afterAll(() => pools.close());

  it('stores a product variation with safe defaults', async () => {
    const { rows } = await insertProduct();
    const product = rows[0];

    expect(product).toMatchObject({ sku: 'PC-BBQ-S', is_active: true });
    expect(product?.id).toMatch(/^[0-9a-f-]{36}$/);
    // Money comes back as an exact decimal string, never a rounded float.
    expect(product?.default_price).toBe('0.50');
  });

  it('rejects a negative price', async () => {
    const error = await pgErrorOf(insertProduct({ defaultPrice: '-0.01' }));
    expect(error).toMatchObject({
      code: PG.checkViolation,
      constraint: 'products_default_price_not_negative',
    });
  });

  it('rejects a duplicate SKU', async () => {
    await insertProduct();
    const error = await pgErrorOf(insertProduct({ size: 'Large', barcode: null }));
    expect(error).toMatchObject({ code: PG.uniqueViolation, constraint: 'products_sku_key' });
  });

  it('rejects a duplicate barcode but allows several products without one', async () => {
    await insertProduct();
    const error = await pgErrorOf(insertProduct({ sku: 'PC-BBQ-L', size: 'Large' }));
    expect(error).toMatchObject({ code: PG.uniqueViolation, constraint: 'products_barcode_key' });

    await insertProduct({ sku: 'PC-BBQ-L', size: 'Large', barcode: null });
    await insertProduct({ sku: 'PC-BBQ-XL', size: 'Extra Large', barcode: null });
  });

  it('rejects the same name, flavour and size twice, ignoring letter case', async () => {
    await insertProduct();
    const error = await pgErrorOf(
      insertProduct({
        sku: 'PC-BBQ-S2',
        name: 'potato crisps',
        flavour: 'bbq',
        size: 'SMALL',
        barcode: null,
      }),
    );
    expect(error).toMatchObject({ code: PG.uniqueViolation, constraint: 'products_variation_key' });
  });

  it('rejects badly formatted SKUs and barcodes', async () => {
    expect(await pgErrorOf(insertProduct({ sku: 'pc-bbq-s' }))).toMatchObject({
      code: PG.checkViolation,
      constraint: 'products_sku_format',
    });
    expect(await pgErrorOf(insertProduct({ barcode: '' }))).toMatchObject({
      code: PG.checkViolation,
      constraint: 'products_barcode_format',
    });
  });

  it('rejects blank or untrimmed names, flavours and sizes', async () => {
    expect(await pgErrorOf(insertProduct({ name: ' Potato Crisps' }))).toMatchObject({
      constraint: 'products_name_valid',
    });
    expect(await pgErrorOf(insertProduct({ flavour: '' }))).toMatchObject({
      constraint: 'products_flavour_valid',
    });
    expect(await pgErrorOf(insertProduct({ size: '   ' }))).toMatchObject({
      constraint: 'products_size_valid',
    });
  });

  it('updates updated_at automatically on every change', async () => {
    const { rows } = await insertProduct();
    const { rows: updated } = await pools.app.query<ProductRow>(
      `UPDATE products SET default_price = 0.55 WHERE id = $1 RETURNING *`,
      [rows[0]?.id],
    );

    expect(updated[0]?.updated_at.getTime()).toBeGreaterThan(rows[0]?.created_at.getTime() ?? 0);
  });

  it('cannot be deleted by the API, only deactivated', async () => {
    const { rows } = await insertProduct();
    const id = rows[0]?.id;

    const error = await pgErrorOf(pools.app.query('DELETE FROM products WHERE id = $1', [id]));
    expect(error.code).toBe(PG.insufficientPrivilege);

    const { rows: deactivated } = await pools.app.query<ProductRow>(
      'UPDATE products SET is_active = false WHERE id = $1 RETURNING *',
      [id],
    );
    expect(deactivated[0]?.is_active).toBe(false);
  });
});
