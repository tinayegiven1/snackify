import { Router, type Response } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import type { AppConfig } from '../../config/env.js';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { businessToday } from '../../utils/dates.js';
import { optionalText, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { organisationFor, scopeOf } from '../organisations/access.js';
import { renderPurchasePdf } from './purchase-pdf.js';
import {
  cancelPurchase,
  createPurchase,
  getPurchase,
  listPurchases,
  purchaseNotFound,
  updatePurchase,
  type PurchaseInput,
} from './purchases.service.js';

const MAX_QUANTITY = 1_000_000;
const MAX_LINES = 200;

const dateSchema = z.iso.date({ error: 'Use a date like 2026-10-12' });
/** A cost per unit: exact, 0 or more, up to 4 decimal places (supplier prices can be fractional). */
const unitCostSchema = z
  .union([z.string(), z.number()], { error: 'Required' })
  .transform((value) => String(value).trim())
  .refine((value) => /^\d{1,10}(\.\d{1,4})?$/.test(value), {
    message: 'Use an amount of 0 or more with up to 4 decimal places, e.g. 0.4250',
  });

const lineSchema = z.object({
  productId: z.uuid({ error: 'Must be a product id' }),
  unitId: z.uuid({ error: 'Must be a unit id' }),
  quantity: z
    .number({ error: 'Must be a whole number' })
    .int('Must be a whole number')
    .min(1, 'Must be at least 1')
    .max(MAX_QUANTITY, `Must be at most ${MAX_QUANTITY.toLocaleString('en')}`),
  unitCost: unitCostSchema,
  notes: optionalText(500),
});

const purchaseSchema = z.object({
  /** Whose stock it is for. Defaults to the user's own organisation. */
  organisationId: z.uuid({ error: 'Must be an organisation id' }).optional(),
  supplierId: z
    .uuid({ error: 'Must be a supplier id' })
    .nullish()
    .transform((value) => value ?? null),
  supplierInvoiceNumber: optionalText(60),
  purchaseDate: dateSchema.optional(),
  notes: optionalText(1000),
  lines: z
    .array(lineSchema, { error: 'Must be a list of lines' })
    .min(1, 'Add at least one product')
    .max(MAX_LINES, `Use at most ${MAX_LINES} lines`),
});

const listSchema = z.object({
  q: z.string().trim().max(60).optional(),
  status: z
    .enum(['OPEN', 'CANCELLED', 'NOT_RECEIVED', 'PARTLY_RECEIVED', 'RECEIVED'], {
      error: 'Must be OPEN, CANCELLED, NOT_RECEIVED, PARTLY_RECEIVED or RECEIVED',
    })
    .optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

const reasonSchema = z.object({
  reason: z
    .string({ error: 'Required' })
    .trim()
    .min(3, 'Explain the reason in a few words')
    .max(500, 'Use at most 500 characters'),
});

/**
 * Goods bought (/api/v1/purchases). Finance and administrators (purchase.manage) enter, change
 * and cancel lists; warehouse staff (stock.receive) and verifiers (receipt.verify) see them, to
 * receive against them and check deliveries.
 */
export function purchasesRouter(db: pg.Pool, config: AppConfig): Router {
  const router = Router();
  router.use(
    requireAuth(db),
    requirePermission('purchase.manage', 'stock.receive', 'receipt.verify'),
  );
  const today = () => businessToday(config.businessTimezone);
  const scope = (res: Response) => scopeOf(getAuth(res).user);
  const purchaseId = (value: unknown) => parseIdParam(value, purchaseNotFound);

  function toInput(res: Response, body: unknown): PurchaseInput {
    const { organisationId, purchaseDate, ...input } = parseBody(purchaseSchema, body);
    const date = purchaseDate ?? today();
    if (date > today()) {
      throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
        { field: 'purchaseDate', message: 'Cannot be in the future' },
      ]);
    }
    return {
      ...input,
      purchaseDate: date,
      ownerOrganisationId: organisationFor(scope(res), organisationId),
    };
  }

  router.get('/', async (req, res) => {
    res.json(await listPurchases(db, scope(res), parseBody(listSchema, req.query)));
  });

  router.get('/:id', async (req, res) => {
    res.json({ purchase: await getPurchase(db, scope(res), purchaseId(req.params.id)) });
  });

  router.get('/:id/pdf', async (req, res) => {
    const purchase = await getPurchase(db, scope(res), purchaseId(req.params.id));
    const pdf = await renderPurchasePdf(purchase, config.business);
    res
      .type('application/pdf')
      .set('Content-Disposition', `inline; filename="${purchase.purchaseNumber}.pdf"`)
      .set('Cache-Control', 'no-store')
      .send(pdf);
  });

  router.post('/', requirePermission('purchase.manage'), async (req, res) => {
    const purchase = await createPurchase(
      db,
      toInput(res, req.body),
      getAuth(res).user,
      config.baseCurrency,
    );
    res.status(201).json({ purchase });
  });

  router.put('/:id', requirePermission('purchase.manage'), async (req, res) => {
    const purchase = await updatePurchase(
      db,
      scope(res),
      purchaseId(req.params.id),
      toInput(res, req.body),
      getAuth(res).user,
    );
    res.json({ purchase });
  });

  router.post('/:id/cancel', requirePermission('purchase.manage'), async (req, res) => {
    const { reason } = parseBody(reasonSchema, req.body);
    const purchase = await cancelPurchase(
      db,
      scope(res),
      purchaseId(req.params.id),
      reason,
      getAuth(res).user,
    );
    res.json({ purchase });
  });

  return router;
}
