import { runMigrations } from '../../database/migrations.js';
import { migrateTestDatabase, ownerDatabaseUrl } from './db-test-helpers.js';

/**
 * Runs once before the database tests: rebuilds the test schema from the migrations,
 * so results never depend on changes someone made to snackify_test by hand.
 */
export default async function setup(): Promise<void> {
  await runMigrations(ownerDatabaseUrl, 'down', { count: Number.POSITIVE_INFINITY, quiet: true });
  await migrateTestDatabase();
}
