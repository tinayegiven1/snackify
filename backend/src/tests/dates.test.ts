import { describe, expect, it } from 'vitest';
import {
  addDays,
  businessToday,
  daysBetween,
  lastCompleteBillingWeek,
  periods,
  periodStart,
} from '../utils/dates.js';

describe('businessToday', () => {
  it("uses the business's time zone, not the server's", () => {
    // 22:30 UTC on 12 October is already 00:30 on 13 October in Harare (UTC+2).
    const lateEveningUtc = new Date('2026-10-12T22:30:00Z');

    expect(businessToday('Africa/Harare', lateEveningUtc)).toBe('2026-10-13');
    expect(businessToday('UTC', lateEveningUtc)).toBe('2026-10-12');
  });

  it('formats single-digit months and days with a leading zero', () => {
    expect(businessToday('Africa/Harare', new Date('2026-03-05T08:00:00Z'))).toBe('2026-03-05');
  });
});

describe('daysBetween', () => {
  it('counts whole days, including across month ends', () => {
    expect(daysBetween('2026-10-12', '2026-10-12')).toBe(0);
    expect(daysBetween('2026-09-30', '2026-10-02')).toBe(2);
    expect(daysBetween('2026-01-01', '2027-01-01')).toBe(365);
  });
});

describe('lastCompleteBillingWeek', () => {
  it('gives Monday to Sunday of the previous week when weeks start on Monday', () => {
    // 12 Oct 2026 is a Monday; 18 Oct is the Sunday of the same week.
    expect(lastCompleteBillingWeek('2026-10-12', 1)).toEqual({
      from: '2026-10-05',
      to: '2026-10-11',
    });
    expect(lastCompleteBillingWeek('2026-10-18', 1)).toEqual({
      from: '2026-10-05',
      to: '2026-10-11',
    });
    expect(lastCompleteBillingWeek('2026-10-19', 1)).toEqual({
      from: '2026-10-12',
      to: '2026-10-18',
    });
  });

  it('follows the configured first day of the week', () => {
    // Weeks starting on Sunday: on Wednesday 14 Oct, the last full week is Sun 4 - Sat 10 Oct.
    expect(lastCompleteBillingWeek('2026-10-14', 7)).toEqual({
      from: '2026-10-04',
      to: '2026-10-10',
    });
  });

  it('crosses month and year ends', () => {
    expect(lastCompleteBillingWeek('2027-01-01', 1)).toEqual({
      from: '2026-12-21',
      to: '2026-12-27',
    });
  });
});

describe('addDays', () => {
  it('moves forwards and backwards across month ends', () => {
    expect(addDays('2026-10-31', 1)).toBe('2026-11-01');
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28');
  });
});

describe('periods', () => {
  it('splits a range into days', () => {
    expect(periods('2026-10-10', '2026-10-12', 'day', 1).map((p) => p.start)).toEqual([
      '2026-10-10',
      '2026-10-11',
      '2026-10-12',
    ]);
  });

  it('splits a range into weeks starting on the billing day, clipped at both ends', () => {
    // 2026-10-10 is a Saturday; weeks start on Monday.
    expect(periods('2026-10-10', '2026-10-20', 'week', 1)).toEqual([
      { key: '2026-10-05', start: '2026-10-10', end: '2026-10-11' },
      { key: '2026-10-12', start: '2026-10-12', end: '2026-10-18' },
      { key: '2026-10-19', start: '2026-10-19', end: '2026-10-20' },
    ]);
    // With weeks starting on Sunday (7).
    expect(periods('2026-10-10', '2026-10-12', 'week', 7).map((p) => p.key)).toEqual([
      '2026-10-04',
      '2026-10-11',
    ]);
  });

  it('splits a range into calendar months, across a year end and a leap February', () => {
    expect(periods('2027-12-15', '2028-03-02', 'month', 1)).toEqual([
      { key: '2027-12-01', start: '2027-12-15', end: '2027-12-31' },
      { key: '2028-01-01', start: '2028-01-01', end: '2028-01-31' },
      { key: '2028-02-01', start: '2028-02-01', end: '2028-02-29' },
      { key: '2028-03-01', start: '2028-03-01', end: '2028-03-02' },
    ]);
  });

  it('gives the start of the period a date falls in', () => {
    expect(periodStart('2026-10-15', 'month', 1)).toBe('2026-10-01');
    expect(periodStart('2026-10-15', 'week', 1)).toBe('2026-10-12');
    expect(periodStart('2026-10-15', 'day', 1)).toBe('2026-10-15');
  });
});
