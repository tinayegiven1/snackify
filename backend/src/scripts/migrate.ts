// Applies or undoes database migrations, connecting as the schema owner (MIGRATION_DATABASE_URL).
//
//   npm run db:migrate    apply all pending migrations
//   npm run db:rollback   undo the most recent migration (refused in production)
import { loadDotEnv, readDatabaseUrl } from '../config/env.js';
import { runMigrations } from '../database/migrations.js';
import { logger } from '../utils/logger.js';

loadDotEnv();

const direction = process.argv[2] === 'down' ? 'down' : 'up';

try {
  if (direction === 'down' && process.env.NODE_ENV === 'production') {
    throw new Error('Rollback is disabled in production. Write a new forward migration instead.');
  }

  const databaseUrl = readDatabaseUrl('MIGRATION_DATABASE_URL');
  const ran = await runMigrations(databaseUrl, direction, { quiet: true });

  if (ran.length === 0) {
    logger.info(direction === 'up' ? 'Database is up to date' : 'No migrations to roll back');
  } else {
    logger.info(direction === 'up' ? 'Applied migrations' : 'Rolled back migrations', {
      migrations: ran,
    });
  }
} catch (error) {
  logger.error('Migration failed', { reason: (error as Error).message });
  process.exitCode = 1;
}
