import pg from 'pg';
import { logger } from '../utils/logger.js';

// Return DATE columns as 'YYYY-MM-DD' strings. By default pg turns them into JavaScript
// Dates at local midnight, which can shift business dates by a day across time zones.
pg.types.setTypeParser(pg.types.builtins.DATE, (value) => value);

export function createPool(connectionString: string): pg.Pool {
  const pool = new pg.Pool({
    connectionString,
    max: 10,
    connectionTimeoutMillis: 5_000,
    idleTimeoutMillis: 30_000,
    application_name: 'snackify-api',
  });

  // An idle connection can drop (for example when PostgreSQL restarts). Log it instead of crashing.
  pool.on('error', (error) => {
    logger.error('Idle database connection error', { reason: error.message });
  });

  return pool;
}

/** Returns a function that reports whether the database answers within `timeoutMs`. */
export function databaseHealthCheck(pool: pg.Pool, timeoutMs = 2_000): () => Promise<boolean> {
  return async () => {
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error(`No reply within ${timeoutMs} ms`)), timeoutMs);
    });

    try {
      await Promise.race([pool.query('SELECT 1'), timeout]);
      return true;
    } catch (error) {
      logger.warn('Database health check failed', { reason: (error as Error).message });
      return false;
    } finally {
      clearTimeout(timer);
    }
  };
}
