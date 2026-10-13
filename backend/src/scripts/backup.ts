// Backs up the database (MIGRATION_DATABASE_URL) into BACKUP_DIR, proves the new backup can be
// restored, then deletes the oldest backups so that BACKUP_KEEP remain.
//
//   npm run db:backup                 back up, restore-check, prune
//   npm run db:backup -- --no-check   back up and prune only (not recommended)
//
// Old backups are only deleted after the new one has passed its restore check.
import { basename } from 'node:path';
import { parseArgs } from 'node:util';
import { loadBackupConfig } from '../backup/backup-config.js';
import { createBackup, pruneBackups, restoreCheck } from '../backup/backups.js';
import { loadDotEnv } from '../config/env.js';
import { logger } from '../utils/logger.js';

loadDotEnv();

try {
  const { values } = parseArgs({ options: { 'no-check': { type: 'boolean', default: false } } });
  const config = loadBackupConfig();

  const backup = await createBackup(config.sourceUrl, config.dir);
  const tables = Object.values(backup.manifest.fingerprint.tables);
  logger.info('Backup written', {
    file: basename(backup.dumpPath),
    folder: config.dir,
    sizeBytes: backup.manifest.sizeBytes,
    tables: tables.length,
    rows: tables.reduce((sum, table) => sum + table.rows, 0),
  });

  let prune = true;
  if (values['no-check']) {
    logger.warn('Restore check skipped (--no-check)');
  } else {
    const result = await restoreCheck(backup, config.restoreCheckUrl);
    if (result.problems.length > 0) {
      logger.error('Restore check FAILED: the restored copy does not match the backup', {
        file: basename(backup.dumpPath),
        problems: result.problems,
      });
      process.exitCode = 1;
      prune = false;
    } else {
      logger.info('Restore check passed', {
        file: basename(backup.dumpPath),
        seconds: Number(result.seconds.toFixed(1)),
      });
    }
  }

  if (prune) {
    const deleted = await pruneBackups(config.dir, backup.manifest.database, config.keep);
    if (deleted.length > 0) logger.info('Deleted old backups', { keep: config.keep, deleted });
  } else {
    logger.warn('Old backups were kept because the new backup failed its check');
  }
} catch (error) {
  logger.error('Backup failed', { reason: (error as Error).message });
  process.exitCode = 1;
}
