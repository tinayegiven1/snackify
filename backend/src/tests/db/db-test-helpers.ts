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

/** Removes all staff accounts, sessions and audit entries (as the owner, who may delete). */
export async function resetAuthTables(ownerPool: pg.Pool): Promise<void> {
  await ownerPool.query('DELETE FROM audit_logs; DELETE FROM sessions; DELETE FROM users;');
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
