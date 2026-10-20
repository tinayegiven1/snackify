import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { businessToday } from '../../utils/dates.js';
import { moneySchema, optionalText, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import {
  cancelDraft,
  confirmDispatch,
  createDraft,
  getDispatch,
  listDispatches,
  reverseDispatch,
  updateDraft,
} from './dispatches.service.js';

const MAX_LINES = 100;
const MAX_QUANTITY = 1_000_000;

const dateSchema = z.iso.date({ error: 'Use a date like 2026-10-12' });

const lineSchema = z.object({
  productId: z.uuid({ error: 'Must be a product id' }),
  quantity: z
    .number({ error: 'Must be a whole number of packs' })
    .int('Must be a whole number of packs')
    .min(1, 'Must be at least 1')
    .max(MAX_QUANTITY, `Must be at most ${MAX_QUANTITY.toLocaleString('en')}`),
  // Left out = the product's current default price.
  unitPrice: moneySchema.optional(),
});

const draftSchema = z.object({
  customerId: z.uuid({ error: 'Choose a customer' }),
  dispatchDate: dateSchema.optional(),
  notes: optionalText(500),
  items: z
    .array(lineSchema, { error: 'Add at least one product' })
    .min(1, 'Add at least one product')
    .max(MAX_LINES, `Use at most ${MAX_LINES} lines`)
    .refine(
      (items) => new Set(items.map((item) => item.productId)).size === items.length,
      'Each product may appear only once; combine the quantities',
    ),
});

const reasonSchema = z.object({
  reason: z
    .string({ error: 'Required' })
    .trim()
    .min(3, 'Explain the reason in a few words')
    .max(500, 'Use at most 500 characters'),
});

const confirmSchema = z.object({
  acknowledgeCreditLimit: z.boolean({ error: 'Must be true or false' }).default(false),
});

const listQuerySchema = z.object({
  status: z
    .enum(['draft', 'confirmed', 'cancelled', 'reversed'], {
      error: 'Must be draft, confirmed, cancelled or reversed',
    })
    .optional(),
  customerId: z.uuid().optional(),
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  q: z.string().trim().max(100).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

const dispatchNotFound = () => new AppError(404, 'DISPATCH_NOT_FOUND', 'No dispatch has that id.');

/**
 * Dispatches (spec 6.6). Everyone signed in can view them. Salespeople, storekeepers and
 * admins create, edit and cancel drafts; storekeepers and admins confirm them (the goods
 * leave the store); only admins reverse a confirmed dispatch.
 */
export function dispatchesRouter(db: pg.Pool, businessTimezone: string): Router {
  const router = Router();
  router.use(requireAuth(db), requirePermission('dispatch.view'));
  const today = () => businessToday(businessTimezone);

  router.get('/', async (req, res) => {
    const search = parseBody(listQuerySchema, req.query);
    res.json(await listDispatches(db, search));
  });

  router.get('/:id', async (req, res) => {
    const id = parseIdParam(req.params.id, dispatchNotFound);
    res.json({ dispatch: await getDispatch(db, id) });
  });

  router.post('/', requirePermission('dispatch.draft'), async (req, res) => {
    const input = parseBody(draftSchema, req.body);
    const dispatch = await createDraft(
      db,
      { ...input, dispatchDate: input.dispatchDate ?? today() },
      getAuth(res).user,
    );
    res.status(201).json({ dispatch });
  });

  router.put('/:id', requirePermission('dispatch.draft'), async (req, res) => {
    const id = parseIdParam(req.params.id, dispatchNotFound);
    const input = parseBody(draftSchema, req.body);
    const dispatch = await updateDraft(db, id, {
      ...input,
      dispatchDate: input.dispatchDate ?? today(),
    });
    res.json({ dispatch });
  });

  router.post('/:id/cancel', requirePermission('dispatch.draft'), async (req, res) => {
    const id = parseIdParam(req.params.id, dispatchNotFound);
    const { reason } = parseBody(reasonSchema, req.body);
    res.json({ dispatch: await cancelDraft(db, id, reason, getAuth(res).user) });
  });

  router.post('/:id/confirm', requirePermission('dispatch.confirm'), async (req, res) => {
    const id = parseIdParam(req.params.id, dispatchNotFound);
    const { acknowledgeCreditLimit } = parseBody(confirmSchema, req.body);
    const result = await confirmDispatch(db, id, getAuth(res).user, {
      acknowledgeCreditLimit,
      today: today(),
    });
    res.json(result);
  });

  router.post('/:id/reverse', requirePermission('dispatch.reverse'), async (req, res) => {
    const id = parseIdParam(req.params.id, dispatchNotFound);
    const { reason } = parseBody(reasonSchema, req.body);
    res.json({ dispatch: await reverseDispatch(db, id, reason, getAuth(res).user, today()) });
  });

  return router;
}
