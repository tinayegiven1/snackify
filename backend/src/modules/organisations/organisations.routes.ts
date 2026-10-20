import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { optionalText } from '../../utils/schemas.js';
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

const createSchema = z.object({
  code: codeSchema,
  name: nameSchema,
  ...details,
  existingCustomerId: z
    .uuid({ error: 'Must be a customer id' })
    .nullish()
    .transform((value) => value ?? null),
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
});

function idParam(id: unknown): string {
  if (!z.uuid().safeParse(id).success) throw organisationNotFound();
  return id as string;
}

/**
 * The Head Office and its subsidiaries. Everyone signed in sees the organisations they may
 * access (Head Office staff: all; a subsidiary's staff: their own). Adding and changing them
 * needs organisation.manage.
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
    const organisation = await createSubsidiary(db, input, getAuth(res).user);
    res.status(201).json({ organisation });
  });

  router.patch('/:id', requirePermission('organisation.manage'), async (req, res) => {
    const id = idParam(req.params.id);
    const { user } = getAuth(res);
    await getOrganisation(db, scopeOf(user), id);
    const changes = parseBody(updateSchema, req.body);
    res.json({ organisation: await updateOrganisation(db, id, changes, user) });
  });

  return router;
}
