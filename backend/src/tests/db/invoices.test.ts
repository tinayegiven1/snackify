import type { Express } from 'express';
import pg from 'pg';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../../modules/auth/roles.js';
import { addDays, businessToday, lastCompleteBillingWeek } from '../../utils/dates.js';
import {
  appDatabaseUrl,
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestProduct,
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
let bbq: string;
let cheese: string;
let avondale: string;
let mabelreign: string;

const today = () => businessToday('Africa/Harare');
const lastWeek = () => lastCompleteBillingWeek(today(), 1);

const as = (role: Role) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${tokens[role]}`),
  post: (path: string, body: object = {}) =>
    request(app).post(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
});

/** Creates a dispatch and moves it to `status` (confirmed by default). */
async function dispatch(
  customerId: string,
  items: { productId: string; quantity: number; unitPrice?: string }[],
  options: { date?: string; status?: 'draft' | 'confirmed' | 'cancelled' | 'reversed' } = {},
) {
  const created = await as('admin').post('/api/v1/dispatches', {
    customerId,
    items,
    dispatchDate: options.date ?? addDays(lastWeek().from, 1),
  });
  if (created.status !== 201) throw new Error(JSON.stringify(created.body));
  const id = created.body.dispatch.id as string;
  const status = options.status ?? 'confirmed';
  if (status === 'cancelled') {
    await as('admin').post(`/api/v1/dispatches/${id}/cancel`, { reason: 'Not needed' });
  }
  if (status === 'confirmed' || status === 'reversed') {
    await as('admin').post(`/api/v1/dispatches/${id}/confirm`, { acknowledgeCreditLimit: true });
  }
  if (status === 'reversed') {
    await as('admin').post(`/api/v1/dispatches/${id}/reverse`, { reason: 'Returned' });
  }
  return { id, number: created.body.dispatch.dispatchNumber as string };
}

const createInvoice = (customerId: string, body: object = {}) =>
  as('accounts').post('/api/v1/invoices', { customerId, ...body });

beforeEach(async () => {
  await resetDatabase(pools.owner);
  await pools.owner.query(
    'ALTER SEQUENCE dispatch_number_seq RESTART; ALTER SEQUENCE invoice_number_seq RESTART',
  );
  app = createDbTestApp(pools.app);
  for (const role of ['admin', 'storekeeper', 'salesperson', 'accounts'] as const) {
    await createTestUser(pools.app, {
      username: role,
      fullName: `Test ${role}`,
      role,
      password: PASSWORD,
    });
    tokens[role] = await signIn(app, role, PASSWORD);
  }
  bbq = await createTestProduct(pools.owner);
  cheese = await createTestProduct(pools.owner, {
    sku: 'MP-CH-S',
    name: 'Maize Puffs',
    flavour: 'Cheese',
  });
  // Received well before last week, so every dispatch below has stock.
  for (const productId of [bbq, cheese]) {
    await as('admin').post('/api/v1/stock/receipts', {
      productId,
      quantity: 1000,
      receivedDate: addDays(lastWeek().from, -1),
    });
  }
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO customers (code, name, phone, address) VALUES
       ('C0001', 'Avondale Tuckshop', '+263 00 000 0001', '1 Example Road'),
       ('C0002', 'Mabelreign Grocers', NULL, NULL)
     RETURNING id`,
  );
  [avondale, mabelreign] = rows.map((row) => row.id) as [string, string];
});
afterAll(() => pools.close());

describe('preview', () => {
  it("lists only the customer's confirmed, unbilled dispatch lines in the period", async () => {
    const billed = await dispatch(avondale, [
      { productId: bbq, quantity: 12 },
      { productId: cheese, quantity: 5, unitPrice: '0.25' },
    ]);
    await dispatch(mabelreign, [{ productId: bbq, quantity: 7 }]); // other customer
    await dispatch(avondale, [{ productId: bbq, quantity: 1 }], { status: 'draft' });
    await dispatch(avondale, [{ productId: bbq, quantity: 2 }], { status: 'cancelled' });
    await dispatch(avondale, [{ productId: bbq, quantity: 3 }], { status: 'reversed' });
    await dispatch(avondale, [{ productId: bbq, quantity: 4 }], {
      date: addDays(lastWeek().from, -1),
    });
    await dispatch(avondale, [{ productId: bbq, quantity: 6 }], { date: today() });

    const response = await as('accounts').get(`/api/v1/invoices/preview?customerId=${avondale}`);

    expect(response.status).toBe(200);
    const preview = response.body.preview;
    expect(preview).toMatchObject({
      periodFrom: lastWeek().from,
      periodTo: lastWeek().to,
      currency: 'USD',
      subtotal: '7.25',
      customer: { code: 'C0001', name: 'Avondale Tuckshop' },
    });
    expect(
      preview.lines.map((l: { dispatchNumber: string; quantity: number; lineTotal: string }) => [
        l.dispatchNumber,
        l.quantity,
        l.lineTotal,
      ]),
    ).toEqual([
      [billed.number, 5, '1.25'],
      [billed.number, 12, '6.00'],
    ]);
    expect((await pools.owner.query('SELECT 1 FROM invoices')).rowCount).toBe(0);
  });

  it('checks the period', async () => {
    const preview = (query: string) =>
      as('accounts').get(`/api/v1/invoices/preview?customerId=${avondale}&${query}`);

    expect((await preview(`from=${today()}&to=${addDays(today(), -1)}`)).status).toBe(400);
    expect((await preview(`from=${today()}&to=${addDays(today(), 1)}`)).status).toBe(400);
    expect((await preview(`from=${addDays(today(), -100)}&to=${today()}`)).status).toBe(400);
    expect((await as('accounts').get('/api/v1/invoices/preview')).status).toBe(400);
  });
});

describe('draft invoices', () => {
  it('hold exactly the previewed lines, and the total equals the sum of the lines', async () => {
    await dispatch(avondale, [
      { productId: bbq, quantity: 12 },
      { productId: cheese, quantity: 5, unitPrice: '0.25' },
    ]);

    const response = await createInvoice(avondale);

    expect(response.status).toBe(201);
    expect(response.body.invoice).toMatchObject({
      status: 'draft',
      invoiceNumber: null,
      subtotal: '7.25',
      total: '7.25',
      amountPaid: '0.00',
      balanceDue: '7.25',
      currency: 'USD',
    });
    expect(response.body.invoice.lines).toHaveLength(2);

    const { rows } = await pools.owner.query<{ total: string; lines: string }>(
      `SELECT v.total::text AS total, sum(i.line_total)::text AS lines
       FROM invoices v JOIN invoice_items i ON i.invoice_id = v.id GROUP BY v.id`,
    );
    expect(rows).toEqual([{ total: '7.25', lines: '7.25' }]);
  });

  it('never bill a dispatch line twice', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    expect((await createInvoice(avondale)).status).toBe(201);

    const second = await createInvoice(avondale);
    expect(second.status).toBe(409);
    expect(second.body.error.code).toBe('NOTHING_TO_INVOICE');
  });

  it('cannot bill anything twice when several people invoice the same customer at once', async () => {
    await dispatch(avondale, [
      { productId: bbq, quantity: 12 },
      { productId: cheese, quantity: 5 },
    ]);
    const busyPool = new pg.Pool({ connectionString: appDatabaseUrl, max: 8 });
    try {
      const busyApp = createDbTestApp(busyPool);
      const results = await Promise.all(
        Array.from({ length: 6 }, () =>
          request(busyApp)
            .post('/api/v1/invoices')
            .set('Authorization', `Bearer ${tokens.accounts}`)
            .send({ customerId: avondale }),
        ),
      );
      expect(results.filter((r) => r.status === 201)).toHaveLength(1);
      expect(results.filter((r) => r.status === 409)).toHaveLength(5);
    } finally {
      await busyPool.end();
    }
    const { rows } = await pools.owner.query('SELECT count(*)::int AS lines FROM invoice_items');
    expect(rows).toEqual([{ lines: 2 }]);
  });

  it('can be voided, which frees the dispatch lines to be invoiced again', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    const draft = (await createInvoice(avondale)).body.invoice;

    const voided = await as('accounts').post(`/api/v1/invoices/${draft.id}/void`, {
      reason: 'Wrong period chosen',
    });
    expect(voided.body.invoice).toMatchObject({
      status: 'voided',
      lines: [],
      balanceDue: '0.00',
      voidReason: 'Wrong period chosen',
    });

    expect((await createInvoice(avondale)).status).toBe(201);
  });

  it('are created for every customer at once by the weekly run', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    await dispatch(avondale, [{ productId: bbq, quantity: 2 }]);
    await dispatch(mabelreign, [{ productId: cheese, quantity: 3, unitPrice: '0.25' }]);
    await dispatch(mabelreign, [{ productId: cheese, quantity: 1 }], { status: 'cancelled' });

    // First, the overview of who still needs invoicing.
    const unbilled = await as('accounts').get('/api/v1/invoices/unbilled');
    expect(unbilled.status).toBe(200);
    expect(unbilled.body).toEqual({
      from: lastWeek().from,
      to: lastWeek().to,
      customers: [
        {
          customer: { id: avondale, code: 'C0001', name: 'Avondale Tuckshop' },
          dispatchCount: 2,
          lineCount: 2,
          subtotal: '7.00',
        },
        {
          customer: { id: mabelreign, code: 'C0002', name: 'Mabelreign Grocers' },
          dispatchCount: 1,
          lineCount: 1,
          subtotal: '0.75',
        },
      ],
    });

    const run = await as('accounts').post('/api/v1/invoices/generate');
    expect(run.status).toBe(201);
    expect(run.body).toMatchObject({ from: lastWeek().from, to: lastWeek().to });
    expect(
      run.body.invoices.map((i: { customer: { code: string } }) => i.customer.code).sort(),
    ).toEqual(['C0001', 'C0002']);

    const again = await as('accounts').post('/api/v1/invoices/generate');
    expect(again.body.invoices).toEqual([]);
    expect((await as('accounts').get('/api/v1/invoices/unbilled')).body.customers).toEqual([]);
  });
});

describe('issuing', () => {
  it('gives the next number and today as the issue date, and freezes the customer details', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    const draft = (await createInvoice(avondale)).body.invoice;

    const issued = await as('accounts').post(`/api/v1/invoices/${draft.id}/issue`);
    expect(issued.status).toBe(200);
    expect(issued.body.invoice).toMatchObject({
      status: 'issued',
      invoiceNumber: 'INV-000001',
      issueDate: today(),
      issuedBy: 'Test accounts',
      customer: { name: 'Avondale Tuckshop', phone: '+263 00 000 0001', address: '1 Example Road' },
    });

    // Changing the customer later does not change the issued invoice.
    await pools.owner.query(`UPDATE customers SET name = 'Renamed Shop' WHERE id = $1`, [avondale]);
    const later = await as('accounts').get(`/api/v1/invoices/${draft.id}`);
    expect(later.body.invoice.customer.name).toBe('Avondale Tuckshop');

    // Issuing again changes nothing.
    const again = await as('accounts').post(`/api/v1/invoices/${draft.id}/issue`);
    expect(again.body.invoice.invoiceNumber).toBe('INV-000001');
    expect(await auditEntries(pools.owner, 'invoice.issued')).toHaveLength(1);
  });

  it('makes the invoice impossible to change, void or delete, even directly in the database', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    const draft = (await createInvoice(avondale)).body.invoice;
    await as('accounts').post(`/api/v1/invoices/${draft.id}/issue`);

    const voided = await as('accounts').post(`/api/v1/invoices/${draft.id}/void`, {
      reason: 'Oops',
    });
    expect(voided.status).toBe(409);
    expect(voided.body.error.code).toBe('INVOICE_ISSUED');

    for (const sql of [
      `UPDATE invoices SET total = 0, subtotal = 0 WHERE id = '${draft.id}'`,
      `UPDATE invoices SET customer_name = 'Someone else' WHERE id = '${draft.id}'`,
      `UPDATE invoices SET status = 'draft' WHERE id = '${draft.id}'`,
      `UPDATE invoice_items SET quantity = 1 WHERE invoice_id = '${draft.id}'`,
      `DELETE FROM invoice_items WHERE invoice_id = '${draft.id}'`,
    ]) {
      expect((await pgErrorOf(pools.app.query(sql))).code, sql).toBe(PG.checkViolation);
    }
    expect((await pgErrorOf(pools.app.query('DELETE FROM invoices'))).code).toBe(
      PG.insufficientPrivilege,
    );
  });

  it('is refused by the database when the total does not match the lines', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    const draft = (await createInvoice(avondale)).body.invoice;
    await pools.app.query(`UPDATE invoices SET subtotal = 1, total = 1 WHERE id = $1`, [draft.id]);

    const error = await pgErrorOf(
      pools.app.query(
        `UPDATE invoices SET status = 'issued', invoice_number = 'INV-TEST', issue_date = current_date,
           issued_by = created_by, issued_at = now(), customer_code = 'C0001', customer_name = 'X'
         WHERE id = $1`,
        [draft.id],
      ),
    );
    expect(error.code).toBe(PG.checkViolation);
    expect(error.message).toContain('does not match its lines');
  });
});

describe('dispatches on invoices', () => {
  it('are never both reversed and invoiced when both happen at the same moment', async () => {
    const busyPool = new pg.Pool({ connectionString: appDatabaseUrl, max: 4 });
    try {
      const busyApp = createDbTestApp(busyPool);
      for (let round = 0; round < 5; round += 1) {
        const shipped = await dispatch(avondale, [{ productId: bbq, quantity: 1 }]);
        const [invoiced, reversed] = await Promise.all([
          request(busyApp)
            .post('/api/v1/invoices')
            .set('Authorization', `Bearer ${tokens.accounts}`)
            .send({ customerId: avondale }),
          request(busyApp)
            .post(`/api/v1/dispatches/${shipped.id}/reverse`)
            .set('Authorization', `Bearer ${tokens.admin}`)
            .send({ reason: 'Returned' }),
        ]);
        // Exactly one wins: either the invoice (and the reversal is refused) or the reversal
        // (and there is nothing left to invoice).
        const outcome = [invoiced.status, reversed.status];
        expect([
          [201, 409],
          [409, 200],
        ]).toContainEqual(outcome);
        // Clear the way for the next round.
        if (invoiced.status === 201) {
          await as('accounts').post(`/api/v1/invoices/${invoiced.body.invoice.id}/void`, {
            reason: 'Next round',
          });
          await as('admin').post(`/api/v1/dispatches/${shipped.id}/reverse`, { reason: 'Next' });
        }
      }
    } finally {
      await busyPool.end();
    }
    // Nothing reversed is on any invoice.
    const { rows } = await pools.owner.query(
      `SELECT count(*)::int AS billed_reversed
       FROM invoice_items ii JOIN dispatch_items i ON i.id = ii.dispatch_item_id
       JOIN dispatches d ON d.id = i.dispatch_id
       WHERE d.status = 'reversed'`,
    );
    expect(rows).toEqual([{ billed_reversed: 0 }]);
  });

  it('cannot be reversed', async () => {
    const shipped = await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    const draft = (await createInvoice(avondale)).body.invoice;

    const whileDraft = await as('admin').post(`/api/v1/dispatches/${shipped.id}/reverse`, {
      reason: 'Mistake',
    });
    expect(whileDraft.status).toBe(409);
    expect(whileDraft.body.error.message).toBe(
      'This dispatch is on a draft invoice. Void the draft invoice first, then reverse it.',
    );

    await as('accounts').post(`/api/v1/invoices/${draft.id}/issue`);
    const whileIssued = await as('admin').post(`/api/v1/dispatches/${shipped.id}/reverse`, {
      reason: 'Mistake',
    });
    expect(whileIssued.body.error.code).toBe('DISPATCH_INVOICED');
    expect(whileIssued.body.error.message).toContain('INV-000001');
  });
});

describe('PDF', () => {
  const binary = (res: request.Response, done: (error: Error | null, body: Buffer) => void) => {
    const chunks: Buffer[] = [];
    res.on('data', (chunk: Buffer) => chunks.push(chunk));
    res.on('end', () => done(null, Buffer.concat(chunks)));
  };
  const pdf = (id: string) =>
    request(app)
      .get(`/api/v1/invoices/${id}/pdf`)
      .set('Authorization', `Bearer ${tokens.accounts}`)
      .buffer(true)
      .parse(binary);

  it('is produced for issued invoices, named after the invoice number', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    const draft = (await createInvoice(avondale)).body.invoice;
    await as('accounts').post(`/api/v1/invoices/${draft.id}/issue`);

    const response = await pdf(draft.id);

    expect(response.status).toBe(200);
    expect(response.headers['content-type']).toBe('application/pdf');
    expect(response.headers['content-disposition']).toBe('inline; filename="INV-000001.pdf"');
    const body = response.body as Buffer;
    expect(body.subarray(0, 5).toString()).toBe('%PDF-');
    expect(body.toString('latin1')).toContain('(Invoice INV-000001)');
  });

  it('marks a draft clearly as not an invoice', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    const draft = (await createInvoice(avondale)).body.invoice;

    const body = (await pdf(draft.id)).body as Buffer;
    expect(body.toString('latin1')).toContain('(Draft invoice for Avondale Tuckshop)');
  });
});

describe('who can use invoices', () => {
  it('is accounts staff and admins only', async () => {
    await dispatch(avondale, [{ productId: bbq, quantity: 12 }]);
    for (const role of ['salesperson', 'storekeeper'] as const) {
      expect((await as(role).get('/api/v1/invoices')).status, role).toBe(403);
      expect((await as(role).post('/api/v1/invoices', { customerId: avondale })).status, role).toBe(
        403,
      );
    }
    expect((await as('admin').get('/api/v1/invoices')).status).toBe(200);
  });
});
