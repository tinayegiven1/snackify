import { Router } from 'express';
import type { AppConfig } from '../../config/env.js';

export function healthRouter(config: AppConfig): Router {
  const router = Router();

  router.get('/', (_req, res) => {
    res.set('Cache-Control', 'no-store');
    res.json({
      status: 'ok',
      service: 'snackify-api',
      environment: config.nodeEnv,
      timestamp: new Date().toISOString(),
      uptimeSeconds: Math.round(process.uptime()),
      checks: {
        // PostgreSQL is connected in the next stage; this will then report "up" or "down".
        database: 'not_configured',
      },
    });
  });

  return router;
}
