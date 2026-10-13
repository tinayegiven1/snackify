import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import pg from 'pg';
import { z } from 'zod';
import { MIGRATIONS_TABLE } from '../database/migrations.js';
import { compareFingerprints, fingerprintDatabase, type Fingerprint } from './fingerprint.js';
import { parseConnection, runPostgresTool } from './postgres-tools.js';

/**
 * Written next to each backup file (as <backup>.json). It records what the backup should
 * contain, so a restore can be checked against it, and a checksum that reveals a damaged file.
 */
export interface BackupManifest {
  format: 1;
  database: string;
  createdAt: string;
  file: string;
  sizeBytes: number;
  sha256: string;
  serverVersion: string;
  latestMigration: string | null;
  fingerprint: Fingerprint;
}

export interface Backup {
  dumpPath: string;
  manifest: BackupManifest;
}

const BACKUP_FILE = /^(?<database>.+)-(?<stamp>\d{8}T\d{6}\.\d{3}Z)\.dump$/;

/** For example snackify_dev-20261013T101500.123Z.dump: sorts by time, safe on every system. */
export function backupFileName(database: string, at: Date): string {
  return `${database}-${at.toISOString().replace(/[-:]/g, '')}.dump`;
}

export const manifestPathOf = (dumpPath: string) => `${dumpPath}.json`;

/**
 * Backs up the database at `databaseUrl` (connect as the schema owner) into `dir`.
 *
 * The dump and the fingerprint come from one snapshot of the database, so they agree even while
 * the app keeps writing. The dump is written under a temporary name and only renamed once
 * pg_restore can read it; the manifest is written last. An interrupted backup therefore never
 * looks like a complete one.
 */
export async function createBackup(
  databaseUrl: string,
  dir: string,
  now = new Date(),
): Promise<Backup> {
  const connection = parseConnection(databaseUrl);
  await mkdir(dir, { recursive: true });
  const dumpPath = join(dir, backupFileName(connection.database, now));
  const partialPath = `${dumpPath}.partial`;

  const client = new pg.Client({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const { rows } = await client.query<{ id: string }>('SELECT pg_export_snapshot() AS id');
    const snapshot = (rows[0] as { id: string }).id;

    const fingerprint = await fingerprintDatabase(client);
    const serverVersion = await showServerVersion(client);
    const latestMigration = await readLatestMigration(client);

    // pg_dump reads the exported snapshot, which stays valid while this transaction is open.
    await runPostgresTool(
      'pg_dump',
      ['--format=custom', `--snapshot=${snapshot}`, '--file', partialPath],
      connection,
    );
    await client.query('COMMIT');

    await listArchive(partialPath);
    const { size } = await stat(partialPath);
    const sha256 = await sha256Of(partialPath);
    await rename(partialPath, dumpPath);

    const manifest: BackupManifest = {
      format: 1,
      database: connection.database,
      createdAt: now.toISOString(),
      file: basename(dumpPath),
      sizeBytes: size,
      sha256,
      serverVersion,
      latestMigration,
      fingerprint,
    };
    const manifestPath = manifestPathOf(dumpPath);
    await writeFile(`${manifestPath}.partial`, `${JSON.stringify(manifest, null, 2)}\n`);
    await rename(`${manifestPath}.partial`, manifestPath);
    return { dumpPath, manifest };
  } finally {
    await client.end();
    await rm(partialPath, { force: true });
  }
}

/** Complete backups in `dir` (those with a manifest), newest first. */
export async function listBackups(dir: string, database?: string): Promise<Backup[]> {
  let names: string[];
  try {
    names = await readdir(dir);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw error;
  }
  const present = new Set(names);
  const backups: Backup[] = [];
  for (const name of names) {
    const match = BACKUP_FILE.exec(name);
    if (!match || !present.has(`${name}.json`)) continue;
    if (database && match.groups?.database !== database) continue;
    const dumpPath = join(dir, name);
    backups.push({ dumpPath, manifest: await readManifest(dumpPath) });
  }
  return backups.sort((a, b) => b.manifest.createdAt.localeCompare(a.manifest.createdAt));
}

/** Deletes all but the newest `keep` complete backups of `database`. Returns the deleted files. */
export async function pruneBackups(dir: string, database: string, keep: number): Promise<string[]> {
  if (!Number.isInteger(keep) || keep < 1) throw new Error('Keep at least one backup.');
  const old = (await listBackups(dir, database)).slice(keep);
  for (const { dumpPath } of old) {
    await rm(dumpPath, { force: true });
    await rm(manifestPathOf(dumpPath), { force: true });
  }
  return old.map(({ dumpPath }) => basename(dumpPath));
}

const fingerprintSchema = z.object({
  tables: z.record(z.string(), z.object({ rows: z.number(), hash: z.string() })),
  sequences: z.record(z.string(), z.object({ lastValue: z.string(), isCalled: z.boolean() })),
  schema: z.record(z.string(), z.object({ count: z.number(), hash: z.string() })),
});

const manifestSchema = z.object({
  format: z.literal(1),
  database: z.string(),
  createdAt: z.string(),
  file: z.string(),
  sizeBytes: z.number(),
  sha256: z.string(),
  serverVersion: z.string(),
  latestMigration: z.string().nullable(),
  fingerprint: fingerprintSchema,
});

export async function readManifest(dumpPath: string): Promise<BackupManifest> {
  const path = manifestPathOf(dumpPath);
  let text: string;
  try {
    text = await readFile(path, 'utf8');
  } catch {
    throw new Error(`${basename(path)} is missing, so this backup cannot be checked.`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error(`${basename(path)} is damaged (not valid JSON).`);
  }
  const result = manifestSchema.safeParse(parsed);
  if (!result.success) throw new Error(`${basename(path)} is damaged (unexpected contents).`);
  return result.data as BackupManifest;
}

/**
 * Confirms the backup file is exactly the one that was made (size and SHA-256 checksum) and
 * that pg_restore can read it.
 */
export async function verifyArchive(backup: Backup): Promise<void> {
  const { dumpPath, manifest } = backup;
  const { size } = await stat(dumpPath);
  if (size !== manifest.sizeBytes || (await sha256Of(dumpPath)) !== manifest.sha256) {
    throw new Error(
      `${basename(dumpPath)} has changed or been damaged since it was made (checksum mismatch).`,
    );
  }
  await listArchive(dumpPath);
}

/**
 * Empties the public schema of the database at `databaseUrl`, leaving it like a newly created
 * database (connect as its owner). Everything in it is deleted: only call this on a database
 * that is about to be restored into.
 */
export async function wipeDatabase(databaseUrl: string): Promise<void> {
  const client = new pg.Client({ connectionString: databaseUrl });
  await client.connect();
  try {
    // Fail rather than wait forever if something (like a running API) is using the database.
    await client.query(`SET lock_timeout = '10s'`);
    await client.query('BEGIN');
    await client.query('DROP SCHEMA IF EXISTS public CASCADE');
    await client.query('CREATE SCHEMA public AUTHORIZATION pg_database_owner');
    await client.query(`COMMENT ON SCHEMA public IS 'standard public schema'`);
    await client.query('GRANT USAGE ON SCHEMA public TO PUBLIC');
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    await client.end();
  }
}

/**
 * Restores the backup into the (empty) database at `databaseUrl`, connecting as the schema
 * owner. It all happens in one transaction: if anything fails, nothing is restored. Object
 * ownership goes to the connecting role; privileges, such as the app role's REVOKEs, are kept.
 */
export async function restoreBackup(dumpPath: string, databaseUrl: string): Promise<void> {
  await runPostgresTool(
    'pg_restore',
    ['--no-owner', '--exit-on-error', '--single-transaction', dumpPath],
    parseConnection(databaseUrl),
  );
}

/** Compares the database at `databaseUrl` with what the backup recorded. Returns the differences. */
export async function compareWithBackup(
  databaseUrl: string,
  manifest: BackupManifest,
): Promise<string[]> {
  const client = new pg.Client({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const restored = await fingerprintDatabase(client);
    await client.query('COMMIT');
    return compareFingerprints(manifest.fingerprint, restored);
  } finally {
    await client.end();
  }
}

/** Refuses any database not named like snackify_restore_check, because restoring wipes it. */
export function assertRestoreCheckDatabase(databaseUrl: string): void {
  const { database } = parseConnection(databaseUrl);
  if (!database.endsWith('_restore_check')) {
    throw new Error(
      `Restore checks wipe the database they restore into, so it must be named like ` +
        `snackify_restore_check, not "${database}".`,
    );
  }
}

/** A real restore replaces everything, so the person must type the target database's name. */
export function assertRestoreConfirmed(
  databaseUrl: string,
  confirmation: string | undefined,
): void {
  const { database } = parseConnection(databaseUrl);
  if (confirmation !== database) {
    throw new Error(
      `Restoring replaces everything in "${database}". To go ahead, add --confirm ${database}`,
    );
  }
}

export interface RestoreCheckResult {
  backup: Backup;
  problems: string[];
  seconds: number;
}

/**
 * Proves a backup can be restored: checks the file, restores it into an empty scratch database,
 * compares the result with the backup's manifest, then empties the scratch database again so no
 * copy of the business data is left lying around.
 */
export async function restoreCheck(
  backup: Backup,
  scratchDatabaseUrl: string,
): Promise<RestoreCheckResult> {
  assertRestoreCheckDatabase(scratchDatabaseUrl);
  const started = performance.now();
  await verifyArchive(backup);
  await wipeDatabase(scratchDatabaseUrl);
  try {
    await restoreBackup(backup.dumpPath, scratchDatabaseUrl);
    const problems = await compareWithBackup(scratchDatabaseUrl, backup.manifest);
    return { backup, problems, seconds: (performance.now() - started) / 1000 };
  } finally {
    await wipeDatabase(scratchDatabaseUrl);
  }
}

async function listArchive(dumpPath: string): Promise<void> {
  try {
    await runPostgresTool('pg_restore', ['--list', dumpPath]);
  } catch (error) {
    throw new Error(
      `${basename(dumpPath)} cannot be read as a backup: ${(error as Error).message}`,
      { cause: error },
    );
  }
}

async function sha256Of(path: string): Promise<string> {
  const hash = createHash('sha256');
  await pipeline(createReadStream(path), hash);
  return hash.digest('hex');
}

async function showServerVersion(client: pg.ClientBase): Promise<string> {
  const { rows } = await client.query<{ server_version: string }>('SHOW server_version');
  return (rows[0] as { server_version: string }).server_version;
}

async function readLatestMigration(client: pg.ClientBase): Promise<string | null> {
  const { rows: found } = await client.query<{ exists: boolean }>(
    'SELECT to_regclass($1) IS NOT NULL AS exists',
    [MIGRATIONS_TABLE],
  );
  if (!found[0]?.exists) return null;
  const { rows } = await client.query<{ name: string }>(
    `SELECT name FROM ${client.escapeIdentifier(MIGRATIONS_TABLE)} ORDER BY id DESC LIMIT 1`,
  );
  return rows[0]?.name ?? null;
}
