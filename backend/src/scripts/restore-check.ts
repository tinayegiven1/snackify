// Proves a backup can be restored: restores it into the empty scratch database
// snackify_restore_check (or RESTORE_CHECK_DATABASE_URL), compares every table, sequence and
// privilege with what the backup recorded, then empties the scratch database again.
// The real database is not touched.
//
//   npm run db:restore-check                          the newest backup in BACKUP_DIR
//   npm run db:restore-check -- --file <backup.dump>  a particular backup
import { basename, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { loadBackupConfig } from '../backup/backup-config.js';
import { listBackups, readManifest, restoreCheck, type Backup } from '../backup/backups.js';
import { parseConnection } from '../backup/postgres-tools.js';
import { loadDotEnv } from '../config/env.js';
import { logger } from '../utils/logger.js';

loadDotEnv();

try {
  const { values } = parseArgs({ options: { file: { type: 'string' } } });
  const config = loadBackupConfig();

  let backup: Backup;
  if (values.file) {
    const dumpPath = resolve(values.file);
    backup = { dumpPath, manifest: await readManifest(dumpPath) };
  } else {
    const database = parseConnection(config.sourceUrl).database;
    const newest = (await listBackups(config.dir, database))[0];
    if (!newest) {
      throw new Error(`No backups of ${database} in ${config.dir}. Run npm run db:backup first.`);
    }
    backup = newest;
  }

  const result = await restoreCheck(backup, config.restoreCheckUrl);
  const tables = Object.values(backup.manifest.fingerprint.tables);
  const details = {
    file: basename(backup.dumpPath),
    madeAt: backup.manifest.createdAt,
    tables: tables.length,
    rows: tables.reduce((sum, table) => sum + table.rows, 0),
    seconds: Number(result.seconds.toFixed(1)),
  };
  if (result.problems.length > 0) {
    logger.error('Restore check FAILED: the restored copy does not match the backup', {
      ...details,
      problems: result.problems,
    });
    process.exitCode = 1;
  } else {
    logger.info('Restore check passed: every table, sequence and privilege matches', details);
  }
} catch (error) {
  logger.error('Restore check failed', { reason: (error as Error).message });
  process.exitCode = 1;
}
