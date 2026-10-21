import type { Express } from 'express';
import pg from 'pg';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { businessToday } from '../../utils/dates.js';
import {
  appDatabaseUrl,
  auditEntries,
  createDbTestApp,
  createTestPools,
  receiveTestStock,
  createTestProduct,
  createTestUser,
  PG,
  pgErrorOf,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

const pools = createTestPools();
const PASSWORD = 'correct horse battery';
let app: Express;
let adminToken: string;
let storekeeperToken: string;
let salespersonToken: string;
let productId: string;

/** A date relative to today in Harare, as YYYY-MM-DD. */
function businessDate(daysFromToday = 0): string {
  const today = businessToday('Africa/Harare');
  const date = new Date(`${today}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + daysFromToday);
  return date.toISOString().slice(0, 10);
}

const as = (token: string) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${token}`),
  post: (path: string, body: object) =>
    request(app).post(path).set('Authorization', `Bearer ${token}`).send(body),
  patch: (path: string, body: object) =>
    request(app).patch(path).set('Authorization', `Bearer ${token}`).send(body),
});

/** Stock received directly (deliveries normally come in through goods-received notes). */
function receive(quantity: number, extra: object = {}) {
  return receiveTestStock(pools.app, { productId, quantity, ...extra });
}

/** The old quick receipt: since StockFlow Stage 4, for opening balances only. */
const postOpening = (body: object, token = adminToken) =>
  as(token).post('/api/v1/stock/receipts', { productId, isOpeningBalance: true, ...body });

function adjust(quantityDelta: number, type = 'adjustment', reason = 'Stock count correction') {
  return as(adminToken).post('/api/v1/stock/adjustments', {
    productId,
    type,
    quantityDelta,
    reason,
  });
}

async function onHand(id = productId): Promise<number> {
  const { rows } = await pools.owner.query<{ quantity_on_hand: number }>(
    'SELECT quantity_on_hand FROM hq_stock_on_hand WHERE product_id = $1',
    [id],
  );
  return rows[0]?.quantity_on_hand ?? NaN;
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
  app = createDbTestApp(pools.app);
  await createTestUser(pools.app, {
    username: 'admin',
    fullName: 'Ada Admin',
    role: 'admin',
    password: PASSWORD,
  });
  await createTestUser(pools.app, {
    username: 'store',
    fullName: 'Sam Storekeeper',
    role: 'storekeeper',
    password: PASSWORD,
  });
  await createTestUser(pools.app, { username: 'sales', role: 'salesperson', password: PASSWORD });
  adminToken = await signIn(app, 'admin', PASSWORD);
  storekeeperToken = await signIn(app, 'store', PASSWORD);
  salespersonToken = await signIn(app, 'sales', PASSWORD);
  productId = await createTestProduct(pools.owner);
});
afterAll(() => pools.close());

describe('receiving stock directly', () => {
  it('increases stock by exactly the quantity received', async () => {
    const result = await receive(100);

    expect(result.quantityOnHand).toBe(100);
    expect(await onHand()).toBe(100);
    expect(result.receipt).toMatchObject({
      quantity: 100,
      receivedDate: businessDate(),
      isOpeningBalance: false,
      receivedBy: { fullName: 'Ada Admin' },
      product: { sku: 'PC-BBQ-S', name: 'Potato Crisps' },
    });

    await receive(20);
    expect(await onHand()).toBe(120);

    const { rows } = await pools.owner.query(
      'SELECT movement_type, quantity_delta FROM stock_movements ORDER BY occurred_at',
    );
    expect(rows).toEqual([
      { movement_type: 'receipt', quantity_delta: 100 },
      { movement_type: 'receipt', quantity_delta: 20 },
    ]);
  });

  it('keeps the batch number, expiry date and supplier reference', async () => {
    const { receipt } = await receive(48, {
      receivedDate: businessDate(-1),
      batchNumber: 'L2026-10A',
      expiryDate: businessDate(90),
      supplierReference: 'Delivery note 1042',
    });

    expect(receipt).toMatchObject({
      receivedDate: businessDate(-1),
      batchNumber: 'L2026-10A',
      expiryDate: businessDate(90),
      supplierReference: 'Delivery note 1042',
    });
    const { rows } = await pools.owner.query(
      'SELECT reference, business_date FROM stock_movements',
    );
    expect(rows).toEqual([{ reference: 'Delivery note 1042', business_date: businessDate(-1) }]);
  });

  it('rejects invalid quantities and stores nothing', async () => {
    for (const quantity of [0, -5, 1.5, '10', 1_000_001, null, undefined]) {
      const response = await postOpening({ quantity });
      expect(response.status, `quantity ${String(quantity)}`).toBe(400);
      expect(response.body.error.details[0].field).toBe('quantity');
    }
    expect(await onHand()).toBe(0);
    expect((await pools.owner.query('SELECT 1 FROM stock_batches')).rowCount).toBe(0);
  });

  it('rejects impossible dates', async () => {
    const post = (body: object) => postOpening({ quantity: 5, ...body });

    const future = await post({ receivedDate: businessDate(1) });
    expect(future.status).toBe(400);
    expect(future.body.error.details).toEqual([
      { field: 'receivedDate', message: 'Cannot be in the future' },
    ]);

    const expiredBeforeArrival = await post({
      receivedDate: businessDate(-1),
      expiryDate: businessDate(-2),
    });
    expect(expiredBeforeArrival.body.error.details[0].field).toBe('expiryDate');

    expect((await post({ receivedDate: '2026-13-40' })).status).toBe(400);
    expect(await onHand()).toBe(0);
  });

  it('is refused through the quick receipt: deliveries need a goods-received note', async () => {
    for (const token of [storekeeperToken, adminToken]) {
      const response = await as(token).post('/api/v1/stock/receipts', { productId, quantity: 5 });
      expect(response.status).toBe(409);
      expect(response.body.error.code).toBe('USE_GOODS_RECEIVED_NOTE');
    }
    const asSalesperson = await postOpening({ quantity: 5 }, salespersonToken);
    expect(asSalesperson.status).toBe(403);
    expect(await onHand()).toBe(0);
  });

  it('refuses stock for an inactive or unknown product', async () => {
    const inactiveId = await createTestProduct(pools.owner, {
      sku: 'PC-CH-S',
      flavour: 'Chutney',
      isActive: false,
    });

    const inactive = await postOpening({ productId: inactiveId, quantity: 5 });
    expect(inactive.status).toBe(409);
    expect(inactive.body.error.code).toBe('PRODUCT_INACTIVE');

    const unknown = await postOpening({
      productId: '00000000-0000-4000-8000-000000000000',
      quantity: 5,
    });
    expect(unknown.status).toBe(404);
  });

  it('can never be changed or deleted afterwards, even directly in the database', async () => {
    await receive(10);

    for (const sql of [
      'UPDATE stock_batches SET quantity_received = 1000',
      'DELETE FROM stock_batches',
      'UPDATE stock_movements SET quantity_delta = 1000',
      'DELETE FROM stock_movements',
    ]) {
      expect((await pgErrorOf(pools.app.query(sql))).code, sql).toBe(PG.insufficientPrivilege);
    }
    expect(await onHand()).toBe(10);
  });
});

describe('opening balances', () => {
  it('an admin records opening stock once, before any other movement', async () => {
    const opening = await as(adminToken).post('/api/v1/stock/receipts', {
      productId,
      quantity: 50,
      isOpeningBalance: true,
    });
    expect(opening.status).toBe(201);
    expect(opening.body.receipt.isOpeningBalance).toBe(true);
    expect(await onHand()).toBe(50);

    const [entry] = await auditEntries(pools.owner, 'stock.opening_balance');
    expect(entry?.details).toMatchObject({ quantity: 50 });

    const again = await as(adminToken).post('/api/v1/stock/receipts', {
      productId,
      quantity: 10,
      isOpeningBalance: true,
    });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('OPENING_BALANCE_NOT_ALLOWED');
    expect(await onHand()).toBe(50);
  });

  it('cannot be recorded by a storekeeper, or after stock has been received', async () => {
    const byStorekeeper = await as(storekeeperToken).post('/api/v1/stock/receipts', {
      productId,
      quantity: 50,
      isOpeningBalance: true,
    });
    expect(byStorekeeper.status).toBe(403);

    await receive(10);
    const afterReceipt = await as(adminToken).post('/api/v1/stock/receipts', {
      productId,
      quantity: 50,
      isOpeningBalance: true,
    });
    expect(afterReceipt.status).toBe(409);
    expect(await onHand()).toBe(10);
  });
});

describe('damage and adjustments (POST /api/v1/stock/adjustments)', () => {
  it('change stock by the amount given, with a reason', async () => {
    await receive(100);

    const damage = await adjust(-1, 'damage', 'Packs torn in transit');
    expect(damage.status).toBe(201);
    expect(damage.body.quantityOnHand).toBe(99);
    expect(damage.body.movement).toMatchObject({
      type: 'damage',
      quantityDelta: -1,
      reason: 'Packs torn in transit',
      balanceAfter: 99,
    });

    expect((await adjust(2, 'adjustment', 'Recount found 2 more')).body.quantityOnHand).toBe(101);
    expect(await onHand()).toBe(101);
  });

  it('refuse to take stock below zero', async () => {
    await receive(5);

    const response = await adjust(-6);
    expect(response.status).toBe(409);
    expect(response.body.error).toEqual({
      code: 'INSUFFICIENT_STOCK',
      message: 'Only 5 in stock, so 6 cannot be removed.',
    });
    expect(await onHand()).toBe(5);

    expect((await adjust(-5)).status).toBe(201);
    expect(await onHand()).toBe(0);
  });

  it('require a sensible amount and a reason', async () => {
    await receive(10);
    const fields = async (body: object) =>
      (await as(adminToken).post('/api/v1/stock/adjustments', { productId, ...body })).body.error
        .details;

    expect(await fields({ type: 'damage', quantityDelta: 3, reason: 'Broken' })).toEqual([
      { field: 'quantityDelta', message: 'Damage removes stock, so use a negative number' },
    ]);
    expect(await fields({ type: 'adjustment', quantityDelta: 0, reason: 'Nothing' })).toEqual([
      { field: 'quantityDelta', message: 'Must not be 0' },
    ]);
    expect(await fields({ type: 'adjustment', quantityDelta: -1, reason: ' ' })).toEqual([
      { field: 'reason', message: 'Explain the reason in a few words' },
    ]);
    expect(await onHand()).toBe(10);
  });

  it('are allowed for admins only, and recorded in the audit log', async () => {
    await receive(10);
    const byStorekeeper = await as(storekeeperToken).post('/api/v1/stock/adjustments', {
      productId,
      type: 'damage',
      quantityDelta: -1,
      reason: 'Torn',
    });
    expect(byStorekeeper.status).toBe(403);

    await adjust(-3, 'damage', 'Water damage');
    const [entry] = await auditEntries(pools.owner, 'stock.adjusted');
    expect(entry?.details).toEqual({
      type: 'damage',
      quantityDelta: -3,
      reason: 'Water damage',
      balanceBefore: 10,
      balanceAfter: 7,
      // Which delivery the damaged packs came from (the one that expires first).
      parts: [{ batchId: expect.any(String), warehouseId: expect.any(String), quantity: -3 }],
    });
  });

  it('cannot oversell when many arrive at the same moment', async () => {
    // A separate app with enough connections that the requests really run in parallel.
    // Several rounds make it very unlikely that a missing lock goes unnoticed by luck.
    const busyPool = new pg.Pool({ connectionString: appDatabaseUrl, max: 22 });
    const busyApp = createDbTestApp(busyPool);
    try {
      for (let round = 1; round <= 3; round++) {
        await receive(100);
        const attempts = await Promise.all(
          Array.from({ length: 20 }, () =>
            request(busyApp)
              .post('/api/v1/stock/adjustments')
              .set('Authorization', `Bearer ${adminToken}`)
              .send({ productId, type: 'damage', quantityDelta: -10, reason: 'Concurrency test' }),
          ),
        );
        const statuses = attempts.map((response) => response.status);

        // 100 packs cover ten removals of 10; the other ten must be refused.
        expect(
          statuses.filter((status) => status === 201),
          `round ${round}`,
        ).toHaveLength(10);
        expect(
          statuses.filter((status) => status === 409),
          `round ${round}`,
        ).toHaveLength(10);
        expect(await onHand(), `round ${round}`).toBe(0);
      }
    } finally {
      await busyPool.end();
    }
  });
});

describe('stock on hand and history', () => {
  it('lists every product with its stock and a low-stock flag', async () => {
    const lowId = await createTestProduct(pools.owner, {
      sku: 'MP-CH-S',
      name: 'Maize Puffs',
      flavour: 'Cheese',
      reorderLevel: 50,
    });
    await createTestProduct(pools.owner, { sku: 'PC-SV-S', flavour: 'Salt & Vinegar' });
    await receive(30); // BBQ: no reorder level, so never "low"
    await receiveTestStock(pools.app, { productId: lowId, quantity: 20 });

    const response = await as(salespersonToken).get('/api/v1/stock/balance');
    expect(response.status).toBe(200);
    expect(
      response.body.balances.map(
        (b: { product: { sku: string }; quantityOnHand: number; isLowStock: boolean }) => [
          b.product.sku,
          b.quantityOnHand,
          b.isLowStock,
        ],
      ),
    ).toEqual([
      ['MP-CH-S', 20, true],
      ['PC-BBQ-S', 30, false],
      ['PC-SV-S', 0, false],
    ]);

    const lowOnly = await as(salespersonToken).get('/api/v1/stock/balance?lowStockOnly=true');
    expect(lowOnly.body.balances.map((b: { product: { sku: string } }) => b.product.sku)).toEqual([
      'MP-CH-S',
    ]);
  });

  it('lets an admin set or clear a reorder level on the product', async () => {
    const set = await as(adminToken).patch(`/api/v1/products/${productId}`, { reorderLevel: 24 });
    expect(set.body.product.reorderLevel).toBe(24);

    const cleared = await as(adminToken).patch(`/api/v1/products/${productId}`, {
      reorderLevel: null,
    });
    expect(cleared.body.product.reorderLevel).toBeNull();

    const invalid = await as(adminToken).patch(`/api/v1/products/${productId}`, {
      reorderLevel: -1,
    });
    expect(invalid.status).toBe(400);
  });

  it('lists receipts for a day or a date range', async () => {
    await receive(10, { receivedDate: businessDate(-3) });
    await receive(20, { receivedDate: businessDate(-1) });
    await receive(30);

    const todayOnly = await as(salespersonToken).get('/api/v1/stock/receipts');
    expect(todayOnly.body).toMatchObject({ from: businessDate(), totalQuantity: 30 });

    const lastThreeDays = await as(salespersonToken).get(
      `/api/v1/stock/receipts?from=${businessDate(-3)}&to=${businessDate()}`,
    );
    expect(lastThreeDays.body.totalQuantity).toBe(60);
    expect(lastThreeDays.body.receipts.map((r: { quantity: number }) => r.quantity)).toEqual([
      30, 20, 10,
    ]);

    const backwards = await as(salespersonToken).get(
      `/api/v1/stock/receipts?from=${businessDate()}&to=${businessDate(-1)}`,
    );
    expect(backwards.status).toBe(400);
    const tooLong = await as(salespersonToken).get(
      `/api/v1/stock/receipts?from=${businessDate(-400)}&to=${businessDate()}`,
    );
    expect(tooLong.status).toBe(400);
  });

  it("shows a product's history, newest first, with the balance after each entry", async () => {
    await receive(100);
    await adjust(-1, 'damage', 'Torn pack');
    await adjust(2, 'adjustment', 'Recount');

    const response = await as(salespersonToken).get(
      `/api/v1/stock/movements?productId=${productId}`,
    );
    expect(response.body.total).toBe(3);
    expect(
      response.body.movements.map(
        (m: { type: string; quantityDelta: number; balanceAfter: number }) => [
          m.type,
          m.quantityDelta,
          m.balanceAfter,
        ],
      ),
    ).toEqual([
      ['adjustment', 2, 101],
      ['damage', -1, 99],
      ['receipt', 100, 100],
    ]);
    expect(response.body.movements[2].createdBy.fullName).toBe('Ada Admin');
  });
});
