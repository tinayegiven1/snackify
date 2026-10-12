import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requireRole } from '../../middleware/authenticate.js';
import type { Role } from '../auth/roles.js';
import { AppError } from '../../utils/app-error.js';
import { moneySchema, optionalText, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import {
  createCustomer,
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

const createCustomerSchema = z.object({
  // Empty or missing: the next code (C0001, C0002, ...) is generated.
  code: z.preprocess(
    (value) => (typeof value === 'string' && value.trim() === '' ? undefined : value),
    codeSchema.optional(),
  ),
  name: nameSchema,
  phone: phoneSchema,
  address: addressSchema,
  creditLimit: creditLimitSchema.optional().transform((value) => value ?? null),
});

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

/**
 * Who may change which customer fields (spec section 5: salespeople manage "permitted"
 * customer information). Admins may change everything.
 */
const FIELD_ROLES: Record<keyof CustomerChanges, { roles: Role[]; label: string }> = {
  code: { roles: ['salesperson'], label: 'customer details' },
  name: { roles: ['salesperson'], label: 'customer details' },
  phone: { roles: ['salesperson'], label: 'customer details' },
  address: { roles: ['salesperson'], label: 'customer details' },
  creditLimit: { roles: ['accounts'], label: 'credit limits' },
  isActive: { roles: [], label: 'whether a customer is active' },
};

function checkFieldPermissions(role: Role, changes: CustomerChanges): void {
  if (role === 'admin') return;
  for (const field of Object.keys(changes) as (keyof CustomerChanges)[]) {
    if (changes[field] === undefined) continue;
    const rule = FIELD_ROLES[field];
    if (!rule.roles.includes(role)) {
      throw new AppError(403, 'FORBIDDEN', `Your role does not allow changing ${rule.label}.`, [
        { field, message: 'Your role cannot change this' },
      ]);
    }
  }
}

/**
 * Customers (spec 6.5). Everyone signed in can view them. Salespeople and admins add
 * customers and edit their details; accounts staff and admins set credit limits;
 * only admins deactivate customers. Customers are never deleted.
 */
export function customersRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db));

  router.get('/', async (req, res) => {
    const search = parseBody(listQuerySchema, req.query);
    res.json(await listCustomers(db, search));
  });

  router.get('/:id', async (req, res) => {
    const id = parseIdParam(req.params.id, customerNotFound);
    res.json({ customer: await getCustomer(db, id) });
  });

  router.post('/', requireRole('salesperson'), async (req, res) => {
    const input = parseBody(createCustomerSchema, req.body);
    const { user } = getAuth(res);
    if (input.creditLimit !== null)
      checkFieldPermissions(user.role, { creditLimit: input.creditLimit });

    const customer = await createCustomer(db, input, user.id);
    res.status(201).json({ customer });
  });

  router.patch('/:id', requireRole('salesperson', 'accounts'), async (req, res) => {
    const id = parseIdParam(req.params.id, customerNotFound);
    const changes = parseBody(updateCustomerSchema, req.body);
    const { user } = getAuth(res);
    checkFieldPermissions(user.role, changes);

    const customer = await updateCustomer(db, id, changes, user.id);
    res.json({ customer });
  });

  return router;
}
