import { randomUUID } from 'node:crypto';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { StaffUser } from '../../modules/users/users.service.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestUser,
  resetAuthTables,
  signIn,
} from './db-test-helpers.js';

const pools = createTestPools();
const PASSWORD = 'correct horse battery';
let app: Express;
let admin: StaffUser;
let adminToken: string;
let storekeeperToken: string;

const as = (token: string) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${token}`),
  post: (path: string, body: object) =>
    request(app).post(path).set('Authorization', `Bearer ${token}`).send(body),
  patch: (path: string, body: object) =>
    request(app).patch(path).set('Authorization', `Bearer ${token}`).send(body),
});

const bbqSmall = {
  sku: 'PC-BBQ-S',
  name: 'Potato Crisps',
  flavour: 'BBQ',
  size: 'Small',
  barcode: '2000000000015',
  defaultPrice: '0.50',
};

async function addProduct(overrides: Record<string, unknown> = {}) {
  const response = await as(adminToken).post('/api/v1/products', { ...bbqSmall, ...overrides });
  if (response.status !== 201) {
    throw new Error(`Could not add product: ${JSON.stringify(response.body)}`);
  }
  return response.body.product as { id: string; sku: string };
}

/** Three products: two BBQ crisps and one cheese puff. */
async function addSampleProducts() {
  await addProduct();
  await addProduct({
    sku: 'PC-BBQ-L',
    size: 'Large',
    barcode: '2000000000022',
    defaultPrice: '1.00',
  });
  await addProduct({
    sku: 'MP-CH-S',
    name: 'Maize Puffs',
    flavour: 'Cheese',
    barcode: null,
    defaultPrice: '0.30',
  });
}

beforeEach(async () => {
  await resetAuthTables(pools.owner);
  await pools.owner.query('DELETE FROM products');
  app = createDbTestApp(pools.app);
  admin = await createTestUser(pools.app, { username: 'admin', role: 'admin', password: PASSWORD });
  await createTestUser(pools.app, { username: 'store', role: 'storekeeper', password: PASSWORD });
  adminToken = await signIn(app, 'admin', PASSWORD);
  storekeeperToken = await signIn(app, 'store', PASSWORD);
});
afterAll(() => pools.close());

describe('who can use /api/v1/products', () => {
  it('every signed-in role can view products; signed-out requests are refused', async () => {
    await addSampleProducts();

    const asStorekeeper = await as(storekeeperToken).get('/api/v1/products');
    expect(asStorekeeper.status).toBe(200);
    expect(asStorekeeper.body.total).toBe(3);

    expect((await request(app).get('/api/v1/products')).status).toBe(401);
  });

  it('only admins can add or change products', async () => {
    const product = await addProduct();

    const add = await as(storekeeperToken).post('/api/v1/products', { ...bbqSmall, sku: 'NEW-1' });
    const change = await as(storekeeperToken).patch(`/api/v1/products/${product.id}`, {
      defaultPrice: '0.01',
    });

    expect(add.status).toBe(403);
    expect(change.status).toBe(403);
    const { rows } = await pools.owner.query('SELECT sku, default_price FROM products');
    expect(rows).toEqual([{ sku: 'PC-BBQ-S', default_price: '0.50' }]);
  });

  it('has no way to delete a product (they are deactivated instead)', async () => {
    const product = await addProduct();
    const response = await request(app)
      .delete(`/api/v1/products/${product.id}`)
      .set('Authorization', `Bearer ${adminToken}`);

    expect(response.status).toBe(404);
    expect(response.body.error.code).toBe('NOT_FOUND');
  });
});

describe('adding products', () => {
  it('stores a product, tidying the SKU, text and an empty barcode', async () => {
    const response = await as(adminToken).post('/api/v1/products', {
      sku: ' pc-bbq-s ',
      name: '  Potato Crisps ',
      flavour: 'BBQ',
      size: 'Small',
      barcode: '',
      defaultPrice: '0.5',
    });

    expect(response.status).toBe(201);
    expect(response.body.product).toMatchObject({
      sku: 'PC-BBQ-S',
      name: 'Potato Crisps',
      barcode: null,
      defaultPrice: '0.50',
      isActive: true,
    });

    const [entry] = await auditEntries(pools.owner, 'product.created');
    expect(entry).toMatchObject({ actor_user_id: admin.id, entity_id: response.body.product.id });
  });

  it('accepts the price as a JSON number too', async () => {
    const product = await addProduct({ defaultPrice: 0.75 });
    const response = await as(adminToken).get(`/api/v1/products/${product.id}`);

    expect(response.body.product.defaultPrice).toBe('0.75');
  });

  it('rejects invalid prices', async () => {
    for (const defaultPrice of ['-1', '-0.01', '0.555', 'abc', '', '12345678901', null, true]) {
      const response = await as(adminToken).post('/api/v1/products', { ...bbqSmall, defaultPrice });

      expect(response.status, `price ${JSON.stringify(defaultPrice)}`).toBe(400);
      expect(response.body.error.details.map((d: { field: string }) => d.field)).toEqual([
        'defaultPrice',
      ]);
    }
    expect((await pools.owner.query('SELECT 1 FROM products')).rowCount).toBe(0);
  });

  it('explains every missing or invalid field', async () => {
    const response = await as(adminToken).post('/api/v1/products', { barcode: 'x' });

    expect(response.status).toBe(400);
    expect(response.body.error.details.map((d: { field: string }) => d.field)).toEqual([
      'sku',
      'name',
      'flavour',
      'size',
      'barcode',
      'defaultPrice',
    ]);
  });

  it('rejects a duplicate SKU, barcode or variation with a clear message', async () => {
    await addProduct();

    const sameSku = await as(adminToken).post('/api/v1/products', {
      ...bbqSmall,
      size: 'Large',
      barcode: null,
    });
    expect(sameSku.status).toBe(409);
    expect(sameSku.body.error).toMatchObject({
      code: 'SKU_TAKEN',
      details: [{ field: 'sku', message: 'Already used by another product' }],
    });

    const sameBarcode = await as(adminToken).post('/api/v1/products', {
      ...bbqSmall,
      sku: 'PC-BBQ-L',
      size: 'Large',
    });
    expect(sameBarcode.status).toBe(409);
    expect(sameBarcode.body.error.code).toBe('BARCODE_TAKEN');

    const sameVariation = await as(adminToken).post('/api/v1/products', {
      ...bbqSmall,
      sku: 'PC-BBQ-S2',
      name: 'POTATO CRISPS',
      flavour: 'bbq',
      barcode: null,
    });
    expect(sameVariation.status).toBe(409);
    expect(sameVariation.body.error.code).toBe('PRODUCT_EXISTS');
  });
});

describe('listing and searching', () => {
  const skus = (response: request.Response) =>
    response.body.products.map((p: { sku: string }) => p.sku);

  it('lists products by name, flavour and size, with the total count', async () => {
    await addSampleProducts();
    const response = await as(storekeeperToken).get('/api/v1/products');

    expect(skus(response)).toEqual(['MP-CH-S', 'PC-BBQ-L', 'PC-BBQ-S']);
    expect(response.body.total).toBe(3);
  });

  it('finds products by part of the name, flavour, size or SKU, ignoring case', async () => {
    await addSampleProducts();
    const search = (q: string) =>
      as(storekeeperToken).get(`/api/v1/products?q=${encodeURIComponent(q)}`);

    expect(skus(await search('bbq'))).toEqual(['PC-BBQ-L', 'PC-BBQ-S']);
    expect(skus(await search('CHEESE'))).toEqual(['MP-CH-S']);
    expect(skus(await search('larg'))).toEqual(['PC-BBQ-L']);
    expect(skus(await search('mp-ch'))).toEqual(['MP-CH-S']);
  });

  it('finds a product by its exact barcode only', async () => {
    await addSampleProducts();
    const search = (q: string) => as(storekeeperToken).get(`/api/v1/products?q=${q}`);

    expect(skus(await search('2000000000022'))).toEqual(['PC-BBQ-L']);
    expect(skus(await search('200000000002'))).toEqual([]);
  });

  it('treats % and _ in a search as ordinary characters', async () => {
    await addSampleProducts();

    expect((await as(storekeeperToken).get('/api/v1/products?q=%25')).body.total).toBe(0);
    expect((await as(storekeeperToken).get('/api/v1/products?q=_')).body.total).toBe(0);
  });

  it('pages through long lists', async () => {
    await addSampleProducts();
    const firstPage = await as(storekeeperToken).get('/api/v1/products?limit=2');
    const secondPage = await as(storekeeperToken).get('/api/v1/products?limit=2&offset=2');

    expect(skus(firstPage)).toEqual(['MP-CH-S', 'PC-BBQ-L']);
    expect(skus(secondPage)).toEqual(['PC-BBQ-S']);
    expect(secondPage.body.total).toBe(3);
  });

  it('rejects bad paging values', async () => {
    const response = await as(storekeeperToken).get('/api/v1/products?limit=0&offset=-1');

    expect(response.status).toBe(400);
    expect(response.body.error.details.map((d: { field: string }) => d.field)).toEqual([
      'limit',
      'offset',
    ]);
  });
});

describe('changing products', () => {
  it('hides a deactivated product unless inactive products are requested', async () => {
    const product = await addProduct();

    const response = await as(adminToken).patch(`/api/v1/products/${product.id}`, {
      isActive: false,
    });
    expect(response.body.product.isActive).toBe(false);

    expect((await as(storekeeperToken).get('/api/v1/products')).body.total).toBe(0);
    const withInactive = await as(storekeeperToken).get('/api/v1/products?includeInactive=true');
    expect(withInactive.body.total).toBe(1);
  });

  it('changes a price and records what changed', async () => {
    const product = await addProduct();

    const response = await as(adminToken).patch(`/api/v1/products/${product.id}`, {
      defaultPrice: '0.55',
    });

    expect(response.status).toBe(200);
    expect(response.body.product.defaultPrice).toBe('0.55');
    const [entry] = await auditEntries(pools.owner, 'product.updated');
    expect(entry).toMatchObject({
      actor_user_id: admin.id,
      details: { changes: { defaultPrice: { from: '0.50', to: '0.55' } } },
    });
  });

  it('keeps the barcode when it is left out, and removes it when set to null', async () => {
    const product = await addProduct();
    const path = `/api/v1/products/${product.id}`;

    expect((await as(adminToken).patch(path, { name: 'Potato Chips' })).body.product.barcode).toBe(
      '2000000000015',
    );
    expect((await as(adminToken).patch(path, { barcode: null })).body.product.barcode).toBeNull();
  });

  it('refuses a change that would duplicate another product', async () => {
    await addProduct();
    const large = await addProduct({ sku: 'PC-BBQ-L', size: 'Large', barcode: null });

    const response = await as(adminToken).patch(`/api/v1/products/${large.id}`, {
      sku: 'pc-bbq-s',
    });
    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('SKU_TAKEN');
  });

  it('returns 404 for unknown ids and 400 for unknown fields or empty changes', async () => {
    const product = await addProduct();

    expect((await as(adminToken).get(`/api/v1/products/${randomUUID()}`)).status).toBe(404);
    expect((await as(adminToken).patch('/api/v1/products/not-an-id', { name: 'X' })).status).toBe(
      404,
    );
    expect((await as(adminToken).patch(`/api/v1/products/${product.id}`, { id: 'x' })).status).toBe(
      400,
    );
    expect((await as(adminToken).patch(`/api/v1/products/${product.id}`, {})).status).toBe(400);
  });
});
