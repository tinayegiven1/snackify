import { fileURLToPath } from 'node:url';
import { runner } from 'node-pg-migrate';
import { logger } from '../utils/logger.js';

/** SQL migration files live in database/migrations at the repository root. */
export const MIGRATIONS_DIR = fileURLToPath(
  new URL('../../../database/migrations', import.meta.url),
);
export const MIGRATIONS_TABLE = 'schema_migrations';

export type MigrationDirection = 'up' | 'down';

/**
 * Applies pending migrations ('up', all by default) or undoes applied ones ('down', one by
 * default). All migrations in one run share a transaction, so a failure changes nothing.
 * Returns the names of the migrations that ran.
 */
export async function runMigrations(
  databaseUrl: string,
  direction: MigrationDirection,
  options: { count?: number; quiet?: boolean } = {},
): Promise<string[]> {
  const log = options.quiet ? () => {} : (message: string) => logger.info(message);

  const migrations = await runner({
    databaseUrl,
    dir: MIGRATIONS_DIR,
    migrationsTable: MIGRATIONS_TABLE,
    direction,
    ...(options.count === undefined ? {} : { count: options.count }),
    checkOrder: true,
    singleTransaction: true,
    logger: { debug: () => {}, info: log, warn: log, error: log },
  });

  return migrations.map((migration) => migration.name);
}
