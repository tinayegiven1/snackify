import type pg from 'pg';

/** Anything that can run a query: the pool, or a client inside a transaction. */
export type Queryable = pg.Pool | pg.PoolClient;

/**
 * Runs `work` inside a database transaction. Everything it does is saved together,
 * or, if it throws, nothing is saved.
 */
export async function withTransaction<T>(
  pool: pg.Pool,
  work: (client: pg.PoolClient) => Promise<T>,
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await work(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

/** True when `error` is a PostgreSQL unique-constraint violation on `constraint`. */
export function isUniqueViolation(error: unknown, constraint: string): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    error.code === '23505' &&
    'constraint' in error &&
    error.constraint === constraint
  );
}
