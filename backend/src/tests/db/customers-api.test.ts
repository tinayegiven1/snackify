import { randomUUID } from 'node:crypto';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../../modules/auth/roles.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestUser,
  PG,
  pgErrorOf,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

const pools = createTestPools();
const PASSWORD = 'correct horse battery';
let app: Express;
const tokens = {} as Record<Role, string>;

const as = (role: Role) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${tokens[role]}`),
  post: (path: string, body: object) =>
    request(app).post(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
  patch: (path: string, body: object) =>
    request(app).patch(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
});

async function addCustomer(body: object = {}, role: Role = 'salesperson') {
  const response = await as(role).post('/api/v1/customers', {
    name: 'Avondale Tuckshop',
    phone: '+263 77 123 4567',
    address: '12 King George Road, Avondale, Harare',
    ...body,
  });
  if (response.status !== 201) {
    throw new Error(`Could not add customer: ${JSON.stringify(response.body)}`);
  }
  return response.body.customer as { id: string; code: string };
}

const fields = (response: request.Response) =>
  (response.body.error?.details ?? []).map((d: { field: string }) => d.field);

beforeEach(async () => {
  await resetDatabase(pools.owner);
  // Restart generated codes at C0001 for each test.
  await pools.owner.query('ALTER SEQUENCE customer_code_seq RESTART');
  app = createDbTestApp(pools.app);
  for (const role of ['admin', 'storekeeper', 'salesperson', 'accounts'] as const) {
    await createTestUser(pools.app, { username: role, role, password: PASSWORD });
    tokens[role] = await signIn(app, role, PASSWORD);
  }
});
afterAll(() => pools.close());

describe('adding customers', () => {
  it('gives each new customer the next free code unless one is chosen', async () => {
    const first = await addCustomer();
    const own = await addCustomer({ name: 'Borrowdale Spar', code: ' spar-bdl ' }, 'admin');
    const second = await addCustomer({ name: 'Mabelreign Grocers' });

    expect([first.code, own.code, second.code]).toEqual(['C0001', 'SPAR-BDL', 'C0002']);
  });

  it('skips generated codes that staff have already used', async () => {
    await addCustomer({ name: 'Manual One', code: 'C0001' });
    expect((await addCustomer({ name: 'Generated' })).code).toBe('C0002');
  });

  it('stores tidied details and records who added the customer', async () => {
    const response = await as('salesperson').post('/api/v1/customers', {
      name: '  Avondale Tuckshop ',
      phone: '',
      address: '  12 King George Road ',
    });

    expect(response.status).toBe(201);
    expect(response.body.customer).toMatchObject({
      code: 'C0001',
      name: 'Avondale Tuckshop',
      phone: null,
      address: '12 King George Road',
      creditLimit: null,
      isActive: true,
    });
    const [entry] = await auditEntries(pools.owner, 'customer.created');
    expect(entry?.details).toEqual({ code: 'C0001', name: 'Avondale Tuckshop', creditLimit: null });
  });

  it('explains every invalid field', async () => {
    const response = await as('salesperson').post('/api/v1/customers', {
      code: 'bad code!',
      name: '',
      phone: 'call me',
    });

    expect(response.status).toBe(400);
    expect(fields(response)).toEqual(['code', 'name', 'phone']);
  });

  it('rejects a code that another customer already uses, in any letter case', async () => {
    await addCustomer({ code: 'SPAR-BDL' });
    const response = await as('salesperson').post('/api/v1/customers', {
      name: 'Another Spar',
      code: 'spar-bdl',
    });

    expect(response.status).toBe(409);
    expect(response.body.error).toMatchObject({
      code: 'CUSTOMER_CODE_TAKEN',
      details: [{ field: 'code', message: 'Already used by another customer' }],
    });
  });

  it('is allowed for salespeople and admins only', async () => {
    for (const role of ['storekeeper', 'accounts'] as const) {
      const response = await as(role).post('/api/v1/customers', { name: 'Not allowed' });
      expect(response.status, role).toBe(403);
    }
    expect((await pools.owner.query('SELECT 1 FROM customers')).rowCount).toBe(0);
  });
});

describe('credit limits and other restricted fields', () => {
  it('only accounts staff and admins can set a credit limit', async () => {
    const bySalesperson = await as('salesperson').post('/api/v1/customers', {
      name: 'Credit Customer',
      creditLimit: '500',
    });
    expect(bySalesperson.status).toBe(403);
    expect(fields(bySalesperson)).toEqual(['creditLimit']);

    const customer = await addCustomer();
    const salesChange = await as('salesperson').patch(`/api/v1/customers/${customer.id}`, {
      creditLimit: '500',
    });
    expect(salesChange.status).toBe(403);

    const accountsChange = await as('accounts').patch(`/api/v1/customers/${customer.id}`, {
      creditLimit: '500',
    });
    expect(accountsChange.status).toBe(200);
    expect(accountsChange.body.customer.creditLimit).toBe('500.00');

    const [entry] = await auditEntries(pools.owner, 'customer.updated');
    expect(entry?.details).toEqual({ changes: { creditLimit: { from: null, to: '500.00' } } });
  });

  it('accounts staff can change credit limits but not customer details', async () => {
    const customer = await addCustomer();
    const response = await as('accounts').patch(`/api/v1/customers/${customer.id}`, {
      name: 'Renamed',
    });

    expect(response.status).toBe(403);
    expect(response.body.error.message).toBe('Your role does not allow changing customer details.');
  });

  it('salespeople edit details; only admins deactivate customers', async () => {
    const customer = await addCustomer();

    const edit = await as('salesperson').patch(`/api/v1/customers/${customer.id}`, {
      phone: '0242 123 456',
      address: null,
    });
    expect(edit.status).toBe(200);
    expect(edit.body.customer).toMatchObject({ phone: '0242 123 456', address: null });

    const deactivateBySales = await as('salesperson').patch(`/api/v1/customers/${customer.id}`, {
      isActive: false,
    });
    expect(deactivateBySales.status).toBe(403);

    const deactivate = await as('admin').patch(`/api/v1/customers/${customer.id}`, {
      isActive: false,
    });
    expect(deactivate.body.customer.isActive).toBe(false);
  });

  it('storekeepers cannot change customers at all', async () => {
    const customer = await addCustomer();
    const response = await as('storekeeper').patch(`/api/v1/customers/${customer.id}`, {
      phone: '0242 000 000',
    });
    expect(response.status).toBe(403);
  });

  it('rejects invalid credit limits', async () => {
    const customer = await addCustomer();
    for (const creditLimit of ['-1', '10.555', 'lots']) {
      const response = await as('accounts').patch(`/api/v1/customers/${customer.id}`, {
        creditLimit,
      });
      expect(response.status, creditLimit).toBe(400);
      expect(fields(response)).toEqual(['creditLimit']);
    }
  });
});

describe('finding customers', () => {
  it('lists active customers by name for every role, and searches code, name or phone', async () => {
    await addCustomer({ name: 'Mabelreign Grocers', phone: '0242 300 300' });
    await addCustomer({ name: 'avondale tuckshop' });
    const inactive = await addCustomer({ name: 'Closed Kiosk' });
    await as('admin').patch(`/api/v1/customers/${inactive.id}`, { isActive: false });

    const all = await as('storekeeper').get('/api/v1/customers');
    expect(all.body.customers.map((c: { name: string }) => c.name)).toEqual([
      'avondale tuckshop',
      'Mabelreign Grocers',
    ]);
    expect(all.body.total).toBe(2);

    const search = (q: string) =>
      as('accounts').get(`/api/v1/customers?q=${encodeURIComponent(q)}`);
    expect((await search('MABEL')).body.total).toBe(1);
    expect((await search('c0002')).body.customers[0].name).toBe('avondale tuckshop');
    expect((await search('300 300')).body.total).toBe(1);
    expect((await search('%')).body.total).toBe(0);

    const withInactive = await as('admin').get('/api/v1/customers?includeInactive=true');
    expect(withInactive.body.total).toBe(3);
  });

  it('returns one customer, or 404 for unknown and malformed ids', async () => {
    const customer = await addCustomer();

    expect(
      (await as('storekeeper').get(`/api/v1/customers/${customer.id}`)).body.customer.code,
    ).toBe('C0001');
    expect((await as('storekeeper').get(`/api/v1/customers/${randomUUID()}`)).status).toBe(404);
    expect((await as('storekeeper').get('/api/v1/customers/nope')).status).toBe(404);
  });

  it('cannot be deleted, through the API or directly by the API role', async () => {
    const customer = await addCustomer();

    const viaApi = await request(app)
      .delete(`/api/v1/customers/${customer.id}`)
      .set('Authorization', `Bearer ${tokens.admin}`);
    expect(viaApi.status).toBe(404);

    const direct = await pgErrorOf(pools.app.query('DELETE FROM customers'));
    expect(direct.code).toBe(PG.insufficientPrivilege);
  });
});
