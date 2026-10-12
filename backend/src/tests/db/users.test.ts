import { randomUUID } from 'node:crypto';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { StaffUser } from '../../modules/users/users.service.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestUser,
  resetAuthTables,
  signIn,
} from './db-test-helpers.js';

const pools = createTestPools();
const PASSWORD = 'correct horse battery';
let app: Express;
let admin: StaffUser;
let staff: StaffUser;
let adminToken: string;
let staffToken: string;

const as = (token: string) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${token}`),
  post: (path: string, body: object = {}) =>
    request(app).post(path).set('Authorization', `Bearer ${token}`).send(body),
  patch: (path: string, body: object) =>
    request(app).patch(path).set('Authorization', `Bearer ${token}`).send(body),
});

beforeEach(async () => {
  await resetAuthTables(pools.owner);
  app = createDbTestApp(pools.app);
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
  it('is refused for anyone who is not an admin', async () => {
    const asStaff = as(staffToken);
    const responses = [
      await asStaff.get('/api/v1/users'),
      await asStaff.post('/api/v1/users', {
        username: 'sneaky',
        fullName: 'Sneaky',
        role: 'admin',
        password: PASSWORD,
      }),
      await asStaff.patch(`/api/v1/users/${staff.id}`, { role: 'admin' }),
      await asStaff.post(`/api/v1/users/${admin.id}/reset-password`, { newPassword: PASSWORD }),
    ];
    for (const response of responses) {
      expect(response.status).toBe(403);
      expect(response.body.error.code).toBe('FORBIDDEN');
    }
    expect((await request(app).get('/api/v1/users')).status).toBe(401);

    // Nothing changed.
    const { rows } = await pools.owner.query('SELECT username, role FROM users ORDER BY username');
    expect(rows).toEqual([
      { username: 'admin', role: 'admin' },
      { username: 'tendai', role: 'salesperson' },
    ]);
  });

  it('lists staff accounts by name, without password hashes', async () => {
    const response = await as(adminToken).get('/api/v1/users');

    expect(response.status).toBe(200);
    expect(response.body.users.map((u: StaffUser) => u.fullName)).toEqual([
      'Tendai Moyo',
      'Test admin',
    ]);
    expect(response.body.users[0]).toMatchObject({
      username: 'tendai',
      fullName: 'Tendai Moyo',
      role: 'salesperson',
      isActive: true,
      lastSignInAt: expect.any(String),
    });
    expect(JSON.stringify(response.body)).not.toMatch(/argon2|password/i);
  });

  it('creates an account that can then sign in', async () => {
    const response = await as(adminToken).post('/api/v1/users', {
      username: 'Rudo',
      fullName: 'Rudo Chikore',
      role: 'accounts',
      password: 'rudo-first-passphrase',
    });

    expect(response.status).toBe(201);
    expect(response.body.user).toMatchObject({
      username: 'rudo',
      role: 'accounts',
      isActive: true,
    });
    expect(
      (
        await request(app)
          .post('/api/v1/auth/login')
          .send({ username: 'rudo', password: 'rudo-first-passphrase' })
      ).status,
    ).toBe(200);

    const [entry] = await auditEntries(pools.owner, 'user.created').then((rows) =>
      rows.filter((row) => row.actor_user_id === admin.id),
    );
    expect(entry?.details).toEqual({ username: 'rudo', role: 'accounts', via: 'api' });
  });

  it('rejects a username that is already taken, in any letter case', async () => {
    const response = await as(adminToken).post('/api/v1/users', {
      username: 'TENDAI',
      fullName: 'Another Tendai',
      role: 'storekeeper',
      password: PASSWORD,
    });

    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('USERNAME_TAKEN');
  });

  it('explains every invalid field', async () => {
    const response = await as(adminToken).post('/api/v1/users', {
      username: 'x',
      fullName: '',
      role: 'manager',
      password: 'short',
    });

    expect(response.status).toBe(400);
    expect(response.body.error.details.map((d: { field: string }) => d.field)).toEqual([
      'username',
      'fullName',
      'role',
      'password',
    ]);
  });

  it('changes a role, and the new permissions apply immediately', async () => {
    expect((await as(staffToken).get('/api/v1/users')).status).toBe(403);

    const response = await as(adminToken).patch(`/api/v1/users/${staff.id}`, { role: 'admin' });
    expect(response.status).toBe(200);
    expect(response.body.user.role).toBe('admin');

    expect((await as(staffToken).get('/api/v1/users')).status).toBe(200);
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
      role: 'accounts',
    });
    const renameSelf = await as(adminToken).patch(`/api/v1/users/${admin.id}`, {
      fullName: 'The Boss',
    });

    expect(deactivateSelf.status).toBe(409);
    expect(deactivateSelf.body.error.code).toBe('CANNOT_CHANGE_OWN_ACCESS');
    expect(demoteSelf.status).toBe(409);
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
