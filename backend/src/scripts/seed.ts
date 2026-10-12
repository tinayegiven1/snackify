// Loads sample data for local development: npm run db:seed
//
// Runs every .sql file in database/seeds (in name order) as the API role, each in its own
// transaction. Seed files must be safe to run repeatedly and contain no real customer data.
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { loadDotEnv, readDatabaseUrl } from '../config/env.js';
import { logger } from '../utils/logger.js';

const SEEDS_DIR = fileURLToPath(new URL('../../../database/seeds', import.meta.url));

loadDotEnv();

let client: pg.Client | undefined;

try {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('Seeding is disabled in production.');
  }

  const files = (await readdir(SEEDS_DIR)).filter((name) => name.endsWith('.sql')).sort();
  client = new pg.Client({ connectionString: readDatabaseUrl('DATABASE_URL') });
  await client.connect();

  for (const file of files) {
    const sql = await readFile(join(SEEDS_DIR, file), 'utf8');
    await client.query('BEGIN');
    try {
      await client.query(sql);
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw new Error(`${file}: ${(error as Error).message}`, { cause: error });
    }
    logger.info('Seeded', { file });
  }
} catch (error) {
  logger.error('Seeding failed', { reason: (error as Error).message });
  process.exitCode = 1;
} finally {
  await client?.end();
}
