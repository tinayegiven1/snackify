import { createHash } from 'node:crypto';
import { copyFile, mkdtemp, readdir, readFile, rm, truncate, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  compareWithBackup,
  createBackup,
  manifestPathOf,
  restoreBackup,
  restoreCheck,
  verifyArchive,
  wipeDatabase,
  type Backup,
} from '../../backup/backups.js';
import { RESTORE_CHECK_DATABASE } from '../../backup/backup-config.js';
import { withDatabase } from '../../backup/postgres-tools.js';
import { MIGRATIONS_DIR } from '../../database/migrations.js';
import {
  createTestPools,
  createTestProduct,
  createTestUser,
  ownerDatabaseUrl,
  resetDatabase,
} from './db-test-helpers.js';

// Backs up snackify_test and restores it into the scratch database snackify_restore_check
// (created by database/setup/local-setup.sql), exactly as npm run db:backup does.
const scratchUrl = withDatabase(ownerDatabaseUrl, RESTORE_CHECK_DATABASE);
const pools = createTestPools();
const scratch = new pg.Pool({ connectionString: scratchUrl, max: 1 });
let dir: string;

async function seed(): Promise<void> {
  await resetDatabase(pools.owner);
  await pools.owner.query('ALTER SEQUENCE customer_code_seq RESTART');
  await createTestProduct(pools.owner, { sku: 'PC-BBQ-S', reorderLevel: 24 });
  await createTestProduct(pools.owner, { sku: 'MP-CH-S', name: 'Maize Puffs', flavour: 'Cheese' });
  await createTestUser(pools.app, {
    username: 'backup-check',
    role: 'admin',
    password: 'a-long-test-password',
  });
  // Text that is easy to mangle (an apostrophe, a dash, an accent), a NULL and an exact amount.
  await pools.owner.query(
    `INSERT INTO customers (code, name, phone, address, credit_limit)
     VALUES ('C' || lpad(nextval('customer_code_seq')::text, 4, '0'),
             'Mai Chipo''s Tuckshop — Mbare', NULL, 'Stand 12, Café Road', 1250.75)`,
  );
}

async function publicTables(): Promise<string[]> {
  const { rows } = await scratch.query<{ name: string }>(
    `SELECT relname AS name FROM pg_class WHERE relnamespace = 'public'::regnamespace`,
  );
  return rows.map((row) => row.name);
}

beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), 'snackify-backup-test-'));
});

afterAll(async () => {
  await wipeDatabase(scratchUrl);
  await scratch.end();
  await pools.close();
  await rm(dir, { recursive: true, force: true });
});

beforeEach(seed);

describe('backups', () => {
  it('restore into an empty database and match the original exactly', async () => {
    const backup = await createBackup(ownerDatabaseUrl, dir);

    const migrations = (await readdir(MIGRATIONS_DIR)).filter((name) => name.endsWith('.sql'));
    expect(backup.manifest).toMatchObject({
      database: 'snackify_test',
      latestMigration: migrations
        .sort()
        .at(-1)
        ?.replace(/\.sql$/, ''),
    });
    expect(backup.manifest.fingerprint.tables.products?.rows).toBe(2);
    expect(backup.manifest.fingerprint.tables.customers?.rows).toBe(1);
    expect(backup.manifest.fingerprint.sequences.customer_code_seq).toEqual({
      lastValue: '1',
      isCalled: true,
    });

    const result = await restoreCheck(backup, scratchUrl);

    expect(result.problems).toEqual([]);
    // The restored copy of the business data is removed again afterwards.
    expect(await publicTables()).toEqual([]);
  });

  it('capture one moment, even if the data changes after the backup', async () => {
    const backup = await createBackup(ownerDatabaseUrl, dir);
    await createTestProduct(pools.owner, { sku: 'PC-SV-S', flavour: 'Salt & Vinegar' });

    await wipeDatabase(scratchUrl);
    await restoreBackup(backup.dumpPath, scratchUrl);

    const { rows } = await scratch.query<{ name: string; credit_limit: string }>(
      'SELECT name, credit_limit FROM customers',
    );
    expect(rows).toEqual([{ name: "Mai Chipo's Tuckshop — Mbare", credit_limit: '1250.75' }]);
    expect((await scratch.query('SELECT 1 FROM products')).rowCount).toBe(2);
    expect(await compareWithBackup(scratchUrl, backup.manifest)).toEqual([]);
  });

  it('report a restored copy that lost or changed anything', async () => {
    const backup = await createBackup(ownerDatabaseUrl, dir);
    await wipeDatabase(scratchUrl);
    await restoreBackup(backup.dumpPath, scratchUrl);

    await scratch.query(`DELETE FROM products WHERE sku = 'MP-CH-S'`);
    await scratch.query(`UPDATE customers SET credit_limit = 1250.70`);
    await scratch.query(`SELECT setval('customer_code_seq', 1, false)`);
    await scratch.query('DROP TRIGGER customers_set_updated_at ON customers');
    // The app role must never be able to rewrite the stock ledger.
    await scratch.query('GRANT UPDATE ON stock_movements TO snackify_app');

    expect(await compareWithBackup(scratchUrl, backup.manifest)).toEqual([
      'table customers: same number of rows, but the contents differ',
      'table products: 2 rows in the backup, 1 restored',
      'sequence customer_code_seq: at 1 in the backup, 1 restored (used/unused state differs)',
      'triggers: 23 in the backup, 22 restored',
      'privileges: same number, but the definitions differ',
    ]);
  });

  it('refuse a backup file that was damaged after it was made', async () => {
    const backup = await createBackup(ownerDatabaseUrl, dir);
    const damaged: Backup = { ...backup, dumpPath: join(dir, 'damaged.dump') };
    await copyFile(backup.dumpPath, damaged.dumpPath);
    const bytes = await readFile(damaged.dumpPath);
    const middle = Math.floor(bytes.length / 2);
    bytes.writeUInt8(bytes.readUInt8(middle) ^ 0xff, middle);
    await writeFile(damaged.dumpPath, bytes);

    await expect(verifyArchive(damaged)).rejects.toThrow(/checksum mismatch/);
    await expect(restoreCheck(damaged, scratchUrl)).rejects.toThrow(/checksum mismatch/);
  });

  it('fail clearly, and leave nothing behind, when a backup cannot be restored', async () => {
    const backup = await createBackup(ownerDatabaseUrl, dir);
    // A file missing its last few bytes, with a manifest updated to match: the checksum and the
    // table of contents pass, but the last table's data is incomplete.
    const cut: Backup = { ...backup, dumpPath: join(dir, 'cut-off.dump') };
    await copyFile(backup.dumpPath, cut.dumpPath);
    await truncate(cut.dumpPath, backup.manifest.sizeBytes - 16);
    const reread = await matchManifestToFile(cut);

    await verifyArchive(reread);
    // Something is left in the scratch database from before, to show the check cleans up.
    await wipeDatabase(scratchUrl);
    await restoreBackup(backup.dumpPath, scratchUrl);

    await expect(restoreCheck(reread, scratchUrl)).rejects.toThrow(/^pg_restore failed/);
    expect(await publicTables()).toEqual([]);
  });

  it('only restore-check into a database meant for it', async () => {
    const backup = await createBackup(ownerDatabaseUrl, dir);
    await expect(restoreCheck(backup, ownerDatabaseUrl)).rejects.toThrow(
      'must be named like snackify_restore_check, not "snackify_test"',
    );
    // The real test data is untouched.
    expect((await pools.owner.query('SELECT 1 FROM products')).rowCount).toBe(2);
  });
});

/** Rewrites the manifest's size and checksum to match the file as it is now. */
async function matchManifestToFile(backup: Backup): Promise<Backup> {
  const bytes = await readFile(backup.dumpPath);
  const manifest = {
    ...backup.manifest,
    sizeBytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
  await writeFile(manifestPathOf(backup.dumpPath), JSON.stringify(manifest));
  return { dumpPath: backup.dumpPath, manifest };
}
