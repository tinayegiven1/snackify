// Restores a backup into the real database (MIGRATION_DATABASE_URL), replacing everything in it.
// For emergencies; stop the API first.
//
//   npm run db:restore -- --file <backup.dump> --confirm snackify_dev
//
// Steps, stopping at the first problem:
//   1. Check the backup file and prove it restores, in the scratch database.
//   2. Back up the current database, so the restore itself can be undone.
//   3. Empty the database, restore the backup, and compare the result with the backup.
// Afterwards run npm run db:migrate, in case the backup is from an older version of Snackify.
import { basename, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { loadBackupConfig } from '../backup/backup-config.js';
import {
  assertRestoreConfirmed,
  compareWithBackup,
  createBackup,
  readManifest,
  restoreBackup,
  restoreCheck,
  wipeDatabase,
} from '../backup/backups.js';
import { parseConnection } from '../backup/postgres-tools.js';
import { loadDotEnv } from '../config/env.js';
import { logger } from '../utils/logger.js';

loadDotEnv();

try {
  const { values } = parseArgs({
    options: { file: { type: 'string' }, confirm: { type: 'string' } },
  });
  if (!values.file) throw new Error('Name the backup to restore: --file <backup.dump>');
  const config = loadBackupConfig();
  assertRestoreConfirmed(config.sourceUrl, values.confirm);
  const target = parseConnection(config.sourceUrl).database;

  const dumpPath = resolve(values.file);
  const backup = { dumpPath, manifest: await readManifest(dumpPath) };

  const check = await restoreCheck(backup, config.restoreCheckUrl);
  if (check.problems.length > 0) {
    throw new Error(
      `The backup did not restore correctly in the scratch database, so ${target} was not ` +
        `touched: ${check.problems.join('; ')}`,
    );
  }
  logger.info('Step 1 of 3: the backup restores correctly', { file: basename(dumpPath) });

  const safety = await createBackup(config.sourceUrl, config.dir);
  logger.info('Step 2 of 3: backed up the current database first', {
    file: basename(safety.dumpPath),
    folder: config.dir,
  });

  await wipeDatabase(config.sourceUrl);
  try {
    await restoreBackup(dumpPath, config.sourceUrl);
  } catch (error) {
    throw new Error(
      `${(error as Error).message}\n${target} is now empty. To put back what was there, run: ` +
        `npm run db:restore -- --file "${safety.dumpPath}" --confirm ${target}`,
      { cause: error },
    );
  }
  const problems = await compareWithBackup(config.sourceUrl, backup.manifest);
  if (problems.length > 0) {
    throw new Error(
      `The restored database does not match the backup: ${problems.join('; ')}\n` +
        `The data from before the restore is in ${safety.dumpPath}`,
    );
  }
  logger.info('Step 3 of 3: restored and checked. Now run npm run db:migrate', {
    database: target,
    file: basename(dumpPath),
    madeAt: backup.manifest.createdAt,
  });
} catch (error) {
  logger.error('Restore failed', { reason: (error as Error).message });
  process.exitCode = 1;
}
