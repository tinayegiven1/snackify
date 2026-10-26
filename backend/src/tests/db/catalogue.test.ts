import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { toBaseQuantity } from '../../modules/products/products.service.js';
import {
  createDbTestApp,
  createTestPools,
  receiveTestStock,
  createTestProduct,
  createTestUser,
  resetDatabase,
  signIn,
  type Role,
} from './db-test-helpers.js';

// StockFlow Stage 4.1: categories, units and conversions, suppliers, warehouses.
const pools = createTestPools();
const PASSWORD = '4826';
let app: Express;
const tokens = {} as Record<Role, string>;

const as = (role: Role) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${tokens[role]}`),
  post: (path: string, body: object) =>
    request(app).post(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
  patch: (path: string, body: object) =>
    request(app).patch(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
  put: (path: string, body: object) =>
    request(app).put(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
});

async function unitId(code: string): Promise<string> {
  const { rows } = await pools.owner.query<{ id: string }>('SELECT id FROM units WHERE code = $1', [
    code,
  ]);
  return rows[0]?.id as string;
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
  app = createDbTestApp(pools.app);
  for (const role of ['admin', 'storekeeper', 'salesperson'] as const) {
    await createTestUser(pools.app, { username: role, role, password: PASSWORD });
    tokens[role] = await signIn(app, role, PASSWORD);
  }
});
afterAll(() => pools.close());

describe('catalogue lists', () => {
  it('are read by everyone and changed only with the right permission', async () => {
    const category = await as('admin').post('/api/v1/categories', { name: 'Crisps' });
    expect(category.status).toBe(201);
    expect(category.body.item).toMatchObject({ name: 'Crisps', isActive: true });

    // Warehouse staff add suppliers (they receive the goods) but not categories.
    expect((await as('storekeeper').post('/api/v1/categories', { name: 'Puffs' })).status).toBe(
      403,
    );
    const supplier = await as('storekeeper').post('/api/v1/suppliers', {
      code: 'sup-01',
      name: 'Harare Potato Co-op',
      phone: '+263 00 300 0000',
      email: 'orders@potato.example',
    });
    expect(supplier.status).toBe(201);
    expect(supplier.body.item).toMatchObject({ code: 'SUP-01', contactName: null });
    expect(
      (await as('salesperson').post('/api/v1/suppliers', { code: 'X1', name: 'X' })).status,
    ).toBe(403);

    const list = await as('salesperson').get('/api/v1/suppliers');
    expect(list.body.items.map((s: { name: string }) => s.name)).toEqual(['Harare Potato Co-op']);
    const units = await as('salesperson').get('/api/v1/units');
    expect(units.body.items.map((u: { code: string }) => u.code)).toEqual([
      'carton',
      'case',
      'pack',
    ]);
  });

  it('refuse duplicates and explain invalid fields', async () => {
    await as('admin').post('/api/v1/categories', { name: 'Crisps' });
    const duplicate = await as('admin').post('/api/v1/categories', { name: 'crisps' });
    expect(duplicate.status).toBe(409);
    expect(duplicate.body.error.details).toEqual([
      { field: 'name', message: 'Already used by another category' },
    ]);

    const invalid = await as('admin').post('/api/v1/suppliers', {
      code: 'x',
      name: '',
      email: 'nope',
    });
    expect(invalid.status).toBe(400);
    expect(invalid.body.error.details.map((d: { field: string }) => d.field)).toEqual([
      'code',
      'name',
      'email',
    ]);
  });

  it('keep the default warehouse, and let others be added and deactivated', async () => {
    const list = await as('storekeeper').get('/api/v1/warehouses');
    const main = list.body.items[0];
    expect(main).toMatchObject({ code: 'HQ-MAIN', isDefault: true });
    const refused = await as('admin').patch(`/api/v1/warehouses/${main.id}`, { isActive: false });
    expect(refused.status).toBe(409);

    const second = await as('admin').post('/api/v1/warehouses', {
      code: 'byo-depot',
      name: 'Bulawayo depot',
    });
    expect(second.status).toBe(201);
    const off = await as('admin').patch(`/api/v1/warehouses/${second.body.item.id}`, {
      isActive: false,
    });
    expect(off.body.item.isActive).toBe(false);
    expect((await as('admin').get('/api/v1/warehouses')).body.items).toHaveLength(1);
  });
});

describe('products and units', () => {
  it('have a description, category, base unit and conversions', async () => {
    const category = await as('admin').post('/api/v1/categories', { name: 'Crisps' });
    const created = await as('admin').post('/api/v1/products', {
      sku: 'PC-BBQ-L',
      name: 'Potato Crisps',
      flavour: 'BBQ',
      size: 'Large',
      defaultPrice: '1.20',
      description: '  Thick-cut, 125 g ',
      categoryId: category.body.item.id,
    });
    expect(created.status).toBe(201);
    expect(created.body.product).toMatchObject({
      description: 'Thick-cut, 125 g',
      category: { name: 'Crisps' },
      baseUnit: { code: 'pack', name: 'Pack' },
      conversions: [],
    });

    const id = created.body.product.id as string;
    const converted = await as('admin').put(`/api/v1/products/${id}/conversions`, {
      conversions: [
        { unitId: await unitId('carton'), baseQuantity: 24 },
        { unitId: await unitId('case'), baseQuantity: 144 },
      ],
    });
    expect(converted.status).toBe(200);
    expect(
      converted.body.product.conversions.map(
        (c: { unit: { code: string }; baseQuantity: number }) => `${c.unit.code}=${c.baseQuantity}`,
      ),
    ).toEqual(['carton=24', 'case=144']);
  });

  it('convert quantities exactly, and never between units without a conversion', async () => {
    const product = await createTestProduct(pools.owner);
    await as('admin').put(`/api/v1/products/${product}/conversions`, {
      conversions: [{ unitId: await unitId('carton'), baseQuantity: 24 }],
    });

    expect(await toBaseQuantity(pools.app, product, await unitId('pack'), 7)).toBe(7);
    expect(await toBaseQuantity(pools.app, product, await unitId('carton'), 3)).toBe(72);
    await expect(toBaseQuantity(pools.app, product, await unitId('case'), 1)).rejects.toMatchObject(
      {
        details: [{ field: 'unitId', message: 'This product has no conversion for that unit' }],
      },
    );

    // A conversion to the base unit itself makes no sense.
    const toItself = await as('admin').put(`/api/v1/products/${product}/conversions`, {
      conversions: [{ unitId: await unitId('pack'), baseQuantity: 2 }],
    });
    expect(toItself.status).toBe(400);
  });

  it('keep their base unit once stock is recorded', async () => {
    const product = await createTestProduct(pools.owner);
    const before = await as('admin').patch(`/api/v1/products/${product}`, {
      baseUnitId: await unitId('carton'),
    });
    expect(before.status).toBe(200);
    await as('admin').patch(`/api/v1/products/${product}`, { baseUnitId: await unitId('pack') });

    await receiveTestStock(pools.app, { productId: product, quantity: 5 });
    const after = await as('admin').patch(`/api/v1/products/${product}`, {
      baseUnitId: await unitId('carton'),
    });
    expect(after.status).toBe(409);
    expect(after.body.error.code).toBe('BASE_UNIT_IN_USE');
  });
});
