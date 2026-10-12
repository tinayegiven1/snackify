import { Router } from 'express';
import type { AppConfig } from '../../config/env.js';

/** Resolves to true when the database answers; never rejects. */
export type DatabaseCheck = () => Promise<boolean>;

export function healthRouter(config: AppConfig, checkDatabase: DatabaseCheck): Router {
  const router = Router();

  router.get('/', async (_req, res) => {
    const databaseUp = await checkDatabase();

    res.set('Cache-Control', 'no-store');
    // 503 tells monitoring tools and clients that the API cannot serve requests right now.
    res.status(databaseUp ? 200 : 503).json({
      status: databaseUp ? 'ok' : 'unavailable',
      service: 'snackify-api',
      environment: config.nodeEnv,
      timestamp: new Date().toISOString(),
      uptimeSeconds: Math.round(process.uptime()),
      checks: {
        database: databaseUp ? 'up' : 'down',
      },
    });
  });

  return router;
}
