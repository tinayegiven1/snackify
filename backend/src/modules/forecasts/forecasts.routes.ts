import { Router } from 'express';
import type pg from 'pg';
import type { AppConfig } from '../../config/env.js';
import { getAuth, requireAuth, requireRole } from '../../middleware/authenticate.js';
import { businessToday } from '../../utils/dates.js';
import { latestForecast, runForecast } from './forecasts.service.js';

/**
 * Sales forecasts (spec 6.11): estimates of demand for the next week and month, for admins,
 * accounts staff and storekeepers (who plan deliveries).
 */
export function forecastsRouter(db: pg.Pool, config: AppConfig): Router {
  const router = Router();
  router.use(requireAuth(db), requireRole('storekeeper', 'accounts'));
  const today = () => businessToday(config.businessTimezone);

  router.get('/', async (_req, res) => {
    res.json({ forecast: await latestForecast(db, today()) });
  });

  router.post('/run', async (_req, res) => {
    res.status(201).json({ forecast: await runForecast(db, today(), getAuth(res).user) });
  });

  return router;
}
