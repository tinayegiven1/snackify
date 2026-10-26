import type { Express } from 'express';
import pg from 'pg';
import request from 'supertest';
import { createApp } from '../../app.js';
import { loadDotEnv, readDatabaseUrl } from '../../config/env.js';
import { runMigrations } from '../../database/migrations.js';
import { LEGACY_ROLE_ALIASES } from '../../modules/auth/permissions.js';
import type { PublicUser } from '../../modules/auth/roles.js';
import { receiveStock } from '../../modules/stock/stock.service.js';
import { businessToday } from '../../utils/dates.js';
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
    TRUNCATE forecasts, forecast_runs, payment_allocations, payments, invoice_items, invoices, stock_balances, stock_movements, stock_batches, stock_receipt_attachments,
             stock_receipt_lines, stock_receipts, order_item_changes, order_status_history,
             order_items, orders, dispatch_items, dispatches, audit_logs,
             sessions, user_roles, users, unit_conversions, products, product_categories, suppliers, customers`);
  // Only what the migrations create stays: the default warehouse and the standard units.
  await ownerPool.query(`DELETE FROM warehouses WHERE NOT is_default`);
  await ownerPool.query(`DELETE FROM units WHERE code NOT IN ('pack', 'carton', 'case')`);
  // Only the Head Office (created by the migrations) stays, with its original details.
  await ownerPool.query(`DELETE FROM organisations WHERE organisation_type <> 'HQ'`);
  await ownerPool.query(`
    UPDATE organisations
    SET code = 'HQ', name = 'Head Office', is_active = true, contact_name = NULL,
        contact_phone = NULL, contact_email = NULL, address = NULL, billing_name = NULL,
        billing_address = NULL, tax_number = NULL
    WHERE organisation_type = 'HQ'`);
}

/** The old single roles, still used by most tests; each stands for the roles it became. */
export type Role = 'admin' | 'storekeeper' | 'salesperson' | 'accounts';

/** The Head Office's id. */
export async function headOfficeId(pool: pg.Pool): Promise<string> {
  const { rows } = await pool.query<{ id: string }>('SELECT hq_organisation_id() AS id');
  return (rows[0] as { id: string }).id;
}

/** Adds a subsidiary directly (as the owner) and returns its id. */
export async function createTestSubsidiary(
  ownerPool: pg.Pool,
  code: string,
  name = `Subsidiary ${code}`,
): Promise<string> {
  const { rows } = await ownerPool.query<{ id: string }>(
    `INSERT INTO organisations (code, name, organisation_type) VALUES ($1, $2, 'SUBSIDIARY')
     RETURNING id`,
    [code, name],
  );
  return (rows[0] as { id: string }).id;
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

/**
 * Puts Head Office stock in directly, as a delivery recorded without a goods-received note (as
 * before StockFlow Stage 4), for tests that need stock but are not about receiving it. Recorded
 * as the first staff account, so create one first.
 */
export async function receiveTestStock(
  appPool: pg.Pool,
  input: {
    productId: string;
    quantity: number;
    receivedDate?: string;
    batchNumber?: string | null;
    expiryDate?: string | null;
    supplierReference?: string | null;
    isOpeningBalance?: boolean;
  },
) {
  const { rows } = await appPool.query<{ id: string }>(
    'SELECT id FROM users ORDER BY created_at LIMIT 1',
  );
  if (!rows[0]) throw new Error('receiveTestStock needs a staff account');
  return receiveStock(
    appPool,
    {
      productId: input.productId,
      quantity: input.quantity,
      receivedDate: input.receivedDate ?? businessToday(testConfig.businessTimezone),
      batchNumber: input.batchNumber ?? null,
      expiryDate: input.expiryDate ?? null,
      supplierReference: input.supplierReference ?? null,
      isOpeningBalance: input.isOpeningBalance ?? false,
    },
    { id: rows[0].id } as PublicUser,
  );
}

/**
 * Creates a staff account. Give either an old `role` (a Head Office user with the roles it
 * became) or `roleCodes` plus `organisationId`.
 */
export async function createTestUser(
  appPool: pg.Pool,
  user: {
    username: string;
    fullName?: string;
    /** The account's PIN (test accounts get their own, so they need not change it). */
    password: string;
    role?: Role;
    roleCodes?: string[];
    organisationId?: string;
  },
): Promise<StaffUser> {
  const roleCodes = user.roleCodes ?? LEGACY_ROLE_ALIASES[user.role ?? 'salesperson'] ?? [];
  return createUser(
    appPool,
    {
      username: user.username,
      fullName: user.fullName ?? `Test ${user.username}`,
      pin: user.password,
      roleCodes: [...roleCodes].sort(),
      organisationId: user.organisationId ?? (await headOfficeId(appPool)),
    },
    { actorUserId: null, via: 'cli' },
  );
}

/** Signs in through the API with the user's PIN and returns the session token. */
export async function signIn(app: Express, username: string, password: string): Promise<string> {
  const response = await request(app).post('/api/v1/auth/login').send({ username, pin: password });
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
