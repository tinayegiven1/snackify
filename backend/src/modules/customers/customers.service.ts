import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { changedFields, recordAudit } from '../audit/audit.js';

/** A customer (spec 6.5). */
export interface Customer {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  address: string | null;
  /** Exact decimal string in the base currency, or null when no limit is set. */
  creditLimit: string | null;
  isActive: boolean;
  createdAt: Date;
  updatedAt: Date;
}

interface CustomerRow {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  address: string | null;
  credit_limit: string | null;
  is_active: boolean;
  created_at: Date;
  updated_at: Date;
}

const CUSTOMER_COLUMNS =
  'id, code, name, phone, address, credit_limit, is_active, created_at, updated_at';

const toCustomer = (row: CustomerRow): Customer => ({
  id: row.id,
  code: row.code,
  name: row.name,
  phone: row.phone,
  address: row.address,
  creditLimit: row.credit_limit,
  isActive: row.is_active,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

const customerNotFound = () => new AppError(404, 'CUSTOMER_NOT_FOUND', 'No customer has that id.');

function codeTaken(error: unknown, code: string | undefined): AppError | null {
  if (!isUniqueViolation(error, 'customers_code_key')) return null;
  return new AppError(
    409,
    'CUSTOMER_CODE_TAKEN',
    `Another customer already uses the code "${code}".`,
    [{ field: 'code', message: 'Already used by another customer' }],
  );
}

export interface CustomerSearch {
  /** Matches part of the code, name or phone number, ignoring case. */
  q?: string | undefined;
  includeInactive: boolean;
  limit: number;
  offset: number;
}

export async function listCustomers(
  db: Queryable,
  search: CustomerSearch,
): Promise<{ customers: Customer[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  if (!search.includeInactive) conditions.push('is_active');
  if (search.q) {
    params.push(`%${escapeLike(search.q)}%`);
    conditions.push('(code ILIKE $1 OR name ILIKE $1 OR phone ILIKE $1)');
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows: countRows } = await db.query<{ total: number }>(
    `SELECT count(*)::int AS total FROM customers ${where}`,
    params,
  );
  const { rows } = await db.query<CustomerRow>(
    `SELECT ${CUSTOMER_COLUMNS} FROM customers ${where}
     ORDER BY lower(name), code
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, search.limit, search.offset],
  );
  return { customers: rows.map(toCustomer), total: countRows[0]?.total ?? 0 };
}

export async function getCustomer(db: Queryable, id: string): Promise<Customer> {
  const { rows } = await db.query<CustomerRow>(
    `SELECT ${CUSTOMER_COLUMNS} FROM customers WHERE id = $1`,
    [id],
  );
  if (!rows[0]) throw customerNotFound();
  return toCustomer(rows[0]);
}

/** The next free code C0001, C0002, ... skipping any that staff have already used. */
async function nextCustomerCode(client: pg.PoolClient): Promise<string> {
  for (let attempt = 0; attempt < 100; attempt++) {
    const { rows } = await client.query<{ code: string; taken: boolean }>(
      `WITH next AS (SELECT 'C' || lpad(nextval('customer_code_seq')::text, 4, '0') AS code)
       SELECT code, EXISTS (SELECT 1 FROM customers c WHERE c.code = next.code) AS taken FROM next`,
    );
    const row = rows[0] as { code: string; taken: boolean };
    if (!row.taken) return row.code;
  }
  throw new Error('Could not find a free customer code');
}

export interface NewCustomerInput {
  /** Leave out to have the next code generated. */
  code?: string | undefined;
  name: string;
  phone: string | null;
  address: string | null;
  creditLimit: string | null;
}

export async function createCustomer(
  pool: pg.Pool,
  input: NewCustomerInput,
  actorUserId: string,
): Promise<Customer> {
  try {
    return await withTransaction(pool, async (client) => {
      const code = input.code ?? (await nextCustomerCode(client));
      const { rows } = await client.query<CustomerRow>(
        `INSERT INTO customers (code, name, phone, address, credit_limit)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING ${CUSTOMER_COLUMNS}`,
        [code, input.name, input.phone, input.address, input.creditLimit],
      );
      const customer = toCustomer(rows[0] as CustomerRow);
      await recordAudit(client, {
        actorUserId,
        action: 'customer.created',
        entityType: 'customer',
        entityId: customer.id,
        details: { code: customer.code, name: customer.name, creditLimit: customer.creditLimit },
      });
      return customer;
    });
  } catch (error) {
    throw codeTaken(error, input.code) ?? error;
  }
}

export interface CustomerChanges {
  code?: string | undefined;
  name?: string | undefined;
  phone?: string | null | undefined;
  address?: string | null | undefined;
  creditLimit?: string | null | undefined;
  isActive?: boolean | undefined;
}

export async function updateCustomer(
  pool: pg.Pool,
  id: string,
  changes: CustomerChanges,
  actorUserId: string,
): Promise<Customer> {
  // undefined = leave as it is; null = clear it.
  const pick = <T>(change: T | undefined, current: T) => (change === undefined ? current : change);
  try {
    return await withTransaction(pool, async (client) => {
      const { rows } = await client.query<CustomerRow>(
        `SELECT ${CUSTOMER_COLUMNS} FROM customers WHERE id = $1 FOR UPDATE`,
        [id],
      );
      if (!rows[0]) throw customerNotFound();
      const before = toCustomer(rows[0]);

      const { rows: updated } = await client.query<CustomerRow>(
        `UPDATE customers
         SET code = $2, name = $3, phone = $4, address = $5, credit_limit = $6, is_active = $7
         WHERE id = $1
         RETURNING ${CUSTOMER_COLUMNS}`,
        [
          id,
          pick(changes.code, before.code),
          pick(changes.name, before.name),
          pick(changes.phone, before.phone),
          pick(changes.address, before.address),
          pick(changes.creditLimit, before.creditLimit),
          pick(changes.isActive, before.isActive),
        ],
      );
      const after = toCustomer(updated[0] as CustomerRow);

      const editable = (c: Customer) => ({
        code: c.code,
        name: c.name,
        phone: c.phone,
        address: c.address,
        creditLimit: c.creditLimit,
        isActive: c.isActive,
      });
      await recordAudit(client, {
        actorUserId,
        action: 'customer.updated',
        entityType: 'customer',
        entityId: id,
        details: { changes: changedFields(editable(before), editable(after)) },
      });
      return after;
    });
  } catch (error) {
    throw codeTaken(error, changes.code) ?? error;
  }
}
