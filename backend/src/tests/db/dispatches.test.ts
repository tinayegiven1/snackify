import type { Express } from 'express';
import pg from 'pg';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../../modules/auth/roles.js';
import { businessToday } from '../../utils/dates.js';
import {
  appDatabaseUrl,
  auditEntries,
  createDbTestApp,
  createTestPools,
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
const tokens = {} as Record<Role, string>;
let bbq: string; // Potato Crisps BBQ, default price 0.50, 100 in stock
let cheese: string; // Maize Puffs Cheese, default price 0.50, 50 in stock
let limited: string; // customer with a credit limit of 10.00
let unlimited: string; // customer without a credit limit

const as = (role: Role) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${tokens[role]}`),
  post: (path: string, body: object = {}) =>
    request(app).post(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
  put: (path: string, body: object) =>
    request(app).put(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
});

function tomorrow(): string {
  const date = new Date(`${businessToday('Africa/Harare')}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
}

async function draft(
  items: { productId: string; quantity: number; unitPrice?: string }[],
  customerId = unlimited,
  extra: object = {},
) {
  const response = await as('salesperson').post('/api/v1/dispatches', {
    customerId,
    items,
    ...extra,
  });
  if (response.status !== 201) throw new Error(`Draft failed: ${JSON.stringify(response.body)}`);
  return response.body.dispatch as { id: string; dispatchNumber: string };
}

const confirm = (id: string, body: object = {}, role: Role = 'storekeeper') =>
  as(role).post(`/api/v1/dispatches/${id}/confirm`, body);

async function onHand(productId: string): Promise<number> {
  const { rows } = await pools.owner.query<{ quantity_on_hand: number }>(
    'SELECT quantity_on_hand FROM stock_balances WHERE product_id = $1',
    [productId],
  );
  return rows[0]?.quantity_on_hand ?? NaN;
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
  await pools.owner.query('ALTER SEQUENCE dispatch_number_seq RESTART');
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
  bbq = await createTestProduct(pools.owner);
  cheese = await createTestProduct(pools.owner, {
    sku: 'MP-CH-S',
    name: 'Maize Puffs',
    flavour: 'Cheese',
  });
  for (const [productId, quantity] of [
    [bbq, 100],
    [cheese, 50],
  ] as const) {
    await as('storekeeper').post('/api/v1/stock/receipts', { productId, quantity });
  }
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO customers (code, name, credit_limit) VALUES
       ('C0001', 'Avondale Tuckshop', 10.00), ('C0002', 'Mabelreign Grocers', NULL)
     RETURNING id`,
  );
  [limited, unlimited] = rows.map((row) => row.id) as [string, string];
});
afterAll(() => pools.close());

describe('drafts', () => {
  it('get a number, default prices and totals, without touching stock', async () => {
    const response = await as('salesperson').post('/api/v1/dispatches', {
      customerId: unlimited,
      items: [
        { productId: bbq, quantity: 12 },
        { productId: cheese, quantity: 5, unitPrice: '0.25' },
      ],
    });

    expect(response.status).toBe(201);
    const dispatch = response.body.dispatch;
    expect(dispatch).toMatchObject({
      dispatchNumber: 'D000001',
      status: 'draft',
      dispatchDate: businessToday('Africa/Harare'),
      customer: { code: 'C0002', name: 'Mabelreign Grocers' },
      totalQuantity: 17,
      totalValue: '7.25',
      createdBy: { fullName: 'Test salesperson' },
    });
    expect(
      dispatch.items.map((i: { quantity: number; unitPrice: string; lineTotal: string }) => [
        i.quantity,
        i.unitPrice,
        i.lineTotal,
      ]),
    ).toEqual([
      [5, '0.25', '1.25'],
      [12, '0.50', '6.00'],
    ]);
    expect(await onHand(bbq)).toBe(100);
  });

  it('explain what is wrong with an invalid draft', async () => {
    const post = (body: object) => as('salesperson').post('/api/v1/dispatches', body);
    const fields = (response: request.Response) =>
      response.body.error.details.map((d: { field: string }) => d.field);

    expect(fields(await post({ customerId: unlimited, items: [] }))).toEqual(['items']);
    expect(
      fields(
        await post({
          customerId: unlimited,
          items: [
            { productId: bbq, quantity: 1 },
            { productId: bbq, quantity: 2 },
          ],
        }),
      ),
    ).toEqual(['items']);
    expect(
      fields(
        await post({
          customerId: unlimited,
          items: [{ productId: bbq, quantity: 0, unitPrice: '-1' }],
        }),
      ),
    ).toEqual(['items.0.quantity', 'items.0.unitPrice']);

    const unknownCustomer = await post({
      customerId: '00000000-0000-4000-8000-000000000000',
      items: [{ productId: bbq, quantity: 1 }],
    });
    expect(unknownCustomer.status).toBe(404);

    await pools.owner.query('UPDATE products SET is_active = false WHERE id = $1', [cheese]);
    const inactiveProduct = await post({
      customerId: unlimited,
      items: [{ productId: cheese, quantity: 1 }],
    });
    expect(inactiveProduct.status).toBe(409);
    expect(fields(inactiveProduct)).toEqual(['items.0.productId']);
  });

  it('can be edited by replacing the lines, keeping the number', async () => {
    const created = await draft([{ productId: bbq, quantity: 12 }]);

    const response = await as('storekeeper').put(`/api/v1/dispatches/${created.id}`, {
      customerId: limited,
      notes: 'Deliver before noon',
      items: [{ productId: cheese, quantity: 3 }],
    });

    expect(response.status).toBe(200);
    expect(response.body.dispatch).toMatchObject({
      dispatchNumber: 'D000001',
      notes: 'Deliver before noon',
      customer: { name: 'Avondale Tuckshop' },
      totalQuantity: 3,
    });
    expect(response.body.dispatch.items).toHaveLength(1);
  });

  it('can be cancelled with a reason, and then cannot be edited or confirmed', async () => {
    const created = await draft([{ productId: bbq, quantity: 12 }]);

    const cancelled = await as('salesperson').post(`/api/v1/dispatches/${created.id}/cancel`, {
      reason: 'Customer changed their order',
    });
    expect(cancelled.body.dispatch).toMatchObject({
      status: 'cancelled',
      cancelReason: 'Customer changed their order',
      cancelledBy: { fullName: 'Test salesperson' },
    });

    const edit = await as('salesperson').put(`/api/v1/dispatches/${created.id}`, {
      customerId: unlimited,
      items: [{ productId: bbq, quantity: 1 }],
    });
    expect(edit.status).toBe(409);
    expect(edit.body.error.code).toBe('DISPATCH_NOT_DRAFT');
    expect((await confirm(created.id)).status).toBe(409);
    expect(await onHand(bbq)).toBe(100);
  });

  it('are created by salespeople, storekeepers and admins, but not accounts staff', async () => {
    const response = await as('accounts').post('/api/v1/dispatches', {
      customerId: unlimited,
      items: [{ productId: bbq, quantity: 1 }],
    });
    expect(response.status).toBe(403);
  });
});

describe('confirming', () => {
  it('decreases stock by exactly the quantities dispatched', async () => {
    const created = await draft([
      { productId: bbq, quantity: 12 },
      { productId: cheese, quantity: 5 },
    ]);

    const response = await confirm(created.id);

    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({
      alreadyConfirmed: false,
      dispatch: { status: 'confirmed', confirmedBy: { fullName: 'Test storekeeper' } },
    });
    expect(await onHand(bbq)).toBe(88);
    expect(await onHand(cheese)).toBe(45);

    const { rows } = await pools.owner.query(
      `SELECT movement_type, quantity_delta, reference FROM stock_movements
       WHERE movement_type = 'dispatch' ORDER BY quantity_delta`,
    );
    expect(rows).toEqual([
      { movement_type: 'dispatch', quantity_delta: -12, reference: 'D000001' },
      { movement_type: 'dispatch', quantity_delta: -5, reference: 'D000001' },
    ]);
    const [entry] = await auditEntries(pools.owner, 'dispatch.confirmed');
    expect(entry?.details).toEqual({
      dispatchNumber: 'D000001',
      totalValue: '8.50',
      overCreditLimit: false,
    });
  });

  it('rejects a dispatch larger than the stock and changes nothing', async () => {
    const created = await draft([{ productId: bbq, quantity: 120 }]);

    const response = await confirm(created.id);

    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('INSUFFICIENT_STOCK');
    expect(response.body.error.message).toBe(
      'Not enough stock for: Potato Crisps — BBQ — Small (need 120, have 100).',
    );
    expect(await onHand(bbq)).toBe(100);
    expect(
      (await as('storekeeper').get(`/api/v1/dispatches/${created.id}`)).body.dispatch.status,
    ).toBe('draft');
  });

  /** An app with enough connections that simultaneous requests really run in parallel. */
  async function withBusyApp(work: (busyApp: Express) => Promise<void>) {
    const busyPool = new pg.Pool({ connectionString: appDatabaseUrl, max: 12 });
    try {
      await work(createDbTestApp(busyPool));
    } finally {
      await busyPool.end();
    }
  }

  const confirmOn = (busyApp: Express, id: string) =>
    request(busyApp)
      .post(`/api/v1/dispatches/${id}/confirm`)
      .set('Authorization', `Bearer ${tokens.storekeeper}`)
      .send({});

  it('deducts stock only once when the same confirmation is sent repeatedly', async () => {
    await withBusyApp(async (busyApp) => {
      // Several rounds, so a missing lock is very unlikely to go unnoticed by luck.
      for (let round = 1; round <= 3; round++) {
        const created = await draft([{ productId: bbq, quantity: 10 }]);
        // e.g. a double tap, or the app retrying after a slow network.
        const results = await Promise.all(
          Array.from({ length: 8 }, () => confirmOn(busyApp, created.id)),
        );

        expect(
          results.map((r) => r.status),
          `round ${round}`,
        ).toEqual(Array(8).fill(200));
        expect(
          results.filter((r) => r.body.alreadyConfirmed === false),
          `round ${round}`,
        ).toHaveLength(1);
        expect(await onHand(bbq), `round ${round}`).toBe(100 - 10 * round);
      }
    });
  });

  it('cannot oversell when dispatches to different customers are confirmed at once', async () => {
    // A different customer for each dispatch, so only the product lock keeps them apart.
    const { rows } = await pools.owner.query<{ id: string }>(
      `INSERT INTO customers (code, name)
       SELECT 'BUSY' || n, 'Busy Customer ' || n FROM generate_series(1, 30) AS n
       RETURNING id`,
    );

    await withBusyApp(async (busyApp) => {
      for (let round = 0; round < 3; round++) {
        if (round > 0) {
          await as('storekeeper').post('/api/v1/stock/receipts', { productId: bbq, quantity: 90 });
        }
        const drafts = [];
        for (const row of rows.slice(round * 10, round * 10 + 10)) {
          drafts.push(await draft([{ productId: bbq, quantity: 15 }], row.id));
        }
        const results = await Promise.all(drafts.map((d) => confirmOn(busyApp, d.id)));
        const statuses = results.map((r) => r.status);

        // 100 packs cover six dispatches of 15; the other four must be refused.
        expect(
          statuses.filter((s) => s === 200),
          `round ${round}`,
        ).toHaveLength(6);
        expect(
          statuses.filter((s) => s === 409),
          `round ${round}`,
        ).toHaveLength(4);
        expect(await onHand(bbq), `round ${round}`).toBe(10);
      }
    });
  });

  it('is allowed for storekeepers and admins only', async () => {
    const created = await draft([{ productId: bbq, quantity: 1 }]);
    expect((await confirm(created.id, {}, 'salesperson')).status).toBe(403);
    expect((await confirm(created.id, {}, 'accounts')).status).toBe(403);
    expect((await confirm(created.id, {}, 'admin')).status).toBe(200);
  });

  it('refuses a dispatch dated in the future', async () => {
    const created = await draft([{ productId: bbq, quantity: 1 }], unlimited, {
      dispatchDate: tomorrow(),
    });
    const response = await confirm(created.id);

    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('DISPATCH_DATE_IN_FUTURE');
  });

  it('keeps the agreed price when the product price changes later', async () => {
    const created = await draft([{ productId: bbq, quantity: 10 }]);
    await confirm(created.id);
    await pools.owner.query('UPDATE products SET default_price = 0.99 WHERE id = $1', [bbq]);

    const response = await as('accounts').get(`/api/v1/dispatches/${created.id}`);
    expect(response.body.dispatch.items[0]).toMatchObject({ unitPrice: '0.50', lineTotal: '5.00' });
  });

  it('cannot be edited, cancelled or deleted afterwards, even directly in the database', async () => {
    const created = await draft([{ productId: bbq, quantity: 12 }]);
    await confirm(created.id);

    const edit = await as('admin').put(`/api/v1/dispatches/${created.id}`, {
      customerId: unlimited,
      items: [{ productId: bbq, quantity: 1 }],
    });
    expect(edit.status).toBe(409);
    expect(
      (await as('admin').post(`/api/v1/dispatches/${created.id}/cancel`, { reason: 'Oops' }))
        .status,
    ).toBe(409);

    for (const sql of [
      `UPDATE dispatches SET notes = 'changed' WHERE id = '${created.id}'`,
      `UPDATE dispatch_items SET quantity = 1 WHERE dispatch_id = '${created.id}'`,
      `DELETE FROM dispatch_items WHERE dispatch_id = '${created.id}'`,
    ]) {
      expect((await pgErrorOf(pools.app.query(sql))).code, sql).toBe(PG.checkViolation);
    }
    expect((await pgErrorOf(pools.app.query('DELETE FROM dispatches'))).code).toBe(
      PG.insufficientPrivilege,
    );
    expect(await onHand(bbq)).toBe(88);
  });
});

describe('credit limit warnings', () => {
  it('warn before going over the limit, and record an override', async () => {
    const first = await draft([{ productId: bbq, quantity: 12 }], limited); // 6.00
    expect((await confirm(first.id)).status).toBe(200);

    const second = await draft([{ productId: bbq, quantity: 10 }], limited); // 5.00
    const preview = await as('storekeeper').get(`/api/v1/dispatches/${second.id}`);
    expect(preview.body.dispatch.creditCheck).toEqual({
      creditLimit: '10.00',
      balanceBefore: '6.00',
      dispatchTotal: '5.00',
      balanceAfter: '11.00',
      exceedsLimit: true,
    });

    const refused = await confirm(second.id);
    expect(refused.status).toBe(409);
    expect(refused.body.error.code).toBe('CREDIT_LIMIT_EXCEEDED');
    expect(refused.body.error.message).toContain(
      "would take Avondale Tuckshop's unpaid balance to 11.00, over their credit limit of 10.00",
    );
    expect(await onHand(bbq)).toBe(88);

    const overridden = await confirm(second.id, { acknowledgeCreditLimit: true });
    expect(overridden.status).toBe(200);
    expect(overridden.body.dispatch.confirmedOverCreditLimit).toBe(true);
    expect(await onHand(bbq)).toBe(78);

    const entries = await auditEntries(pools.owner, 'dispatch.confirmed');
    expect(entries[1]?.details).toEqual({
      dispatchNumber: 'D000002',
      totalValue: '5.00',
      overCreditLimit: true,
      creditLimit: '10.00',
      balanceAfter: '11.00',
    });
  });

  it('never appear for customers without a limit', async () => {
    const big = await draft([{ productId: bbq, quantity: 100 }], unlimited);
    expect((await confirm(big.id)).status).toBe(200);
  });

  it('ignore cancelled and reversed dispatches when working out the balance', async () => {
    const first = await draft([{ productId: bbq, quantity: 16 }], limited); // 8.00
    await confirm(first.id);
    await as('admin').post(`/api/v1/dispatches/${first.id}/reverse`, {
      reason: 'Returned unopened',
    });
    const cancelled = await draft([{ productId: bbq, quantity: 16 }], limited);
    await as('salesperson').post(`/api/v1/dispatches/${cancelled.id}/cancel`, {
      reason: 'Not needed',
    });

    const next = await draft([{ productId: bbq, quantity: 16 }], limited);
    const preview = await as('storekeeper').get(`/api/v1/dispatches/${next.id}`);
    expect(preview.body.dispatch.creditCheck).toMatchObject({
      balanceBefore: '0.00',
      exceedsLimit: false,
    });
  });
});

describe('reversing', () => {
  it('puts the stock back and keeps both entries in the history', async () => {
    const created = await draft([{ productId: bbq, quantity: 12 }]);
    await confirm(created.id);

    const response = await as('admin').post(`/api/v1/dispatches/${created.id}/reverse`, {
      reason: 'Delivered to the wrong shop',
    });

    expect(response.status).toBe(200);
    expect(response.body.dispatch).toMatchObject({
      status: 'reversed',
      reversalReason: 'Delivered to the wrong shop',
      reversedBy: { fullName: 'Test admin' },
    });
    expect(await onHand(bbq)).toBe(100);

    const { rows } = await pools.owner.query<{
      movement_type: string;
      quantity_delta: number;
      reverses_original: boolean;
    }>(
      `SELECT m.movement_type, m.quantity_delta,
              m.reverses_movement_id = (SELECT id FROM stock_movements WHERE movement_type = 'dispatch')
                AS reverses_original
       FROM stock_movements m WHERE m.reference = 'D000001' ORDER BY m.occurred_at, m.quantity_delta`,
    );
    expect(rows).toEqual([
      { movement_type: 'dispatch', quantity_delta: -12, reverses_original: null },
      { movement_type: 'reversal', quantity_delta: 12, reverses_original: true },
    ]);
    expect(await auditEntries(pools.owner, 'dispatch.reversed')).toHaveLength(1);
  });

  it('is for admins only, needs a reason, and happens at most once', async () => {
    const created = await draft([{ productId: bbq, quantity: 12 }]);
    await confirm(created.id);
    const reverse = (role: Role, body: object) =>
      as(role).post(`/api/v1/dispatches/${created.id}/reverse`, body);

    expect((await reverse('storekeeper', { reason: 'Mistake' })).status).toBe(403);
    expect((await reverse('admin', { reason: ' ' })).status).toBe(400);
    expect((await reverse('admin', { reason: 'Mistake' })).status).toBe(200);

    const again = await reverse('admin', { reason: 'Mistake' });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('DISPATCH_NOT_CONFIRMED');
    expect(await onHand(bbq)).toBe(100);
  });
});

describe('listing', () => {
  it('shows dispatches newest first, filtered by status, customer or search', async () => {
    const a = await draft([{ productId: bbq, quantity: 2 }], limited);
    await draft([{ productId: cheese, quantity: 3 }], unlimited);
    await confirm(a.id);

    const all = await as('accounts').get('/api/v1/dispatches');
    expect(all.body.total).toBe(2);
    expect(all.body.dispatches[0]).toMatchObject({
      dispatchNumber: 'D000002',
      status: 'draft',
      lineCount: 1,
      totalQuantity: 3,
      totalValue: '1.50',
      customer: { name: 'Mabelreign Grocers' },
    });

    const confirmed = await as('accounts').get('/api/v1/dispatches?status=confirmed');
    expect(
      confirmed.body.dispatches.map((d: { dispatchNumber: string }) => d.dispatchNumber),
    ).toEqual(['D000001']);
    const byCustomer = await as('accounts').get(`/api/v1/dispatches?customerId=${unlimited}`);
    expect(byCustomer.body.total).toBe(1);
    expect((await as('accounts').get('/api/v1/dispatches?q=avondale')).body.total).toBe(1);
    expect((await as('accounts').get('/api/v1/dispatches?q=D000002')).body.total).toBe(1);
  });
});
