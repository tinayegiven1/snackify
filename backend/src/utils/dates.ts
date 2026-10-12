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
