import { mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DEFAULT_BACKUP_DIR, loadBackupConfig } from '../backup/backup-config.js';
import {
  assertRestoreCheckDatabase,
  assertRestoreConfirmed,
  backupFileName,
  listBackups,
  pruneBackups,
  type BackupManifest,
} from '../backup/backups.js';
import { compareFingerprints, SCHEMA_PARTS, type Fingerprint } from '../backup/fingerprint.js';
import { parseConnection, withDatabase } from '../backup/postgres-tools.js';

const OWNER_URL = 'postgres://snackify_owner:p%40ss%3Aword@localhost:5432/snackify_dev';

function fingerprint(): Fingerprint {
  return {
    tables: {
      customers: { rows: 3, hash: 'c1' },
      products: { rows: 10, hash: 'p1' },
    },
    sequences: { customer_code_seq: { lastValue: '3', isCalled: true } },
    schema: Object.fromEntries(
      SCHEMA_PARTS.map((part) => [part, { count: 5, hash: `${part}-1` }]),
    ) as Fingerprint['schema'],
  };
}

describe('backup settings', () => {
  it('back up the migration database and restore-check into snackify_restore_check', () => {
    const config = loadBackupConfig({ MIGRATION_DATABASE_URL: OWNER_URL });
    expect(config).toEqual({
      sourceUrl: OWNER_URL,
      restoreCheckUrl:
        'postgres://snackify_owner:p%40ss%3Aword@localhost:5432/snackify_restore_check',
      dir: DEFAULT_BACKUP_DIR,
      keep: 30,
    });
    expect(DEFAULT_BACKUP_DIR).toMatch(/[\\/]snackify[\\/]backups$/);
  });

  it('can be changed with environment variables', () => {
    const config = loadBackupConfig({
      MIGRATION_DATABASE_URL: OWNER_URL,
      RESTORE_CHECK_DATABASE_URL: 'postgres://checker:secret@backup-host:5433/x_restore_check',
      BACKUP_DIR: 'D:\\Backups\\Snackify',
      BACKUP_KEEP: '14',
    });
    expect(config).toMatchObject({
      restoreCheckUrl: 'postgres://checker:secret@backup-host:5433/x_restore_check',
      dir: 'D:\\Backups\\Snackify',
      keep: 14,
    });
  });

  it('reject an invalid number of backups to keep without echoing secrets', () => {
    for (const keep of ['0', 'ten', '2.5']) {
      expect(() =>
        loadBackupConfig({ MIGRATION_DATABASE_URL: OWNER_URL, BACKUP_KEEP: keep }),
      ).toThrow(/BACKUP_KEEP/);
    }
    expect(() => loadBackupConfig({})).toThrow(/MIGRATION_DATABASE_URL/);
    expect(() =>
      loadBackupConfig({ MIGRATION_DATABASE_URL: 'mysql://root:hunter2@localhost/x' }),
    ).toThrow(expect.objectContaining({ message: expect.not.stringContaining('hunter2') }));
  });

  it('read connection details, including an encoded password', () => {
    expect(parseConnection(OWNER_URL)).toEqual({
      host: 'localhost',
      port: '5432',
      user: 'snackify_owner',
      password: 'p@ss:word',
      database: 'snackify_dev',
    });
    expect(parseConnection('postgres://u:p@db.example.com/snackify').port).toBe('5432');
    expect(withDatabase(OWNER_URL, 'other')).toBe(
      'postgres://snackify_owner:p%40ss%3Aword@localhost:5432/other',
    );
  });
});

describe('restore safeguards', () => {
  it('only restore-check into a database named for it', () => {
    expect(() =>
      assertRestoreCheckDatabase(withDatabase(OWNER_URL, 'snackify_restore_check')),
    ).not.toThrow();
    expect(() => assertRestoreCheckDatabase(OWNER_URL)).toThrow(/not "snackify_dev"/);
  });

  it('only restore for real when the database name is typed as confirmation', () => {
    expect(() => assertRestoreConfirmed(OWNER_URL, 'snackify_dev')).not.toThrow();
    for (const confirmation of [undefined, '', 'yes', 'snackify_test', 'SNACKIFY_DEV']) {
      expect(() => assertRestoreConfirmed(OWNER_URL, confirmation)).toThrow(
        'To go ahead, add --confirm snackify_dev',
      );
    }
  });
});

describe('comparing a restored copy with its backup', () => {
  it('finds nothing to report when they match', () => {
    expect(compareFingerprints(fingerprint(), fingerprint())).toEqual([]);
  });

  it('describes every difference in words', () => {
    const restored = fingerprint();
    delete restored.tables.customers;
    restored.tables.products = { rows: 10, hash: 'p2' };
    restored.tables.extra = { rows: 0, hash: 'e' };
    restored.sequences.customer_code_seq = { lastValue: '1', isCalled: true };
    restored.schema.triggers = { count: 4, hash: 'triggers-2' };
    restored.schema.privileges = { count: 5, hash: 'privileges-2' };

    expect(compareFingerprints(fingerprint(), restored)).toEqual([
      'table customers is missing from the restored copy',
      'table extra is in the restored copy but not in the backup',
      'table products: same number of rows, but the contents differ',
      'sequence customer_code_seq: at 3 in the backup, 1 restored',
      'triggers: 5 in the backup, 4 restored',
      'privileges: same number, but the definitions differ',
    ]);
  });
});

describe('backup files', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'snackify-backups-'));
  });
  afterEach(() => rm(dir, { recursive: true, force: true }));

  async function fakeBackup(database: string, at: string, withManifest = true): Promise<string> {
    const name = backupFileName(database, new Date(at));
    await writeFile(join(dir, name), 'dump');
    if (withManifest) {
      const manifest: BackupManifest = {
        format: 1,
        database,
        createdAt: new Date(at).toISOString(),
        file: name,
        sizeBytes: 4,
        sha256: 'x',
        serverVersion: '18.6',
        latestMigration: null,
        fingerprint: fingerprint(),
      };
      await writeFile(join(dir, `${name}.json`), JSON.stringify(manifest));
    }
    return name;
  }

  it('are named by database and time, so they sort in order', () => {
    expect(backupFileName('snackify_dev', new Date('2026-10-13T08:05:09.042Z'))).toBe(
      'snackify_dev-20261013T080509.042Z.dump',
    );
  });

  it('are listed newest first, ignoring unfinished backups and other databases', async () => {
    const older = await fakeBackup('snackify_dev', '2026-10-11T22:00:00Z');
    const newer = await fakeBackup('snackify_dev', '2026-10-12T22:00:00Z');
    await fakeBackup('snackify_dev', '2026-10-13T22:00:00Z', false);
    await fakeBackup('snackify_test', '2026-10-13T23:00:00Z');
    await writeFile(join(dir, 'notes.txt'), 'keep me');

    const backups = await listBackups(dir, 'snackify_dev');
    expect(backups.map((b) => b.manifest.file)).toEqual([newer, older]);
    expect(await listBackups(join(dir, 'missing'))).toEqual([]);
  });

  it('are pruned to the newest few, leaving everything else alone', async () => {
    const names = [];
    for (const day of ['09', '10', '11', '12', '13']) {
      names.push(await fakeBackup('snackify_dev', `2026-10-${day}T22:00:00Z`));
    }
    const other = await fakeBackup('snackify_test', '2026-10-01T22:00:00Z');
    await writeFile(join(dir, 'notes.txt'), 'keep me');

    const deleted = await pruneBackups(dir, 'snackify_dev', 3);

    expect(deleted).toEqual([names[1], names[0]]);
    expect((await readdir(dir)).sort()).toEqual(
      [
        ...names.slice(2).flatMap((name) => [name, `${name}.json`]),
        other,
        `${other}.json`,
        'notes.txt',
      ].sort(),
    );
    await expect(pruneBackups(dir, 'snackify_dev', 0)).rejects.toThrow(/at least one/);
  });
});
