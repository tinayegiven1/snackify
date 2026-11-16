import { readdir } from 'node:fs/promises';
import { afterAll, describe, expect, it } from 'vitest';
import { MIGRATIONS_DIR, runMigrations } from '../../database/migrations.js';
import {
  createTestPools,
  createTestProduct,
  createTestUser,
  migrateTestDatabase,
  ownerDatabaseUrl,
  resetDatabase,
} from './db-test-helpers.js';

const pools = createTestPools();
const CUSTOMERS_MIGRATION = '20261108090000000_organisations-replace-customers';

async function tableExists(name: string): Promise<boolean> {
  const result = await pools.owner.query<{ exists: boolean }>(
    'SELECT to_regclass($1) IS NOT NULL AS exists',
    [`public.${name}`],
  );
  return result.rows[0]?.exists ?? false;
}

describe('database migrations', () => {
  afterAll(() => pools.close());

  it('apply, roll back completely, and apply again cleanly', async () => {
    await migrateTestDatabase();
    expect(await tableExists('products')).toBe(true);

    const rolledBack = await runMigrations(ownerDatabaseUrl, 'down', {
      count: Number.POSITIVE_INFINITY,
      quiet: true,
    });
    expect(rolledBack).toContain('20261012120000000_create-products');
    expect(await tableExists('products')).toBe(false);

    const applied = await migrateTestDatabase();
    expect(applied).toEqual(rolledBack.toReversed());
    expect(await tableExists('products')).toBe(true);
  });

  it('turn every customer into an organisation, keeping its dispatches and payments', async () => {
    await migrateTestDatabase();
    await resetDatabase(pools.owner);
    const user = await createTestUser(pools.app, { username: 'migrator', password: '482915' });
    // Back to just before customers were replaced by organisations, with every later migration.
    const all = (await readdir(MIGRATIONS_DIR))
      .filter((name) => name.endsWith('.sql'))
      .map((name) => name.replace(/[.]sql$/, ''))
      .sort();
    const later = all.slice(all.indexOf(CUSTOMERS_MIGRATION));
    await runMigrations(ownerDatabaseUrl, 'down', { count: later.length, quiet: true });
    const q = (sql: string, params: unknown[] = []) => pools.owner.query(sql, params);

    const { rows: subsidiary } = await q(
      `INSERT INTO organisations (code, name, organisation_type, address)
       VALUES ('SUB-01', 'Branch One', 'SUBSIDIARY', '1 Main Road') RETURNING id`,
    );
    const branch = subsidiary[0]?.id as string;
    // Linked: its limit and phone move onto the organisation, which keeps its own address.
    // Old shops: a code that clashes, a one-letter code and one with a dot.
    const { rows: shops } = await q(
      `INSERT INTO customers (code, name, phone, address, credit_limit, is_active, organisation_id)
       VALUES ('SUB-01', 'Branch One', '+263 00 000 0001', 'Old address', 250.00, true, $1),
              ('HQ', 'Clashing Shop', NULL, NULL, NULL, true, NULL),
              ('X', 'Shop X', '+263 00 000 0002', '2 Side Street', 75.50, false, NULL),
              ('A.B', 'Dotted Shop', NULL, NULL, NULL, true, NULL)
       RETURNING id, code`,
      [branch],
    );
    const shopX = shops.find((row) => row.code === 'X')?.id as string;
    const { rows: dispatched } = await q(
      `INSERT INTO dispatches (customer_id, dispatch_date, created_by)
       VALUES ($1, '2026-10-01', $2) RETURNING id`,
      [shopX, user.id],
    );
    const dispatchId = dispatched[0]?.id as string;
    await q(
      `UPDATE dispatches SET status = 'confirmed', confirmed_by = $2, confirmed_at = now()
       WHERE id = $1`,
      [dispatchId, user.id],
    );
    const { rows: paid } = await q(
      `INSERT INTO payments (customer_id, payment_date, amount, currency, method, recorded_by)
       VALUES ($1, '2026-10-02', 10.00, 'USD', 'cash', $2) RETURNING id`,
      [shopX, user.id],
    );
    const paymentId = paid[0]?.id as string;

    expect(await migrateTestDatabase()).toEqual(later);
    expect(await tableExists('customers')).toBe(false);

    const { rows: organisations } = await q(
      `SELECT code, name, organisation_type, is_active, contact_phone, address, credit_limit
       FROM organisations WHERE organisation_type = 'SUBSIDIARY' ORDER BY code`,
    );
    expect(organisations).toEqual([
      {
        code: 'A-B',
        name: 'Dotted Shop',
        organisation_type: 'SUBSIDIARY',
        is_active: true,
        contact_phone: null,
        address: null,
        credit_limit: null,
      },
      {
        code: 'HQ-2',
        name: 'Clashing Shop',
        organisation_type: 'SUBSIDIARY',
        is_active: true,
        contact_phone: null,
        address: null,
        credit_limit: null,
      },
      {
        code: 'SUB-01',
        name: 'Branch One',
        organisation_type: 'SUBSIDIARY',
        is_active: true,
        contact_phone: '+263 00 000 0001',
        address: '1 Main Road',
        credit_limit: '250.00',
      },
      {
        code: 'X-1',
        name: 'Shop X',
        organisation_type: 'SUBSIDIARY',
        is_active: false,
        contact_phone: '+263 00 000 0002',
        address: '2 Side Street',
        credit_limit: '75.50',
      },
    ]);

    // The old shop's dispatch and payment now belong to its organisation.
    const { rows: owners } = await q(
      `SELECT o.code FROM dispatches d JOIN organisations o ON o.id = d.organisation_id
       UNION ALL
       SELECT o.code FROM payments p JOIN organisations o ON o.id = p.organisation_id`,
    );
    expect(owners).toEqual([{ code: 'X-1' }, { code: 'X-1' }]);

    // The safety triggers are back on, and use the new column.
    await expect(
      q(`UPDATE dispatches SET notes = 'changed' WHERE id = $1`, [dispatchId]),
    ).rejects.toThrow(/cannot be changed/);
    await q(
      `UPDATE payments SET status = 'voided', voided_by = $2, voided_at = now(),
              void_reason = 'Test void'
       WHERE id = $1`,
      [paymentId, user.id],
    );
    const { rows: permissions } = await q(
      `SELECT code FROM permissions WHERE code LIKE 'customer.%' OR code LIKE '%credit_limit'`,
    );
    expect(permissions).toEqual([{ code: 'organisation.edit_credit_limit' }]);
    await resetDatabase(pools.owner);
  });

  it('revalue every goods-received note at what arrived, even submitted ones', async () => {
    await migrateTestDatabase();
    await resetDatabase(pools.owner);
    const user = await createTestUser(pools.app, { username: 'revaluer', password: '482915' });
    const product = await createTestProduct(pools.owner);
    // Back to just before notes were valued at the quantity received.
    await runMigrations(ownerDatabaseUrl, 'down', { count: 1, quiet: true });
    const q = (sql: string, params: unknown[] = []) => pools.owner.query(sql, params);

    // A submitted note (its lines are locked): 100 bought, 96 arrived, valued the old way.
    const { rows } = await q(
      `INSERT INTO stock_receipts (owner_organisation_id, warehouse_id, received_date, currency,
                                   status, received_by, submitted_by, submitted_at)
       VALUES (hq_organisation_id(), default_warehouse_id(), current_date, 'USD',
               'PENDING_VERIFICATION', $1, $1, now())
       RETURNING id`,
      [user.id],
    );
    const receiptId = rows[0]?.id as string;
    await q('ALTER TABLE stock_receipt_lines DISABLE TRIGGER stock_receipt_lines_draft_only');
    await q(
      `INSERT INTO stock_receipt_lines (receipt_id, line_number, product_id, unit_id,
         quantity_purchased, quantity_received, base_quantity_received, unit_cost, line_total,
         discrepancy_reason)
       VALUES ($1, 1, $2, (SELECT id FROM units WHERE code = 'pack'), 100, 96, 96, 0.4250, 42.50,
               'shortage')`,
      [receiptId, product],
    );
    await q('ALTER TABLE stock_receipt_lines ENABLE TRIGGER stock_receipt_lines_draft_only');

    expect(await migrateTestDatabase()).toEqual(['20261115090000000_grn-totals-from-received']);
    const { rows: lines } = await q('SELECT line_total::text FROM stock_receipt_lines');
    expect(lines).toEqual([{ line_total: '40.80' }]);
    // The lock is back on, and the new rule holds.
    await expect(q('UPDATE stock_receipt_lines SET notes = $1', ['changed'])).rejects.toThrow();
    await resetDatabase(pools.owner);
  });

  it('does nothing when the database is already up to date', async () => {
    expect(await migrateTestDatabase()).toEqual([]);
  });
});
