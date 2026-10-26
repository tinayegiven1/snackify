import { Router, type Response } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import type { AppConfig } from '../../config/env.js';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { businessToday } from '../../utils/dates.js';
import { moneySchema, optionalText, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { organisationFor, scopeOf } from '../organisations/access.js';
import { renderOrderPdf, type SheetParty } from './order-pdf.js';
import {
  approveOrder,
  cancelOrder,
  createOrder,
  getOrder,
  listOrders,
  orderNotFound,
  rejectOrder,
  setActualPrices,
  startReview,
  submitOrder,
  updateDraft,
  type OrderInput,
} from './orders.service.js';

const MAX_LINES = 200;

const dateSchema = z.iso.date({ error: 'Use a date like 2026-10-12' });
const flag = z
  .enum(['true', 'false'], { error: 'Must be true or false' })
  .optional()
  .transform((value) => (value === undefined ? undefined : value === 'true'));
const commentSchema = (max: number) =>
  z
    .string({ error: 'Required' })
    .trim()
    .min(3, 'Explain in a few words')
    .max(max, `Use at most ${max} characters`);

const lineSchema = z
  .object({
    productId: z.uuid({ error: 'Must be a product id' }),
    unitId: z.uuid({ error: 'Must be a unit id' }),
    requestedQuantity: z
      .number({ error: 'Must be a whole number' })
      .int('Must be a whole number')
      .min(1, 'Must be at least 1')
      .max(1_000_000, 'Must be at most 1,000,000'),
    expectedUnitPrice: moneySchema,
    maximumUnitPrice: moneySchema,
    notes: optionalText(500),
  })
  // Compared exactly, as whole cents.
  .refine(
    (line) =>
      Math.round(Number(line.maximumUnitPrice) * 100) >=
      Math.round(Number(line.expectedUnitPrice) * 100),
    { path: ['maximumUnitPrice'], message: 'Must be at least the expected price' },
  );

const orderSchema = z.object({
  /** Head Office staff ordering for a subsidiary name it; a subsidiary's staff need not. */
  organisationId: z.uuid({ error: 'Must be an organisation id' }).optional(),
  requiredDate: dateSchema.nullish().transform((value) => value ?? null),
  notes: optionalText(1000),
  lines: z
    .array(lineSchema, { error: 'Must be a list of lines' })
    .max(MAX_LINES, `Use at most ${MAX_LINES} lines`),
});

const createSchema = orderSchema.extend({
  /** A new random id from the app for each new order; repeating it returns the same order. */
  idempotencyKey: z.uuid({ error: 'Must be a random id (UUID) made for this order' }),
});

const listSchema = z.object({
  status: z
    .enum([
      'DRAFT',
      'SUBMITTED',
      'UNDER_REVIEW',
      'APPROVED',
      'REJECTED',
      'CANCELLED',
      'PARTIALLY_DISPATCHED',
      'FULLY_DISPATCHED',
      'COMPLETED',
    ])
    .optional(),
  organisationId: z.uuid({ error: 'Must be an organisation id' }).optional(),
  priceException: flag,
  q: z.string().trim().max(40).optional(),
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  sort: z.enum(['newest', 'oldest', 'required']).default('newest'),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

const pricesSchema = z.object({
  prices: z
    .array(
      z.object({
        itemId: z.uuid({ error: 'Must be a line id' }),
        actualUnitPrice: moneySchema,
        comment: optionalText(500),
      }),
      { error: 'Must be a list of prices' },
    )
    .min(1, 'Give at least one price')
    .max(MAX_LINES),
});

/**
 * Subsidiary orders (StockFlow Stage 5). A subsidiary's staff see and change only their own
 * organisation's orders (others answer 404); the Head Office sees all, sets the actual prices
 * and approves or rejects.
 */
export function ordersRouter(db: pg.Pool, config: AppConfig): Router {
  const router = Router();
  router.use(requireAuth(db), requirePermission('order.view'));
  const today = () => businessToday(config.businessTimezone);
  const scope = (res: Response) => scopeOf(getAuth(res).user);
  const orderId = (value: unknown) => parseIdParam(value, orderNotFound);
  const input = (body: unknown): OrderInput => parseBody(orderSchema, body);

  router.get('/', async (req, res) => {
    const { organisationId, ...filter } = parseBody(listSchema, req.query);
    res.json(
      await listOrders(db, scope(res), {
        ...filter,
        organisationId:
          organisationId === undefined ? undefined : organisationFor(scope(res), organisationId),
      }),
    );
  });

  router.get('/:id', async (req, res) => {
    res.json({ order: await getOrder(db, scope(res), orderId(req.params.id)) });
  });

  router.get('/:id/pdf', async (req, res) => {
    const order = await getOrder(db, scope(res), orderId(req.params.id));
    const { rows } = await db.query<{
      name: string;
      code: string;
      address: string | null;
      contact_phone: string | null;
      contact_email: string | null;
      tax_number: string | null;
    }>(
      `SELECT name, code, address, contact_phone, contact_email, tax_number
       FROM organisations WHERE id = hq_organisation_id()`,
    );
    const hq = rows[0];
    const headOffice: SheetParty = hq
      ? {
          name: hq.name,
          code: hq.code,
          lines: [
            hq.address,
            hq.contact_phone,
            hq.contact_email,
            hq.tax_number && `Tax number ${hq.tax_number}`,
          ].filter((line): line is string => Boolean(line)),
        }
      : { name: config.business.name, code: 'HQ', lines: [] };
    const pdf = await renderOrderPdf(order, headOffice, config.business);
    res
      .type('application/pdf')
      .set('Content-Disposition', `inline; filename="${order.orderNumber}.pdf"`)
      .set('Cache-Control', 'no-store')
      .send(pdf);
  });

  router.post('/', requirePermission('order.create'), async (req, res) => {
    const body = parseBody(createSchema, req.body);
    const result = await createOrder(db, scope(res), body, getAuth(res).user, {
      currency: config.baseCurrency,
      today: today(),
    });
    // A repeated request answers 200 with the order it created the first time.
    res.status(result.replayed ? 200 : 201).json(result);
  });

  router.put('/:id', requirePermission('order.create'), async (req, res) => {
    const id = orderId(req.params.id);
    const order = await updateDraft(
      db,
      scope(res),
      id,
      input(req.body),
      getAuth(res).user,
      today(),
    );
    res.json({ order });
  });

  router.post('/:id/submit', requirePermission('order.create'), async (req, res) => {
    res.json(await submitOrder(db, scope(res), orderId(req.params.id), getAuth(res).user));
  });

  router.post('/:id/cancel', requirePermission('order.create'), async (req, res) => {
    const { reason } = parseBody(z.object({ reason: commentSchema(500) }), req.body);
    const order = await cancelOrder(
      db,
      scope(res),
      orderId(req.params.id),
      reason,
      getAuth(res).user,
    );
    res.json({ order });
  });

  router.post('/:id/review', requirePermission('order.price'), async (req, res) => {
    const order = await startReview(db, scope(res), orderId(req.params.id), getAuth(res).user);
    res.json({ order });
  });

  router.put('/:id/prices', requirePermission('order.price'), async (req, res) => {
    const { prices } = parseBody(pricesSchema, req.body);
    const order = await setActualPrices(
      db,
      scope(res),
      orderId(req.params.id),
      prices,
      getAuth(res).user,
    );
    res.json({ order });
  });

  router.post('/:id/approve', requirePermission('order.approve'), async (req, res) => {
    const { comment } = parseBody(
      z.object({
        comment: optionalText(1000).refine((value) => value === null || value.length >= 3, {
          message: 'Explain in a few words',
        }),
      }),
      req.body ?? {},
    );
    const order = await approveOrder(
      db,
      scope(res),
      orderId(req.params.id),
      comment,
      getAuth(res).user,
      config.orders,
    );
    res.json({ order });
  });

  router.post('/:id/reject', requirePermission('order.approve'), async (req, res) => {
    const { comment } = parseBody(z.object({ comment: commentSchema(1000) }), req.body);
    const order = await rejectOrder(
      db,
      scope(res),
      orderId(req.params.id),
      comment,
      getAuth(res).user,
    );
    res.json({ order });
  });

  return router;
}
