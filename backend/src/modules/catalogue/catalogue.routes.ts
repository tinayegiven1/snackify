import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { isUniqueViolation, withTransaction } from '../../database/transaction.js';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { optionalText, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { recordAudit } from '../audit/audit.js';
import type { Permission } from '../auth/permissions.js';

// StockFlow Stage 4.1: product categories, units, suppliers and warehouses. Everyone signed in
// may read them (they appear on products and receipts); changing them needs a permission.

const codeSchema = z
  .string({ error: 'Required' })
  .trim()
  .toUpperCase()
  .regex(/^[A-Z0-9][A-Z0-9_-]{1,19}$/, 'Use 2–20 letters, digits, dashes or underscores');

const name = (max: number) =>
  z
    .string({ error: 'Required' })
    .trim()
    .min(1, 'Required')
    .max(max, `Use at most ${max} characters`);

const phoneSchema = optionalText(30).refine(
  (value) => value === null || /^\+?[0-9][0-9 ()-]{5,22}$/.test(value),
  'Use digits, spaces, brackets or dashes, e.g. +263 77 123 4567',
);
const emailSchema = optionalText(254).refine(
  (value) => value === null || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value),
  'Use an email address like sales@example.co.zw',
);
const isActiveSchema = z.boolean({ error: 'Must be true or false' });
const flag = z
  .enum(['true', 'false'], { error: 'Must be true or false' })
  .optional()
  .transform((value) => value === 'true');

/** A catalogue table, described once: its columns, how they appear in the API, and its rules. */
interface CatalogueTable {
  table: string;
  entity: string;
  /** API field -> column, with its schema. */
  fields: Record<string, { column: string; schema: z.ZodType; required?: boolean }>;
  orderBy: string;
  manage: Permission;
  /** Unique constraints, mapped to the field that is reported. */
  unique: Record<string, string>;
  extraSelect?: string;
  /** Stops a change that would break a rule the table relies on. */
  check?: (
    client: pg.PoolClient,
    id: string | null,
    values: Record<string, unknown>,
  ) => Promise<void>;
}

const TABLES: Record<string, CatalogueTable> = {
  categories: {
    table: 'product_categories',
    entity: 'category',
    fields: { name: { column: 'name', schema: name(60), required: true } },
    orderBy: 'name',
    manage: 'catalogue.manage',
    unique: { product_categories_name_key: 'name' },
  },
  units: {
    table: 'units',
    entity: 'unit',
    fields: {
      code: {
        column: 'code',
        schema: z
          .string({ error: 'Required' })
          .trim()
          .toLowerCase()
          .regex(
            /^[a-z][a-z0-9_]{0,19}$/,
            'Use up to 20 lower-case letters, digits or underscores',
          ),
        required: true,
      },
      name: { column: 'name', schema: name(40), required: true },
    },
    orderBy: 'name',
    manage: 'catalogue.manage',
    unique: { units_code_key: 'code' },
  },
  suppliers: {
    table: 'suppliers',
    entity: 'supplier',
    fields: {
      code: { column: 'code', schema: codeSchema, required: true },
      name: { column: 'name', schema: name(120), required: true },
      contactName: { column: 'contact_name', schema: optionalText(120) },
      phone: { column: 'phone', schema: phoneSchema },
      email: { column: 'email', schema: emailSchema },
      address: { column: 'address', schema: optionalText(300) },
    },
    orderBy: 'name',
    manage: 'supplier.manage',
    unique: { suppliers_code_key: 'code' },
  },
  warehouses: {
    table: 'warehouses',
    entity: 'warehouse',
    fields: {
      code: { column: 'code', schema: codeSchema, required: true },
      name: { column: 'name', schema: name(120), required: true },
      address: { column: 'address', schema: optionalText(300) },
    },
    orderBy: 'is_default DESC, name',
    manage: 'catalogue.manage',
    unique: { warehouses_code_key: 'code' },
    extraSelect: ', is_default, organisation_id',
    // The default warehouse (where today's screens keep stock) is always active.
    check: async (client, id, values) => {
      if (id === null || values.is_active !== false) return;
      const { rows } = await client.query<{ is_default: boolean }>(
        'SELECT is_default FROM warehouses WHERE id = $1',
        [id],
      );
      if (rows[0]?.is_default) {
        throw new AppError(409, 'DEFAULT_WAREHOUSE_ACTIVE', 'The default warehouse stays active.', [
          { field: 'isActive', message: 'The default warehouse stays active' },
        ]);
      }
    },
  },
};

const camel = (column: string) => column.replace(/_([a-z])/g, (_m, c: string) => c.toUpperCase());

function toApi(row: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [camel(key), value]));
}

function catalogueRouter(db: pg.Pool, spec: CatalogueTable): Router {
  const router = Router();
  router.use(requireAuth(db));
  const columns = [
    'id',
    ...Object.values(spec.fields).map((field) => field.column),
    'is_active',
  ].join(', ');
  const notFound = () => new AppError(404, 'NOT_FOUND', `No ${spec.entity} has that id.`);

  const createSchema = z.object(
    Object.fromEntries(
      Object.entries(spec.fields).map(([key, field]) => [
        key,
        field.required ? field.schema : field.schema.optional(),
      ]),
    ),
  );
  const updateSchema = z
    .strictObject(
      {
        ...Object.fromEntries(
          Object.entries(spec.fields).map(([key, field]) => [key, field.schema.optional()]),
        ),
        isActive: isActiveSchema.optional(),
      },
      { error: 'This field cannot be changed' },
    )
    .refine((changes) => Object.keys(changes).length > 0, 'Send at least one field to change');

  const uniqueError = (error: unknown) => {
    for (const [constraint, field] of Object.entries(spec.unique)) {
      if (isUniqueViolation(error, constraint)) {
        return new AppError(409, 'ALREADY_EXISTS', `Another ${spec.entity} already uses that.`, [
          { field, message: `Already used by another ${spec.entity}` },
        ]);
      }
    }
    return null;
  };

  router.get('/', async (req, res) => {
    const { includeInactive } = parseBody(z.object({ includeInactive: flag }), req.query);
    const { rows } = await db.query(
      `SELECT ${columns}${spec.extraSelect ?? ''} FROM ${spec.table}
       ${includeInactive ? '' : 'WHERE is_active'}
       ORDER BY ${spec.orderBy}`,
    );
    res.json({ items: rows.map(toApi) });
  });

  router.post('/', requirePermission(spec.manage), async (req, res) => {
    const input = parseBody(createSchema, req.body) as Record<string, unknown>;
    const values: Record<string, unknown> = {};
    for (const [key, field] of Object.entries(spec.fields))
      values[field.column] = input[key] ?? null;
    if (spec.table === 'warehouses') values.organisation_id = getAuth(res).user.organisation.id;
    try {
      const row = await withTransaction(db, async (client) => {
        await spec.check?.(client, null, values);
        const keys = Object.keys(values);
        const { rows } = await client.query(
          `INSERT INTO ${spec.table} (${keys.join(', ')})
           VALUES (${keys.map((_k, i) => `$${i + 1}`).join(', ')})
           RETURNING ${columns}${spec.extraSelect ?? ''}`,
          Object.values(values),
        );
        const created = rows[0] as Record<string, unknown>;
        await recordAudit(client, {
          actorUserId: getAuth(res).user.id,
          action: 'catalogue.created',
          entityType: 'catalogue',
          entityId: created.id as string,
          details: { kind: spec.entity, ...toApi(values) },
        });
        return created;
      });
      res.status(201).json({ item: toApi(row) });
    } catch (error) {
      throw uniqueError(error) ?? error;
    }
  });

  router.patch('/:id', requirePermission(spec.manage), async (req, res) => {
    const id = parseIdParam(req.params.id, notFound);
    const changes = parseBody(updateSchema, req.body) as Record<string, unknown>;
    const values: Record<string, unknown> = {};
    for (const [key, field] of Object.entries(spec.fields)) {
      if (changes[key] !== undefined) values[field.column] = changes[key];
    }
    if (changes.isActive !== undefined) values.is_active = changes.isActive;
    try {
      const row = await withTransaction(db, async (client) => {
        await spec.check?.(client, id, values);
        const keys = Object.keys(values);
        const { rows } = await client.query(
          `UPDATE ${spec.table} SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')}
           WHERE id = $1
           RETURNING ${columns}${spec.extraSelect ?? ''}`,
          [id, ...Object.values(values)],
        );
        if (!rows[0]) throw notFound();
        await recordAudit(client, {
          actorUserId: getAuth(res).user.id,
          action: 'catalogue.updated',
          entityType: 'catalogue',
          entityId: id,
          details: { kind: spec.entity, ...toApi(values) },
        });
        return rows[0] as Record<string, unknown>;
      });
      res.json({ item: toApi(row) });
    } catch (error) {
      throw uniqueError(error) ?? error;
    }
  });

  return router;
}

/** Mounts /categories, /units, /suppliers and /warehouses. */
export function catalogueRouters(db: pg.Pool): Record<string, Router> {
  return Object.fromEntries(
    Object.entries(TABLES).map(([path, spec]) => [path, catalogueRouter(db, spec)]),
  );
}
