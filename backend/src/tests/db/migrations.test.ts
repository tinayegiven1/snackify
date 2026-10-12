import { afterAll, describe, expect, it } from 'vitest';
import { runMigrations } from '../../database/migrations.js';
import { createTestPools, migrateTestDatabase, ownerDatabaseUrl } from './db-test-helpers.js';

const pools = createTestPools();

async function tableExists(name: string): Promise<boolean> {
  const result = await pools.owner.query<{ exists: boolean }>(
    'SELECT to_regclass($1) IS NOT NULL AS exists',
    [`public.${name}`],
  );
  return result.rows[0]?.exists ?? false;
}

describe('database migrations', () => {
  afterAll(() => pools.close());

  it('apply, roll back completely, and apply again cleanly', async () => {
    await migrateTestDatabase();
    expect(await tableExists('products')).toBe(true);

    const rolledBack = await runMigrations(ownerDatabaseUrl, 'down', {
      count: Number.POSITIVE_INFINITY,
      quiet: true,
    });
    expect(rolledBack).toContain('20261012120000000_create-products');
    expect(await tableExists('products')).toBe(false);

    const applied = await migrateTestDatabase();
    expect(applied).toEqual(rolledBack.toReversed());
    expect(await tableExists('products')).toBe(true);
  });

  it('does nothing when the database is already up to date', async () => {
    expect(await migrateTestDatabase()).toEqual([]);
  });
});
