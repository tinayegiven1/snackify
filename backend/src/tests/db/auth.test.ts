import { createHash } from 'node:crypto';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../../app.js';
import { testConfig } from '../test-config.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestUser,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

const pools = createTestPools();
const PASSWORD = 'correct horse battery';
let app: Express;

const login = (username: string, password: string) =>
  request(app).post('/api/v1/auth/login').send({ username, password });
const me = (token?: string) => {
  const req = request(app).get('/api/v1/auth/me');
  return token ? req.set('Authorization', `Bearer ${token}`) : req;
};

beforeEach(async () => {
  await resetDatabase(pools.owner);
  app = createDbTestApp(pools.app);
  await createTestUser(pools.app, {
    username: 'tendai',
    fullName: 'Tendai Moyo',
    role: 'storekeeper',
    password: PASSWORD,
  });
});
afterAll(() => pools.close());

describe('POST /api/v1/auth/login', () => {
  it('signs in with the right username and password', async () => {
    const response = await login('tendai', PASSWORD);

    expect(response.status).toBe(200);
    expect(response.body.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    // Who they are, where they work, and what they may do (an old storekeeper became an HQ
    // Warehouse Officer).
    expect(response.body.user).toEqual({
      id: expect.any(String),
      username: 'tendai',
      fullName: 'Tendai Moyo',
      organisation: { id: expect.any(String), code: 'HQ', name: 'Head Office', type: 'HQ' },
      roles: [{ code: 'hq_warehouse_officer', name: 'HQ Warehouse Officer' }],
      permissions: [
        'customer.view',
        'dispatch.confirm',
        'dispatch.draft',
        'dispatch.view',
        'forecast.use',
        'label.print',
        'report.dashboard',
        'report.stock',
        'stock.receive',
        'stock.view',
        'supplier.manage',
      ],
    });
    const hoursLeft = (Date.parse(response.body.expiresAt) - Date.now()) / 3_600_000;
    expect(hoursLeft).toBeGreaterThan(11.9);
    expect(hoursLeft).toBeLessThanOrEqual(12);
    expect(JSON.stringify(response.body)).not.toMatch(/argon2|password/i);
  });

  it('accepts the username in any letter case', async () => {
    expect((await login('  Tendai ', PASSWORD)).status).toBe(200);
  });

  it('gives the same answer for a wrong password and an unknown username', async () => {
    const wrongPassword = await login('tendai', 'not the password');
    const unknownUser = await login('nobody', PASSWORD);

    expect(wrongPassword.status).toBe(401);
    expect(unknownUser.status).toBe(401);
    expect(wrongPassword.body).toEqual(unknownUser.body);
    expect(wrongPassword.body.error.code).toBe('INVALID_CREDENTIALS');
  });

  it('refuses a deactivated account, even with the right password', async () => {
    await pools.owner.query(`UPDATE users SET is_active = false WHERE username = 'tendai'`);

    const response = await login('tendai', PASSWORD);
    expect(response.status).toBe(401);
    expect(response.body.error.code).toBe('INVALID_CREDENTIALS');
  });

  it('explains which fields are missing', async () => {
    const response = await request(app).post('/api/v1/auth/login').send({});

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('VALIDATION_ERROR');
    expect(response.body.error.details.map((d: { field: string }) => d.field)).toEqual([
      'username',
      'password',
    ]);
  });

  it('records sign-ins and failed attempts in the audit log, without passwords', async () => {
    await login('tendai', 'not the password');
    await login('tendai', PASSWORD);

    const failed = await auditEntries(pools.owner, 'auth.login_failed');
    expect(failed).toHaveLength(1);
    expect(failed[0]?.details).toEqual({ username: 'tendai', reason: 'wrong_password' });

    const succeeded = await auditEntries(pools.owner, 'auth.login');
    expect(succeeded).toHaveLength(1);

    const { rows } = await pools.owner.query<{ all_details: string }>(
      `SELECT string_agg(details::text, ' ') AS all_details FROM audit_logs`,
    );
    expect(rows[0]?.all_details).not.toContain('not the password');
    expect(rows[0]?.all_details).not.toContain(PASSWORD);
  });

  it('blocks further attempts after 10 failures, even with the right password', async () => {
    for (let attempt = 1; attempt <= 10; attempt++) {
      expect((await login('tendai', `wrong ${attempt}`)).status).toBe(401);
    }
    const blocked = await login('tendai', PASSWORD);

    expect(blocked.status).toBe(429);
    expect(blocked.body.error.code).toBe('TOO_MANY_ATTEMPTS');
  });

  it('behind a proxy (Cloud Run), limits each client address, which clients cannot fake', async () => {
    const proxied = createApp(
      { ...testConfig, trustProxyHops: 1 },
      {
        db: pools.app,
        checkDatabase: async () => true,
      },
    );
    // The proxy adds the real client address at the end; anything before it came from the client.
    const from = (forwardedFor: string, password: string) =>
      request(proxied)
        .post('/api/v1/auth/login')
        .set('X-Forwarded-For', forwardedFor)
        .send({ username: 'tendai', password });

    for (let attempt = 1; attempt <= 10; attempt++) {
      const fakeAddress = `203.0.113.${attempt}`;
      expect((await from(`${fakeAddress}, 198.51.100.1`, `wrong ${attempt}`)).status).toBe(401);
    }

    expect((await from('203.0.113.99, 198.51.100.1', PASSWORD)).status).toBe(429);
    // Another client, for example in another shop, can still sign in.
    expect((await from('198.51.100.2', PASSWORD)).status).toBe(200);
  });

  it('stores only a hash of the session token', async () => {
    const token = await signIn(app, 'tendai', PASSWORD);
    const { rows } = await pools.owner.query<{ token_hash: Buffer }>(
      'SELECT token_hash FROM sessions',
    );

    expect(rows).toHaveLength(1);
    expect(rows[0]?.token_hash.equals(createHash('sha256').update(token).digest())).toBe(true);
  });
});

describe('signed-in requests', () => {
  it('GET /me returns the signed-in user', async () => {
    const token = await signIn(app, 'tendai', PASSWORD);
    const response = await me(token);

    expect(response.status).toBe(200);
    expect(response.body.user).toMatchObject({
      username: 'tendai',
      organisation: { code: 'HQ' },
      roles: [{ code: 'hq_warehouse_officer' }],
    });
    expect(response.body.user.permissions).toContain('stock.receive');
  });

  it('rejects a missing, malformed or unknown token', async () => {
    for (const response of [
      await me(),
      await me('not-a-token'),
      await me('A'.repeat(43)),
      await request(app).get('/api/v1/auth/me').set('Authorization', 'Basic abc'),
    ]) {
      expect(response.status).toBe(401);
      expect(response.body.error.code).toBe('UNAUTHENTICATED');
    }
  });

  it('signs out: the token stops working', async () => {
    const token = await signIn(app, 'tendai', PASSWORD);

    const logout = await request(app)
      .post('/api/v1/auth/logout')
      .set('Authorization', `Bearer ${token}`);
    expect(logout.status).toBe(204);
    expect((await me(token)).status).toBe(401);
    expect(await auditEntries(pools.owner, 'auth.logout')).toHaveLength(1);
  });

  it('rejects an expired session', async () => {
    const token = await signIn(app, 'tendai', PASSWORD);
    await pools.owner.query(
      `UPDATE sessions SET created_at = now() - interval '13 hours', expires_at = now() - interval '1 hour'`,
    );

    expect((await me(token)).status).toBe(401);
  });

  it('stops working immediately when the account is deactivated', async () => {
    const token = await signIn(app, 'tendai', PASSWORD);
    await pools.owner.query(`UPDATE users SET is_active = false WHERE username = 'tendai'`);

    expect((await me(token)).status).toBe(401);
  });
});

describe('POST /api/v1/auth/change-password', () => {
  const changePassword = (token: string, body: object) =>
    request(app)
      .post('/api/v1/auth/change-password')
      .set('Authorization', `Bearer ${token}`)
      .send(body);

  it('changes the password and signs out every other session', async () => {
    const thisDevice = await signIn(app, 'tendai', PASSWORD);
    const otherDevice = await signIn(app, 'tendai', PASSWORD);

    const response = await changePassword(thisDevice, {
      currentPassword: PASSWORD,
      newPassword: 'a brand new passphrase',
    });

    expect(response.status).toBe(204);
    expect((await me(thisDevice)).status).toBe(200);
    expect((await me(otherDevice)).status).toBe(401);
    expect((await login('tendai', PASSWORD)).status).toBe(401);
    expect((await login('tendai', 'a brand new passphrase')).status).toBe(200);
    expect(await auditEntries(pools.owner, 'auth.password_changed')).toHaveLength(1);
  });

  it('requires the correct current password', async () => {
    const token = await signIn(app, 'tendai', PASSWORD);
    const response = await changePassword(token, {
      currentPassword: 'wrong',
      newPassword: 'a brand new passphrase',
    });

    expect(response.status).toBe(400);
    expect(response.body.error.details).toEqual([
      { field: 'currentPassword', message: 'Incorrect password' },
    ]);
  });

  it('rejects a new password that is too short', async () => {
    const token = await signIn(app, 'tendai', PASSWORD);
    const response = await changePassword(token, {
      currentPassword: PASSWORD,
      newPassword: 'short',
    });

    expect(response.status).toBe(400);
    expect(response.body.error.details).toEqual([
      { field: 'newPassword', message: 'Use at least 10 characters' },
    ]);
  });
});
