import { afterAll, describe, expect, it } from 'vitest';
import { createTestPools, PG, pgErrorOf } from './db-test-helpers.js';

const pools = createTestPools();

// The API connects as snackify_app, which may read and write data but not change the schema.
describe('API database role (least privilege)', () => {
  afterAll(() => pools.close());

  it('cannot create tables', async () => {
    const error = await pgErrorOf(pools.app.query('CREATE TABLE not_allowed (id int)'));
    expect(error.code).toBe(PG.insufficientPrivilege);
  });

  it('cannot drop or alter existing tables', async () => {
    expect((await pgErrorOf(pools.app.query('DROP TABLE products'))).code).toBe(
      PG.insufficientPrivilege,
    );
    expect(
      (await pgErrorOf(pools.app.query('ALTER TABLE products ADD COLUMN not_allowed int'))).code,
    ).toBe(PG.insufficientPrivilege);
  });

  it('cannot read or change the migration history', async () => {
    const error = await pgErrorOf(pools.app.query('DELETE FROM schema_migrations'));
    expect(error.code).toBe(PG.insufficientPrivilege);
  });

  it('uses UTC for timestamps', async () => {
    const { rows } = await pools.app.query<{ TimeZone: string }>('SHOW timezone');
    expect(rows[0]?.TimeZone).toBe('UTC');
  });
});
