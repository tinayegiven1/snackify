import type { Express } from 'express';
import pg from 'pg';
import request from 'supertest';
import { createApp } from '../../app.js';
import { loadDotEnv, readDatabaseUrl } from '../../config/env.js';
import { runMigrations } from '../../database/migrations.js';
import type { Role } from '../../modules/auth/roles.js';
import { createUser, type StaffUser } from '../../modules/users/users.service.js';
import { testConfig } from '../test-config.js';

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

/** The full app on the real test database. Create a new one per test for a fresh rate limiter. */
export function createDbTestApp(appPool: pg.Pool): Express {
  return createApp(testConfig, { db: appPool, checkDatabase: async () => true });
}

/**
 * Empties every table (as the owner). TRUNCATE skips the row-by-row safety triggers, which
 * would otherwise refuse to remove the lines of confirmed dispatches.
 * Each test starts from an empty database this way.
 */
export async function resetDatabase(ownerPool: pg.Pool): Promise<void> {
  await ownerPool.query(`
    TRUNCATE payment_allocations, payments, invoice_items, invoices, stock_movements, stock_batches, dispatch_items, dispatches, audit_logs,
             sessions, users, products, customers`);
}

/** Adds a product directly (as the owner) and returns its id. */
export async function createTestProduct(
  ownerPool: pg.Pool,
  product: Partial<{
    sku: string;
    name: string;
    flavour: string;
    size: string;
    reorderLevel: number | null;
    isActive: boolean;
  }> = {},
): Promise<string> {
  const p = {
    sku: 'PC-BBQ-S',
    name: 'Potato Crisps',
    flavour: 'BBQ',
    size: 'Small',
    reorderLevel: null,
    isActive: true,
    ...product,
  };
  const { rows } = await ownerPool.query<{ id: string }>(
    `INSERT INTO products (sku, name, flavour, size, default_price, reorder_level, is_active)
     VALUES ($1, $2, $3, $4, 0.50, $5, $6) RETURNING id`,
    [p.sku, p.name, p.flavour, p.size, p.reorderLevel, p.isActive],
  );
  return (rows[0] as { id: string }).id;
}

export function createTestUser(
  appPool: pg.Pool,
  user: { username: string; fullName?: string; role: Role; password: string },
): Promise<StaffUser> {
  return createUser(
    appPool,
    { fullName: `Test ${user.username}`, ...user },
    { actorUserId: null, via: 'cli' },
  );
}

/** Signs in through the API and returns the session token. */
export async function signIn(app: Express, username: string, password: string): Promise<string> {
  const response = await request(app).post('/api/v1/auth/login').send({ username, password });
  if (response.status !== 200) {
    throw new Error(`Sign-in failed: ${response.status} ${JSON.stringify(response.body)}`);
  }
  return response.body.token as string;
}

export async function auditEntries(ownerPool: pg.Pool, action: string) {
  const { rows } = await ownerPool.query<{
    actor_user_id: string | null;
    entity_id: string | null;
    details: Record<string, unknown>;
  }>(
    'SELECT actor_user_id, entity_id, details FROM audit_logs WHERE action = $1 ORDER BY occurred_at',
    [action],
  );
  return rows;
}

/** PostgreSQL error codes used in assertions. */
export const PG = {
  uniqueViolation: '23505',
  checkViolation: '23514',
  insufficientPrivilege: '42501',
} as const;
