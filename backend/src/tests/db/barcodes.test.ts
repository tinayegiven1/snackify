import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../../modules/auth/roles.js';
import { isValidEan13 } from '../../utils/ean13.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestProduct,
  createTestUser,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

const pools = createTestPools();
const PASSWORD = 'correct horse battery';
let app: Express;
const tokens = {} as Record<Role, string>;
let withBarcode: string;
let withoutBarcode: string;
let inactive: string;
let notEan: string;
let upcA: string;

const as = (role: Role) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${tokens[role]}`),
  post: (path: string, body: object = {}) =>
    request(app).post(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
});

const setBarcode = (id: string, barcode: string) =>
  pools.owner.query('UPDATE products SET barcode = $2 WHERE id = $1', [id, barcode]);

beforeEach(async () => {
  await resetDatabase(pools.owner);
  await pools.owner.query('ALTER SEQUENCE internal_barcode_seq RESTART');
  app = createDbTestApp(pools.app);
  for (const role of ['admin', 'storekeeper', 'salesperson', 'accounts'] as const) {
    await createTestUser(pools.app, {
      username: role,
      fullName: `Test ${role}`,
      role,
      password: PASSWORD,
    });
    tokens[role] = await signIn(app, role, PASSWORD);
  }
  withBarcode = await createTestProduct(pools.owner);
  await setBarcode(withBarcode, '5901234123457');
  withoutBarcode = await createTestProduct(pools.owner, {
    sku: 'MP-CH-S',
    name: 'Maize Puffs',
    flavour: 'Cheese',
  });
  inactive = await createTestProduct(pools.owner, {
    sku: 'PC-SV-S',
    flavour: 'Salt & Vinegar',
    isActive: false,
  });
  await setBarcode(inactive, '4006381333931');
  notEan = await createTestProduct(pools.owner, { sku: 'PC-CH-S', flavour: 'Chutney' });
  await setBarcode(notEan, 'PCCH-0001');
  upcA = await createTestProduct(pools.owner, { sku: 'PC-BBQ-L', size: 'Large' });
  await setBarcode(upcA, '036000291452');
});
afterAll(() => pools.close());

describe('looking up a scanned barcode', () => {
  it('finds the product for every signed-in role', async () => {
    for (const role of ['admin', 'storekeeper', 'salesperson', 'accounts'] as const) {
      const response = await as(role).get('/api/v1/products/barcode/5901234123457');
      expect(response.status, role).toBe(200);
      expect(response.body.product).toMatchObject({ id: withBarcode, sku: 'PC-BBQ-S' });
    }
  });

  it('ignores spaces typed in the middle of the number', async () => {
    const response = await as('salesperson').get(
      `/api/v1/products/barcode/${encodeURIComponent(' 5 901234 123457 ')}`,
    );
    expect(response.body.product.id).toBe(withBarcode);
  });

  it('returns inactive products too, marked inactive, so the app can say why it cannot be used', async () => {
    const response = await as('storekeeper').get('/api/v1/products/barcode/4006381333931');
    expect(response.body.product).toMatchObject({ id: inactive, isActive: false });
  });

  it('answers an unknown barcode with a clear, safe message (spec 11)', async () => {
    const unknown = await as('storekeeper').get('/api/v1/products/barcode/6009876543210');
    expect(unknown.status).toBe(404);
    expect(unknown.body.error).toEqual({
      code: 'BARCODE_NOT_FOUND',
      message: 'No product has the barcode 6009876543210.',
    });

    // Only an exact match counts: part of a barcode (a misread scan) finds nothing.
    const partial = await as('storekeeper').get('/api/v1/products/barcode/590123412345');
    expect(partial.status).toBe(404);

    for (const junk of ["1' OR '1'='1", '<script>', 'x'.repeat(49)]) {
      const response = await as('storekeeper').get(
        `/api/v1/products/barcode/${encodeURIComponent(junk)}`,
      );
      expect(response.status, junk).toBe(400);
      expect(response.body.error.details).toEqual([
        { field: 'barcode', message: 'A barcode has only letters, digits and dashes' },
      ]);
      expect(JSON.stringify(response.body)).not.toContain(junk);
    }
  });

  it('needs a signed-in user', async () => {
    expect((await request(app).get('/api/v1/products/barcode/5901234123457')).status).toBe(401);
  });
});

describe("Snackify's own barcodes", () => {
  it('are EAN-13 codes starting with 20, given by admins to products without one', async () => {
    const first = await as('admin').post(`/api/v1/products/${withoutBarcode}/barcode`);
    expect(first.status).toBe(200);
    expect(first.body.product.barcode).toBe('2000000000015');
    expect(isValidEan13(first.body.product.barcode)).toBe(true);

    // Scanning it finds the product.
    const found = await as('salesperson').get('/api/v1/products/barcode/2000000000015');
    expect(found.body.product.id).toBe(withoutBarcode);

    const again = await as('admin').post(`/api/v1/products/${withoutBarcode}/barcode`);
    expect(again.status).toBe(409);
    expect(again.body.error).toMatchObject({
      code: 'PRODUCT_HAS_BARCODE',
      message: 'This product already has the barcode 2000000000015.',
    });
    expect(await auditEntries(pools.owner, 'product.barcode_assigned')).toHaveLength(1);
  });

  it('skip a number another product already uses', async () => {
    // Someone typed the next internal number by hand onto another product.
    const typedByHand = await createTestProduct(pools.owner, { sku: 'X-1', name: 'Typed' });
    await setBarcode(typedByHand, '2000000000015');

    const response = await as('admin').post(`/api/v1/products/${withoutBarcode}/barcode`);
    expect(response.body.product.barcode).toBe('2000000000022');
  });

  it('are only given by admins', async () => {
    for (const role of ['storekeeper', 'salesperson', 'accounts'] as const) {
      expect((await as(role).post(`/api/v1/products/${withoutBarcode}/barcode`)).status).toBe(403);
    }
  });
});

describe('barcode labels', () => {
  const pdf = (role: Role, id: string, query = '') =>
    request(app)
      .get(`/api/v1/products/${id}/labels${query}`)
      .set('Authorization', `Bearer ${tokens[role]}`)
      .buffer(true)
      .parse((res, done) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => done(null, Buffer.concat(chunks)));
      });
  const pages = (body: Buffer) =>
    (body.toString('latin1').match(/\/Type \/Page\b(?!s)/g) ?? []).length;

  it('print a sheet of 24 for storekeepers and admins', async () => {
    for (const role of ['storekeeper', 'admin'] as const) {
      const response = await pdf(role, withBarcode);
      expect(response.status, role).toBe(200);
      expect(response.headers['content-type']).toBe('application/pdf');
      expect(response.headers['content-disposition']).toBe(
        'inline; filename="labels-PC-BBQ-S.pdf"',
      );
      const body = response.body as Buffer;
      expect(body.subarray(0, 5).toString()).toBe('%PDF-');
      expect(body.toString('latin1')).toContain('(Barcode labels PC-BBQ-S)');
      expect(pages(body)).toBe(1);
    }
  });

  it('can start part-way down a used sheet and run over several sheets', async () => {
    // 30 labels starting at position 21: 3 on the first sheet, 24 on the second, 3 on a third.
    const response = await pdf('storekeeper', withBarcode, '?count=30&skip=21');
    expect(pages(response.body as Buffer)).toBe(3);
  });

  it('work for UPC-A barcodes, but not for products without an EAN-13', async () => {
    expect((await pdf('storekeeper', upcA)).status).toBe(200);

    const none = await as('storekeeper').get(`/api/v1/products/${withoutBarcode}/labels`);
    expect(none.status).toBe(409);
    expect(none.body.error.code).toBe('PRODUCT_HAS_NO_BARCODE');

    const other = await as('storekeeper').get(`/api/v1/products/${notEan}/labels`);
    expect(other.body.error).toMatchObject({
      code: 'BARCODE_NOT_PRINTABLE',
      message:
        'Labels can only be printed for EAN-13 barcodes, and PCCH-0001 is not one. ' +
        'Use the barcode printed on the pack.',
    });
  });

  it('check the number of labels and the position to start at', async () => {
    for (const query of ['?count=0', '?count=241', '?count=two', '?skip=24', '?skip=-1']) {
      expect(
        (await as('admin').get(`/api/v1/products/${withBarcode}/labels${query}`)).status,
        query,
      ).toBe(400);
    }
  });

  it('are not for salespeople or accounts staff', async () => {
    for (const role of ['salesperson', 'accounts'] as const) {
      expect((await as(role).get(`/api/v1/products/${withBarcode}/labels`)).status).toBe(403);
    }
  });
});
