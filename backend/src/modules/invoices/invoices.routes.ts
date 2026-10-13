import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import type { AppConfig } from '../../config/env.js';
import { getAuth, requireAuth, requireRole } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { businessToday, daysBetween, lastCompleteBillingWeek } from '../../utils/dates.js';
import { parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { renderInvoicePdf } from './invoice-pdf.js';
import {
  createDraftInvoice,
  createDraftInvoicesForPeriod,
  getInvoice,
  issueInvoice,
  listInvoices,
  listUnbilledCustomers,
  previewInvoice,
  voidDraftInvoice,
} from './invoices.service.js';

const MAX_PERIOD_DAYS = 92;

const dateSchema = z.iso.date({ error: 'Use a date like 2026-10-12' });
const periodSchema = z.object({ from: dateSchema.optional(), to: dateSchema.optional() });
const customerPeriodSchema = periodSchema.extend({
  customerId: z.uuid({ error: 'Choose a customer' }),
});

const listQuerySchema = z.object({
  status: z
    .enum(['draft', 'issued', 'voided'], { error: 'Must be draft, issued or voided' })
    .optional(),
  payment: z.enum(['unpaid', 'overdue'], { error: 'Must be unpaid or overdue' }).optional(),
  customerId: z.uuid().optional(),
  q: z.string().trim().max(100).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

const voidSchema = z.object({
  reason: z
    .string({ error: 'Required' })
    .trim()
    .min(3, 'Explain the reason in a few words')
    .max(500, 'Use at most 500 characters'),
});

const invoiceNotFound = () => new AppError(404, 'INVOICE_NOT_FOUND', 'No invoice has that id.');

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

/**
 * Invoices (spec 6.8). Accounts staff and admins only (spec section 5).
 * The billing period defaults to the last complete billing week in the business time zone.
 */
export function invoicesRouter(db: pg.Pool, config: AppConfig): Router {
  const router = Router();
  router.use(requireAuth(db), requireRole('accounts'));
  const today = () => businessToday(config.businessTimezone);

  /** The requested period, or the last complete billing week; checked for sense. */
  function resolvePeriod(input: { from?: string | undefined; to?: string | undefined }) {
    const fallback = lastCompleteBillingWeek(today(), config.billingWeekStartsOn);
    const from = input.from ?? fallback.from;
    const to = input.to ?? (input.from ? input.from : fallback.to);
    if (to < from) throw fieldError('to', 'Must be on or after "from"');
    if (daysBetween(from, to) >= MAX_PERIOD_DAYS) {
      throw fieldError('to', `Choose a period of at most ${MAX_PERIOD_DAYS} days`);
    }
    if (to > today()) throw fieldError('to', 'Cannot be in the future');
    return { from, to };
  }

  /** Who still has dispatches to invoice in the period (the weekly run's overview). */
  router.get('/unbilled', async (req, res) => {
    const period = resolvePeriod(parseBody(periodSchema, req.query));
    res.json({ ...period, customers: await listUnbilledCustomers(db, period) });
  });

  router.get('/preview', async (req, res) => {
    const query = parseBody(customerPeriodSchema, req.query);
    const period = resolvePeriod(query);
    res.json({
      preview: await previewInvoice(db, query.customerId, period, config.baseCurrency),
    });
  });

  router.get('/', async (req, res) => {
    const search = parseBody(listQuerySchema, req.query);
    res.json(await listInvoices(db, search, today()));
  });

  /** A draft invoice for one customer and period. */
  router.post('/', async (req, res) => {
    const input = parseBody(customerPeriodSchema, req.body);
    const period = resolvePeriod(input);
    const invoice = await createDraftInvoice(
      db,
      { customerId: input.customerId, ...period },
      getAuth(res).user,
      config.baseCurrency,
    );
    res.status(201).json({ invoice });
  });

  /** Draft invoices for every customer with unbilled dispatches in the period. */
  router.post('/generate', async (req, res) => {
    const period = resolvePeriod(parseBody(periodSchema, req.body));
    const invoices = await createDraftInvoicesForPeriod(
      db,
      period,
      getAuth(res).user,
      config.baseCurrency,
    );
    res.status(201).json({ ...period, invoices });
  });

  router.get('/:id', async (req, res) => {
    const id = parseIdParam(req.params.id, invoiceNotFound);
    res.json({ invoice: await getInvoice(db, id, today()) });
  });

  router.get('/:id/pdf', async (req, res) => {
    const id = parseIdParam(req.params.id, invoiceNotFound);
    const invoice = await getInvoice(db, id, today());
    const pdf = await renderInvoicePdf(invoice, config.business);
    const name = invoice.invoiceNumber ?? `draft-${invoice.customer.code}-${invoice.periodFrom}`;
    res
      .type('application/pdf')
      .set('Content-Disposition', `inline; filename="${name}.pdf"`)
      .set('Cache-Control', 'no-store')
      .send(pdf);
  });

  router.post('/:id/issue', async (req, res) => {
    const id = parseIdParam(req.params.id, invoiceNotFound);
    const invoice = await issueInvoice(db, id, getAuth(res).user, today(), config.paymentTermsDays);
    res.json({ invoice });
  });

  router.post('/:id/void', async (req, res) => {
    const id = parseIdParam(req.params.id, invoiceNotFound);
    const { reason } = parseBody(voidSchema, req.body);
    res.json({ invoice: await voidDraftInvoice(db, id, reason, getAuth(res).user) });
  });

  return router;
}
