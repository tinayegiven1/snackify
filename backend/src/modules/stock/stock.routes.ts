import { Router, type Response } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { can, getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { businessToday, daysBetween } from '../../utils/dates.js';
import { optionalText } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { organisationFor, scopeOf } from '../organisations/access.js';
import {
  adjustStock,
  listBalances,
  listMovements,
  listReceipts,
  receiveStock,
} from './stock.service.js';

const MAX_QUANTITY = 1_000_000;
const MAX_REPORT_DAYS = 366;

const dateSchema = z.iso.date({ error: 'Use a date like 2026-10-12' });
const productIdSchema = z.uuid({ error: 'Must be a product id' });

const receiptSchema = z.object({
  productId: productIdSchema,
  quantity: z
    .number({ error: 'Must be a whole number of packs' })
    .int('Must be a whole number of packs')
    .min(1, 'Must be at least 1')
    .max(MAX_QUANTITY, `Must be at most ${MAX_QUANTITY.toLocaleString('en')}`),
  receivedDate: dateSchema.optional(),
  batchNumber: optionalText(60),
  expiryDate: dateSchema.nullish().transform((value) => value ?? null),
  supplierReference: optionalText(120),
  isOpeningBalance: z.boolean({ error: 'Must be true or false' }).default(false),
});

const adjustmentSchema = z
  .object({
    productId: productIdSchema,
    type: z.enum(['adjustment', 'damage'], { error: 'Must be "adjustment" or "damage"' }),
    quantityDelta: z
      .number({ error: 'Must be a whole number' })
      .int('Must be a whole number')
      .refine((value) => value !== 0, 'Must not be 0')
      .refine((value) => Math.abs(value) <= MAX_QUANTITY, 'Too large'),
    reason: z
      .string({ error: 'Required' })
      .trim()
      .min(3, 'Explain the reason in a few words')
      .max(500, 'Use at most 500 characters'),
    businessDate: dateSchema.optional(),
    // Whose stock, where, and which delivery (StockFlow Stage 4). All optional.
    organisationId: z.uuid({ error: 'Must be an organisation id' }).optional(),
    warehouseId: z.uuid({ error: 'Must be a warehouse id' }).optional(),
    batchId: z.uuid({ error: 'Must be a batch id' }).optional(),
  })
  .refine((input) => input.type !== 'damage' || input.quantityDelta < 0, {
    path: ['quantityDelta'],
    message: 'Damage removes stock, so use a negative number',
  });

const flag = z
  .enum(['true', 'false'], { error: 'Must be true or false' })
  .optional()
  .transform((value) => value === 'true');

/** Whose stock to show. Defaults to the user's own organisation; checked against their access. */
const organisationQuery = {
  organisationId: z.uuid({ error: 'Must be an organisation id' }).optional(),
};

const balanceQuerySchema = z.object({
  ...organisationQuery,
  q: z.string().trim().max(100).optional(),
  lowStockOnly: flag,
  includeInactive: flag,
});

const dateRangeQuerySchema = z.object({
  ...organisationQuery,
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  productId: productIdSchema.optional(),
});

const movementsQuerySchema = dateRangeQuerySchema.extend({
  limit: z.coerce.number().int().min(1).max(500).default(100),
  offset: z.coerce.number().int().min(0).default(0),
});

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

/** Business dates may not be in the future (in the business's time zone). */
function checkNotFuture(field: string, date: string, today: string): void {
  if (date > today) throw fieldError(field, 'Cannot be in the future');
}

/**
 * Stock (spec 6.3 and 6.4). Stock belongs to an organisation: Head Office users may see any
 * organisation's, a subsidiary's users only their own (the scope is applied in every query).
 * Recording receipts, opening balances and adjustments each need their own permission.
 */
export function stockRouter(db: pg.Pool, businessTimezone: string): Router {
  const router = Router();
  router.use(requireAuth(db), requirePermission('stock.view'));
  const today = () => businessToday(businessTimezone);
  const ownerFor = (res: Response, requested: string | undefined) =>
    organisationFor(scopeOf(getAuth(res).user), requested);

  router.get('/balance', async (req, res) => {
    const { organisationId, ...filter } = parseBody(balanceQuerySchema, req.query);
    const ownerOrganisationId = ownerFor(res, organisationId);
    res.json({ balances: await listBalances(db, { ...filter, ownerOrganisationId }) });
  });

  router.get('/receipts', async (req, res) => {
    const query = parseBody(dateRangeQuerySchema, req.query);
    const from = query.from ?? today();
    const to = query.to ?? from;
    if (to < from) throw fieldError('to', 'Must be on or after "from"');
    if (daysBetween(from, to) >= MAX_REPORT_DAYS) {
      throw fieldError('to', `Choose a range of at most ${MAX_REPORT_DAYS} days`);
    }
    const ownerOrganisationId = ownerFor(res, query.organisationId);
    res.json({
      from,
      to,
      ...(await listReceipts(db, { ownerOrganisationId, from, to, productId: query.productId })),
    });
  });

  // Since StockFlow Stage 4, deliveries come in through goods-received notes (/api/v1/receipts),
  // which check documents and record whose stock it is. This quick receipt now only records a
  // product's opening balance (the Head Office's stock on the day Snackify started).
  router.post(
    '/receipts',
    requirePermission('stock.receive', 'stock.opening_balance'),
    async (req, res) => {
      const input = parseBody(receiptSchema, req.body);
      const { user } = getAuth(res);
      if (!input.isOpeningBalance) {
        throw new AppError(
          409,
          'USE_GOODS_RECEIVED_NOTE',
          'Record deliveries with a goods-received note (Receive Stock), with the supplier document.',
        );
      }
      if (!can(user, 'stock.opening_balance')) {
        throw new AppError(403, 'FORBIDDEN', 'Only admins can record opening balances.');
      }

      const receivedDate = input.receivedDate ?? today();
      checkNotFuture('receivedDate', receivedDate, today());
      if (input.expiryDate !== null && input.expiryDate < receivedDate) {
        throw fieldError('expiryDate', 'Cannot be before the date the stock was received');
      }

      const result = await receiveStock(db, { ...input, receivedDate }, user);
      res.status(201).json(result);
    },
  );

  router.get('/movements', async (req, res) => {
    const { organisationId, ...query } = parseBody(movementsQuerySchema, req.query);
    const ownerOrganisationId = ownerFor(res, organisationId);
    res.json(await listMovements(db, { ...query, ownerOrganisationId }));
  });

  router.post('/adjustments', requirePermission('stock.adjust'), async (req, res) => {
    const { organisationId, ...input } = parseBody(adjustmentSchema, req.body);
    const businessDate = input.businessDate ?? today();
    checkNotFuture('businessDate', businessDate, today());
    const ownerOrganisationId = ownerFor(res, organisationId);

    const result = await adjustStock(
      db,
      { ...input, businessDate, ownerOrganisationId },
      getAuth(res).user,
    );
    res.status(201).json(result);
  });

  return router;
}
