import { randomUUID } from 'node:crypto';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../../app.js';
import { PERMISSIONS } from '../../modules/auth/permissions.js';
import { testConfig } from '../test-config.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestProduct,
  createTestSubsidiary,
  createTestUser,
  headOfficeId,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

// StockFlow Stage 3 (docs/STAGE_3_5_PLAN.md): organisations, permissions and separation.
const pools = createTestPools();
const PASSWORD = '4826';
let app: Express;
let hq: string;
let subA: string;
let subB: string;
const tokens: Record<string, string> = {};

/** One account per role: the Head Office roles at HQ, the subsidiary roles at subsidiary A. */
const ROLE_USERS = {
  system_admin: 'hq',
  hq_warehouse_officer: 'hq',
  hq_finance_officer: 'hq',
  hq_sales_officer: 'hq',
  subsidiary_manager: 'a',
  subsidiary_storekeeper: 'a',
} as const;
type RoleCode = keyof typeof ROLE_USERS;

const as = (who: string) => {
  const auth = (r: request.Test) => r.set('Authorization', `Bearer ${tokens[who]}`);
  return {
    get: (path: string) => auth(request(app).get(path)),
    post: (path: string, body: object = {}) => auth(request(app).post(path)).send(body),
    patch: (path: string, body: object) => auth(request(app).patch(path)).send(body),
    put: (path: string, body: object) => auth(request(app).put(path)).send(body),
  };
};

/** Adds a ledger entry owned by `owner` directly (receiving for a subsidiary comes in Stage 4). */
async function addOwnedStock(productId: string, owner: string, quantity: number) {
  const { rows } = await pools.owner.query<{ id: string }>('SELECT id FROM users LIMIT 1');
  await pools.owner.query(
    `INSERT INTO stock_movements (product_id, movement_type, quantity_delta, business_date,
                                  created_by, reason, owner_organisation_id)
     VALUES ($1, 'adjustment', $2, current_date, $3, 'test stock', $4)`,
    [productId, quantity, rows[0]?.id, owner],
  );
}

let rolePermissionsSnapshot: { role_id: string; permission_code: string }[] = [];

beforeAll(async () => {
  const { rows } = await pools.owner.query<{ role_id: string; permission_code: string }>(
    'SELECT role_id, permission_code FROM role_permissions',
  );
  rolePermissionsSnapshot = rows;
});

beforeEach(async () => {
  await resetDatabase(pools.owner);
  app = createDbTestApp(pools.app);
  hq = await headOfficeId(pools.owner);
  subA = await createTestSubsidiary(pools.owner, 'SUB-A', 'Mbare Branch');
  subB = await createTestSubsidiary(pools.owner, 'SUB-B', 'Gweru Branch');
  for (const [role, where] of Object.entries(ROLE_USERS)) {
    await createTestUser(pools.app, {
      username: role.replaceAll('_', '.'),
      roleCodes: [role],
      organisationId: where === 'hq' ? hq : subA,
      password: PASSWORD,
    });
    tokens[role] = await signIn(app, role.replaceAll('_', '.'), PASSWORD);
  }
  await createTestUser(pools.app, {
    username: 'manager.b',
    roleCodes: ['subsidiary_manager'],
    organisationId: subB,
    password: PASSWORD,
  });
  tokens.managerB = await signIn(app, 'manager.b', PASSWORD);
});

afterEach(async () => {
  // Tests may change what roles allow; put it back for the next file.
  await pools.owner.query('DELETE FROM role_permissions');
  for (const row of rolePermissionsSnapshot) {
    await pools.owner.query(
      'INSERT INTO role_permissions (role_id, permission_code) VALUES ($1, $2)',
      [row.role_id, row.permission_code],
    );
  }
});
afterAll(() => pools.close());

describe('permissions', () => {
  it('are the same list in the code and in the database', async () => {
    const { rows } = await pools.owner.query<{ code: string }>(
      'SELECT code FROM permissions ORDER BY code',
    );
    expect(rows.map((row) => row.code)).toEqual([...PERMISSIONS].sort());
  });

  // One request per permission. Anything but 403 means the role was let in (the requests are
  // deliberately incomplete, so nothing is actually changed).
  const CHECKS: Record<string, (who: string) => Promise<request.Response>> = {
    'organisation.manage': (who) => as(who).post('/api/v1/organisations', {}),
    'user.manage': (who) => as(who).get('/api/v1/users'),
    'role.manage': (who) => as(who).put('/api/v1/roles/nobody/permissions', {}),
    'audit.view': (who) => as(who).get('/api/v1/audit-logs'),
    'product.manage': (who) => as(who).post('/api/v1/products', {}),
    'stock.view': (who) => as(who).get('/api/v1/stock/balance'),
    // A complete change to a goods-received note that does not exist: 404 when let in.
    'stock.receive': (who) => as(who).put(`/api/v1/receipts/${randomUUID()}`, { lines: [] }),
    'receipt.verify': (who) => as(who).post(`/api/v1/receipts/${randomUUID()}/verify`, {}),
    'receipt.reverse': (who) =>
      as(who).post(`/api/v1/receipts/${randomUUID()}/reverse`, { reason: 'Wrong supplier' }),
    'stock.adjust': (who) => as(who).post('/api/v1/stock/adjustments', {}),
    // A credit limit for an organisation that does not exist: 404 when let in.
    'organisation.edit_credit_limit': (who) =>
      as(who).patch(`/api/v1/organisations/${randomUUID()}`, { creditLimit: '100.00' }),
    'dispatch.confirm': (who) => as(who).post(`/api/v1/dispatches/${randomUUID()}/confirm`, {}),
    'dispatch.reverse': (who) => as(who).post(`/api/v1/dispatches/${randomUUID()}/reverse`, {}),
    'invoice.manage': (who) => as(who).get('/api/v1/invoices'),
    'payment.manage': (who) => as(who).get('/api/v1/payments'),
    'payment.void': (who) => as(who).post(`/api/v1/payments/${randomUUID()}/void`, {}),
    'report.dashboard': (who) => as(who).get('/api/v1/reports/dashboard'),
    'report.financial': (who) => as(who).get('/api/v1/reports/sales'),
    'forecast.use': (who) => as(who).get('/api/v1/forecasts'),
  };

  // What each role may do (the file's role table, plus today's features for D2).
  const ALLOWED: Record<RoleCode, string[]> = {
    system_admin: [
      'organisation.manage',
      'user.manage',
      'role.manage',
      'audit.view',
      'product.manage',
      'stock.view',
      'stock.adjust',
      'receipt.reverse',
      'dispatch.reverse',
      // Voiding also needs the payments area (finance), so an administrator without a finance
      // role cannot void payments on their own. (Old admins hold both roles: decision D2.)
      'report.dashboard',
    ],
    hq_warehouse_officer: [
      'stock.view',
      'stock.receive',
      'dispatch.confirm',
      'report.dashboard',
      'forecast.use',
    ],
    hq_finance_officer: [
      'stock.view',
      'receipt.verify',
      'organisation.edit_credit_limit',
      'invoice.manage',
      'payment.manage',
      'report.dashboard',
      'report.financial',
      'forecast.use',
    ],
    hq_sales_officer: ['stock.view', 'report.dashboard'],
    subsidiary_manager: ['stock.view'],
    subsidiary_storekeeper: ['stock.view'],
  };

  for (const role of Object.keys(ROLE_USERS) as RoleCode[]) {
    it(`lets a ${role.replaceAll('_', ' ')} do exactly what the role allows`, async () => {
      const outcome: Record<string, boolean> = {};
      for (const [permission, check] of Object.entries(CHECKS)) {
        outcome[permission] = (await check(role)).status !== 403;
      }
      const expected = Object.fromEntries(
        Object.keys(CHECKS).map((permission) => [permission, ALLOWED[role].includes(permission)]),
      );
      expect(outcome).toEqual(expected);
    });
  }

  it('the finance officer cannot change physical quantities; the warehouse cannot take payments', async () => {
    expect((await as('hq_finance_officer').post('/api/v1/stock/receipts', {})).status).toBe(403);
    expect((await as('hq_finance_officer').post('/api/v1/receipts', {})).status).toBe(403);
    expect((await as('hq_finance_officer').post('/api/v1/stock/adjustments', {})).status).toBe(403);
    expect((await as('hq_warehouse_officer').get('/api/v1/payments')).status).toBe(403);
  });

  it('can be changed per role without code changes, and apply at once', async () => {
    expect((await as('hq_sales_officer').get('/api/v1/forecasts')).status).toBe(403);

    const changed = await as('system_admin').put('/api/v1/roles/hq_sales_officer/permissions', {
      permissions: ['stock.view', 'report.dashboard', 'forecast.use'],
    });
    expect(changed.status).toBe(200);
    expect(changed.body.role.permissions).toContain('forecast.use');
    expect((await as('hq_sales_officer').get('/api/v1/forecasts')).status).toBe(200);

    const [entry] = await auditEntries(pools.owner, 'role.permissions_changed');
    expect(entry?.details).toMatchObject({ role: 'hq_sales_officer' });
  });

  it('never lets the System Administrator role lose staff and role management', async () => {
    const response = await as('system_admin').put('/api/v1/roles/system_admin/permissions', {
      permissions: ['audit.view'],
    });
    expect(response.status).toBe(409);
    expect((await as('system_admin').get('/api/v1/users')).status).toBe(200);
  });

  it('are listed with the roles for anyone who manages staff', async () => {
    const response = await as('system_admin').get('/api/v1/roles');
    expect(response.status).toBe(200);
    expect(response.body.roles.map((role: { code: string }) => role.code)).toEqual([
      'hq_finance_officer',
      'hq_sales_officer',
      'hq_warehouse_officer',
      'system_admin',
      'subsidiary_manager',
      'subsidiary_storekeeper',
    ]);
    expect(response.body.permissions).toHaveLength(PERMISSIONS.length);
  });
});

describe('organisation separation', () => {
  it('lets a subsidiary see only its own stock, by list and by direct id', async () => {
    const product = await createTestProduct(pools.owner);
    await addOwnedStock(product, hq, 100);
    await addOwnedStock(product, subA, 7);
    await addOwnedStock(product, subB, 3);

    const own = await as('subsidiary_manager').get('/api/v1/stock/balance');
    expect(own.status).toBe(200);
    expect(own.body.balances[0].quantityOnHand).toBe(7);

    for (const other of [hq, subB]) {
      for (const path of ['balance', 'movements', 'receipts']) {
        const response = await as('subsidiary_storekeeper').get(
          `/api/v1/stock/${path}?organisationId=${other}`,
        );
        expect(response.status, `${path} of another organisation`).toBe(404);
      }
    }

    const ownMovements = await as('subsidiary_storekeeper').get('/api/v1/stock/movements');
    expect(
      ownMovements.body.movements.map((m: { quantityDelta: number }) => m.quantityDelta),
    ).toEqual([7]);
  });

  it('lets Head Office staff see every organisation, and keeps ownership apart', async () => {
    const product = await createTestProduct(pools.owner);
    await addOwnedStock(product, hq, 100);
    await addOwnedStock(product, subA, 7);

    const ownBalance = await as('hq_warehouse_officer').get('/api/v1/stock/balance');
    expect(ownBalance.body.balances[0].quantityOnHand).toBe(100);
    const subsidiaryBalance = await as('hq_warehouse_officer').get(
      `/api/v1/stock/balance?organisationId=${subA}`,
    );
    expect(subsidiaryBalance.body.balances[0].quantityOnHand).toBe(7);

    // The Head Office's own stock (what it can dispatch) never includes a subsidiary's goods.
    const { rows } = await pools.owner.query<{ quantity_on_hand: number }>(
      'SELECT quantity_on_hand FROM hq_stock_on_hand WHERE product_id = $1',
      [product],
    );
    expect(rows[0]?.quantity_on_hand).toBe(100);
  });

  it('shows a subsidiary only its own organisation, and hides others by id', async () => {
    const list = await as('subsidiary_manager').get('/api/v1/organisations');
    expect(list.body.organisations.map((o: { code: string }) => o.code)).toEqual(['SUB-A']);
    expect((await as('subsidiary_manager').get(`/api/v1/organisations/${subB}`)).status).toBe(404);
    expect((await as('subsidiary_manager').get(`/api/v1/organisations/${hq}`)).status).toBe(404);
    expect((await as('managerB').get(`/api/v1/organisations/${subA}`)).status).toBe(404);

    const all = await as('hq_finance_officer').get('/api/v1/organisations');
    expect(all.body.organisations.map((o: { code: string }) => o.code)).toEqual([
      'HQ',
      'SUB-B',
      'SUB-A',
    ]);
  });

  it('never trusts an organisation from the request when adding staff', async () => {
    // Only the Head Office has staff managers; a subsidiary's staff get 403 before anything else.
    const response = await as('subsidiary_manager').post('/api/v1/users', {
      username: 'intruder',
      fullName: 'Intruder',
      organisationId: subB,
      roleCodes: ['subsidiary_manager'],
      password: PASSWORD,
    });
    expect(response.status).toBe(403);
  });
});

describe('organisations', () => {
  it('adds a subsidiary: a customer of the Head Office, with its own credit limit', async () => {
    const response = await as('system_admin').post('/api/v1/organisations', {
      code: 'bul-01',
      name: 'Bulawayo Branch',
      contactName: 'Nomsa Dube',
      contactPhone: '+263 29 222 3333',
      contactEmail: 'orders@bulawayo.example',
      address: '5 Fife Street, Bulawayo',
    });

    expect(response.status).toBe(201);
    expect(response.body.organisation).toMatchObject({
      code: 'BUL-01',
      name: 'Bulawayo Branch',
      type: 'SUBSIDIARY',
      isActive: true,
      contactEmail: 'orders@bulawayo.example',
      creditLimit: null,
    });
    expect(response.body.organisation).not.toHaveProperty('customerId');

    const [entry] = await auditEntries(pools.owner, 'organisation.created');
    expect(entry?.details).toEqual({ code: 'BUL-01', name: 'Bulawayo Branch' });

    // There is no separate customers list any more.
    expect((await as('system_admin').get('/api/v1/customers')).status).toBe(404);
  });

  it('lists only the subsidiaries (the customers) when asked', async () => {
    const response = await as('hq_sales_officer').get('/api/v1/organisations?type=SUBSIDIARY');
    expect(response.status).toBe(200);
    const types = response.body.organisations.map((o: { type: string }) => o.type);
    expect(types.length).toBeGreaterThan(0);
    expect(new Set(types)).toEqual(new Set(['SUBSIDIARY']));
    expect((await as('hq_sales_officer').get('/api/v1/organisations?type=SHOP')).status).toBe(400);
  });

  it('lets finance set credit limits, and only credit limits', async () => {
    const limited = await as('hq_finance_officer').patch(`/api/v1/organisations/${subA}`, {
      creditLimit: '500.00',
    });
    expect(limited.status).toBe(200);
    expect(limited.body.organisation.creditLimit).toBe('500.00');
    const [entry] = await auditEntries(pools.owner, 'organisation.updated');
    expect(entry?.details).toEqual({ changes: { creditLimit: { from: null, to: '500.00' } } });

    // Finance cannot rename; an administrator without finance cannot change the limit.
    const renamed = await as('hq_finance_officer').patch(`/api/v1/organisations/${subA}`, {
      name: 'Renamed',
      creditLimit: '600.00',
    });
    expect(renamed.status).toBe(403);
    expect(renamed.body.error.details).toEqual([
      { field: 'name', message: 'Your role cannot change this' },
    ]);
    const byAdmin = await as('system_admin').patch(`/api/v1/organisations/${subA}`, {
      creditLimit: null,
    });
    expect(byAdmin.status).toBe(403);
    expect(
      (
        await as('system_admin').post('/api/v1/organisations', {
          code: 'NEW',
          name: 'New Branch',
          creditLimit: '10.00',
        })
      ).status,
    ).toBe(403);

    // A limit can be removed again, but never made negative.
    const negative = await as('hq_finance_officer').patch(`/api/v1/organisations/${subA}`, {
      creditLimit: '-1.00',
    });
    expect(negative.status).toBe(400);
    const cleared = await as('hq_finance_officer').patch(`/api/v1/organisations/${subA}`, {
      creditLimit: null,
    });
    expect(cleared.body.organisation.creditLimit).toBeNull();
  });

  it('refuses a code that is taken, and explains invalid fields', async () => {
    const taken = await as('system_admin').post('/api/v1/organisations', {
      code: 'sub-a',
      name: 'Copy',
    });
    expect(taken.status).toBe(409);
    expect(taken.body.error.code).toBe('ORGANISATION_CODE_TAKEN');

    const invalid = await as('system_admin').post('/api/v1/organisations', {
      code: 'x',
      name: '',
      contactEmail: 'not-an-email',
    });
    expect(invalid.status).toBe(400);
    expect(invalid.body.error.details.map((d: { field: string }) => d.field)).toEqual([
      'code',
      'name',
      'contactEmail',
    ]);
  });

  it('deactivating a subsidiary signs its staff out and keeps them out', async () => {
    expect((await as('subsidiary_manager').get('/api/v1/auth/me')).status).toBe(200);

    const response = await as('system_admin').patch(`/api/v1/organisations/${subA}`, {
      isActive: false,
    });
    expect(response.status).toBe(200);

    expect((await as('subsidiary_manager').get('/api/v1/auth/me')).status).toBe(401);
    const signIn = await request(app)
      .post('/api/v1/auth/login')
      .send({ username: 'subsidiary.manager', pin: PASSWORD });
    expect(signIn.status).toBe(401);
    // Other organisations carry on.
    expect((await as('managerB').get('/api/v1/auth/me')).status).toBe(200);
  });

  it('checks the organisation on every request, not only when it is deactivated through the app', async () => {
    await pools.owner.query('UPDATE organisations SET is_active = false WHERE id = $1', [subA]);
    expect((await as('subsidiary_storekeeper').get('/api/v1/auth/me')).status).toBe(401);
    expect((await as('managerB').get('/api/v1/auth/me')).status).toBe(200);
  });

  it('never deactivates the Head Office', async () => {
    const response = await as('system_admin').patch(`/api/v1/organisations/${hq}`, {
      isActive: false,
    });
    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('HEAD_OFFICE_ALWAYS_ACTIVE');
  });

  it('can only be added or changed with organisation.manage', async () => {
    for (const who of ['hq_finance_officer', 'subsidiary_manager']) {
      expect(
        (await as(who).post('/api/v1/organisations', { code: 'NEW', name: 'New' })).status,
      ).toBe(403);
      expect((await as(who).patch(`/api/v1/organisations/${subA}`, { name: 'X' })).status).toBe(
        403,
      );
    }
  });
});

describe('audit log', () => {
  it('records the organisation and network address of every action', async () => {
    await as('system_admin').patch(`/api/v1/organisations/${subB}`, { name: 'Gweru Depot' });
    await request(app)
      .post('/api/v1/auth/login')
      .send({ username: 'subsidiary.manager', pin: '9999' });

    const { rows } = await pools.owner.query<{
      action: string;
      organisation_id: string | null;
      ip: string | null;
    }>(
      `SELECT action, organisation_id, host(ip_address) AS ip FROM audit_logs
       WHERE action IN ('organisation.updated', 'auth.login_failed') ORDER BY occurred_at`,
    );
    expect(rows).toEqual([
      { action: 'organisation.updated', organisation_id: subB, ip: expect.stringMatching(/\d/) },
      { action: 'auth.login_failed', organisation_id: subA, ip: expect.stringMatching(/\d/) },
    ]);
  });

  it('can be read, filtered and paged by those with audit.view only', async () => {
    const response = await as('system_admin').get('/api/v1/audit-logs?action=auth&limit=2');
    expect(response.status).toBe(200);
    expect(response.body.total).toBeGreaterThanOrEqual(7); // the sign-ins in beforeEach
    expect(response.body.entries).toHaveLength(2);
    expect(response.body.entries[0]).toMatchObject({
      action: 'auth.login',
      actor: { fullName: expect.any(String) },
      organisation: { code: expect.any(String) },
    });
    expect(JSON.stringify(response.body)).not.toMatch(/argon2|password_hash/i);

    expect((await as('hq_finance_officer').get('/api/v1/audit-logs')).status).toBe(403);
  });
});

describe('sessions', () => {
  it('are only read from the Authorization header, never from cookies (so no CSRF)', async () => {
    const proxied = createApp(testConfig, { db: pools.app, checkDatabase: async () => true });
    const response = await request(proxied)
      .get('/api/v1/auth/me')
      .set('Cookie', `token=${tokens.system_admin}; session=${tokens.system_admin}`);
    expect(response.status).toBe(401);
  });
});
