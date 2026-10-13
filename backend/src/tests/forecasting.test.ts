import { describe, expect, it } from 'vitest';
import {
  forecastDemand,
  meanAbsoluteError,
  MIN_HISTORY_DAYS,
  suggestedReorder,
} from '../modules/forecasts/forecasting.js';
import { addDays } from '../utils/dates.js';

// Monday 12 October 2026.
const START = '2026-10-12';

/** Demand on every day from `days` days before START up to the day before it. */
function daily(days: number, packsFor: (date: string, dayIndex: number) => number) {
  const demand = new Map<string, number>();
  for (let i = days; i >= 1; i -= 1) {
    const date = addDays(START, -i);
    demand.set(date, packsFor(date, i));
  }
  return demand;
}

describe('forecastDemand', () => {
  it('says so when a product has never been dispatched', () => {
    expect(forecastDemand(new Map(), null, START, 7)).toEqual({
      status: 'no_history',
      predicted: null,
      lower: null,
      upper: null,
      historyDays: 0,
      weeksUsed: 0,
    });
  });

  it('refuses to guess with less than four weeks of history (spec: report it honestly)', () => {
    const first = addDays(START, -(MIN_HISTORY_DAYS - 1));
    const result = forecastDemand(
      daily(27, () => 10),
      first,
      START,
      7,
    );
    expect(result).toMatchObject({
      status: 'insufficient_history',
      predicted: null,
      historyDays: 27,
    });
  });

  it('forecasts steady demand exactly, with no spread', () => {
    const result = forecastDemand(
      daily(56, () => 10),
      addDays(START, -56),
      START,
      7,
    );
    expect(result).toEqual({
      status: 'ok',
      predicted: 70,
      lower: 70,
      upper: 70,
      historyDays: 56,
      weeksUsed: 8,
    });
    expect(
      forecastDemand(
        daily(56, () => 10),
        addDays(START, -56),
        START,
        30,
      ).predicted,
    ).toBe(300);
  });

  it('follows the weekly pattern: a customer who only orders on Mondays', () => {
    const mondaysOnly = daily(56, (date) =>
      new Date(`${date}T00:00:00Z`).getUTCDay() === 1 ? 24 : 0,
    );
    const week = forecastDemand(mondaysOnly, addDays(START, -56), START, 7);
    expect(week.predicted).toBe(24);
    // 12 Oct to 10 Nov holds five Mondays.
    expect(forecastDemand(mondaysOnly, addDays(START, -56), START, 30).predicted).toBe(120);
    // Starting on a Tuesday, the next 6 days hold no Monday.
    expect(forecastDemand(mondaysOnly, addDays(START, -56), addDays(START, 1), 6).predicted).toBe(
      0,
    );
  });

  it('uses at most the last 8 weeks, and never anything on or after the start', () => {
    const demand = daily(120, (_, daysBefore) => (daysBefore > 56 ? 1000 : 7));
    // Records from the forecast period itself must be ignored.
    demand.set(START, 5000);
    demand.set(addDays(START, 3), 5000);
    const result = forecastDemand(demand, addDays(START, -120), START, 7);
    expect(result).toMatchObject({ predicted: 49, weeksUsed: 8 });
  });

  it('uses only the whole weeks there are, between 4 and 8', () => {
    const result = forecastDemand(
      daily(40, () => 3),
      addDays(START, -40),
      START,
      7,
    );
    expect(result).toMatchObject({ status: 'ok', weeksUsed: 5, predicted: 21 });
  });

  it('gives a wider range when weekly demand varies more, and never below zero', () => {
    const uneven = daily(56, (_, daysBefore) => (Math.ceil(daysBefore / 7) % 2 === 0 ? 0 : 6));
    const result = forecastDemand(uneven, addDays(START, -56), START, 7);
    expect(result.predicted).toBe(21);
    expect(result.lower).toBeGreaterThanOrEqual(0);
    expect(result.lower).toBeLessThan(21);
    expect(result.upper).toBeGreaterThan(21);
    const month = forecastDemand(uneven, addDays(START, -56), START, 30);
    expect((month.upper as number) - (month.predicted as number)).toBeGreaterThan(
      (result.upper as number) - 21,
    );
  });
});

describe('meanAbsoluteError', () => {
  it('averages how far forecasts were from what happened', () => {
    expect(
      meanAbsoluteError([
        { predicted: 10, actual: 12 },
        { predicted: 20, actual: 15 },
        { predicted: 7, actual: 7 },
      ]),
    ).toBe(2.3);
    expect(meanAbsoluteError([])).toBeNull();
  });
});

describe('suggestedReorder', () => {
  it('covers the forecast plus safety stock, less what is on hand', () => {
    expect(suggestedReorder(12.3, 5, 4)).toBe(14);
    expect(suggestedReorder(12.3, 5, 40)).toBe(0);
    expect(suggestedReorder(0, 0, 0)).toBe(0);
  });
});
