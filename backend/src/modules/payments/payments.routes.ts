import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import type { AppConfig } from '../../config/env.js';
import { getAuth, requireAuth, requireRole } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { addDays, businessToday, daysBetween } from '../../utils/dates.js';
import { toCents } from '../../utils/money.js';
import { moneySchema, optionalText, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { getCustomerAccount, listCustomerBalances } from './balances.service.js';
import {
  PAYMENT_METHODS,
  allocatePayment,
  getPayment,
  listPayments,
  recordPayment,
  voidPayment,
} from './payments.service.js';

const MAX_STATEMENT_DAYS = 366;

const dateSchema = z.iso.date({ error: 'Use a date like 2026-10-12' });
const positiveMoney = moneySchema.refine((value) => toCents(value) > 0, 'Must be more than 0');

const allocationsSchema = z
  .array(
    z.object({
      invoiceId: z.uuid({ error: 'Choose an invoice' }),
      amount: positiveMoney,
    }),
    { error: 'Must be a list of invoices and amounts' },
  )
  .max(100, 'Allocate to at most 100 invoices at once');

const paymentSchema = z.object({
  customerId: z.uuid({ error: 'Choose a customer' }),
  paymentDate: dateSchema,
  amount: positiveMoney,
  method: z.enum(PAYMENT_METHODS, { error: 'Choose how the customer paid' }),
  reference: optionalText(100),
  notes: optionalText(500),
  idempotencyKey: z
    .uuid({ error: 'Must be a UUID' })
    .nullish()
    .transform((value) => value ?? null),
  allocations: allocationsSchema.default([]),
});

const listQuerySchema = z.object({
  customerId: z.uuid().optional(),
  status: z.enum(['recorded', 'voided'], { error: 'Must be recorded or voided' }).optional(),
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  q: z.string().trim().max(100).optional(),
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

const periodSchema = z.object({ from: dateSchema.optional(), to: dateSchema.optional() });

const paymentNotFound = () => new AppError(404, 'PAYMENT_NOT_FOUND', 'No payment has that id.');
const customerNotFound = () => new AppError(404, 'CUSTOMER_NOT_FOUND', 'No customer has that id.');

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

/**
 * Payments (spec 6.9). Accounts staff and admins record and allocate payments; only admins void
 * one, with a reason. Amounts are in the base currency.
 */
export function paymentsRouter(db: pg.Pool, config: AppConfig): Router {
  const router = Router();
  router.use(requireAuth(db), requireRole('accounts'));
  const today = () => businessToday(config.businessTimezone);

  router.get('/', async (req, res) => {
    res.json(await listPayments(db, parseBody(listQuerySchema, req.query)));
  });

  router.post('/', async (req, res) => {
    const input = parseBody(paymentSchema, req.body);
    if (input.paymentDate > today()) throw fieldError('paymentDate', 'Cannot be in the future');
    const result = await recordPayment(db, input, getAuth(res).user, config.baseCurrency);
    res.status(result.duplicate ? 200 : 201).json(result);
  });

  router.get('/:id', async (req, res) => {
    const id = parseIdParam(req.params.id, paymentNotFound);
    res.json({ payment: await getPayment(db, id) });
  });

  router.post('/:id/allocations', async (req, res) => {
    const id = parseIdParam(req.params.id, paymentNotFound);
    const { allocations } = parseBody(
      z.object({ allocations: allocationsSchema.min(1, 'Choose at least one invoice') }),
      req.body,
    );
    res.json({ payment: await allocatePayment(db, id, allocations, getAuth(res).user) });
  });

  router.post('/:id/void', requireRole('admin'), async (req, res) => {
    const id = parseIdParam(req.params.id, paymentNotFound);
    const { reason } = parseBody(reasonSchema, req.body);
    res.json({ payment: await voidPayment(db, id, reason, getAuth(res).user) });
  });

  return router;
}

/** Customer balances and account statements (spec 6.9). Accounts staff and admins. */
export function balancesRouter(db: pg.Pool, config: AppConfig): Router {
  const router = Router();
  router.use(requireAuth(db), requireRole('accounts'));
  const today = () => businessToday(config.businessTimezone);

  router.get('/', async (_req, res) => {
    res.json({ currency: config.baseCurrency, ...(await listCustomerBalances(db, today())) });
  });

  /** One customer's account. The statement covers the last 90 days unless dates are given. */
  router.get('/:customerId', async (req, res) => {
    const customerId = parseIdParam(req.params.customerId, customerNotFound);
    const query = parseBody(periodSchema, req.query);
    const to = query.to ?? today();
    const from = query.from ?? addDays(to, -89);
    if (to < from) throw fieldError('to', 'Must be on or after "from"');
    if (daysBetween(from, to) >= MAX_STATEMENT_DAYS) {
      throw fieldError('to', `Choose a period of at most ${MAX_STATEMENT_DAYS} days`);
    }
    const account = await getCustomerAccount(
      db,
      customerId,
      { from, to },
      today(),
      config.baseCurrency,
    );
    res.json({ account });
  });

  return router;
}
