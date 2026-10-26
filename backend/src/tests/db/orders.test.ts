import { randomUUID } from 'node:crypto';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../../app.js';
import { testConfig } from '../test-config.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestProduct,
  createTestSubsidiary,
  createTestUser,
  receiveTestStock,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

// StockFlow Stage 5: subsidiary orders with expected, maximum and actual prices.
const pools = createTestPools();
const PASSWORD = '4826';
let app: Express;
const tokens: Record<string, string> = {};
let subA: string;
let subB: string;
let bbq: string;
let cheese: string;
const units: Record<string, string> = {};

const as = (who: string, target = () => app) => {
  const auth = { Authorization: `Bearer ${tokens[who]}` };
  return {
    get: (path: string) => request(target()).get(path).set(auth),
    post: (path: string, body: object = {}) => request(target()).post(path).set(auth).send(body),
    put: (path: string, body: object) => request(target()).put(path).set(auth).send(body),
  };
};

const line = (overrides: object = {}) => ({
  productId: bbq,
  unitId: units.pack,
  requestedQuantity: 3,
  expectedUnitPrice: '0.10',
  maximumUnitPrice: '0.15',
  ...overrides,
});

const orderBody = (overrides: object = {}) => ({
  idempotencyKey: randomUUID(),
  requiredDate: null,
  notes: null,
  lines: [line()],
  ...overrides,
});

/** A draft created by Avondale's manager. */
async function draft(overrides: object = {}, who = 'manager-a') {
  const response = await as(who).post('/api/v1/orders', orderBody(overrides));
  expect(response.status, JSON.stringify(response.body)).toBe(201);
  return response.body.order;
}

/** A submitted order from Avondale. */
async function submitted(overrides: object = {}) {
  const order = await draft(overrides);
  const response = await as('manager-a').post(`/api/v1/orders/${order.id}/submit`);
  expect(response.status, JSON.stringify(response.body)).toBe(200);
  return response.body.order;
}

/** Finance sets an actual price on every line. */
async function price(order: { id: string; lines: { id: string }[] }, actual: string) {
  const response = await as('finance').put(`/api/v1/orders/${order.id}/prices`, {
    prices: order.lines.map((l) => ({ itemId: l.id, actualUnitPrice: actual })),
  });
  expect(response.status, JSON.stringify(response.body)).toBe(200);
  return response.body.order;
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
  app = createDbTestApp(pools.app);
  subA = await createTestSubsidiary(pools.owner, 'SUB-A', 'Avondale Shop');
  subB = await createTestSubsidiary(pools.owner, 'SUB-B', 'Borrowdale Shop');
  // An HQ role that may review and approve but not approve price exceptions.
  await pools.owner.query(`
    INSERT INTO roles (code, name, description, organisation_type)
    VALUES ('hq_order_clerk', 'HQ Order Clerk', 'Test role', 'HQ')
    ON CONFLICT (code) DO NOTHING;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, p FROM roles r, unnest(ARRAY['order.view', 'order.price', 'order.approve']) p
    WHERE r.code = 'hq_order_clerk'
    ON CONFLICT DO NOTHING;`);
  const users: [string, object][] = [
    ['admin', { role: 'admin' }],
    ['finance', { role: 'accounts' }],
    ['sales', { role: 'salesperson' }],
    ['store', { role: 'storekeeper' }],
    ['clerk', { roleCodes: ['hq_order_clerk'] }],
    ['manager-a', { roleCodes: ['subsidiary_manager'], organisationId: subA }],
    ['manager-b', { roleCodes: ['subsidiary_manager'], organisationId: subB }],
    ['keeper-a', { roleCodes: ['subsidiary_storekeeper'], organisationId: subA }],
  ];
  for (const [username, options] of users) {
    await createTestUser(pools.app, { username, password: PASSWORD, ...options });
    tokens[username] = await signIn(app, username, PASSWORD);
  }
  bbq = await createTestProduct(pools.owner);
  cheese = await createTestProduct(pools.owner, { sku: 'PC-CH-S', flavour: 'Cheese' });
  const { rows } = await pools.owner.query<{ id: string; code: string }>(
    'SELECT id, code FROM units',
  );
  for (const unit of rows) units[unit.code] = unit.id;
});
afterAll(() => pools.close());

describe('order totals', () => {
  it('are exact decimals worked out by the server (0.10 x 3 = 0.30)', async () => {
    const order = await draft({
      lines: [
        line(),
        line({
          productId: cheese,
          requestedQuantity: 7,
          expectedUnitPrice: '0.35',
          maximumUnitPrice: '0.40',
        }),
      ],
      // Totals sent by the app are ignored.
      expectedTotal: '999.00',
    });
    expect(order).toMatchObject({
      orderNumber: expect.stringMatching(/^ORD\d{6}$/),
      status: 'DRAFT',
      organisation: { id: subA, code: 'SUB-A' },
      currency: 'USD',
      expectedTotal: '2.75', // 0.30 + 2.45
      maximumTotal: '3.25', // 0.45 + 2.80
      actualTotal: null,
      priceException: false,
    });
    expect(order.lines.map((l: { expectedLineTotal: string }) => l.expectedLineTotal)).toEqual([
      '0.30',
      '2.45',
    ]);
    expect(order.lines[0].maximumLineTotal).toBe('0.45');

    const sub = await as('manager-a').post(`/api/v1/orders/${order.id}/submit`);
    const priced = await as('finance').put(`/api/v1/orders/${order.id}/prices`, {
      prices: [
        { itemId: sub.body.order.lines[0].id, actualUnitPrice: '0.12' },
        { itemId: sub.body.order.lines[1].id, actualUnitPrice: '0.33' },
      ],
    });
    expect(priced.body.order).toMatchObject({ actualTotal: '2.67', status: 'UNDER_REVIEW' });
  });

  it('refuse a maximum below the expected price, and cartons count in packs', async () => {
    const bad = await as('manager-a').post(
      '/api/v1/orders',
      orderBody({ lines: [line({ maximumUnitPrice: '0.09' })] }),
    );
    expect(bad.body.error.details).toEqual([
      { field: 'lines.0.maximumUnitPrice', message: 'Must be at least the expected price' },
    ]);

    await as('admin').put(`/api/v1/products/${bbq}/conversions`, {
      conversions: [{ unitId: units.carton, baseQuantity: 24 }],
    });
    const cartons = await draft({
      lines: [
        line({
          unitId: units.carton,
          requestedQuantity: 2,
          expectedUnitPrice: '10.20',
          maximumUnitPrice: '11.00',
        }),
      ],
    });
    expect(cartons.lines[0]).toMatchObject({
      unit: { code: 'carton' },
      baseQuantity: 48,
      expectedLineTotal: '20.40',
    });
  });
});

describe('price exceptions', () => {
  it('block approval unless an authorised user approves with a comment', async () => {
    const order = await price(await submitted(), '0.20'); // maximum is 0.15
    expect(order.priceException).toBe(true);
    expect(order.lines[0]).toMatchObject({ priceException: true, actualLineTotal: '0.60' });

    const byClerk = await as('clerk').post(`/api/v1/orders/${order.id}/approve`, {
      comment: 'Looks fine',
    });
    expect(byClerk.status).toBe(403);
    expect(byClerk.body.error.code).toBe('PRICE_EXCEPTION_NOT_ALLOWED');

    const noComment = await as('finance').post(`/api/v1/orders/${order.id}/approve`);
    expect(noComment.status).toBe(400);
    expect(noComment.body.error.details[0].field).toBe('comment');

    const approved = await as('finance').post(`/api/v1/orders/${order.id}/approve`, {
      comment: 'Supplier cost went up; agreed with the branch',
    });
    expect(approved.status).toBe(200);
    expect(approved.body.order).toMatchObject({
      status: 'APPROVED',
      priceExceptionApproved: true,
      decidedBy: { fullName: 'Test finance' },
    });
    const [entry] = await auditEntries(pools.owner, 'order.approved');
    expect(entry?.details).toMatchObject({ priceExceptionApproved: true });
  });

  it('do not arise at or below the maximum, so the clerk may approve without a comment', async () => {
    const order = await price(await submitted(), '0.15');
    expect(order.priceException).toBe(false);
    const approved = await as('clerk').post(`/api/v1/orders/${order.id}/approve`);
    expect(approved.body.order).toMatchObject({
      status: 'APPROVED',
      priceExceptionApproved: false,
    });
  });

  it('cannot be approved before every line is priced', async () => {
    const order = await submitted({ lines: [line(), line({ productId: cheese })] });
    const early = await as('finance').post(`/api/v1/orders/${order.id}/approve`);
    expect(early.body.error.code).toBe('PRICES_MISSING');
    await as('finance').put(`/api/v1/orders/${order.id}/prices`, {
      prices: [{ itemId: order.lines[0].id, actualUnitPrice: '0.12' }],
    });
    const half = await as('finance').post(`/api/v1/orders/${order.id}/approve`);
    expect(half.body.error.code).toBe('PRICES_MISSING');
  });
});

describe('submitted values', () => {
  it('are kept as submitted, and every price change is logged', async () => {
    const order = await submitted();
    await price(order, '0.12');
    const again = await as('finance').put(`/api/v1/orders/${order.id}/prices`, {
      prices: [{ itemId: order.lines[0].id, actualUnitPrice: '0.14', comment: 'Rounded up' }],
    });
    const result = again.body.order;
    expect(result.lines[0]).toMatchObject({
      requestedQuantity: 3,
      expectedUnitPrice: '0.10',
      maximumUnitPrice: '0.15',
      actualUnitPrice: '0.14',
    });
    expect(
      result.changes.map(
        (c: { oldValue: string | null; newValue: string; comment: string | null }) => [
          c.oldValue,
          c.newValue,
          c.comment,
        ],
      ),
    ).toEqual([
      [null, '0.12', null],
      ['0.12', '0.14', 'Rounded up'],
    ]);
    expect(result.changes[0].changedBy.fullName).toBe('Test finance');

    // The subsidiary cannot change its order any more, and nor can anyone in the database.
    const edit = await as('manager-a').put(`/api/v1/orders/${order.id}`, orderBody());
    expect(edit.body.error.code).toBe('ORDER_WRONG_STATUS');
    for (const sql of [
      'UPDATE order_items SET requested_quantity = 99',
      'UPDATE order_items SET expected_unit_price = 0.01',
      'DELETE FROM order_items',
      "UPDATE orders SET notes = 'changed'",
      'DELETE FROM orders',
      'UPDATE order_item_changes SET new_value = $$9.99$$',
      'DELETE FROM order_status_history',
    ]) {
      await expect(pools.app.query(sql), sql).rejects.toThrow();
    }
    // Totals are generated by the database and cannot be written.
    await expect(
      pools.owner.query('UPDATE order_items SET expected_line_total = 1'),
    ).rejects.toThrow();
  });

  it('keep a full status history with who, when and why', async () => {
    const order = await submitted();
    await price(order, '0.12');
    await as('finance').post(`/api/v1/orders/${order.id}/reject`, { comment: 'Out of season' });
    const { body } = await as('manager-a').get(`/api/v1/orders/${order.id}`);
    expect(
      body.order.history.map(
        (h: { fromStatus: string | null; toStatus: string; comment: string | null }) => [
          h.fromStatus,
          h.toStatus,
          h.comment,
        ],
      ),
    ).toEqual([
      [null, 'DRAFT', null],
      ['DRAFT', 'SUBMITTED', null],
      ['SUBMITTED', 'UNDER_REVIEW', null],
      ['UNDER_REVIEW', 'REJECTED', 'Out of season'],
    ]);
    expect(body.order.decisionComment).toBe('Out of season');
  });
});

describe('organisation separation', () => {
  it("keeps one subsidiary out of another's orders", async () => {
    const order = await draft();
    const path = `/api/v1/orders/${order.id}`;
    expect((await as('manager-b').get(path)).status).toBe(404);
    expect((await as('manager-b').get(`${path}/pdf`)).status).toBe(404);
    expect(
      (await as('manager-b').put(path, orderBody({ lines: [line({ requestedQuantity: 9 })] })))
        .status,
    ).toBe(404);
    expect((await as('manager-b').post(`${path}/submit`)).status).toBe(404);
    expect((await as('manager-b').post(`${path}/cancel`, { reason: 'Not mine' })).status).toBe(404);
    // ...and nothing was changed behind the 404s.
    const { rows } = await pools.owner.query(
      'SELECT o.status, o.cancel_reason, count(i.*)::int AS lines, max(i.requested_quantity) AS qty FROM orders o JOIN order_items i ON i.order_id = o.id GROUP BY o.id',
    );
    expect(rows).toEqual([{ status: 'DRAFT', cancel_reason: null, lines: 1, qty: 3 }]);
    expect(await auditEntries(pools.owner, 'order.updated')).toHaveLength(0);
    expect((await as('manager-b').get('/api/v1/orders')).body.total).toBe(0);
    expect((await as('manager-b').get(`/api/v1/orders?organisationId=${subA}`)).status).toBe(404);
    expect((await as('manager-a').get('/api/v1/orders')).body.total).toBe(1);

    // The ordering organisation comes from the user, never from the request.
    const forOther = await as('manager-a').post(
      '/api/v1/orders',
      orderBody({ organisationId: subB }),
    );
    expect(forOther.status).toBe(404);
    expect((await pools.owner.query('SELECT 1 FROM orders')).rowCount).toBe(1);

    // A subsidiary never sees the Head Office's stock; the Head Office does.
    expect((await as('manager-a').get(path)).body.order.lines[0].hqAvailable).toBeUndefined();
    await receiveTestStock(pools.app, { productId: bbq, quantity: 40 });
    expect((await as('finance').get(path)).body.order.lines[0].hqAvailable).toBe(40);
  });

  it('lets only the right people create, review and decide', async () => {
    expect((await as('keeper-a').get('/api/v1/orders')).status).toBe(403);
    expect((await as('store').get('/api/v1/orders')).status).toBe(403);
    expect((await as('sales').post('/api/v1/orders', orderBody())).status).toBe(403);
    const order = await submitted();
    expect((await as('sales').get(`/api/v1/orders/${order.id}`)).status).toBe(200);
    expect((await as('sales').post(`/api/v1/orders/${order.id}/review`)).status).toBe(403);
    expect((await as('manager-a').post(`/api/v1/orders/${order.id}/approve`)).status).toBe(403);
    // The system administrator alone cannot approve prices (only with the finance role).
    const adminOnly = 'sysadmin';
    await createTestUser(pools.app, {
      username: adminOnly,
      password: PASSWORD,
      roleCodes: ['system_admin'],
    });
    tokens[adminOnly] = await signIn(app, adminOnly, PASSWORD);
    expect((await as(adminOnly).get(`/api/v1/orders/${order.id}`)).status).toBe(200);
    expect((await as(adminOnly).post(`/api/v1/orders/${order.id}/approve`)).status).toBe(403);
    // The Head Office must say which subsidiary orders (if a role ever lets it create orders).
    expect((await as('finance').post('/api/v1/orders', orderBody())).status).toBe(403);
  });
});

describe('status changes', () => {
  it('follow the allowed steps only', async () => {
    const order = await draft();
    const at = (action: string, body: object = {}, who = 'finance') =>
      as(who).post(`/api/v1/orders/${order.id}/${action}`, body);

    expect((await at('approve')).body.error.code).toBe('ORDER_WRONG_STATUS'); // a draft
    expect((await at('reject', { comment: 'No' })).status).toBe(400); // comment too short
    expect((await at('reject', { comment: 'Not now' })).body.error.code).toBe('ORDER_WRONG_STATUS');
    expect((await at('review')).body.error.code).toBe('ORDER_WRONG_STATUS');

    await at('submit', {}, 'manager-a');
    await at('review');
    // Once under review, the subsidiary can no longer cancel or change it.
    expect((await at('cancel', { reason: 'Changed mind' }, 'manager-a')).body.error.code).toBe(
      'ORDER_WRONG_STATUS',
    );
    expect((await at('submit', {}, 'manager-a')).body.error.code).toBe('ORDER_WRONG_STATUS');

    const rejected = await at('reject', { comment: 'Too late in the month' });
    expect(rejected.body.order.status).toBe('REJECTED');
    expect((await at('approve')).body.error.code).toBe('ORDER_WRONG_STATUS');

    // The database refuses skipped steps too.
    const other = await draft();
    await expect(
      pools.app.query(
        `UPDATE orders SET status = 'APPROVED', submitted_at = now(), decided_at = now() WHERE id = $1`,
        [other.id],
      ),
    ).rejects.toThrow(/cannot go from DRAFT to APPROVED/);
  });

  it('let the subsidiary cancel a draft or a submitted order, with a reason', async () => {
    const order = await submitted();
    const noReason = await as('manager-a').post(`/api/v1/orders/${order.id}/cancel`, {});
    expect(noReason.status).toBe(400);
    const cancelled = await as('manager-a').post(`/api/v1/orders/${order.id}/cancel`, {
      reason: 'Ordered twice',
    });
    expect(cancelled.body.order).toMatchObject({
      status: 'CANCELLED',
      cancelReason: 'Ordered twice',
    });
  });

  it('need enough Head Office stock to approve when backorders are switched off', async () => {
    const strict = createApp(
      { ...testConfig, orders: { allowBackorders: false } },
      { db: pools.app, checkDatabase: async () => true },
    );
    const order = await price(
      await submitted({ lines: [line({ requestedQuantity: 30 })] }),
      '0.12',
    );
    await receiveTestStock(pools.app, { productId: bbq, quantity: 20 });
    const short = await as('finance', () => strict).post(`/api/v1/orders/${order.id}/approve`);
    expect(short.status).toBe(409);
    expect(short.body.error.message).toContain('PC-BBQ-S (20 of 30)');

    // With backorders allowed (the default), the rest waits.
    const approved = await as('finance').post(`/api/v1/orders/${order.id}/approve`);
    expect(approved.body.order.status).toBe('APPROVED');
  });
});

describe('repeated requests', () => {
  it('never create a second order', async () => {
    const body = orderBody();
    const first = await as('manager-a').post('/api/v1/orders', body);
    const second = await as('manager-a').post('/api/v1/orders', body);
    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect(second.body).toMatchObject({ replayed: true, order: { id: first.body.order.id } });

    // The same request sent several times at once.
    const burst = orderBody();
    const results = await Promise.all(
      Array.from({ length: 6 }, () => as('manager-a').post('/api/v1/orders', burst)),
    );
    expect(results.map((r) => r.status).sort()).toEqual([200, 200, 200, 200, 200, 201]);
    expect(new Set(results.map((r) => r.body.order.id)).size).toBe(1);
    expect((await pools.owner.query('SELECT 1 FROM orders')).rowCount).toBe(2);
  });

  it('submit once, however often the button is pressed', async () => {
    const order = await draft();
    const presses = await Promise.all(
      Array.from({ length: 4 }, () => as('manager-a').post(`/api/v1/orders/${order.id}/submit`)),
    );
    expect(presses.every((p) => p.status === 200)).toBe(true);
    expect(presses.filter((p) => p.body.alreadySubmitted === false)).toHaveLength(1);
    expect(await auditEntries(pools.owner, 'order.submitted')).toHaveLength(1);
  });
});

describe('the order sheet', () => {
  it('is a PDF named after the order', async () => {
    const order = await price(await submitted(), '0.12');
    const binary = (res: request.Response, done: (error: Error | null, body: Buffer) => void) => {
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => done(null, Buffer.concat(chunks)));
    };
    const response = await request(app)
      .get(`/api/v1/orders/${order.id}/pdf`)
      .set('Authorization', `Bearer ${tokens['manager-a']}`)
      .buffer(true)
      .parse(binary);
    expect(response.status).toBe(200);
    expect(response.headers['content-type']).toBe('application/pdf');
    expect(response.headers['content-disposition']).toBe(
      `inline; filename="${order.orderNumber}.pdf"`,
    );
    expect((response.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');
  });
});
