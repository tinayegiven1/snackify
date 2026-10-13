import { addDays, daysBetween } from '../../utils/dates.js';

/*
 * Demand forecasting (spec 6.11), as pure functions so it can be tested without a database.
 *
 * Method "weekday-average": the demand expected on a day is the average of the packs dispatched
 * on the same weekday over the last few weeks (up to 8). Tuckshops tend to order on the same days
 * each week, which a plain daily average would smear out. The forecast for a period is the sum
 * of its days.
 */

export const METHOD = 'weekday-average';
/** At least four whole weeks of dispatch history, so every weekday has been seen 4 times. */
export const MIN_HISTORY_DAYS = 28;
export const MAX_HISTORY_WEEKS = 8;
/** z for a rough 80% range (10% below, 10% above) of a normal distribution. */
const Z_80 = 1.2816;

export type ForecastStatus = 'ok' | 'insufficient_history' | 'no_history';

export interface ForecastResult {
  status: ForecastStatus;
  /** Expected packs over the horizon (1 decimal); null without enough history. */
  predicted: number | null;
  /** A rough 80% range, in whole packs; null without enough history. */
  lower: number | null;
  upper: number | null;
  /** Days from the product's first confirmed dispatch to the forecast start. */
  historyDays: number;
  /** Whole weeks of history used (0 when there was not enough). */
  weeksUsed: number;
}

/** ISO weekday: 1 = Monday ... 7 = Sunday. */
const weekday = (date: string) => ((new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7) + 1;

const round1 = (n: number) => Math.round(n * 10) / 10;

/**
 * Forecasts one product's demand for `horizonDays` days from `start` (included).
 *
 * @param demand packs dispatched per day (missing days count as 0); only days before `start`
 *   are used, so later records can never leak into a forecast.
 * @param firstDispatch the date of the product's first confirmed dispatch, or null if none.
 */
export function forecastDemand(
  demand: ReadonlyMap<string, number>,
  firstDispatch: string | null,
  start: string,
  horizonDays: number,
): ForecastResult {
  if (firstDispatch === null || firstDispatch >= start) {
    return {
      status: 'no_history',
      predicted: null,
      lower: null,
      upper: null,
      historyDays: 0,
      weeksUsed: 0,
    };
  }
  const historyDays = daysBetween(firstDispatch, start);
  if (historyDays < MIN_HISTORY_DAYS) {
    return {
      status: 'insufficient_history',
      predicted: null,
      lower: null,
      upper: null,
      historyDays,
      weeksUsed: 0,
    };
  }

  const weeks = Math.min(MAX_HISTORY_WEEKS, Math.floor(historyDays / 7));
  const packsOn = (date: string) => (date < start ? (demand.get(date) ?? 0) : 0);

  // Average packs per weekday over the weeks used, and the total of each of those weeks.
  const weekdayTotals = new Map<number, number>();
  const weeklyTotals: number[] = [];
  for (let week = 0; week < weeks; week += 1) {
    let total = 0;
    for (let d = 1; d <= 7; d += 1) {
      const date = addDays(start, -(week * 7 + d));
      const packs = packsOn(date);
      total += packs;
      weekdayTotals.set(weekday(date), (weekdayTotals.get(weekday(date)) ?? 0) + packs);
    }
    weeklyTotals.push(total);
  }
  let predicted = 0;
  for (let d = 0; d < horizonDays; d += 1) {
    predicted += (weekdayTotals.get(weekday(addDays(start, d))) ?? 0) / weeks;
  }

  // The spread of past weekly totals, scaled to the horizon, gives the range.
  const mean = weeklyTotals.reduce((s, t) => s + t, 0) / weeks;
  const variance = weeklyTotals.reduce((s, t) => s + (t - mean) ** 2, 0) / (weeks - 1);
  const spread = Z_80 * Math.sqrt(variance) * Math.sqrt(horizonDays / 7);

  return {
    status: 'ok',
    predicted: round1(predicted),
    lower: Math.max(0, Math.floor(predicted - spread)),
    upper: Math.ceil(predicted + spread),
    historyDays,
    weeksUsed: weeks,
  };
}

/** Mean absolute error of past forecasts against what was actually dispatched. */
export function meanAbsoluteError(pairs: { predicted: number; actual: number }[]): number | null {
  if (pairs.length === 0) return null;
  return round1(pairs.reduce((s, p) => s + Math.abs(p.predicted - p.actual), 0) / pairs.length);
}

/**
 * Packs to receive so that stock covers the forecast plus the safety stock (0 when there is
 * already enough). Uses the forecast itself, rounded up to whole packs.
 */
export function suggestedReorder(predicted: number, safetyStock: number, onHand: number): number {
  return Math.max(0, Math.ceil(predicted) + safetyStock - onHand);
}
