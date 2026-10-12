import { describe, expect, it } from 'vitest';
import { businessToday, daysBetween } from '../utils/dates.js';

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
