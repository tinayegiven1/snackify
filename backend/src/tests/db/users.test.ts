import { randomUUID } from 'node:crypto';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { StaffUser } from '../../modules/users/users.service.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestSubsidiary,
  createTestUser,
  headOfficeId,
  PG,
  pgErrorOf,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

const pools = createTestPools();
const PASSWORD = 'correct horse battery';
let app: Express;
let admin: StaffUser;
let staff: StaffUser;
let adminToken: string;
let staffToken: string;
let hq: string;
let subsidiary: string;

const as = (token: string) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${token}`),
  post: (path: string, body: object = {}) =>
    request(app).post(path).set('Authorization', `Bearer ${token}`).send(body),
  patch: (path: string, body: object) =>
    request(app).patch(path).set('Authorization', `Bearer ${token}`).send(body),
});

const roleCodes = (user: { roles: { code: string }[] }) => user.roles.map((role) => role.code);

beforeEach(async () => {
  await resetDatabase(pools.owner);
  app = createDbTestApp(pools.app);
  hq = await headOfficeId(pools.owner);
  subsidiary = await createTestSubsidiary(pools.owner, 'SUB1', 'Mbare Branch');
  admin = await createTestUser(pools.app, { username: 'admin', role: 'admin', password: PASSWORD });
  staff = await createTestUser(pools.app, {
    username: 'tendai',
    fullName: 'Tendai Moyo',
    role: 'salesperson',
    password: PASSWORD,
  });
  adminToken = await signIn(app, 'admin', PASSWORD);
  staffToken = await signIn(app, 'tendai', PASSWORD);
});
afterAll(() => pools.close());

describe('staff account management (/api/v1/users)', () => {
  it('is refused for anyone without the user.manage permission', async () => {
    const asStaff = as(staffToken);
    const responses = [
      await asStaff.get('/api/v1/users'),
      await asStaff.post('/api/v1/users', {
        username: 'sneaky',
        fullName: 'Sneaky',
        organisationId: hq,
        roleCodes: ['system_admin'],
        password: PASSWORD,
      }),
      await asStaff.patch(`/api/v1/users/${staff.id}`, { roleCodes: ['system_admin'] }),
      await asStaff.post(`/api/v1/users/${admin.id}/reset-password`, { newPassword: PASSWORD }),
    ];
    for (const response of responses) {
      expect(response.status).toBe(403);
      expect(response.body.error.code).toBe('FORBIDDEN');
    }
    expect((await request(app).get('/api/v1/users')).status).toBe(401);

    // Nothing changed.
    const { rows } = await pools.owner.query(
      `SELECT u.username, string_agg(r.code, ',' ORDER BY r.code) AS roles
       FROM users u JOIN user_roles ur ON ur.user_id = u.id JOIN roles r ON r.id = ur.role_id
       GROUP BY u.username ORDER BY u.username`,
    );
    expect(rows).toEqual([
      {
        username: 'admin',
        roles: 'hq_finance_officer,hq_sales_officer,hq_warehouse_officer,system_admin',
      },
      { username: 'tendai', roles: 'hq_sales_officer' },
    ]);
  });

  it('lists staff accounts with organisation and roles, without password hashes', async () => {
    const response = await as(adminToken).get('/api/v1/users');

    expect(response.status).toBe(200);
    expect(response.body.users.map((u: StaffUser) => u.fullName)).toEqual([
      'Tendai Moyo',
      'Test admin',
    ]);
    expect(response.body.users[0]).toMatchObject({
      username: 'tendai',
      fullName: 'Tendai Moyo',
      organisation: { code: 'HQ', type: 'HQ' },
      roles: [{ code: 'hq_sales_officer', name: 'HQ Sales Officer' }],
      isActive: true,
      lastSignInAt: expect.any(String),
    });
    expect(JSON.stringify(response.body)).not.toMatch(/argon2|password/i);
  });

  it('creates an account with several roles that can then sign in', async () => {
    const response = await as(adminToken).post('/api/v1/users', {
      username: 'Rudo',
      fullName: 'Rudo Chikore',
      organisationId: hq,
      roleCodes: ['hq_finance_officer', 'hq_warehouse_officer'],
      password: 'rudo-first-passphrase',
    });

    expect(response.status).toBe(201);
    expect(response.body.user).toMatchObject({
      username: 'rudo',
      organisation: { id: hq },
      isActive: true,
    });
    expect(roleCodes(response.body.user)).toEqual(['hq_finance_officer', 'hq_warehouse_officer']);
    const signedIn = await request(app)
      .post('/api/v1/auth/login')
      .send({ username: 'rudo', password: 'rudo-first-passphrase' });
    expect(signedIn.status).toBe(200);
    // The permissions of both roles.
    expect(signedIn.body.user.permissions).toEqual(
      expect.arrayContaining(['invoice.manage', 'stock.receive']),
    );

    const [entry] = await auditEntries(pools.owner, 'user.created').then((rows) =>
      rows.filter((row) => row.actor_user_id === admin.id),
    );
    expect(entry?.details).toEqual({
      username: 'rudo',
      organisation: 'HQ',
      roles: ['hq_finance_officer', 'hq_warehouse_officer'],
      via: 'api',
    });
  });

  it("creates a subsidiary's staff, who may only hold subsidiary roles", async () => {
    const headOfficeRole = await as(adminToken).post('/api/v1/users', {
      username: 'chipo',
      fullName: 'Chipo Ndlovu',
      organisationId: subsidiary,
      roleCodes: ['subsidiary_manager', 'hq_finance_officer'],
      password: PASSWORD,
    });
    expect(headOfficeRole.status).toBe(400);
    expect(headOfficeRole.body.error.details).toEqual([
      { field: 'roleCodes', message: 'hq_finance_officer is for Head Office staff' },
    ]);

    const created = await as(adminToken).post('/api/v1/users', {
      username: 'chipo',
      fullName: 'Chipo Ndlovu',
      organisationId: subsidiary,
      roleCodes: ['subsidiary_manager'],
      password: PASSWORD,
    });
    expect(created.status).toBe(201);
    expect(created.body.user.organisation).toMatchObject({ code: 'SUB1', type: 'SUBSIDIARY' });

    // The database refuses a mismatch too, however it is attempted.
    const hqRole = await pools.owner.query<{ id: string }>(
      `SELECT id FROM roles WHERE code = 'hq_finance_officer'`,
    );
    const error = await pgErrorOf(
      pools.app.query('INSERT INTO user_roles (user_id, role_id) VALUES ($1, $2)', [
        created.body.user.id,
        hqRole.rows[0]?.id,
      ]),
    );
    expect(error).toMatchObject({
      code: PG.checkViolation,
      constraint: 'user_roles_organisation_type',
    });
  });

  it('rejects a username that is already taken, in any letter case', async () => {
    const response = await as(adminToken).post('/api/v1/users', {
      username: 'TENDAI',
      fullName: 'Another Tendai',
      organisationId: hq,
      roleCodes: ['hq_warehouse_officer'],
      password: PASSWORD,
    });

    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('USERNAME_TAKEN');
  });

  it('explains every invalid field', async () => {
    const response = await as(adminToken).post('/api/v1/users', {
      username: 'x',
      fullName: '',
      organisationId: 'nowhere',
      roleCodes: [],
      password: 'short',
    });

    expect(response.status).toBe(400);
    expect(response.body.error.details.map((d: { field: string }) => d.field)).toEqual([
      'username',
      'fullName',
      'organisationId',
      'roleCodes',
      'password',
    ]);

    const unknownRole = await as(adminToken).post('/api/v1/users', {
      username: 'rudo',
      fullName: 'Rudo',
      organisationId: hq,
      roleCodes: ['manager'],
      password: PASSWORD,
    });
    expect(unknownRole.body.error.details).toEqual([
      { field: 'roleCodes', message: 'Unknown role: manager' },
    ]);
  });

  it('changes roles, and the new permissions apply immediately', async () => {
    expect((await as(staffToken).get('/api/v1/users')).status).toBe(403);

    const response = await as(adminToken).patch(`/api/v1/users/${staff.id}`, {
      roleCodes: ['system_admin'],
    });
    expect(response.status).toBe(200);
    expect(roleCodes(response.body.user)).toEqual(['system_admin']);

    expect((await as(staffToken).get('/api/v1/users')).status).toBe(200);
    const [entry] = await auditEntries(pools.owner, 'user.roles_changed');
    expect(entry).toMatchObject({
      actor_user_id: admin.id,
      entity_id: staff.id,
      details: { from: ['hq_sales_officer'], to: ['system_admin'] },
    });
  });

  it('moves someone to another organisation only with roles that suit it, and signs them out', async () => {
    const keepsHqRole = await as(adminToken).patch(`/api/v1/users/${staff.id}`, {
      organisationId: subsidiary,
    });
    expect(keepsHqRole.status).toBe(400);
    expect(keepsHqRole.body.error.details[0].field).toBe('roleCodes');

    const moved = await as(adminToken).patch(`/api/v1/users/${staff.id}`, {
      organisationId: subsidiary,
      roleCodes: ['subsidiary_storekeeper'],
    });
    expect(moved.status).toBe(200);
    expect(moved.body.user.organisation.code).toBe('SUB1');
    expect((await as(staffToken).get('/api/v1/auth/me')).status).toBe(401);
  });

  it('deactivates an account: it is signed out and cannot sign in again', async () => {
    const response = await as(adminToken).patch(`/api/v1/users/${staff.id}`, { isActive: false });

    expect(response.status).toBe(200);
    expect(response.body.user.isActive).toBe(false);
    expect((await as(staffToken).get('/api/v1/auth/me')).status).toBe(401);
    expect(
      (
        await request(app)
          .post('/api/v1/auth/login')
          .send({ username: 'tendai', password: PASSWORD })
      ).status,
    ).toBe(401);

    const [entry] = await auditEntries(pools.owner, 'user.updated');
    expect(entry).toMatchObject({
      actor_user_id: admin.id,
      entity_id: staff.id,
      details: { changes: { isActive: { from: true, to: false } } },
    });
  });

  it('does not let an admin lock themselves out', async () => {
    const deactivateSelf = await as(adminToken).patch(`/api/v1/users/${admin.id}`, {
      isActive: false,
    });
    const demoteSelf = await as(adminToken).patch(`/api/v1/users/${admin.id}`, {
      roleCodes: ['hq_finance_officer'],
    });
    const moveSelf = await as(adminToken).patch(`/api/v1/users/${admin.id}`, {
      organisationId: subsidiary,
      roleCodes: ['subsidiary_manager'],
    });
    const renameSelf = await as(adminToken).patch(`/api/v1/users/${admin.id}`, {
      fullName: 'The Boss',
    });

    for (const refused of [deactivateSelf, demoteSelf, moveSelf]) {
      expect(refused.status).toBe(409);
      expect(refused.body.error.code).toBe('CANNOT_CHANGE_OWN_ACCESS');
    }
    expect(renameSelf.status).toBe(200);
  });

  it('resets a password and signs that user out everywhere', async () => {
    const response = await as(adminToken).post(`/api/v1/users/${staff.id}/reset-password`, {
      newPassword: 'temporary passphrase',
    });

    expect(response.status).toBe(204);
    expect((await as(staffToken).get('/api/v1/auth/me')).status).toBe(401);
    expect(await signIn(app, 'tendai', 'temporary passphrase')).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const [entry] = await auditEntries(pools.owner, 'user.password_reset');
    expect(entry).toMatchObject({ actor_user_id: admin.id, entity_id: staff.id, details: {} });
  });

  it('refuses to reset your own password without the current one', async () => {
    const response = await as(adminToken).post(`/api/v1/users/${admin.id}/reset-password`, {
      newPassword: 'temporary passphrase',
    });
    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('USE_CHANGE_PASSWORD');
  });

  it('returns 404 for unknown or malformed ids, and 400 for unknown fields', async () => {
    expect(
      (await as(adminToken).patch(`/api/v1/users/${randomUUID()}`, { fullName: 'X' })).status,
    ).toBe(404);
    expect((await as(adminToken).patch('/api/v1/users/not-an-id', { fullName: 'X' })).status).toBe(
      404,
    );

    const unknownField = await as(adminToken).patch(`/api/v1/users/${staff.id}`, { password: 'x' });
    expect(unknownField.status).toBe(400);
    expect(unknownField.body.error.code).toBe('VALIDATION_ERROR');
  });
});
