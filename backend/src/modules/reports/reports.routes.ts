import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import type { AppConfig } from '../../config/env.js';
import { can, getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { addDays, businessToday, daysBetween } from '../../utils/dates.js';
import { parseBody } from '../../utils/validation.js';
import {
  customerSummaryReport,
  dashboard,
  expiringStock,
  productSalesReport,
  salesReport,
  stockReceivedReport,
} from './reports.service.js';

/** Two years: enough for year-on-year comparisons, small enough to answer quickly. */
const MAX_RANGE_DAYS = 731;

const dateSchema = z.iso.date({ error: 'Use a date like 2026-10-12' });
const rangeSchema = z.object({ from: dateSchema.optional(), to: dateSchema.optional() });

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

/**
 * Reports (spec 6.10). The dashboard is for everyone, with money shown only to admins and
 * accounts staff; sales, product and customer reports are for admins and accounts staff; stock
 * reports also for storekeepers.
 */
export function reportsRouter(db: pg.Pool, config: AppConfig): Router {
  const router = Router();
  router.use(requireAuth(db));
  const today = () => businessToday(config.businessTimezone);

  /** The requested dates, or the last 30 days up to today. */
  function resolveRange(input: { from?: string | undefined; to?: string | undefined }) {
    const to = input.to ?? today();
    const from = input.from ?? addDays(to, -29);
    if (to < from) throw fieldError('to', 'Must be on or after "from"');
    if (to > today()) throw fieldError('to', 'Cannot be in the future');
    if (daysBetween(from, to) >= MAX_RANGE_DAYS) {
      throw fieldError('to', 'Choose a period of at most two years');
    }
    return { from, to };
  }

  router.get('/dashboard', requirePermission('report.dashboard'), async (_req, res) => {
    const { user } = getAuth(res);
    res.json({
      dashboard: await dashboard(
        db,
        today(),
        config.billingWeekStartsOn,
        config.baseCurrency,
        can(user, 'report.financial'),
      ),
    });
  });

  router.get('/sales', requirePermission('report.financial'), async (req, res) => {
    const query = parseBody(
      rangeSchema.extend({
        groupBy: z
          .enum(['day', 'week', 'month'], { error: 'Must be day, week or month' })
          .default('day'),
      }),
      req.query,
    );
    res.json(
      await salesReport(
        db,
        resolveRange(query),
        query.groupBy,
        config.billingWeekStartsOn,
        config.baseCurrency,
      ),
    );
  });

  router.get('/products', requirePermission('report.financial'), async (req, res) => {
    const query = parseBody(
      rangeSchema.extend({
        sortBy: z.enum(['value', 'packs'], { error: 'Must be value or packs' }).default('value'),
      }),
      req.query,
    );
    const range = resolveRange(query);
    res.json({
      ...range,
      currency: config.baseCurrency,
      ...(await productSalesReport(db, range, query.sortBy)),
    });
  });

  router.get('/customers', requirePermission('report.financial'), async (req, res) => {
    const range = resolveRange(parseBody(rangeSchema, req.query));
    res.json({
      ...range,
      currency: config.baseCurrency,
      ...(await customerSummaryReport(db, range, today())),
    });
  });

  router.get('/stock-received', requirePermission('report.stock'), async (req, res) => {
    const range = resolveRange(parseBody(rangeSchema, req.query));
    res.json({ ...range, ...(await stockReceivedReport(db, range)) });
  });

  router.get('/expiring', requirePermission('report.stock'), async (req, res) => {
    const { days } = parseBody(
      z.object({
        days: z.coerce
          .number({ error: 'Must be a whole number of days' })
          .int('Must be a whole number of days')
          .min(1, 'Must be at least 1')
          .max(365, 'Must be at most 365')
          .default(30),
      }),
      req.query,
    );
    res.json({ today: today(), ...(await expiringStock(db, today(), days)) });
  });

  return router;
}
