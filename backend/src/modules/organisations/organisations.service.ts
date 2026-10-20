import type pg from 'pg';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { changedFields, recordAudit } from '../audit/audit.js';
import type { OrganisationType } from '../auth/permissions.js';
import type { PublicUser } from '../auth/roles.js';
import { insertCustomer } from '../customers/customers.service.js';
import { canAccessOrganisation, organisationNotFound, type AccessScope } from './access.js';

/** The Head Office or a subsidiary, with its contact and billing details. */
export interface Organisation {
  id: string;
  code: string;
  name: string;
  type: OrganisationType;
  isActive: boolean;
  contactName: string | null;
  contactPhone: string | null;
  contactEmail: string | null;
  address: string | null;
  billingName: string | null;
  billingAddress: string | null;
  taxNumber: string | null;
  /** The customer record dispatches and invoices use for this subsidiary (decision D1). */
  customerId: string | null;
  createdAt: Date;
  updatedAt: Date;
}

interface OrganisationRow {
  id: string;
  code: string;
  name: string;
  organisation_type: OrganisationType;
  is_active: boolean;
  contact_name: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  address: string | null;
  billing_name: string | null;
  billing_address: string | null;
  tax_number: string | null;
  customer_id: string | null;
  created_at: Date;
  updated_at: Date;
}

const ORGANISATION_SELECT = `
  SELECT o.id, o.code, o.name, o.organisation_type, o.is_active, o.contact_name, o.contact_phone,
         o.contact_email, o.address, o.billing_name, o.billing_address, o.tax_number,
         c.id AS customer_id, o.created_at, o.updated_at
  FROM organisations o
  LEFT JOIN customers c ON c.organisation_id = o.id`;

const toOrganisation = (row: OrganisationRow): Organisation => ({
  id: row.id,
  code: row.code,
  name: row.name,
  type: row.organisation_type,
  isActive: row.is_active,
  contactName: row.contact_name,
  contactPhone: row.contact_phone,
  contactEmail: row.contact_email,
  address: row.address,
  billingName: row.billing_name,
  billingAddress: row.billing_address,
  taxNumber: row.tax_number,
  customerId: row.customer_id,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

/** The details that can be set and changed. Null clears a detail. */
export interface OrganisationDetails {
  name: string;
  contactName: string | null;
  contactPhone: string | null;
  contactEmail: string | null;
  address: string | null;
  billingName: string | null;
  billingAddress: string | null;
  taxNumber: string | null;
}

const DETAIL_COLUMNS: Record<keyof OrganisationDetails, string> = {
  name: 'name',
  contactName: 'contact_name',
  contactPhone: 'contact_phone',
  contactEmail: 'contact_email',
  address: 'address',
  billingName: 'billing_name',
  billingAddress: 'billing_address',
  taxNumber: 'tax_number',
};

function fieldError(field: string, message: string, status = 400, code = 'VALIDATION_ERROR') {
  return new AppError(status, code, 'Some fields are missing or invalid.', [{ field, message }]);
}

const codeTaken = (code: string) =>
  new AppError(409, 'ORGANISATION_CODE_TAKEN', `The code "${code}" is already used.`, [
    { field: 'code', message: 'Already used by another organisation' },
  ]);

/** Organisations the user may see: all for the Head Office, otherwise only their own. */
export async function listOrganisations(
  db: Queryable,
  scope: AccessScope,
  filter: { includeInactive: boolean },
): Promise<Organisation[]> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  if (!scope.allOrganisations) {
    params.push(scope.organisationId);
    conditions.push(`o.id = $${params.length}`);
  }
  if (!filter.includeInactive) conditions.push('o.is_active');
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const { rows } = await db.query<OrganisationRow>(
    `${ORGANISATION_SELECT} ${where} ORDER BY o.organisation_type, o.name`,
    params,
  );
  return rows.map(toOrganisation);
}

/** One organisation, or 404 when it does not exist or the user may not see it. */
export async function getOrganisation(
  db: Queryable,
  scope: AccessScope,
  id: string,
): Promise<Organisation> {
  if (!canAccessOrganisation(scope, id)) throw organisationNotFound();
  const { rows } = await db.query<OrganisationRow>(`${ORGANISATION_SELECT} WHERE o.id = $1`, [id]);
  if (!rows[0]) throw organisationNotFound();
  return toOrganisation(rows[0]);
}

export interface NewSubsidiaryInput extends OrganisationDetails {
  code: string;
  /** Link an existing customer record instead of creating one (decision D1). */
  existingCustomerId: string | null;
}

/**
 * Adds a subsidiary (there is only ever one Head Office) together with the customer record that
 * today's dispatch and invoice screens use for it, in one transaction.
 */
export async function createSubsidiary(
  pool: pg.Pool,
  input: NewSubsidiaryInput,
  actor: PublicUser,
): Promise<Organisation> {
  try {
    const id = await withTransaction(pool, async (client) => {
      const { rows } = await client.query<{ id: string }>(
        `INSERT INTO organisations (code, name, organisation_type, contact_name, contact_phone,
                                    contact_email, address, billing_name, billing_address,
                                    tax_number)
         VALUES ($1, $2, 'SUBSIDIARY', $3, $4, $5, $6, $7, $8, $9)
         RETURNING id`,
        [
          input.code,
          input.name,
          input.contactName,
          input.contactPhone,
          input.contactEmail,
          input.address,
          input.billingName,
          input.billingAddress,
          input.taxNumber,
        ],
      );
      const organisationId = (rows[0] as { id: string }).id;

      let customer: { id: string; code: string };
      if (input.existingCustomerId) {
        const { rows: linked } = await client.query<{ id: string; code: string }>(
          `UPDATE customers SET organisation_id = $2
           WHERE id = $1 AND organisation_id IS NULL
           RETURNING id, code`,
          [input.existingCustomerId, organisationId],
        );
        if (!linked[0]) {
          throw fieldError(
            'existingCustomerId',
            'No customer with that id is free to link (it may already belong to a subsidiary)',
          );
        }
        customer = linked[0];
      } else {
        // The subsidiary's code is used as the customer code when it is free.
        const { rowCount } = await client.query('SELECT 1 FROM customers WHERE code = $1', [
          input.code,
        ]);
        customer = await insertCustomer(
          client,
          {
            code: rowCount ? undefined : input.code,
            name: input.name,
            phone: input.contactPhone,
            address: input.address,
            creditLimit: null,
            organisationId,
          },
          actor.id,
        );
      }

      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'organisation.created',
        entityType: 'organisation',
        entityId: organisationId,
        details: { code: input.code, name: input.name, customerCode: customer.code },
      });
      return organisationId;
    });
    return await getOrganisation(pool, { allOrganisations: true, organisationId: id }, id);
  } catch (error) {
    if (isUniqueViolation(error, 'organisations_code_key')) throw codeTaken(input.code);
    throw error;
  }
}

export type OrganisationChanges = Partial<OrganisationDetails> & {
  code?: string;
  isActive?: boolean;
};

/**
 * Changes an organisation's details. Deactivating a subsidiary signs its staff out and stops
 * them signing in, and deactivates its customer record; the Head Office cannot be deactivated.
 * The linked customer record keeps the subsidiary's name.
 */
export async function updateOrganisation(
  pool: pg.Pool,
  id: string,
  changes: OrganisationChanges,
  actor: PublicUser,
): Promise<Organisation> {
  try {
    await withTransaction(pool, async (client) => {
      const { rows } = await client.query<OrganisationRow>(
        `${ORGANISATION_SELECT} WHERE o.id = $1 FOR UPDATE OF o`,
        [id],
      );
      const row = rows[0];
      if (!row) throw organisationNotFound();
      const before = toOrganisation(row);
      if (before.type === 'HQ' && changes.isActive === false) {
        throw fieldError(
          'isActive',
          'The Head Office cannot be deactivated',
          409,
          'HEAD_OFFICE_ALWAYS_ACTIVE',
        );
      }

      const assignments: string[] = [];
      const params: unknown[] = [id];
      const set = (column: string, value: unknown) => {
        params.push(value);
        assignments.push(`${column} = $${params.length}`);
      };
      for (const [field, column] of Object.entries(DETAIL_COLUMNS)) {
        const value = changes[field as keyof OrganisationDetails];
        if (value !== undefined) set(column, value);
      }
      if (changes.code !== undefined) set('code', changes.code);
      if (changes.isActive !== undefined) set('is_active', changes.isActive);
      if (assignments.length > 0) {
        await client.query(
          `UPDATE organisations SET ${assignments.join(', ')} WHERE id = $1`,
          params,
        );
      }

      if (before.customerId && (changes.name !== undefined || changes.isActive !== undefined)) {
        await client.query(`UPDATE customers SET name = $2, is_active = $3 WHERE id = $1`, [
          before.customerId,
          changes.name ?? before.name,
          changes.isActive ?? before.isActive,
        ]);
      }
      if (before.isActive && changes.isActive === false) {
        await client.query(
          `UPDATE sessions SET revoked_at = now()
           WHERE revoked_at IS NULL
             AND user_id IN (SELECT id FROM users WHERE organisation_id = $1)`,
          [id],
        );
      }

      const beforeFields: Record<string, unknown> = {
        code: before.code,
        isActive: before.isActive,
        ...Object.fromEntries(
          Object.keys(DETAIL_COLUMNS).map((field) => [
            field,
            before[field as keyof OrganisationDetails],
          ]),
        ),
      };
      const afterFields = { ...beforeFields };
      for (const key of Object.keys(changes) as (keyof OrganisationChanges)[]) {
        if (changes[key] !== undefined) {
          (afterFields as Record<string, unknown>)[key] = changes[key];
        }
      }
      const fieldChanges = changedFields(
        beforeFields as Record<string, unknown>,
        afterFields as Record<string, unknown>,
      );
      if (Object.keys(fieldChanges).length > 0) {
        await recordAudit(client, {
          actorUserId: actor.id,
          action: 'organisation.updated',
          entityType: 'organisation',
          entityId: id,
          organisationId: id,
          details: { changes: fieldChanges },
        });
      }
    });
  } catch (error) {
    if (isUniqueViolation(error, 'organisations_code_key') && changes.code) {
      throw codeTaken(changes.code);
    }
    throw error;
  }
  return getOrganisation(pool, { allOrganisations: true, organisationId: id }, id);
}
