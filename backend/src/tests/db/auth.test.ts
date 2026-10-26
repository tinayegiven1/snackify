import { createHash } from 'node:crypto';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../../app.js';
import { createUser } from '../../modules/users/users.service.js';
import { testConfig } from '../test-config.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestUser,
  headOfficeId,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

const pools = createTestPools();
const PIN = '4826';
let app: Express;

const login = (username: string, pin: string) =>
  request(app).post('/api/v1/auth/login').send({ username, pin });
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
    password: PIN,
  });
});
afterAll(() => pools.close());

describe('POST /api/v1/auth/login', () => {
  it('signs in with the right username and PIN', async () => {
    const response = await login('tendai', PIN);

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
      mustChangePin: false,
    });
    const hoursLeft = (Date.parse(response.body.expiresAt) - Date.now()) / 3_600_000;
    expect(hoursLeft).toBeGreaterThan(11.9);
    expect(hoursLeft).toBeLessThanOrEqual(12);
    expect(JSON.stringify(response.body)).not.toMatch(/argon2|password|hash/i);
  });

  it('accepts the username in any letter case', async () => {
    expect((await login('  Tendai ', PIN)).status).toBe(200);
  });

  it('gives the same answer for a wrong PIN and an unknown username', async () => {
    const wrongPin = await login('tendai', '9999');
    const unknownUser = await login('nobody', PIN);

    expect(wrongPin.status).toBe(401);
    expect(unknownUser.status).toBe(401);
    expect(wrongPin.body).toEqual(unknownUser.body);
    expect(wrongPin.body.error.code).toBe('INVALID_CREDENTIALS');
  });

  it('refuses a deactivated account, even with the right PIN', async () => {
    await pools.owner.query(`UPDATE users SET is_active = false WHERE username = 'tendai'`);

    const response = await login('tendai', PIN);
    expect(response.status).toBe(401);
    expect(response.body.error.code).toBe('INVALID_CREDENTIALS');
  });

  it('explains which fields are missing', async () => {
    const response = await request(app).post('/api/v1/auth/login').send({});

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('VALIDATION_ERROR');
    expect(response.body.error.details.map((d: { field: string }) => d.field)).toEqual([
      'username',
      'pin',
    ]);
    const letters = await login('tendai', 'abcd');
    expect(letters.body.error.details).toEqual([{ field: 'pin', message: 'Use digits only' }]);
  });

  it('records sign-ins and failed attempts in the audit log, without PINs', async () => {
    await login('tendai', '9999');
    await login('tendai', PIN);

    const failed = await auditEntries(pools.owner, 'auth.login_failed');
    expect(failed).toHaveLength(1);
    expect(failed[0]?.details).toEqual({ username: 'tendai', reason: 'wrong_pin' });

    const succeeded = await auditEntries(pools.owner, 'auth.login');
    expect(succeeded).toHaveLength(1);

    const { rows } = await pools.owner.query<{ all_details: string }>(
      `SELECT string_agg(details::text, ' ') AS all_details FROM audit_logs`,
    );
    expect(rows[0]?.all_details).not.toContain('9999');
    expect(rows[0]?.all_details).not.toContain(PIN);
  });

  it('blocks an address after 10 failures, even with the right PIN', async () => {
    // Different (unknown) usernames, so no single account is locked first.
    for (let attempt = 1; attempt <= 10; attempt++) {
      expect((await login(`nobody${attempt}`, '9999')).status).toBe(401);
    }
    const blocked = await login('tendai', PIN);

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
    const from = (forwardedFor: string, username: string, pin: string) =>
      request(proxied)
        .post('/api/v1/auth/login')
        .set('X-Forwarded-For', forwardedFor)
        .send({ username, pin });

    for (let attempt = 1; attempt <= 10; attempt++) {
      const fakeAddress = `203.0.113.${attempt}`;
      const response = await from(`${fakeAddress}, 198.51.100.1`, `nobody${attempt}`, '9999');
      expect(response.status).toBe(401);
    }

    expect((await from('203.0.113.99, 198.51.100.1', 'tendai', PIN)).status).toBe(429);
    // Another client, for example in another shop, can still sign in.
    expect((await from('198.51.100.2', 'tendai', PIN)).status).toBe(200);
  });

  it('locks an account for 15 minutes after 5 wrong PINs in a row', async () => {
    for (let attempt = 1; attempt <= 4; attempt++) {
      expect((await login('tendai', '9999')).status).toBe(401);
    }
    const fifth = await login('tendai', '9999');
    expect(fifth.status).toBe(423);
    expect(fifth.body.error.code).toBe('ACCOUNT_LOCKED');
    // Even the right PIN is refused while locked.
    expect((await login('tendai', PIN)).status).toBe(423);
    expect(await auditEntries(pools.owner, 'auth.account_locked')).toHaveLength(1);

    // Once the 15 minutes are over, the right PIN works and the count starts again.
    await pools.owner.query(`UPDATE users SET locked_until = now() - interval '1 second'`);
    expect((await login('tendai', PIN)).status).toBe(200);
    const { rows } = await pools.owner.query('SELECT failed_pin_attempts, locked_until FROM users');
    expect(rows).toEqual([{ failed_pin_attempts: 0, locked_until: null }]);
  });

  it('a correct PIN clears earlier wrong ones', async () => {
    for (let attempt = 1; attempt <= 4; attempt++) await login('tendai', '9999');
    expect((await login('tendai', PIN)).status).toBe(200);
    for (let attempt = 1; attempt <= 4; attempt++) {
      expect((await login('tendai', '9999')).status).toBe(401);
    }
  });

  it('stores only a hash of the session token', async () => {
    const token = await signIn(app, 'tendai', PIN);
    const { rows } = await pools.owner.query<{ token_hash: Buffer }>(
      'SELECT token_hash FROM sessions',
    );

    expect(rows).toHaveLength(1);
    expect(rows[0]?.token_hash.equals(createHash('sha256').update(token).digest())).toBe(true);
  });
});

describe('signed-in requests', () => {
  it('GET /me returns the signed-in user', async () => {
    const token = await signIn(app, 'tendai', PIN);
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
    const token = await signIn(app, 'tendai', PIN);

    const logout = await request(app)
      .post('/api/v1/auth/logout')
      .set('Authorization', `Bearer ${token}`);
    expect(logout.status).toBe(204);
    expect((await me(token)).status).toBe(401);
    expect(await auditEntries(pools.owner, 'auth.logout')).toHaveLength(1);
  });

  it('rejects an expired session', async () => {
    const token = await signIn(app, 'tendai', PIN);
    await pools.owner.query(
      `UPDATE sessions SET created_at = now() - interval '13 hours', expires_at = now() - interval '1 hour'`,
    );

    expect((await me(token)).status).toBe(401);
  });

  it('stops working immediately when the account is deactivated', async () => {
    const token = await signIn(app, 'tendai', PIN);
    await pools.owner.query(`UPDATE users SET is_active = false WHERE username = 'tendai'`);

    expect((await me(token)).status).toBe(401);
  });
});

describe('the default PIN', () => {
  const changePin = (token: string, body: object) =>
    request(app).post('/api/v1/auth/change-pin').set('Authorization', `Bearer ${token}`).send(body);

  it('lets a new account do nothing but choose its own PIN', async () => {
    // Created without a PIN, as admins do: it starts on 1234.
    await createUser(
      pools.app,
      {
        username: 'chipo',
        fullName: 'Chipo Ndlovu',
        organisationId: await headOfficeId(pools.app),
        roleCodes: ['hq_warehouse_officer'],
      },
      { actorUserId: null, via: 'cli' },
    );
    const signedIn = await login('chipo', '1234');
    expect(signedIn.status).toBe(200);
    expect(signedIn.body.user.mustChangePin).toBe(true);
    const token = signedIn.body.token as string;

    const blocked = await request(app)
      .get('/api/v1/stock/balance')
      .set('Authorization', `Bearer ${token}`);
    expect(blocked.status).toBe(403);
    expect(blocked.body.error.code).toBe('PIN_CHANGE_REQUIRED');
    expect((await me(token)).body.user.mustChangePin).toBe(true);

    for (const easy of ['1234', '0000', '7777', '4321', '2468', '123456', '98765']) {
      const refused = await changePin(token, { currentPin: '1234', newPin: easy });
      expect(refused.status, easy).toBe(400);
      expect(refused.body.error.details[0].field).toBe('newPin');
    }
    const tooShort = await changePin(token, { currentPin: '1234', newPin: '12' });
    expect(tooShort.body.error.details).toEqual([
      { field: 'newPin', message: 'Use at least 4 digits' },
    ]);

    const changed = await changePin(token, { currentPin: '1234', newPin: '7391' });
    expect(changed.status).toBe(200);
    expect(changed.body.user.mustChangePin).toBe(false);
    const allowed = await request(app)
      .get('/api/v1/stock/balance')
      .set('Authorization', `Bearer ${token}`);
    expect(allowed.status).toBe(200);
    expect((await login('chipo', '1234')).status).toBe(401);
    expect((await login('chipo', '7391')).status).toBe(200);
    expect(await auditEntries(pools.owner, 'auth.pin_changed')).toHaveLength(1);
  });
});

describe('POST /api/v1/auth/change-pin', () => {
  const changePin = (token: string, body: object) =>
    request(app).post('/api/v1/auth/change-pin').set('Authorization', `Bearer ${token}`).send(body);

  it('changes the PIN and signs out every other session', async () => {
    const thisDevice = await signIn(app, 'tendai', PIN);
    const otherDevice = await signIn(app, 'tendai', PIN);

    const response = await changePin(thisDevice, { currentPin: PIN, newPin: '58203' });

    expect(response.status).toBe(200);
    expect((await me(thisDevice)).status).toBe(200);
    expect((await me(otherDevice)).status).toBe(401);
    expect((await login('tendai', PIN)).status).toBe(401);
    expect((await login('tendai', '58203')).status).toBe(200);
  });

  it('requires the correct current PIN, and a different new one', async () => {
    const token = await signIn(app, 'tendai', PIN);
    const wrong = await changePin(token, { currentPin: '9999', newPin: '58203' });
    expect(wrong.body.error.details).toEqual([{ field: 'currentPin', message: 'Incorrect PIN' }]);
    const same = await changePin(token, { currentPin: PIN, newPin: PIN });
    expect(same.body.error.details).toEqual([
      { field: 'newPin', message: 'Must be different from the current PIN' },
    ]);
  });
});
