import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { businessToday } from '../../utils/dates.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestProduct,
  createTestSubsidiary,
  createTestUser,
  headOfficeId,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

// Goods bought: finance enters what was bought; the warehouse receives against it.
const pools = createTestPools();
const PASSWORD = '4826';
let app: Express;
const tokens: Record<string, string> = {};
let hq: string;
let subA: string;
let supplierId: string;
let bbq: string;
let cheese: string;
let pack: string;

const today = () => businessToday('Africa/Harare');
const auth = (who: string) => ({ Authorization: `Bearer ${tokens[who]}` });
const as = (who: string) => ({
  get: (path: string) => request(app).get(path).set(auth(who)),
  post: (path: string, body: object = {}) => request(app).post(path).set(auth(who)).send(body),
  put: (path: string, body: object) => request(app).put(path).set(auth(who)).send(body),
});

const PDF = Buffer.from('%PDF-1.4\n% supplier invoice\n%%EOF\n');

const purchaseBody = (overrides: object = {}) => ({
  supplierId,
  supplierInvoiceNumber: 'INV-2040',
  lines: [
    { productId: bbq, unitId: pack, quantity: 100, unitCost: '0.4250' },
    { productId: cheese, unitId: pack, quantity: 50, unitCost: '0.3000', notes: 'Promo packs' },
  ],
  ...overrides,
});

async function bought(overrides: object = {}) {
  const response = await as('accounts').post('/api/v1/purchases', purchaseBody(overrides));
  expect(response.status, JSON.stringify(response.body)).toBe(201);
  return response.body.purchase;
}

interface BoughtLine {
  id: string;
  product: { id: string };
  unit: { id: string };
  unitCost: string;
}

/** A goods-received note made from [purchase], receiving [received] of each line. */
async function receiveAgainst(
  purchase: { id: string; lines: BoughtLine[] },
  received: number[],
  submit = true,
) {
  const body = {
    supplierId,
    purchaseId: purchase.id,
    lines: purchase.lines.map((line, index) => ({
      productId: line.product.id,
      unitId: line.unit.id,
      quantityPurchased: received[index],
      quantityReceived: received[index],
      unitCost: line.unitCost,
      purchaseLineId: line.id,
    })),
  };
  const draft = await as('storekeeper').post('/api/v1/receipts', body);
  expect(draft.status, JSON.stringify(draft.body)).toBe(201);
  const id = draft.body.receipt.id as string;
  if (!submit) return draft.body.receipt;
  const uploaded = await request(app)
    .post(`/api/v1/receipts/${id}/attachments?filename=invoice.pdf`)
    .set(auth('storekeeper'))
    .set('Content-Type', 'application/octet-stream')
    .send(PDF);
  expect(uploaded.status).toBe(201);
  const submitted = await as('storekeeper').post(`/api/v1/receipts/${id}/submit`);
  expect(submitted.status, JSON.stringify(submitted.body)).toBe(200);
  return submitted.body.receipt;
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
  await pools.owner.query(
    'ALTER SEQUENCE purchase_number_seq RESTART; ALTER SEQUENCE stock_receipt_number_seq RESTART',
  );
  app = createDbTestApp(pools.app);
  hq = await headOfficeId(pools.owner);
  subA = await createTestSubsidiary(pools.owner, 'SUB-A', 'Avondale Shop');
  for (const role of ['admin', 'storekeeper', 'accounts', 'salesperson'] as const) {
    await createTestUser(pools.app, { username: role, role, password: PASSWORD });
    tokens[role] = await signIn(app, role, PASSWORD);
  }
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO suppliers (code, name) VALUES ('SUP-01', 'Harare Potato Co-op') RETURNING id`,
  );
  supplierId = (rows[0] as { id: string }).id;
  bbq = await createTestProduct(pools.owner);
  cheese = await createTestProduct(pools.owner, { sku: 'PC-CH-S', flavour: 'Cheese' });
  const { rows: units } = await pools.owner.query<{ id: string }>(
    `SELECT id FROM units WHERE code = 'pack'`,
  );
  pack = (units[0] as { id: string }).id;
});
afterAll(() => pools.close());

describe('goods bought', () => {
  it('are entered by finance, seen by the warehouse, and kept from everyone else', async () => {
    const purchase = await bought();
    expect(purchase).toMatchObject({
      purchaseNumber: 'GB000001',
      status: 'OPEN',
      receivingStatus: 'NOT_RECEIVED',
      owner: { id: hq, code: 'HQ' },
      supplier: { code: 'SUP-01' },
      supplierInvoiceNumber: 'INV-2040',
      purchaseDate: today(),
      currency: 'USD',
      total: '57.50', // 100 x 0.4250 + 50 x 0.3000
      lineCount: 2,
      createdBy: { fullName: 'Test accounts' },
      canChange: true,
      canCancel: true,
      receipts: [],
    });
    expect(purchase.lines[0]).toMatchObject({
      lineNumber: 1,
      quantity: 100,
      unitCost: '0.4250',
      lineTotal: '42.50',
      quantityReceived: 0,
      quantityOutstanding: 100,
    });
    expect(purchase.lines[1].notes).toBe('Promo packs');
    expect(await auditEntries(pools.owner, 'purchase.created')).toHaveLength(1);

    // The warehouse sees it but cannot enter one; sales staff see nothing.
    expect((await as('storekeeper').get(`/api/v1/purchases/${purchase.id}`)).status).toBe(200);
    expect((await as('storekeeper').post('/api/v1/purchases', purchaseBody())).status).toBe(403);
    expect((await as('salesperson').get('/api/v1/purchases')).status).toBe(403);
    expect((await as('admin').post('/api/v1/purchases', purchaseBody())).status).toBe(201);
  });

  it('print as a PDF', async () => {
    const purchase = await bought();
    const pdf = await request(app)
      .get(`/api/v1/purchases/${purchase.id}/pdf`)
      .set(auth('storekeeper'))
      .buffer(true)
      .parse((res, done) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => done(null, Buffer.concat(chunks)));
      });
    expect(pdf.status).toBe(200);
    expect(pdf.headers['content-type']).toBe('application/pdf');
    expect(pdf.headers['content-disposition']).toBe('inline; filename="GB000001.pdf"');
    expect((pdf.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');
  });

  it('check what is entered', async () => {
    const fields = async (body: object) =>
      ((await as('accounts').post('/api/v1/purchases', body)).body.error?.details ?? []).map(
        (d: { field: string }) => d.field,
      );
    expect(await fields(purchaseBody({ lines: [] }))).toEqual(['lines']);
    expect(
      await fields(
        purchaseBody({ lines: [{ productId: bbq, unitId: pack, quantity: 0, unitCost: '1' }] }),
      ),
    ).toEqual(['lines.0.quantity']);
    expect(await fields(purchaseBody({ purchaseDate: '2999-01-01' }))).toEqual(['purchaseDate']);
  });

  it('show what has arrived as the warehouse receives against them', async () => {
    const purchase = await bought();

    // A draft does not count as arrived, but it already stops the list being changed.
    const draft = await receiveAgainst(purchase, [60, 50], false);
    expect(draft.purchase).toEqual({ id: purchase.id, purchaseNumber: 'GB000001' });
    let now = (await as('accounts').get(`/api/v1/purchases/${purchase.id}`)).body.purchase;
    expect(now).toMatchObject({
      receivingStatus: 'NOT_RECEIVED',
      canChange: false,
      canCancel: false,
    });
    const changed = await as('accounts').put(`/api/v1/purchases/${purchase.id}`, purchaseBody());
    expect(changed.status).toBe(409);
    expect(changed.body.error.code).toBe('PURCHASE_HAS_RECEIPTS');
    expect(
      (await as('accounts').post(`/api/v1/purchases/${purchase.id}/cancel`, { reason: 'Wrong' }))
        .status,
    ).toBe(409);

    // Submitted: 60 of 100 BBQ and all 50 Cheese have arrived.
    await request(app)
      .post(`/api/v1/receipts/${draft.id}/attachments?filename=invoice.pdf`)
      .set(auth('storekeeper'))
      .set('Content-Type', 'application/octet-stream')
      .send(PDF);
    expect((await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`)).status).toBe(200);
    now = (await as('accounts').get(`/api/v1/purchases/${purchase.id}`)).body.purchase;
    expect(now.receivingStatus).toBe('PARTLY_RECEIVED');
    expect(
      now.lines.map((l: { quantityReceived: number; quantityOutstanding: number }) => [
        l.quantityReceived,
        l.quantityOutstanding,
      ]),
    ).toEqual([
      [60, 40],
      [50, 0],
    ]);
    expect(now.receipts).toEqual([
      expect.objectContaining({ grnNumber: 'GRN000001', status: 'PENDING_VERIFICATION' }),
    ]);

    // The rest arrives on a second note; finance approves it (a different person).
    const second = await receiveAgainst({ ...purchase, lines: [purchase.lines[0]] }, [40]);
    expect((await as('accounts').post(`/api/v1/receipts/${second.id}/verify`)).status).toBe(200);
    now = (await as('accounts').get(`/api/v1/purchases/${purchase.id}`)).body.purchase;
    expect(now.receivingStatus).toBe('RECEIVED');
    const filtered = await as('accounts').get('/api/v1/purchases?status=RECEIVED');
    expect(filtered.body.purchases.map((p: { id: string }) => p.id)).toEqual([purchase.id]);
  });

  it('only take deliveries that match them', async () => {
    const purchase = await bought();
    const line = (overrides: object = {}) => ({
      productId: bbq,
      unitId: pack,
      quantityPurchased: 10,
      quantityReceived: 10,
      unitCost: '0.4250',
      purchaseLineId: purchase.lines[0].id,
      ...overrides,
    });
    const field = async (body: object) => {
      const response = await as('storekeeper').post('/api/v1/receipts', body);
      expect(response.status, JSON.stringify(response.body)).toBe(400);
      return response.body.error.details[0].field;
    };
    // A line from a list, without the list.
    expect(await field({ lines: [line()] })).toBe('lines.0.purchaseLineId');
    // The wrong product for that line.
    expect(await field({ purchaseId: purchase.id, lines: [line({ productId: cheese })] })).toBe(
      'lines.0.productId',
    );
    // Another organisation's stock.
    expect(await field({ purchaseId: purchase.id, organisationId: subA, lines: [line()] })).toBe(
      'organisationId',
    );
    // A list that was cancelled.
    const cancelled = await bought();
    await as('accounts').post(`/api/v1/purchases/${cancelled.id}/cancel`, { reason: 'Duplicate' });
    expect(
      await field({
        purchaseId: cancelled.id,
        lines: [line({ purchaseLineId: cancelled.lines[0].id })],
      }),
    ).toBe('purchaseId');
    // Receiving without a list is still fine.
    const loose = await as('storekeeper').post('/api/v1/receipts', {
      lines: [line({ purchaseLineId: null })],
    });
    expect(loose.status).toBe(201);
    expect(loose.body.receipt.purchase).toBeNull();
  });

  it('can be changed, or cancelled with a reason, until goods arrive against them', async () => {
    const purchase = await bought();
    const changed = await as('accounts').put(
      `/api/v1/purchases/${purchase.id}`,
      purchaseBody({ lines: [{ productId: bbq, unitId: pack, quantity: 12, unitCost: '1.25' }] }),
    );
    expect(changed.status).toBe(200);
    expect(changed.body.purchase).toMatchObject({ total: '15.00', lineCount: 1 });

    const noReason = await as('accounts').post(`/api/v1/purchases/${purchase.id}/cancel`, {});
    expect(noReason.status).toBe(400);
    const cancelled = await as('accounts').post(`/api/v1/purchases/${purchase.id}/cancel`, {
      reason: 'Supplier could not deliver',
    });
    expect(cancelled.status).toBe(200);
    expect(cancelled.body.purchase).toMatchObject({
      status: 'CANCELLED',
      cancelReason: 'Supplier could not deliver',
      cancelledBy: { fullName: 'Test accounts' },
      canChange: false,
      canCancel: false,
    });
    const again = await as('accounts').put(`/api/v1/purchases/${purchase.id}`, purchaseBody());
    expect(again.body.error.code).toBe('PURCHASE_CANCELLED');
    expect(await auditEntries(pools.owner, 'purchase.cancelled')).toHaveLength(1);
    const open = await as('accounts').get('/api/v1/purchases?status=OPEN');
    expect(open.body.total).toBe(0);
  });
});
