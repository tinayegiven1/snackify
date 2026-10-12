import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requireRole } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { businessToday, daysBetween } from '../../utils/dates.js';
import { optionalText } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
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
  })
  .refine((input) => input.type !== 'damage' || input.quantityDelta < 0, {
    path: ['quantityDelta'],
    message: 'Damage removes stock, so use a negative number',
  });

const flag = z
  .enum(['true', 'false'], { error: 'Must be true or false' })
  .optional()
  .transform((value) => value === 'true');

const balanceQuerySchema = z.object({
  q: z.string().trim().max(100).optional(),
  lowStockOnly: flag,
  includeInactive: flag,
});

const dateRangeQuerySchema = z.object({
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
 * Stock (spec 6.3 and 6.4). Everyone signed in can view stock; storekeepers and admins
 * receive stock; only admins record opening balances and manual adjustments.
 */
export function stockRouter(db: pg.Pool, businessTimezone: string): Router {
  const router = Router();
  router.use(requireAuth(db));
  const today = () => businessToday(businessTimezone);

  router.get('/balance', async (req, res) => {
    const filter = parseBody(balanceQuerySchema, req.query);
    res.json({ balances: await listBalances(db, filter) });
  });

  router.get('/receipts', async (req, res) => {
    const query = parseBody(dateRangeQuerySchema, req.query);
    const from = query.from ?? today();
    const to = query.to ?? from;
    if (to < from) throw fieldError('to', 'Must be on or after "from"');
    if (daysBetween(from, to) >= MAX_REPORT_DAYS) {
      throw fieldError('to', `Choose a range of at most ${MAX_REPORT_DAYS} days`);
    }
    res.json({ from, to, ...(await listReceipts(db, { from, to, productId: query.productId })) });
  });

  router.post('/receipts', requireRole('storekeeper'), async (req, res) => {
    const input = parseBody(receiptSchema, req.body);
    const { user } = getAuth(res);
    if (input.isOpeningBalance && user.role !== 'admin') {
      throw new AppError(403, 'FORBIDDEN', 'Only admins can record opening balances.');
    }

    const receivedDate = input.receivedDate ?? today();
    checkNotFuture('receivedDate', receivedDate, today());
    if (input.expiryDate !== null && input.expiryDate < receivedDate) {
      throw fieldError('expiryDate', 'Cannot be before the date the stock was received');
    }

    const result = await receiveStock(db, { ...input, receivedDate }, user);
    res.status(201).json(result);
  });

  router.get('/movements', async (req, res) => {
    const query = parseBody(movementsQuerySchema, req.query);
    res.json(await listMovements(db, query));
  });

  router.post('/adjustments', requireRole('admin'), async (req, res) => {
    const input = parseBody(adjustmentSchema, req.body);
    const businessDate = input.businessDate ?? today();
    checkNotFuture('businessDate', businessDate, today());

    const result = await adjustStock(db, { ...input, businessDate }, getAuth(res).user);
    res.status(201).json(result);
  });

  return router;
}
