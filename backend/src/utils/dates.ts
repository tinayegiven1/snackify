/** Today's date as YYYY-MM-DD in `timeZone` (e.g. Africa/Harare), not the server's own zone. */
export function businessToday(timeZone: string, now: Date = new Date()): string {
  // The en-CA locale formats dates as YYYY-MM-DD.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now);
}

/** Whole days from `from` to `to` (both YYYY-MM-DD). */
export function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

/** `date` (YYYY-MM-DD) moved by `days` (which may be negative). */
export function addDays(date: string, days: number): string {
  const result = new Date(`${date}T00:00:00Z`);
  result.setUTCDate(result.getUTCDate() + days);
  return result.toISOString().slice(0, 10);
}

/**
 * The last complete billing week before the week containing `today`.
 * `weekStartsOn` is 1 = Monday ... 7 = Sunday. With weeks starting on Monday, on any day of
 * the week of Monday 12 October 2026 this is Monday 5 to Sunday 11 October.
 */
export function lastCompleteBillingWeek(
  today: string,
  weekStartsOn: number,
): { from: string; to: string } {
  const isoWeekday = ((new Date(`${today}T00:00:00Z`).getUTCDay() + 6) % 7) + 1;
  const daysSinceWeekStart = (isoWeekday - weekStartsOn + 7) % 7;
  const thisWeekStart = addDays(today, -daysSinceWeekStart);
  return { from: addDays(thisWeekStart, -7), to: addDays(thisWeekStart, -1) };
}

export type GroupBy = 'day' | 'week' | 'month';

/** ISO weekday of a YYYY-MM-DD date: 1 = Monday ... 7 = Sunday. */
function isoWeekday(date: string): number {
  return ((new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7) + 1;
}

/**
 * The first day of the day, week or month that `date` falls in. Weeks start on `weekStartsOn`
 * (1 = Monday ... 7 = Sunday), like the billing week.
 */
export function periodStart(date: string, groupBy: GroupBy, weekStartsOn: number): string {
  if (groupBy === 'day') return date;
  if (groupBy === 'month') return `${date.slice(0, 7)}-01`;
  return addDays(date, -((isoWeekday(date) - weekStartsOn + 7) % 7));
}

/** The last day of the period that starts on `start`. */
function periodEnd(start: string, groupBy: GroupBy): string {
  if (groupBy === 'day') return start;
  if (groupBy === 'week') return addDays(start, 6);
  const [year, month] = start.split('-').map(Number) as [number, number];
  return addDays(
    month === 12 ? `${year + 1}-01-01` : `${year}-${String(month + 1).padStart(2, '0')}-01`,
    -1,
  );
}

/**
 * Every day, week or month from `from` to `to`, in order. `key` is the period's real first day
 * (what a database groups by); `start` and `end` are clipped to the requested dates, so a report
 * from the 10th shows its first week as starting on the 10th.
 */
export function periods(
  from: string,
  to: string,
  groupBy: GroupBy,
  weekStartsOn: number,
): { key: string; start: string; end: string }[] {
  const result: { key: string; start: string; end: string }[] = [];
  let key = periodStart(from, groupBy, weekStartsOn);
  while (key <= to) {
    const end = periodEnd(key, groupBy);
    result.push({ key, start: key < from ? from : key, end: end > to ? to : end });
    key = addDays(end, 1);
  }
  return result;
}
