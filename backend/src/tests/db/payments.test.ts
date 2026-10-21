import { randomUUID } from 'node:crypto';
import type { Express } from 'express';
import pg from 'pg';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from './db-test-helpers.js';
import { addDays, businessToday, lastCompleteBillingWeek } from '../../utils/dates.js';
import {
  appDatabaseUrl,
  auditEntries,
  createDbTestApp,
  createTestPools,
  receiveTestStock,
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
let avondale: string;
let mabelreign: string;

const today = () => businessToday('Africa/Harare');
/** A complete billing week: 1 = last week, 2 = the week before, ... */
const week = (weeksAgo: number) => {
  const last = lastCompleteBillingWeek(today(), 1);
  return {
    from: addDays(last.from, -7 * (weeksAgo - 1)),
    to: addDays(last.to, -7 * (weeksAgo - 1)),
  };
};

const as = (role: Role) => ({
  get: (path: string) => request(app).get(path).set('Authorization', `Bearer ${tokens[role]}`),
  post: (path: string, body: object = {}) =>
    request(app).post(path).set('Authorization', `Bearer ${tokens[role]}`).send(body),
});

/** A confirmed dispatch of `quantity` packs at 0.50 each. */
async function dispatch(customerId: string, quantity: number, date: string) {
  const created = await as('admin').post('/api/v1/dispatches', {
    customerId,
    items: [{ productId: bbq, quantity }],
    dispatchDate: date,
  });
  if (created.status !== 201) throw new Error(JSON.stringify(created.body));
  await as('admin').post(`/api/v1/dispatches/${created.body.dispatch.id}/confirm`, {
    acknowledgeCreditLimit: true,
  });
  return created.body.dispatch.id as string;
}

/** An issued invoice for `quantity` packs dispatched `weeksAgo` weeks ago (total quantity × 0.50). */
async function issuedInvoice(customerId: string, quantity: number, weeksAgo = 1) {
  const period = week(weeksAgo);
  await dispatch(customerId, quantity, addDays(period.from, 1));
  const draft = await as('accounts').post('/api/v1/invoices', { customerId, ...period });
  if (draft.status !== 201) throw new Error(JSON.stringify(draft.body));
  const issued = await as('accounts').post(`/api/v1/invoices/${draft.body.invoice.id}/issue`);
  return issued.body.invoice as { id: string; invoiceNumber: string; total: string };
}

/** Moves an issued invoice's dates into the past (the database otherwise forbids it). */
async function backdate(invoiceId: string, issueDate: string, dueDate: string) {
  await pools.owner.query('ALTER TABLE invoices DISABLE TRIGGER invoices_protect_finished');
  try {
    await pools.owner.query('UPDATE invoices SET issue_date = $2, due_date = $3 WHERE id = $1', [
      invoiceId,
      issueDate,
      dueDate,
    ]);
  } finally {
    await pools.owner.query('ALTER TABLE invoices ENABLE TRIGGER invoices_protect_finished');
  }
}

const record = (body: object, role: Role = 'accounts') =>
  as(role).post('/api/v1/payments', {
    customerId: avondale,
    paymentDate: today(),
    method: 'cash',
    ...body,
  });

const getInvoice = async (id: string) =>
  (await as('accounts').get(`/api/v1/invoices/${id}`)).body.invoice;

beforeEach(async () => {
  await resetDatabase(pools.owner);
  await pools.owner.query(
    `ALTER SEQUENCE dispatch_number_seq RESTART; ALTER SEQUENCE invoice_number_seq RESTART;
     ALTER SEQUENCE payment_number_seq RESTART`,
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
  await receiveTestStock(pools.app, {
    productId: bbq,
    quantity: 1000,
    receivedDate: addDays(week(6).from, -1),
  });
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO customers (code, name) VALUES
       ('C0001', 'Avondale Tuckshop'), ('C0002', 'Mabelreign Grocers'), ('C0003', 'Quiet Customer')
     RETURNING id`,
  );
  [avondale, mabelreign] = rows.map((row) => row.id) as [string, string];
});
afterAll(() => pools.close());

describe('recording a payment', () => {
  it('pays an invoice in parts; its balance is the total less the payments (spec 11)', async () => {
    const invoice = await issuedInvoice(avondale, 20); // 10.00

    const first = await record({
      amount: '4.00',
      method: 'mobile_money',
      reference: 'MP261012.1234.A56789',
      allocations: [{ invoiceId: invoice.id, amount: '4.00' }],
    });

    expect(first.status).toBe(201);
    expect(first.body).toMatchObject({
      duplicate: false,
      payment: {
        paymentNumber: 'P000001',
        status: 'recorded',
        customer: { code: 'C0001' },
        amount: '4.00',
        currency: 'USD',
        method: 'mobile_money',
        reference: 'MP261012.1234.A56789',
        allocatedAmount: '4.00',
        unallocatedAmount: '0.00',
        allocations: [{ invoiceId: invoice.id, invoiceNumber: 'INV-000001', amount: '4.00' }],
        recordedBy: 'Test accounts',
      },
    });
    expect(await getInvoice(invoice.id)).toMatchObject({
      total: '10.00',
      amountPaid: '4.00',
      balanceDue: '6.00',
      paymentStatus: 'part_paid',
      payments: [{ paymentNumber: 'P000001', amount: '4.00', method: 'mobile_money' }],
    });

    await record({ amount: '6.00', allocations: [{ invoiceId: invoice.id, amount: '6.00' }] });

    expect(await getInvoice(invoice.id)).toMatchObject({
      amountPaid: '10.00',
      balanceDue: '0.00',
      paymentStatus: 'paid',
      overdue: false,
    });
    expect(await auditEntries(pools.owner, 'payment.recorded')).toHaveLength(2);
  });

  it('can pay several invoices; what is left is credit that can be allocated later', async () => {
    const older = await issuedInvoice(avondale, 20, 2); // 10.00
    const newer = await issuedInvoice(avondale, 10, 1); // 5.00

    const payment = (
      await record({
        amount: '20.00',
        method: 'bank_transfer',
        allocations: [
          { invoiceId: older.id, amount: '10.00' },
          { invoiceId: newer.id, amount: '5.00' },
        ],
      })
    ).body.payment;
    expect(payment).toMatchObject({ allocatedAmount: '15.00', unallocatedAmount: '5.00' });

    const later = await issuedInvoice(avondale, 6, 3); // 3.00
    const allocated = await as('accounts').post(`/api/v1/payments/${payment.id}/allocations`, {
      allocations: [{ invoiceId: later.id, amount: '3.00' }],
    });
    expect(allocated.status).toBe(200);
    expect(allocated.body.payment).toMatchObject({
      allocatedAmount: '18.00',
      unallocatedAmount: '2.00',
    });
    expect((await getInvoice(later.id)).paymentStatus).toBe('paid');
    expect(await auditEntries(pools.owner, 'payment.allocated')).toHaveLength(1);
  });

  it('refuses allocations beyond the invoice or the payment, and to the wrong invoices', async () => {
    const invoice = await issuedInvoice(avondale, 20); // 10.00
    const theirs = await issuedInvoice(mabelreign, 4); // 2.00
    await dispatch(avondale, 2, week(2).from);
    const draft = (
      await as('accounts').post('/api/v1/invoices', { customerId: avondale, ...week(2) })
    ).body.invoice;

    const tooMuchForInvoice = await record({
      amount: '12.00',
      allocations: [{ invoiceId: invoice.id, amount: '12.00' }],
    });
    expect(tooMuchForInvoice.status).toBe(409);
    expect(tooMuchForInvoice.body.error).toMatchObject({
      code: 'ALLOCATION_EXCEEDS_BALANCE',
      message: 'Invoice INV-000001 has only USD 10.00 left to pay.',
      details: { invoiceId: invoice.id, balanceDue: '10.00' },
    });

    const tooMuchForPayment = await record({
      amount: '5.00',
      allocations: [{ invoiceId: invoice.id, amount: '6.00' }],
    });
    expect(tooMuchForPayment.body.error.code).toBe('ALLOCATION_EXCEEDS_PAYMENT');

    const toDraft = await record({
      amount: '1.00',
      allocations: [{ invoiceId: draft.id, amount: '1.00' }],
    });
    expect(toDraft.body.error.code).toBe('INVOICE_NOT_ISSUED');

    const toOtherCustomer = await record({
      amount: '1.00',
      allocations: [{ invoiceId: theirs.id, amount: '1.00' }],
    });
    expect(toOtherCustomer.body.error.code).toBe('INVOICE_OTHER_CUSTOMER');

    const twice = await record({
      amount: '2.00',
      allocations: [
        { invoiceId: invoice.id, amount: '1.00' },
        { invoiceId: invoice.id, amount: '1.00' },
      ],
    });
    expect(twice.status).toBe(400);
    expect(twice.body.error.details).toEqual([
      { field: 'allocations', message: 'List each invoice only once' },
    ]);

    // Nothing was recorded by any refused request.
    expect((await pools.owner.query('SELECT 1 FROM payments')).rowCount).toBe(0);
  });

  it('checks the amount, date and method', async () => {
    const fields = async (body: object) =>
      ((await record(body)).body.error.details as { field: string }[]).map((d) => d.field);

    expect(await fields({ amount: '0.00' })).toEqual(['amount']);
    expect(await fields({ amount: '-5' })).toEqual(['amount']);
    expect(await fields({ amount: '1.234' })).toEqual(['amount']);
    expect(await fields({ amount: '5.00', method: 'barter' })).toEqual(['method']);
    expect(await fields({ amount: '5.00', paymentDate: addDays(today(), 1) })).toEqual([
      'paymentDate',
    ]);
    expect(await fields({ amount: '5.00', reference: 'x'.repeat(101) })).toEqual(['reference']);
  });
});

describe('the same payment sent twice', () => {
  it('is recorded once', async () => {
    const invoice = await issuedInvoice(avondale, 20);
    const body = {
      amount: '10.00',
      idempotencyKey: randomUUID(),
      allocations: [{ invoiceId: invoice.id, amount: '10.00' }],
    };

    const first = await record(body);
    const again = await record(body);

    expect(first.status).toBe(201);
    expect(again.status).toBe(200);
    expect(again.body).toMatchObject({ duplicate: true, payment: { id: first.body.payment.id } });
    expect((await pools.owner.query('SELECT 1 FROM payments')).rowCount).toBe(1);
    expect((await getInvoice(invoice.id)).amountPaid).toBe('10.00');

    const different = await record({ ...body, amount: '9.00', allocations: [] });
    expect(different.status).toBe(409);
    expect(different.body.error.code).toBe('IDEMPOTENCY_KEY_REUSED');
  });

  it('is recorded once even when the copies arrive at the same moment', async () => {
    const busyPool = new pg.Pool({ connectionString: appDatabaseUrl, max: 8 });
    try {
      const busyApp = createDbTestApp(busyPool);
      for (let round = 0; round < 3; round += 1) {
        const key = randomUUID();
        const results = await Promise.all(
          Array.from({ length: 5 }, () =>
            request(busyApp)
              .post('/api/v1/payments')
              .set('Authorization', `Bearer ${tokens.accounts}`)
              .send({
                customerId: avondale,
                paymentDate: today(),
                amount: '3.00',
                method: 'cash',
                idempotencyKey: key,
              }),
          ),
        );
        expect(results.map((r) => r.status).sort(), `round ${round}`).toEqual([
          200, 200, 200, 200, 201,
        ]);
        expect(new Set(results.map((r) => r.body.payment.id)).size).toBe(1);
      }
    } finally {
      await busyPool.end();
    }
    expect((await pools.owner.query('SELECT 1 FROM payments')).rowCount).toBe(3);
  });
});

describe('simultaneous allocations', () => {
  it('never pay an invoice more than its total', async () => {
    const busyPool = new pg.Pool({ connectionString: appDatabaseUrl, max: 8 });
    try {
      const busyApp = createDbTestApp(busyPool);
      for (let round = 1; round <= 3; round += 1) {
        const invoice = await issuedInvoice(avondale, 20, round); // 10.00
        // Four payments of 10.00 held as credit, all allocated to the invoice at once.
        const payments: string[] = [];
        for (let i = 0; i < 4; i += 1) {
          payments.push((await record({ amount: '10.00' })).body.payment.id);
        }
        const results = await Promise.all(
          payments.map((id) =>
            request(busyApp)
              .post(`/api/v1/payments/${id}/allocations`)
              .set('Authorization', `Bearer ${tokens.accounts}`)
              .send({ allocations: [{ invoiceId: invoice.id, amount: '10.00' }] }),
          ),
        );
        expect(results.map((r) => r.status).sort(), `round ${round}`).toEqual([200, 409, 409, 409]);
        expect((await getInvoice(invoice.id)).amountPaid).toBe('10.00');
      }
    } finally {
      await busyPool.end();
    }
  });
});

describe('voiding a payment', () => {
  it('is for admins, needs a reason, and makes its invoices owed again', async () => {
    const invoice = await issuedInvoice(avondale, 20);
    const payment = (
      await record({ amount: '10.00', allocations: [{ invoiceId: invoice.id, amount: '6.00' }] })
    ).body.payment;

    expect(
      (await as('accounts').post(`/api/v1/payments/${payment.id}/void`, { reason: 'Bounced' }))
        .status,
    ).toBe(403);
    expect((await as('admin').post(`/api/v1/payments/${payment.id}/void`, {})).status).toBe(400);

    const voided = await as('admin').post(`/api/v1/payments/${payment.id}/void`, {
      reason: 'Cheque bounced',
    });
    expect(voided.status).toBe(200);
    expect(voided.body.payment).toMatchObject({
      status: 'voided',
      voidReason: 'Cheque bounced',
      voidedBy: 'Test admin',
      allocatedAmount: '6.00', // kept as history
      unallocatedAmount: '0.00',
    });
    expect(await getInvoice(invoice.id)).toMatchObject({
      amountPaid: '0.00',
      balanceDue: '10.00',
      paymentStatus: 'unpaid',
      payments: [],
    });

    const allocate = await as('accounts').post(`/api/v1/payments/${payment.id}/allocations`, {
      allocations: [{ invoiceId: invoice.id, amount: '1.00' }],
    });
    expect(allocate.body.error.code).toBe('PAYMENT_VOIDED');

    // Voiding again changes nothing.
    await as('admin').post(`/api/v1/payments/${payment.id}/void`, { reason: 'Again' });
    expect(await auditEntries(pools.owner, 'payment.voided')).toHaveLength(1);
  });
});

describe('the database itself', () => {
  it('refuses to change or delete payments and allocations, or to overpay', async () => {
    const invoice = await issuedInvoice(avondale, 20);
    const payment = (
      await record({ amount: '10.00', allocations: [{ invoiceId: invoice.id, amount: '4.00' }] })
    ).body.payment;
    const other = (await record({ amount: '10.00' })).body.payment;
    const voided = (await record({ amount: '2.00' })).body.payment;
    await as('admin').post(`/api/v1/payments/${voided.id}/void`, { reason: 'Mistake' });

    for (const sql of [
      `UPDATE payments SET amount = 1 WHERE id = '${payment.id}'`,
      `UPDATE payments SET payment_date = '2020-01-01' WHERE id = '${payment.id}'`,
      `UPDATE payments SET status = 'voided' WHERE id = '${payment.id}'`,
      // A voided payment stays voided.
      `UPDATE payments SET status = 'recorded' WHERE id = '${voided.id}'`,
      // Over the invoice: 4.00 paid already, 10.00 total.
      `INSERT INTO payment_allocations (payment_id, invoice_id, amount, created_by)
       SELECT '${other.id}', '${invoice.id}', 6.01, recorded_by FROM payments WHERE id = '${other.id}'`,
      // Over the payment: 6.00 left of it.
      `INSERT INTO payment_allocations (payment_id, invoice_id, amount, created_by)
       SELECT '${payment.id}', '${invoice.id}', 6.01, recorded_by FROM payments WHERE id = '${payment.id}'`,
    ]) {
      expect((await pgErrorOf(pools.app.query(sql))).code, sql).toBe(PG.checkViolation);
    }
    for (const sql of [
      'DELETE FROM payments',
      'DELETE FROM payment_allocations',
      'UPDATE payment_allocations SET amount = 1',
    ]) {
      expect((await pgErrorOf(pools.app.query(sql))).code, sql).toBe(PG.insufficientPrivilege);
    }
  });
});

describe('balances', () => {
  it('separate what is not yet invoiced, unpaid, overdue and in credit', async () => {
    const old = await issuedInvoice(avondale, 20, 3); // 10.00, made overdue below
    await backdate(old.id, addDays(today(), -20), addDays(today(), -13));
    const recent = await issuedInvoice(avondale, 10, 1); // 5.00, due in 7 days
    await dispatch(avondale, 4, today()); // 2.00, not yet invoiced
    await record({ amount: '3.00', allocations: [{ invoiceId: old.id, amount: '3.00' }] });
    await record({ amount: '1.00' }); // credit
    await record({ amount: '2.00', customerId: mabelreign }); // paid in advance

    const response = await as('accounts').get('/api/v1/balances');

    expect(response.status).toBe(200);
    expect(response.body.currency).toBe('USD');
    expect(response.body.customers).toEqual([
      {
        customer: { id: avondale, code: 'C0001', name: 'Avondale Tuckshop', creditLimit: null },
        notYetInvoiced: '2.00',
        invoicedUnpaid: '12.00',
        overdue: '7.00',
        unallocatedCredit: '1.00',
        balance: '13.00',
        oldestOverdueDueDate: addDays(today(), -13),
      },
      {
        customer: { id: mabelreign, code: 'C0002', name: 'Mabelreign Grocers', creditLimit: null },
        notYetInvoiced: '0.00',
        invoicedUnpaid: '0.00',
        overdue: '0.00',
        unallocatedCredit: '2.00',
        balance: '-2.00',
        oldestOverdueDueDate: null,
      },
    ]);
    expect(response.body.totals).toEqual({
      notYetInvoiced: '2.00',
      invoicedUnpaid: '12.00',
      overdue: '7.00',
      unallocatedCredit: '3.00',
      balance: '11.00',
    });
    expect((await getInvoice(old.id)).overdue).toBe(true);
    expect((await getInvoice(recent.id)).overdue).toBe(false);

    // The balance equals confirmed dispatches (17.00) less payments received (4.00).
    const { rows } = await pools.owner.query<{ balance: string }>(
      `SELECT ((SELECT sum(i.quantity * i.unit_price) FROM dispatches d
                JOIN dispatch_items i ON i.dispatch_id = d.id
                WHERE d.customer_id = $1 AND d.status = 'confirmed')
             - (SELECT sum(amount) FROM payments WHERE customer_id = $1 AND status = 'recorded')
              )::text AS balance`,
      [avondale],
    );
    expect(rows[0]?.balance).toBe('13.00');
  });

  it('are what credit-limit warnings use, so payments lower the balance', async () => {
    await issuedInvoice(avondale, 20); // 10.00 owed
    await pools.owner.query(`UPDATE customers SET credit_limit = 12 WHERE id = $1`, [avondale]);
    const draft = await as('admin').post('/api/v1/dispatches', {
      customerId: avondale,
      items: [{ productId: bbq, quantity: 8 }], // 4.00
      dispatchDate: today(),
    });
    expect(draft.body.dispatch.creditCheck).toMatchObject({
      balanceBefore: '10.00',
      exceedsLimit: true,
    });

    await record({ amount: '5.00' });

    const after = await as('admin').get(`/api/v1/dispatches/${draft.body.dispatch.id}`);
    expect(after.body.dispatch.creditCheck).toMatchObject({
      balanceBefore: '5.00',
      balanceAfter: '9.00',
      exceedsLimit: false,
    });
  });
});

describe('a customer account', () => {
  it('shows open invoices, credit, and a statement with a running balance', async () => {
    const first = await issuedInvoice(avondale, 20, 3); // 10.00
    await backdate(first.id, addDays(today(), -40), addDays(today(), -33));
    await issuedInvoice(avondale, 10, 1); // 5.00, issued today
    await record({
      amount: '4.00',
      paymentDate: addDays(today(), -35),
      allocations: [{ invoiceId: first.id, amount: '4.00' }],
    });
    await record({ amount: '1.50', paymentDate: addDays(today(), -2), reference: 'BANK-1' });
    const voided = (await record({ amount: '9.00', paymentDate: addDays(today(), -1) })).body
      .payment;
    await as('admin').post(`/api/v1/payments/${voided.id}/void`, { reason: 'Recorded twice' });

    const response = await as('accounts').get(
      `/api/v1/balances/${avondale}?from=${addDays(today(), -36)}&to=${today()}`,
    );

    expect(response.status).toBe(200);
    const account = response.body.account;
    expect(account.summary).toMatchObject({
      invoicedUnpaid: '11.00',
      overdue: '6.00',
      unallocatedCredit: '1.50',
      balance: '9.50',
    });
    expect(account.openInvoices).toEqual([
      expect.objectContaining({
        invoiceNumber: 'INV-000001',
        balanceDue: '6.00',
        overdue: true,
        daysOverdue: 33,
      }),
      expect.objectContaining({
        invoiceNumber: 'INV-000002',
        balanceDue: '5.00',
        overdue: false,
        daysOverdue: 0,
      }),
    ]);
    expect(account.creditPayments).toEqual([
      expect.objectContaining({ paymentNumber: 'P000002', unallocatedAmount: '1.50' }),
    ]);

    // The invoice issued 40 days ago is carried in; the voided payment is left out.
    expect(account.statement).toMatchObject({ openingBalance: '10.00', closingBalance: '9.50' });
    expect(
      account.statement.entries.map(
        (e: {
          reference: string;
          debit: string | null;
          credit: string | null;
          balance: string;
        }) => [e.reference, e.debit, e.credit, e.balance],
      ),
    ).toEqual([
      ['P000001', null, '4.00', '6.00'],
      ['P000002', null, '1.50', '4.50'],
      ['INV-000002', '5.00', null, '9.50'],
    ]);
    expect(account.statement.entries[1]).toMatchObject({
      type: 'payment',
      method: 'cash',
      paymentReference: 'BANK-1',
    });
    expect(account.statement.entries[2]).toMatchObject({
      type: 'invoice',
      periodFrom: week(1).from,
      periodTo: week(1).to,
    });

    // Without dates: the last 90 days.
    const recent = (await as('accounts').get(`/api/v1/balances/${avondale}`)).body.account;
    expect(recent.statement).toMatchObject({ from: addDays(today(), -89), to: today() });

    const backwards = await as('accounts').get(
      `/api/v1/balances/${avondale}?from=${today()}&to=${addDays(today(), -1)}`,
    );
    expect(backwards.status).toBe(400);
  });
});

describe('invoices', () => {
  it('are due seven days after they are issued, and can be listed by what is unpaid', async () => {
    const paid = await issuedInvoice(avondale, 2, 3);
    const late = await issuedInvoice(avondale, 4, 2);
    await backdate(late.id, addDays(today(), -10), addDays(today(), -3));
    const open = await issuedInvoice(avondale, 6, 1);
    await record({ amount: '1.00', allocations: [{ invoiceId: paid.id, amount: '1.00' }] });

    expect((await getInvoice(open.id)).dueDate).toBe(addDays(today(), 7));

    const list = async (payment: string) =>
      (await as('accounts').get(`/api/v1/invoices?payment=${payment}`)).body.invoices.map(
        (i: { invoiceNumber: string }) => i.invoiceNumber,
      );
    expect(await list('unpaid')).toEqual([open.invoiceNumber, late.invoiceNumber]);
    expect(await list('overdue')).toEqual([late.invoiceNumber]);
  });
});

describe('who can see payments and balances', () => {
  it('is accounts staff and admins only', async () => {
    for (const role of ['salesperson', 'storekeeper'] as const) {
      for (const path of ['/api/v1/payments', '/api/v1/balances', `/api/v1/balances/${avondale}`]) {
        expect((await as(role).get(path)).status, `${role} ${path}`).toBe(403);
      }
      expect((await record({ amount: '1.00' }, role)).status, role).toBe(403);
    }
    expect((await as('admin').get('/api/v1/payments')).status).toBe(200);
  });
});
