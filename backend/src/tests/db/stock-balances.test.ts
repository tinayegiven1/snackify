import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { runMigrations } from '../../database/migrations.js';
import {
  createDbTestApp,
  createTestPools,
  receiveTestStock,
  createTestProduct,
  createTestSubsidiary,
  createTestUser,
  headOfficeId,
  migrateTestDatabase,
  ownerDatabaseUrl,
  PG,
  pgErrorOf,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

// StockFlow Stage 4.2 and 4.3: balances keyed by product + owner + warehouse + batch, kept in
// step with the ledger by a trigger; dispatches take the batches that expire first.
const pools = createTestPools();
const PASSWORD = 'correct horse battery';
let app: Express;
let token: string;
let product: string;

const as = () => ({
  post: (path: string, body: object) =>
    request(app).post(path).set('Authorization', `Bearer ${token}`).send(body),
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${token}`),
});

async function receive(quantity: number, expiryDate: string | null, batchNumber: string) {
  const { receipt } = await receiveTestStock(pools.app, {
    productId: product,
    quantity,
    receivedDate: '2026-10-01',
    expiryDate,
    batchNumber,
  });
  return receipt.id;
}

async function balances() {
  const { rows } = await pools.owner.query<{ batch_number: string | null; on_hand: number }>(
    `SELECT b.batch_number, sb.quantity_on_hand AS on_hand
     FROM stock_balances sb LEFT JOIN stock_batches b ON b.id = sb.batch_id
     WHERE sb.product_id = $1 ORDER BY b.batch_number NULLS LAST`,
    [product],
  );
  return rows;
}

/** The ledger and the balances agree for every product, owner and warehouse. */
async function ledgerMatchesBalances(): Promise<void> {
  const { rows } = await pools.owner.query(
    `SELECT product_id, owner_organisation_id, warehouse_id,
            COALESCE(l.total, 0) AS ledger, COALESCE(b.total, 0) AS balance
     FROM (SELECT product_id, owner_organisation_id, warehouse_id, sum(quantity_delta) AS total
           FROM stock_movements GROUP BY 1, 2, 3) l
     FULL JOIN (SELECT product_id, owner_organisation_id, warehouse_id, sum(quantity_on_hand) AS total
                FROM stock_balances GROUP BY 1, 2, 3) b
       USING (product_id, owner_organisation_id, warehouse_id)
     WHERE COALESCE(l.total, 0) <> COALESCE(b.total, 0)`,
  );
  expect(rows).toEqual([]);
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
  app = createDbTestApp(pools.app);
  await createTestUser(pools.app, { username: 'admin', role: 'admin', password: PASSWORD });
  token = await signIn(app, 'admin', PASSWORD);
  product = await createTestProduct(pools.owner);
});
afterAll(() => pools.close());

describe('stock balances', () => {
  it('follow every ledger entry, per delivery, and always add up to the ledger', async () => {
    await receive(40, '2026-12-31', 'B-LATE');
    await receive(30, '2026-11-30', 'B-SOON');
    expect(await balances()).toEqual([
      { batch_number: 'B-LATE', on_hand: 40 },
      { batch_number: 'B-SOON', on_hand: 30 },
    ]);

    // Damage without naming a delivery comes from the one that expires first.
    const damage = await as().post('/api/v1/stock/adjustments', {
      productId: product,
      type: 'damage',
      quantityDelta: -35,
      reason: 'Water damage',
    });
    expect(damage.status).toBe(201);
    expect(damage.body.movements).toHaveLength(2); // all of B-SOON, then 5 of B-LATE
    expect(await balances()).toEqual([
      { batch_number: 'B-LATE', on_hand: 35 },
      { batch_number: 'B-SOON', on_hand: 0 },
    ]);

    // A count correction upwards belongs to no delivery.
    await as().post('/api/v1/stock/adjustments', {
      productId: product,
      type: 'adjustment',
      quantityDelta: 4,
      reason: 'Found in the back',
    });
    expect((await balances()).at(-1)).toEqual({ batch_number: null, on_hand: 4 });
    await ledgerMatchesBalances();
  });

  it('can only be changed by writing a ledger entry: the API role cannot touch them', async () => {
    await receive(10, null, 'B1');
    const hq = await headOfficeId(pools.owner);
    for (const query of [
      `UPDATE stock_balances SET quantity_on_hand = 1000`,
      `DELETE FROM stock_balances`,
      `INSERT INTO stock_balances (product_id, owner_organisation_id, warehouse_id, quantity_on_hand)
       VALUES ('${product}', '${hq}', default_warehouse_id(), 5)`,
    ]) {
      expect((await pgErrorOf(pools.app.query(query))).code).toBe(PG.insufficientPrivilege);
    }
  });

  it('never go below zero, whatever writes the ledger', async () => {
    await receive(10, null, 'B1');
    const { rows } = await pools.owner.query<{ id: string; batch_id: string }>(
      `SELECT u.id, b.id AS batch_id FROM users u, stock_batches b LIMIT 1`,
    );
    const error = await pgErrorOf(
      pools.app.query(
        `INSERT INTO stock_movements (product_id, batch_id, movement_type, quantity_delta,
                                      business_date, created_by, reason)
         VALUES ($1, $2, 'damage', -11, current_date, $3, 'Too much')`,
        [product, rows[0]?.batch_id, rows[0]?.id],
      ),
    );
    expect(error).toMatchObject({
      code: PG.checkViolation,
      constraint: 'stock_balances_on_hand_not_negative',
    });
    expect(await balances()).toEqual([{ batch_number: 'B1', on_hand: 10 }]);
  });

  it("keep owners apart: one organisation's stock is never another's", async () => {
    await receive(10, null, 'B1');
    const subsidiary = await createTestSubsidiary(pools.owner, 'SUB-A');
    const removal = await as().post('/api/v1/stock/adjustments', {
      productId: product,
      type: 'damage',
      quantityDelta: -1,
      reason: 'Broken',
      organisationId: subsidiary,
    });
    expect(removal.status).toBe(409);
    expect(removal.body.error.code).toBe('INSUFFICIENT_STOCK');
  });

  it('give every movement its own reference, in order', async () => {
    await receive(10, null, 'B1');
    await receive(5, null, 'B2');
    const history = await as().get(`/api/v1/stock/movements?productId=${product}`);
    const [newer, older] = history.body.movements.map(
      (m: { movementNumber: string }) => m.movementNumber,
    ) as string[];
    expect(newer).toMatch(/^M\d{7}$/);
    expect(Number(newer?.slice(1))).toBe(Number(older?.slice(1)) + 1);
    expect(history.body.movements[0].warehouse.code).toBe('HQ-MAIN');
  });
});

describe('dispatches', () => {
  it('take the delivery that expires first, and a reversal puts it back exactly', async () => {
    await receive(20, '2027-03-31', 'B-LATE');
    await receive(15, '2026-11-15', 'B-SOON');
    const { rows } = await pools.owner.query<{ id: string }>(
      `INSERT INTO customers (code, name) VALUES ('C1', 'Test Shop') RETURNING id`,
    );
    const draft = await as().post('/api/v1/dispatches', {
      customerId: rows[0]?.id,
      dispatchDate: '2026-10-02',
      items: [{ productId: product, quantity: 18 }],
    });
    expect(draft.status).toBe(201);
    const confirmed = await as().post(`/api/v1/dispatches/${draft.body.dispatch.id}/confirm`, {});
    expect(confirmed.status).toBe(200);

    expect(await balances()).toEqual([
      { batch_number: 'B-LATE', on_hand: 17 },
      { batch_number: 'B-SOON', on_hand: 0 },
    ]);

    // The expiring-stock report is exact now: B-SOON is empty, so nothing is expiring soon.
    const expiring = await as().get('/api/v1/reports/expiring?days=60');
    expect(expiring.body.batches).toEqual([]);

    const reversed = await as().post(`/api/v1/dispatches/${draft.body.dispatch.id}/reverse`, {
      reason: 'Delivered to the wrong shop',
    });
    expect(reversed.status).toBe(200);
    expect(await balances()).toEqual([
      { batch_number: 'B-LATE', on_hand: 20 },
      { batch_number: 'B-SOON', on_hand: 15 },
    ]);
    await ledgerMatchesBalances();
  });
});

describe('the migration', () => {
  it('splits stock recorded before Stage 4 among the newest deliveries', async () => {
    // Back to just before the balances table, with stock recorded the old way.
    for (;;) {
      const [name] = await runMigrations(ownerDatabaseUrl, 'down', { quiet: true });
      if (!name || name === '20261021100000000_stock-balances') break;
    }
    const { rows: users } = await pools.owner.query<{ id: string }>('SELECT id FROM users LIMIT 1');
    const user = users[0]?.id;
    const batch = async (number: string, received: string, quantity: number) => {
      const { rows } = await pools.owner.query<{ id: string }>(
        `INSERT INTO stock_batches (product_id, quantity_received, received_date, batch_number,
                                    received_by)
         VALUES ($1, $2, $3, $4, $5) RETURNING id`,
        [product, quantity, received, number, user],
      );
      const id = rows[0]?.id;
      await pools.owner.query(
        `INSERT INTO stock_movements (product_id, batch_id, movement_type, quantity_delta,
                                      business_date, created_by)
         VALUES ($1, $2, 'receipt', $3, $4, $5)`,
        [product, id, quantity, received, user],
      );
    };
    const unbatched = (delta: number, type: string) =>
      pools.owner.query(
        `INSERT INTO stock_movements (product_id, movement_type, quantity_delta, business_date,
                                      created_by, reason)
         VALUES ($1, $2, $3, '2026-09-01', $4, 'Old correction')`,
        [product, type, delta, user],
      );
    await batch('OLD', '2026-01-01', 50);
    await batch('NEW', '2026-02-01', 30);
    await unbatched(-60, 'damage');
    await unbatched(15, 'adjustment');
    // 35 left: all 30 of the newest delivery, then 5 of the older one.

    await migrateTestDatabase();

    expect(await balances()).toEqual([
      { batch_number: 'NEW', on_hand: 30 },
      { batch_number: 'OLD', on_hand: 5 },
    ]);
    const { rows: numbers } = await pools.owner.query<{ movement_number: string }>(
      'SELECT movement_number FROM stock_movements ORDER BY occurred_at, id',
    );
    expect(numbers.map((row) => row.movement_number)).toEqual([
      'M0000001',
      'M0000002',
      'M0000003',
      'M0000004',
    ]);
    await ledgerMatchesBalances();

    // New movements carry on numbering.
    await receive(1, null, 'NEXT');
    const { rows: last } = await pools.owner.query<{ movement_number: string }>(
      'SELECT movement_number FROM stock_movements ORDER BY occurred_at DESC, id DESC LIMIT 1',
    );
    expect(last[0]?.movement_number).toBe('M0000005');
  });
});
