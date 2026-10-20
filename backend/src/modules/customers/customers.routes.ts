import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { can, getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import type { Permission } from '../auth/permissions.js';
import type { PublicUser } from '../auth/roles.js';
import { moneySchema, optionalText, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import {
  getCustomer,
  listCustomers,
  updateCustomer,
  type CustomerChanges,
} from './customers.service.js';

const codeSchema = z
  .string({ error: 'Must be text' })
  .trim()
  .toUpperCase()
  .regex(
    /^[A-Z0-9][A-Z0-9._-]{0,19}$/,
    'Use up to 20 letters, digits, dots, dashes or underscores, e.g. C0001',
  );

const nameSchema = z
  .string({ error: 'Required' })
  .trim()
  .min(1, 'Required')
  .max(120, 'Use at most 120 characters');

const phoneSchema = optionalText(30).refine(
  (value) => value === null || /^\+?[0-9][0-9 ()-]{5,22}$/.test(value),
  'Use digits, spaces, brackets or dashes, e.g. +263 77 123 4567',
);

const addressSchema = optionalText(300);

/** A credit limit in the base currency, or null for "no limit set". */
const creditLimitSchema = moneySchema.nullable();

const updateCustomerSchema = z
  .strictObject(
    {
      code: codeSchema.optional(),
      name: nameSchema.optional(),
      phone: phoneSchema.optional(),
      address: addressSchema.optional(),
      creditLimit: creditLimitSchema.optional(),
      isActive: z.boolean({ error: 'Must be true or false' }).optional(),
    },
    { error: 'This field cannot be changed' },
  )
  .refine((changes) => Object.keys(changes).length > 0, 'Send at least one field to change');

const listQuerySchema = z.object({
  q: z.string().trim().max(100, 'Use at most 100 characters').optional(),
  includeInactive: z
    .enum(['true', 'false'], { error: 'Must be true or false' })
    .optional()
    .transform((value) => value === 'true'),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

const customerNotFound = () => new AppError(404, 'CUSTOMER_NOT_FOUND', 'No customer has that id.');

/** Which permission changes which customer field (sales staff manage the details). */
const FIELD_PERMISSIONS: Record<keyof CustomerChanges, { permission: Permission; label: string }> =
  {
    code: { permission: 'customer.edit_details', label: 'customer details' },
    name: { permission: 'customer.edit_details', label: 'customer details' },
    phone: { permission: 'customer.edit_details', label: 'customer details' },
    address: { permission: 'customer.edit_details', label: 'customer details' },
    creditLimit: { permission: 'customer.edit_credit_limit', label: 'credit limits' },
    isActive: { permission: 'customer.change_active', label: 'whether a customer is active' },
  };

function checkFieldPermissions(user: PublicUser, changes: CustomerChanges): void {
  for (const field of Object.keys(changes) as (keyof CustomerChanges)[]) {
    if (changes[field] === undefined) continue;
    const rule = FIELD_PERMISSIONS[field];
    if (!can(user, rule.permission)) {
      throw new AppError(403, 'FORBIDDEN', `Your role does not allow changing ${rule.label}.`, [
        { field, message: 'Your role cannot change this' },
      ]);
    }
  }
}

/**
 * Customers (spec 6.5): the Head Office's buyers, seen by Head Office staff only. Since
 * StockFlow Stage 3 (decision D1) the buyers are the subsidiaries: a customer record is created
 * with each subsidiary under Organisations, never on its own. Customers are never deleted.
 */
export function customersRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db), requirePermission('customer.view'));

  router.get('/', async (req, res) => {
    const search = parseBody(listQuerySchema, req.query);
    res.json(await listCustomers(db, search));
  });

  router.get('/:id', async (req, res) => {
    const id = parseIdParam(req.params.id, customerNotFound);
    res.json({ customer: await getCustomer(db, id) });
  });

  router.post('/', () => {
    throw new AppError(
      409,
      'ADD_AS_SUBSIDIARY',
      'Customers are now the subsidiaries: add a new buyer under Organisations.',
    );
  });

  router.patch(
    '/:id',
    requirePermission(
      'customer.edit_details',
      'customer.edit_credit_limit',
      'customer.change_active',
    ),
    async (req, res) => {
      const id = parseIdParam(req.params.id, customerNotFound);
      const changes = parseBody(updateCustomerSchema, req.body);
      const { user } = getAuth(res);
      checkFieldPermissions(user, changes);

      const customer = await updateCustomer(db, id, changes, user.id);
      res.json({ customer });
    },
  );

  return router;
}
