import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from './db-test-helpers.js';
import { addDays, businessToday } from '../../utils/dates.js';
import { fromCents, toCents } from '../../utils/money.js';
import {
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
let bbq: string;
let cheese: string;
let avondale: string;
let mabelreign: string;

const today = () => businessToday('Africa/Harare');
const T = (days: number) => addDays(today(), days);

const as = (role: Role) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${tokens[role]}`),
  post: (path: string, body: object = {}) =>
    request(app).post(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
});

async function dispatch(
  customerId: string,
  items: { productId: string; quantity: number; unitPrice?: string }[],
  date: string,
  status: 'draft' | 'confirmed' | 'cancelled' | 'reversed' = 'confirmed',
) {
  const created = await as('admin').post('/api/v1/dispatches', {
    customerId,
    items,
    dispatchDate: date,
  });
  if (created.status !== 201) throw new Error(JSON.stringify(created.body));
  const id = created.body.dispatch.id as string;
  if (status === 'cancelled') {
    await as('admin').post(`/api/v1/dispatches/${id}/cancel`, { reason: 'Not needed' });
  }
  if (status === 'confirmed' || status === 'reversed') {
    await as('admin').post(`/api/v1/dispatches/${id}/confirm`, { acknowledgeCreditLimit: true });
  }
  if (status === 'reversed') {
    await as('admin').post(`/api/v1/dispatches/${id}/reverse`, { reason: 'Returned' });
  }
  return id;
}

/** Bills the customer's dispatches dated `from`..`to` and issues the invoice on `issueDate`. */
async function invoice(customerId: string, from: string, to: string, issueDate: string) {
  const draft = await as('accounts').post('/api/v1/invoices', { customerId, from, to });
  if (draft.status !== 201) throw new Error(JSON.stringify(draft.body));
  const id = draft.body.invoice.id as string;
  await as('accounts').post(`/api/v1/invoices/${id}/issue`);
  await pools.owner.query('ALTER TABLE invoices DISABLE TRIGGER invoices_protect_finished');
  try {
    await pools.owner.query('UPDATE invoices SET issue_date = $2, due_date = $2 WHERE id = $1', [
      id,
      issueDate,
    ]);
  } finally {
    await pools.owner.query('ALTER TABLE invoices ENABLE TRIGGER invoices_protect_finished');
  }
  return id;
}

const pay = (customerId: string, amount: string, paymentDate: string) =>
  as('accounts').post('/api/v1/payments', { customerId, amount, paymentDate, method: 'cash' });

/** Amounts straight from the stored records, to check the reports against. */
async function storedRecords() {
  const { rows: sold } = await pools.owner.query<{
    date: string;
    customer_id: string;
    product_id: string;
    quantity: number;
    value: string;
    dispatch_id: string;
  }>(
    `SELECT d.dispatch_date AS date, d.customer_id, i.product_id, i.quantity, d.id AS dispatch_id,
            (i.quantity * i.unit_price)::numeric(14, 2)::text AS value
     FROM dispatches d JOIN dispatch_items i ON i.dispatch_id = d.id
     WHERE d.status = 'confirmed'`,
  );
  const { rows: invoiced } = await pools.owner.query<{ date: string; amount: string }>(
    `SELECT issue_date AS date, total::text AS amount FROM invoices WHERE status = 'issued'`,
  );
  const { rows: paid } = await pools.owner.query<{ date: string; amount: string }>(
    `SELECT payment_date AS date, amount::text FROM payments WHERE status = 'recorded'`,
  );
  return { sold, invoiced, paid };
}

const centsWhere = <T extends { date: string }>(
  rows: T[],
  amount: (row: T) => string,
  from: string,
  to: string,
) =>
  fromCents(
    rows.filter((r) => r.date >= from && r.date <= to).reduce((s, r) => s + toCents(amount(r)), 0),
  );

beforeEach(async () => {
  await resetDatabase(pools.owner);
  await pools.owner.query(
    'ALTER SEQUENCE dispatch_number_seq RESTART; ALTER SEQUENCE invoice_number_seq RESTART',
  );
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
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO customers (code, name) VALUES ('C0001', 'Avondale Tuckshop'), ('C0002', 'Mabelreign Grocers')
     RETURNING id`,
  );
  [avondale, mabelreign] = rows.map((row) => row.id) as [string, string];
});
afterAll(() => pools.close());

/** Six weeks of trading: dispatches, invoices and payments, plus records that must not count. */
async function sixWeeksOfTrading() {
  for (const productId of [bbq, cheese]) {
    await as('admin').post('/api/v1/stock/receipts', {
      productId,
      quantity: 500,
      receivedDate: T(-50),
    });
  }
  await dispatch(avondale, [{ productId: bbq, quantity: 20 }], T(-40)); // 10.00
  await dispatch(avondale, [{ productId: cheese, quantity: 10, unitPrice: '0.30' }], T(-20)); // 3.00
  await dispatch(
    mabelreign,
    [
      { productId: bbq, quantity: 4 },
      { productId: cheese, quantity: 5, unitPrice: '0.30' },
    ],
    T(-3),
  ); // 2.00 + 1.50
  await dispatch(mabelreign, [{ productId: bbq, quantity: 6, unitPrice: '0.55' }], T(0)); // 3.30
  // None of these are sales.
  await dispatch(avondale, [{ productId: bbq, quantity: 100 }], T(-2), 'draft');
  await dispatch(avondale, [{ productId: bbq, quantity: 100 }], T(-2), 'cancelled');
  await dispatch(avondale, [{ productId: bbq, quantity: 100 }], T(-2), 'reversed');

  await invoice(avondale, T(-45), T(-30), T(-25)); // 10.00
  await invoice(mabelreign, T(-5), T(-1), T(0)); // 3.50
  await pay(avondale, '4.00', T(-10));
  await pay(mabelreign, '3.50', T(0));
  const mistake = await pay(avondale, '99.00', T(-1));
  await as('admin').post(`/api/v1/payments/${mistake.body.payment.id}/void`, { reason: 'Typo' });
}

describe('the sales report', () => {
  it('reconciles with the stored records by day, week and month', async () => {
    await sixWeeksOfTrading();
    const stored = await storedRecords();
    const [from, to] = [T(-45), T(0)];

    for (const groupBy of ['day', 'week', 'month'] as const) {
      const response = await as('accounts').get(
        `/api/v1/reports/sales?from=${from}&to=${to}&groupBy=${groupBy}`,
      );
      expect(response.status, groupBy).toBe(200);
      const report = response.body;

      // Totals: exactly what is stored, with each measure kept separate.
      expect(report.totals, groupBy).toEqual({
        dispatches: 4,
        packs: 45,
        salesValue: '19.80',
        invoiced: '13.50',
        paymentsReceived: '7.50',
      });
      expect(report.totals.salesValue).toBe(centsWhere(stored.sold, (r) => r.value, from, to));
      expect(report.totals.invoiced).toBe(centsWhere(stored.invoiced, (r) => r.amount, from, to));
      expect(report.totals.paymentsReceived).toBe(
        centsWhere(stored.paid, (r) => r.amount, from, to),
      );

      // The periods cover the range exactly, one after another...
      expect(report.periods[0].start).toBe(from);
      expect(report.periods.at(-1).end).toBe(to);
      for (let i = 1; i < report.periods.length; i += 1) {
        expect(report.periods[i].start).toBe(addDays(report.periods[i - 1].end, 1));
      }
      // ...and each one holds exactly the records dated inside it.
      for (const p of report.periods) {
        expect(p.salesValue, `${groupBy} ${p.start}`).toBe(
          centsWhere(stored.sold, (r) => r.value, p.start, p.end),
        );
        expect(p.invoiced).toBe(centsWhere(stored.invoiced, (r) => r.amount, p.start, p.end));
        expect(p.paymentsReceived).toBe(centsWhere(stored.paid, (r) => r.amount, p.start, p.end));
        expect(p.packs).toBe(
          stored.sold
            .filter((r) => r.date >= p.start && r.date <= p.end)
            .reduce((s, r) => s + r.quantity, 0),
        );
      }
    }
  });

  it('lists every day in the range, even quiet ones', async () => {
    const response = await as('accounts').get(
      `/api/v1/reports/sales?from=${T(-6)}&to=${T(0)}&groupBy=day`,
    );
    expect(response.body.periods).toHaveLength(7);
    expect(response.body.periods[0]).toEqual({
      start: T(-6),
      end: T(-6),
      dispatches: 0,
      packs: 0,
      salesValue: '0.00',
      invoiced: '0.00',
      paymentsReceived: '0.00',
    });
  });

  it('checks the dates', async () => {
    const status = async (query: string) =>
      (await as('accounts').get(`/api/v1/reports/sales?${query}`)).status;
    expect(await status(`from=${T(0)}&to=${T(-1)}`)).toBe(400);
    expect(await status(`from=${T(-1)}&to=${T(1)}`)).toBe(400);
    expect(await status(`from=${T(-800)}&to=${T(0)}`)).toBe(400);
    expect(await status('groupBy=year')).toBe(400);
    // Without dates: the last 30 days by day.
    const recent = await as('accounts').get('/api/v1/reports/sales');
    expect(recent.body).toMatchObject({ from: T(-29), to: T(0), groupBy: 'day' });
  });
});

describe('the products report', () => {
  it('ranks best sellers by value or packs, adding up to the sales total', async () => {
    await sixWeeksOfTrading();

    const byValue = (await as('accounts').get(`/api/v1/reports/products?from=${T(-45)}`)).body;
    expect(
      byValue.products.map((p: { product: { sku: string }; packs: number; salesValue: string }) => [
        p.product.sku,
        p.packs,
        p.salesValue,
      ]),
    ).toEqual([
      ['PC-BBQ-S', 30, '15.30'],
      ['MP-CH-S', 15, '4.50'],
    ]);
    expect(byValue.totals).toEqual({ packs: 45, salesValue: '19.80' });
    expect(byValue.products[0].product.description).toBe('Potato Crisps — BBQ — Small');

    // In the last week: 10 packs of BBQ, 5 of Cheese.
    const lastWeek = (
      await as('accounts').get(`/api/v1/reports/products?from=${T(-6)}&sortBy=packs`)
    ).body;
    expect(lastWeek.products.map((p: { packs: number }) => p.packs)).toEqual([10, 5]);
  });
});

describe('the customers report', () => {
  it("sums each customer's sales, invoices and payments, with what they owe now", async () => {
    await sixWeeksOfTrading();

    const response = await as('accounts').get(`/api/v1/reports/customers?from=${T(-45)}`);
    expect(response.body.customers).toEqual([
      {
        customer: { id: avondale, code: 'C0001', name: 'Avondale Tuckshop' },
        dispatches: 2,
        packs: 30,
        salesValue: '13.00',
        invoiced: '10.00',
        paymentsReceived: '4.00',
        balanceNow: '9.00', // 13.00 dispatched less 4.00 paid
      },
      {
        customer: { id: mabelreign, code: 'C0002', name: 'Mabelreign Grocers' },
        dispatches: 2,
        packs: 15,
        salesValue: '6.80',
        invoiced: '3.50',
        paymentsReceived: '3.50',
        balanceNow: '3.30',
      },
    ]);
    const balances = (await as('accounts').get('/api/v1/balances')).body.customers;
    for (const row of response.body.customers) {
      expect(
        balances.find((b: { customer: { id: string } }) => b.customer.id === row.customer.id)
          .balance,
      ).toBe(row.balanceNow);
    }
  });
});

describe('stock reports', () => {
  it('count deliveries received, leaving out opening balances', async () => {
    await as('admin').post('/api/v1/stock/receipts', {
      productId: bbq,
      quantity: 40,
      receivedDate: T(-6), // inside the report's dates, but not a delivery
      isOpeningBalance: true,
    });
    await as('storekeeper').post('/api/v1/stock/receipts', {
      productId: bbq,
      quantity: 24,
      receivedDate: T(-5),
    });
    await as('storekeeper').post('/api/v1/stock/receipts', {
      productId: bbq,
      quantity: 12,
      receivedDate: T(-1),
    });
    await as('storekeeper').post('/api/v1/stock/receipts', {
      productId: cheese,
      quantity: 50,
      receivedDate: T(-1),
    });

    const response = await as('storekeeper').get(`/api/v1/reports/stock-received?from=${T(-7)}`);
    expect(response.status).toBe(200);
    expect(
      response.body.products.map(
        (p: { product: { sku: string }; receipts: number; packs: number }) => [
          p.product.sku,
          p.receipts,
          p.packs,
        ],
      ),
    ).toEqual([
      ['MP-CH-S', 1, 50],
      ['PC-BBQ-S', 2, 36],
    ]);
    expect(response.body.totals).toEqual({ receipts: 3, packs: 86 });
  });

  it('estimate which batches near their expiry date are still on the shelf (oldest leave first)', async () => {
    const receive = (
      productId: string,
      quantity: number,
      receivedDate: string,
      expiryDate: string,
      batchNumber: string,
    ) =>
      as('admin').post('/api/v1/stock/receipts', {
        productId,
        quantity,
        receivedDate,
        expiryDate,
        batchNumber,
      });
    await receive(bbq, 10, T(-60), T(5), 'OLD'); // sold out below
    await receive(bbq, 10, T(-30), T(40), 'NEW');
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }], T(-2)); // 8 BBQ left, all from NEW
    await receive(cheese, 4, T(-20), T(-1), 'GONE-OFF'); // already expired
    await receive(cheese, 5, T(-10), T(3), 'SOON');

    const within30 = (await as('storekeeper').get('/api/v1/reports/expiring')).body;
    expect(within30.withinDays).toBe(30);
    expect(
      within30.batches.map(
        (b: { batchNumber: string; estimatedPacksLeft: number; daysToExpiry: number }) => [
          b.batchNumber,
          b.estimatedPacksLeft,
          b.daysToExpiry,
        ],
      ),
    ).toEqual([
      ['GONE-OFF', 4, -1],
      ['SOON', 5, 3],
    ]);

    const within60 = (await as('storekeeper').get('/api/v1/reports/expiring?days=60')).body;
    expect(
      within60.batches.map((b: { batchNumber: string; estimatedPacksLeft: number }) => [
        b.batchNumber,
        b.estimatedPacksLeft,
      ]),
    ).toEqual([
      ['GONE-OFF', 4],
      ['SOON', 5],
      ['NEW', 8],
    ]);
    expect((await as('storekeeper').get('/api/v1/reports/expiring?days=0')).status).toBe(400);
  });
});

describe('the dashboard', () => {
  it('shows everyone today at a glance, and money only to admins and accounts staff', async () => {
    await sixWeeksOfTrading();
    await pools.owner.query('UPDATE products SET reorder_level = 600 WHERE id = $1', [cheese]);
    await as('storekeeper').post('/api/v1/stock/receipts', {
      productId: bbq,
      quantity: 7,
      receivedDate: T(0),
    });

    const forStore = (await as('storekeeper').get('/api/v1/reports/dashboard')).body.dashboard;
    expect(forStore).toMatchObject({
      today: T(0),
      dispatchesToday: { dispatches: 1, packs: 6, salesValue: null },
      receivedToday: { receipts: 1, packs: 7 },
      lowStock: {
        count: 1,
        products: [{ product: { sku: 'MP-CH-S' }, quantityOnHand: 485, reorderLevel: 600 }],
      },
      money: null,
    });
    expect(forStore.trend).toHaveLength(14);
    expect(forStore.trend.at(-1)).toEqual({ date: T(0), packs: 6, salesValue: null });

    const forAccounts = (await as('accounts').get('/api/v1/reports/dashboard')).body.dashboard;
    expect(forAccounts.dispatchesToday.salesValue).toBe('3.30');
    expect(forAccounts.money).toMatchObject({
      currency: 'USD',
      owedByCustomers: '12.30', // 9.00 + 3.30
    });
    const month = (
      await as('accounts').get(`/api/v1/reports/sales?from=${T(0).slice(0, 8)}01&groupBy=month`)
    ).body.totals;
    expect(forAccounts.money).toMatchObject({
      salesThisMonth: month.salesValue,
      invoicedThisMonth: month.invoiced,
      paymentsThisMonth: month.paymentsReceived,
    });
  });
});

describe('who can see which report', () => {
  it('keeps financial reports for admins and accounts staff', async () => {
    const reports = ['sales', 'products', 'customers', 'stock-received', 'expiring', 'dashboard'];
    const allowed: Record<Role, string[]> = {
      admin: reports,
      accounts: reports,
      storekeeper: ['stock-received', 'expiring', 'dashboard'],
      salesperson: ['dashboard'],
    };
    for (const role of ['admin', 'accounts', 'storekeeper', 'salesperson'] as const) {
      for (const report of reports) {
        const status = (await as(role).get(`/api/v1/reports/${report}`)).status;
        expect(status, `${role} ${report}`).toBe(allowed[role].includes(report) ? 200 : 403);
      }
    }
  });
});
