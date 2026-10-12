import pg from 'pg';
import { loadDotEnv, readDatabaseUrl } from '../../config/env.js';
import { runMigrations } from '../../database/migrations.js';

loadDotEnv();

/** Tests delete data, so refuse any database whose name does not end in "_test". */
function testDatabaseUrl(name: string): string {
  const url = readDatabaseUrl(name);
  const database = new URL(url).pathname.slice(1);
  if (!database.endsWith('_test')) {
    throw new Error(`${name} must point to a database ending in _test, not "${database}".`);
  }
  return url;
}

/** Connects as the API role (snackify_app): the privileges the real app has. */
export const appDatabaseUrl = testDatabaseUrl('TEST_DATABASE_URL');
/** Connects as the schema owner (snackify_owner): used for migrations and cleanup. */
export const ownerDatabaseUrl = testDatabaseUrl('TEST_MIGRATION_DATABASE_URL');

export function migrateTestDatabase(): Promise<string[]> {
  return runMigrations(ownerDatabaseUrl, 'up', { quiet: true });
}

export function createTestPools() {
  const app = new pg.Pool({ connectionString: appDatabaseUrl, max: 2 });
  const owner = new pg.Pool({ connectionString: ownerDatabaseUrl, max: 2 });
  return {
    app,
    owner,
    close: () => Promise.all([app.end(), owner.end()]),
  };
}

/** Awaits a query that must fail and returns the PostgreSQL error (code, constraint, ...). */
export async function pgErrorOf(query: Promise<unknown>): Promise<pg.DatabaseError> {
  try {
    await query;
  } catch (error) {
    return error as pg.DatabaseError;
  }
  throw new Error('Expected the query to fail, but it succeeded.');
}

/** PostgreSQL error codes used in assertions. */
export const PG = {
  uniqueViolation: '23505',
  checkViolation: '23514',
  insufficientPrivilege: '42501',
} as const;
