import pg from 'pg';

/**
 * Makes DATE columns come back as 'YYYY-MM-DD' strings. By default pg turns them into
 * JavaScript Dates at local midnight, which shifts business dates by a day across time zones
 * (e.g. 2026-10-12 in Harare would become 2026-10-11T22:00:00Z).
 *
 * pg keeps this setting globally, so it is applied wherever the app or a pool is created,
 * rather than relying on some other file having been loaded first. Safe to call repeatedly.
 */
export function configurePgTypes(): void {
  pg.types.setTypeParser(pg.types.builtins.DATE, (value) => value);
}
