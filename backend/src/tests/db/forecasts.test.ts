import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from './db-test-helpers.js';
import { addDays, businessToday } from '../../utils/dates.js';
import {
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
const tokens = {} as Record<Role, string>;
let bbq: string;
let cheese: string;
let salt: string;
let retired: string;
let shop: string;

const T = (days: number) => addDays(businessToday('Africa/Harare'), days);

const as = (role: Role) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${tokens[role]}`),
  post: (path: string, body: object = {}) =>
    request(app).post(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
  patch: (path: string, body: object) =>
    request(app).patch(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
});

async function dispatch(
  productId: string,
  quantity: number,
  date: string,
  status: 'draft' | 'confirmed' | 'cancelled' | 'reversed' = 'confirmed',
) {
  const created = await as('admin').post('/api/v1/dispatches', {
    customerId: shop,
    items: [{ productId, quantity }],
    dispatchDate: date,
  });
  if (created.status !== 201) throw new Error(JSON.stringify(created.body));
  const id = created.body.dispatch.id as string;
  if (status === 'cancelled') {
    await as('admin').post(`/api/v1/dispatches/${id}/cancel`, { reason: 'Not needed' });
  }
  if (status === 'confirmed' || status === 'reversed') {
    const confirmed = await as('admin').post(`/api/v1/dispatches/${id}/confirm`, {
      acknowledgeCreditLimit: true,
    });
    if (confirmed.status !== 200) throw new Error(JSON.stringify(confirmed.body));
  }
  if (status === 'reversed') {
    await as('admin').post(`/api/v1/dispatches/${id}/reverse`, { reason: 'Returned' });
  }
}

const receive = (productId: string, quantity: number, receivedDate = T(-70)) =>
  receiveTestStock(pools.app, { productId, quantity, receivedDate });

/** BBQ: 10 packs every 7 days for 8 weeks, always on today's weekday, plus records that are not demand. */
async function bbqHistory() {
  await receive(bbq, 200);
  for (let week = 1; week <= 8; week += 1) await dispatch(bbq, 10, T(-7 * week));
  await dispatch(bbq, 100, T(-3), 'draft');
  await dispatch(bbq, 100, T(-3), 'cancelled');
  await dispatch(bbq, 100, T(-3), 'reversed');
  await dispatch(bbq, 100, T(0)); // today: part of the forecast period, not its history
  const damaged = await as('admin').post('/api/v1/stock/adjustments', {
    productId: bbq,
    type: 'damage',
    quantityDelta: -5,
    reason: 'Damaged in the store',
  });
  if (damaged.status !== 201) throw new Error(JSON.stringify(damaged.body));
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
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
  salt = await createTestProduct(pools.owner, { sku: 'PC-SA-S', flavour: 'Salt' });
  retired = await createTestProduct(pools.owner, {
    sku: 'OLD-1',
    name: 'Old Puffs',
    isActive: false,
  });
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO customers (code, name) VALUES ('C0001', 'Avondale Tuckshop') RETURNING id`,
  );
  shop = (rows[0] as { id: string }).id;
});
afterAll(() => pools.close());

describe('running a forecast', () => {
  it('uses only confirmed dispatches before today as demand (spec 11)', async () => {
    await bbqHistory();
    await pools.owner.query('UPDATE products SET safety_stock = 15 WHERE id = $1', [bbq]);

    const response = await as('storekeeper').post('/api/v1/forecasts/run');

    expect(response.status).toBe(201);
    const forecast = response.body.forecast;
    expect(forecast.run).toMatchObject({
      forecastStart: T(0),
      method: 'weekday-average',
      createdBy: 'Test storekeeper',
    });
    const bbqForecast = forecast.products.find(
      (p: { product: { id: string } }) => p.product.id === bbq,
    );
    // 10 packs on this weekday every week: once in the next 7 days, five times in the next 30.
    expect(bbqForecast.week).toMatchObject({
      horizonDays: 7,
      status: 'ok',
      predicted: 10,
      lower: 10,
      upper: 10,
      historyDays: 56,
      weeksUsed: 8,
    });
    expect(bbqForecast.month).toMatchObject({ horizonDays: 30, predicted: 50 });

    // 200 received, 80 + 100 dispatched, 5 damaged: 15 on hand; keep 15 extra.
    expect(bbqForecast).toMatchObject({ onHand: 15, safetyStock: 15 });
    expect(bbqForecast.week.suggestedReorder).toBe(10); // 10 + 15 - 15
    expect(bbqForecast.month.suggestedReorder).toBe(50);
    expect(await auditEntries(pools.owner, 'forecast.run')).toHaveLength(1);
  });

  it('reports too little history honestly instead of guessing (spec 11)', async () => {
    await receive(cheese, 100);
    await dispatch(cheese, 6, T(-10));

    const forecast = (await as('accounts').post('/api/v1/forecasts/run')).body.forecast;
    const find = (id: string) =>
      forecast.products.find((p: { product: { id: string } }) => p.product.id === id);

    expect(find(cheese).week).toEqual({
      horizonDays: 7,
      status: 'insufficient_history',
      predicted: null,
      lower: null,
      upper: null,
      historyDays: 10,
      weeksUsed: 0,
      suggestedReorder: null,
    });
    expect(find(salt).week).toMatchObject({ status: 'no_history', predicted: null });
    // Inactive products are not forecast.
    expect(find(retired)).toBeUndefined();
    expect(forecast.products).toHaveLength(3);
  });

  it('keeps every forecast as it was made', async () => {
    await as('admin').post('/api/v1/forecasts/run');
    const { rows } = await pools.owner.query('SELECT 1 FROM forecasts');
    expect(rows).toHaveLength(6); // 3 active products × 2 horizons

    for (const sql of [
      'UPDATE forecasts SET predicted_quantity = 1',
      'DELETE FROM forecasts',
      'DELETE FROM forecast_runs',
    ]) {
      expect((await pgErrorOf(pools.app.query(sql))).code, sql).toBe(PG.insufficientPrivilege);
    }
  });

  it('shows nothing before the first run', async () => {
    const response = await as('storekeeper').get('/api/v1/forecasts');
    expect(response.body.forecast).toEqual({ run: null, products: [] });
  });
});

describe('forecast accuracy', () => {
  /** Records a past 7-day forecast for BBQ, as an earlier run would have. */
  async function pastForecast(start: string, predicted: number, createdAt: string) {
    const { rows } = await pools.owner.query<{ id: string }>(
      `INSERT INTO forecast_runs (forecast_start, method, created_by, created_at)
       SELECT $1, 'weekday-average', id, $2 FROM users WHERE username = 'admin' RETURNING id`,
      [start, createdAt],
    );
    await pools.owner.query(
      `INSERT INTO forecasts (run_id, product_id, forecast_start, horizon_days, method, status,
                              predicted_quantity, lower_quantity, upper_quantity, history_days,
                              weeks_used, created_at)
       VALUES ($1, $2, $3, 7, 'weekday-average', 'ok', $4, 0, 999, 56, 8, $5)`,
      [(rows[0] as { id: string }).id, bbq, start, predicted, createdAt],
    );
  }

  it('compares completed weekly forecasts with what was actually dispatched', async () => {
    await bbqHistory(); // 10 packs dispatched in each of the last 8 weeks
    await pastForecast(T(-28), 8, `${T(-28)}T06:00:00Z`);
    await pastForecast(T(-21), 12, `${T(-21)}T06:00:00Z`);

    // Two completed weeks are not enough to judge.
    let bbqForecast = (
      await as('storekeeper').post('/api/v1/forecasts/run')
    ).body.forecast.products.find((p: { product: { id: string } }) => p.product.id === bbq);
    expect(bbqForecast.accuracy).toMatchObject({ mae: null, weeksCompared: 2, needed: 3 });

    // A forecast re-run for the same week counts once, as its latest version.
    await pastForecast(T(-14), 99, `${T(-14)}T06:00:00Z`);
    await pastForecast(T(-14), 10, `${T(-14)}T09:00:00Z`);
    // Not finished yet, so it cannot be judged.
    await pastForecast(T(-3), 50, `${T(-3)}T06:00:00Z`);

    bbqForecast = (await as('storekeeper').get('/api/v1/forecasts')).body.forecast.products.find(
      (p: { product: { id: string } }) => p.product.id === bbq,
    );
    expect(bbqForecast.accuracy).toEqual({
      mae: 1.3, // errors 0, 2 and 2 packs
      weeksCompared: 3,
      needed: 3,
      recent: [
        { forecastStart: T(-14), predicted: 10, actual: 10 },
        { forecastStart: T(-21), predicted: 12, actual: 10 },
        { forecastStart: T(-28), predicted: 8, actual: 10 },
      ],
    });
  });
});

describe('safety stock', () => {
  it('is set by admins on the product', async () => {
    const updated = await as('admin').patch(`/api/v1/products/${bbq}`, { safetyStock: 24 });
    expect(updated.body.product.safetyStock).toBe(24);
    expect((await as('admin').patch(`/api/v1/products/${bbq}`, { safetyStock: -1 })).status).toBe(
      400,
    );
    expect(
      (await as('storekeeper').patch(`/api/v1/products/${bbq}`, { safetyStock: 5 })).status,
    ).toBe(403);
  });
});

describe('who can see forecasts', () => {
  it('is admins, accounts staff and storekeepers', async () => {
    for (const role of ['admin', 'accounts', 'storekeeper'] as const) {
      expect((await as(role).get('/api/v1/forecasts')).status, role).toBe(200);
    }
    expect((await as('salesperson').get('/api/v1/forecasts')).status).toBe(403);
    expect((await as('salesperson').post('/api/v1/forecasts/run')).status).toBe(403);
  });
});
