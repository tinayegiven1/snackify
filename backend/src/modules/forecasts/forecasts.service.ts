import type pg from 'pg';
import { withTransaction, type Queryable } from '../../database/transaction.js';
import { addDays } from '../../utils/dates.js';
import { recordAudit } from '../audit/audit.js';
import type { PublicUser } from '../auth/roles.js';
import {
  forecastDemand,
  MAX_HISTORY_WEEKS,
  meanAbsoluteError,
  METHOD,
  suggestedReorder,
  type ForecastStatus,
} from './forecasting.js';

/** The two horizons spec 6.11 asks for: the next week and the next month. */
export const HORIZONS = { week: 7, month: 30 } as const;
/** Completed weekly forecasts needed before an average error is shown. */
export const MIN_FORECASTS_FOR_ACCURACY = 3;
/** How many recent completed weeks the average error covers. */
const ACCURACY_WEEKS = 8;

export interface HorizonForecast {
  horizonDays: number;
  status: ForecastStatus;
  predicted: number | null;
  lower: number | null;
  upper: number | null;
  historyDays: number;
  weeksUsed: number;
  /** Packs to receive to cover this forecast plus the safety stock; null without a forecast. */
  suggestedReorder: number | null;
}

export interface ProductForecast {
  product: { id: string; sku: string; description: string };
  onHand: number;
  safetyStock: number;
  week: HorizonForecast;
  month: HorizonForecast;
  /** How past 7-day forecasts compared with what was actually dispatched, newest first. */
  accuracy: {
    mae: number | null;
    weeksCompared: number;
    needed: number;
    recent: { forecastStart: string; predicted: number; actual: number }[];
  };
}

export interface ForecastView {
  run: {
    id: string;
    forecastStart: string;
    method: string;
    createdAt: Date;
    createdBy: string;
  } | null;
  products: ProductForecast[];
}

/** Packs dispatched per product per day (confirmed dispatches only: the demand). */
async function dailyDemand(
  db: Queryable,
  from: string,
  to: string,
): Promise<Map<string, Map<string, number>>> {
  const { rows } = await db.query<{ product_id: string; date: string; packs: number }>(
    `SELECT i.product_id, d.dispatch_date AS date, sum(i.quantity)::integer AS packs
     FROM dispatches d JOIN dispatch_items i ON i.dispatch_id = d.id
     WHERE d.status = 'confirmed' AND d.dispatch_date BETWEEN $1 AND $2
     GROUP BY i.product_id, d.dispatch_date`,
    [from, to],
  );
  const byProduct = new Map<string, Map<string, number>>();
  for (const row of rows) {
    const days = byProduct.get(row.product_id) ?? new Map<string, number>();
    days.set(row.date, row.packs);
    byProduct.set(row.product_id, days);
  }
  return byProduct;
}

/**
 * Forecasts demand for every active product for the next 7 and 30 days from `today`, using
 * the confirmed dispatches before today, and records the run.
 */
export async function runForecast(
  pool: pg.Pool,
  today: string,
  actor: PublicUser,
): Promise<ForecastView> {
  const start = today;
  await withTransaction(pool, async (client) => {
    const { rows: products } = await client.query<{ id: string }>(
      'SELECT id FROM products WHERE is_active ORDER BY name, flavour, size',
    );
    const demand = await dailyDemand(
      client,
      addDays(start, -7 * MAX_HISTORY_WEEKS),
      addDays(start, -1),
    );
    const { rows: firsts } = await client.query<{ product_id: string; first: string }>(
      `SELECT i.product_id, min(d.dispatch_date) AS first
       FROM dispatches d JOIN dispatch_items i ON i.dispatch_id = d.id
       WHERE d.status = 'confirmed' AND d.dispatch_date < $1
       GROUP BY i.product_id`,
      [start],
    );
    const firstDispatch = new Map(firsts.map((row) => [row.product_id, row.first]));

    const { rows: runs } = await client.query<{ id: string }>(
      `INSERT INTO forecast_runs (forecast_start, method, created_by) VALUES ($1, $2, $3)
       RETURNING id`,
      [start, METHOD, actor.id],
    );
    const runId = (runs[0] as { id: string }).id;
    for (const product of products) {
      for (const horizon of Object.values(HORIZONS)) {
        const result = forecastDemand(
          demand.get(product.id) ?? new Map(),
          firstDispatch.get(product.id) ?? null,
          start,
          horizon,
        );
        await client.query(
          `INSERT INTO forecasts (run_id, product_id, forecast_start, horizon_days, method, status,
                                  predicted_quantity, lower_quantity, upper_quantity,
                                  history_days, weeks_used)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
          [
            runId,
            product.id,
            start,
            horizon,
            METHOD,
            result.status,
            result.predicted,
            result.lower,
            result.upper,
            result.historyDays,
            result.weeksUsed,
          ],
        );
      }
    }
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'forecast.run',
      entityType: 'forecast',
      entityId: runId,
      details: { forecastStart: start, method: METHOD, products: products.length },
    });
  });
  return latestForecast(pool, today);
}

/**
 * The latest forecast run, with stock on hand, safety stock, how much to receive, and how
 * accurate earlier weekly forecasts were.
 */
export async function latestForecast(db: Queryable, today: string): Promise<ForecastView> {
  const { rows: runs } = await db.query<{
    id: string;
    forecast_start: string;
    method: string;
    created_at: Date;
    full_name: string;
  }>(
    `SELECT r.id, r.forecast_start, r.method, r.created_at, u.full_name
     FROM forecast_runs r JOIN users u ON u.id = r.created_by
     ORDER BY r.created_at DESC LIMIT 1`,
  );
  const run = runs[0];
  if (!run) return { run: null, products: [] };

  const { rows } = await db.query<{
    product_id: string;
    sku: string;
    name: string;
    flavour: string;
    size: string;
    safety_stock: number;
    on_hand: number;
    horizon_days: number;
    status: ForecastStatus;
    predicted: string | null;
    lower_quantity: number | null;
    upper_quantity: number | null;
    history_days: number;
    weeks_used: number;
  }>(
    `SELECT f.product_id, p.sku, p.name, p.flavour, p.size, p.safety_stock,
            b.quantity_on_hand AS on_hand, f.horizon_days, f.status,
            f.predicted_quantity::text AS predicted, f.lower_quantity, f.upper_quantity,
            f.history_days, f.weeks_used
     FROM forecasts f
     JOIN products p ON p.id = f.product_id
     JOIN stock_balances b ON b.product_id = f.product_id
     WHERE f.run_id = $1`,
    [run.id],
  );

  // Every completed 7-day forecast (the latest one for each start date) with what was then
  // actually dispatched in those 7 days.
  const { rows: past } = await db.query<{
    product_id: string;
    forecast_start: string;
    predicted: string;
    actual: number;
  }>(
    `WITH latest AS (
       SELECT DISTINCT ON (f.product_id, f.forecast_start)
              f.product_id, f.forecast_start, f.predicted_quantity
       FROM forecasts f
       WHERE f.horizon_days = 7 AND f.status = 'ok' AND f.forecast_start + 6 < $1
       ORDER BY f.product_id, f.forecast_start, f.created_at DESC
     )
     SELECT l.product_id, l.forecast_start, l.predicted_quantity::text AS predicted,
            COALESCE((
              SELECT sum(i.quantity) FROM dispatches d JOIN dispatch_items i ON i.dispatch_id = d.id
              WHERE i.product_id = l.product_id AND d.status = 'confirmed'
                AND d.dispatch_date BETWEEN l.forecast_start AND l.forecast_start + 6
            ), 0)::integer AS actual
     FROM latest l
     ORDER BY l.product_id, l.forecast_start DESC`,
    [today],
  );
  const accuracy = new Map<
    string,
    { forecastStart: string; predicted: number; actual: number }[]
  >();
  for (const row of past) {
    const list = accuracy.get(row.product_id) ?? [];
    if (list.length < ACCURACY_WEEKS) {
      list.push({
        forecastStart: row.forecast_start,
        predicted: Number(row.predicted),
        actual: row.actual,
      });
    }
    accuracy.set(row.product_id, list);
  }

  const byProduct = new Map<string, ProductForecast>();
  for (const row of rows) {
    const predicted = row.predicted === null ? null : Number(row.predicted);
    const horizon: HorizonForecast = {
      horizonDays: row.horizon_days,
      status: row.status,
      predicted,
      lower: row.lower_quantity,
      upper: row.upper_quantity,
      historyDays: row.history_days,
      weeksUsed: row.weeks_used,
      suggestedReorder:
        predicted === null ? null : suggestedReorder(predicted, row.safety_stock, row.on_hand),
    };
    const recent = accuracy.get(row.product_id) ?? [];
    const entry = byProduct.get(row.product_id) ?? {
      product: {
        id: row.product_id,
        sku: row.sku,
        description: `${row.name} — ${row.flavour} — ${row.size}`,
      },
      onHand: row.on_hand,
      safetyStock: row.safety_stock,
      week: horizon,
      month: horizon,
      accuracy: {
        mae: recent.length >= MIN_FORECASTS_FOR_ACCURACY ? meanAbsoluteError(recent) : null,
        weeksCompared: recent.length,
        needed: MIN_FORECASTS_FOR_ACCURACY,
        recent,
      },
    };
    if (row.horizon_days === HORIZONS.week) entry.week = horizon;
    else entry.month = horizon;
    byProduct.set(row.product_id, entry);
  }

  // Products to restock first, then the busiest, then by name.
  const products = [...byProduct.values()].sort(
    (a, b) =>
      (b.week.suggestedReorder ?? -1) - (a.week.suggestedReorder ?? -1) ||
      (b.week.predicted ?? -1) - (a.week.predicted ?? -1) ||
      a.product.description.localeCompare(b.product.description),
  );
  return {
    run: {
      id: run.id,
      forecastStart: run.forecast_start,
      method: run.method,
      createdAt: run.created_at,
      createdBy: run.full_name,
    },
    products,
  };
}
