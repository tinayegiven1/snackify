import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { readDatabaseUrl } from '../config/env.js';
import { withDatabase } from './postgres-tools.js';

/** The backups folder at the repository root (ignored by Git). */
export const DEFAULT_BACKUP_DIR = fileURLToPath(new URL('../../../backups', import.meta.url));
export const RESTORE_CHECK_DATABASE = 'snackify_restore_check';

export interface BackupConfig {
  /** The database to back up, as its owner (MIGRATION_DATABASE_URL). */
  sourceUrl: string;
  /** The empty scratch database that restore checks restore into. */
  restoreCheckUrl: string;
  dir: string;
  keep: number;
}

const keepSchema = z.coerce
  .number({ error: 'Must be a whole number' })
  .int('Must be a whole number')
  .min(1, 'Keep at least 1 backup')
  .max(1000, 'Must be at most 1000')
  .default(30);

/**
 * Reads the backup settings. Without RESTORE_CHECK_DATABASE_URL, restore checks use the
 * owner's login on the same server with the database snackify_restore_check.
 */
export function loadBackupConfig(env: NodeJS.ProcessEnv = process.env): BackupConfig {
  const sourceUrl = readDatabaseUrl('MIGRATION_DATABASE_URL', env);
  const keep = keepSchema.safeParse(env.BACKUP_KEEP || undefined);
  if (!keep.success) {
    throw new Error(
      `Invalid environment configuration:\n  - BACKUP_KEEP: ${keep.error.issues[0]?.message}`,
    );
  }
  return {
    sourceUrl,
    restoreCheckUrl: env.RESTORE_CHECK_DATABASE_URL
      ? readDatabaseUrl('RESTORE_CHECK_DATABASE_URL', env)
      : withDatabase(sourceUrl, RESTORE_CHECK_DATABASE),
    dir: env.BACKUP_DIR || DEFAULT_BACKUP_DIR,
    keep: keep.data,
  };
}
