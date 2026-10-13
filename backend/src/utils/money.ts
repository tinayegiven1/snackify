/**
 * Whole cents for exact sums and comparisons of money. Amounts travel as decimal strings with
 * at most two places ("12.34", "-0.50"), as PostgreSQL's numeric(14, 2) returns them; cents up to
 * 10^12 are exact in a JavaScript number.
 */
export function toCents(amount: string): number {
  const negative = amount.startsWith('-');
  const [whole = '0', fraction = ''] = amount.replace(/^[-+]/, '').split('.');
  const cents = Number(whole) * 100 + Number(fraction.padEnd(2, '0').slice(0, 2));
  return negative ? -cents : cents;
}

/** 1234 -> "12.34", -50 -> "-0.50". */
export function fromCents(cents: number): string {
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(cents);
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}
