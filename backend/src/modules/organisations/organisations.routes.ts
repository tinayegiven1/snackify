import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { can, getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { moneySchema, optionalText } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { organisationNotFound, scopeOf } from './access.js';
import {
  createSubsidiary,
  getOrganisation,
  listOrganisations,
  updateOrganisation,
} from './organisations.service.js';

const codeSchema = z
  .string({ error: 'Required' })
  .trim()
  .toUpperCase()
  .regex(/^[A-Z0-9][A-Z0-9_-]{1,19}$/, 'Use 2–20 letters, digits, dashes or underscores');

const nameSchema = z
  .string({ error: 'Required' })
  .trim()
  .min(1, 'Required')
  .max(120, 'Use at most 120 characters');

const phoneSchema = optionalText(30).refine(
  (value) => value === null || /^\+?[0-9][0-9 ()-]{5,22}$/.test(value),
  'Use digits, spaces, brackets or dashes, e.g. +263 77 123 4567',
);

const emailSchema = optionalText(254).refine(
  (value) => value === null || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value),
  'Use an email address like orders@example.co.zw',
);

const details = {
  contactName: optionalText(120),
  contactPhone: phoneSchema,
  contactEmail: emailSchema,
  address: optionalText(300),
  billingName: optionalText(120),
  billingAddress: optionalText(300),
  taxNumber: optionalText(40),
};

/** Most a subsidiary may owe at once, in the base currency; null for "no limit". */
const creditLimitSchema = moneySchema.nullable();

const createSchema = z.object({
  code: codeSchema,
  name: nameSchema,
  ...details,
  creditLimit: creditLimitSchema.optional().transform((value) => value ?? null),
});

const updateSchema = z
  .strictObject(
    {
      code: codeSchema.optional(),
      name: nameSchema.optional(),
      contactName: details.contactName.optional(),
      contactPhone: details.contactPhone.optional(),
      contactEmail: details.contactEmail.optional(),
      address: details.address.optional(),
      billingName: details.billingName.optional(),
      billingAddress: details.billingAddress.optional(),
      taxNumber: details.taxNumber.optional(),
      creditLimit: creditLimitSchema.optional(),
      isActive: z.boolean({ error: 'Must be true or false' }).optional(),
    },
    { error: 'This field cannot be changed' },
  )
  .refine((changes) => Object.keys(changes).length > 0, 'Send at least one field to change');

const listQuerySchema = z.object({
  includeInactive: z
    .enum(['true', 'false'], { error: 'Must be true or false' })
    .optional()
    .transform((value) => value === 'true'),
  type: z.enum(['HQ', 'SUBSIDIARY'], { error: 'Must be HQ or SUBSIDIARY' }).optional(),
});

function idParam(id: unknown): string {
  if (!z.uuid().safeParse(id).success) throw organisationNotFound();
  return id as string;
}

/**
 * The credit limit is finance's (organisation.edit_credit_limit); every other detail needs
 * organisation.manage. Someone with one of the two may change just those fields.
 */
function checkFieldPermissions(user: Parameters<typeof can>[0], fields: string[]): void {
  for (const field of fields) {
    const permission =
      field === 'creditLimit' ? 'organisation.edit_credit_limit' : 'organisation.manage';
    if (!can(user, permission)) {
      throw new AppError(
        403,
        'FORBIDDEN',
        field === 'creditLimit'
          ? 'Your role does not allow changing credit limits.'
          : "Your role does not allow changing organisations' details.",
        [{ field, message: 'Your role cannot change this' }],
      );
    }
  }
}

/**
 * The Head Office and its subsidiaries; the subsidiaries are the customers that dispatches,
 * invoices and payments are for. Everyone signed in sees the organisations they may access
 * (Head Office staff: all; a subsidiary's staff: their own). Adding them needs
 * organisation.manage; changing them, see checkFieldPermissions.
 */
export function organisationsRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db));

  router.get('/', async (req, res) => {
    const filter = parseBody(listQuerySchema, req.query);
    res.json({
      organisations: await listOrganisations(db, scopeOf(getAuth(res).user), filter),
    });
  });

  router.get('/:id', async (req, res) => {
    const id = idParam(req.params.id);
    res.json({ organisation: await getOrganisation(db, scopeOf(getAuth(res).user), id) });
  });

  router.post('/', requirePermission('organisation.manage'), async (req, res) => {
    const input = parseBody(createSchema, req.body);
    const { user } = getAuth(res);
    if (input.creditLimit !== null) checkFieldPermissions(user, ['creditLimit']);
    const organisation = await createSubsidiary(db, input, user);
    res.status(201).json({ organisation });
  });

  router.patch(
    '/:id',
    requirePermission('organisation.manage', 'organisation.edit_credit_limit'),
    async (req, res) => {
      const id = idParam(req.params.id);
      const { user } = getAuth(res);
      const changes = parseBody(updateSchema, req.body);
      checkFieldPermissions(
        user,
        Object.keys(changes).filter((key) => changes[key as keyof typeof changes] !== undefined),
      );
      await getOrganisation(db, scopeOf(user), id);
      res.json({ organisation: await updateOrganisation(db, id, changes, user) });
    },
  );

  return router;
}
