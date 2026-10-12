import cors from 'cors';
import express, { type Express } from 'express';
import helmet from 'helmet';
import type { AppConfig } from './config/env.js';
import { errorHandler } from './middleware/error-handler.js';
import { notFoundHandler } from './middleware/not-found.js';
import { healthRouter, type DatabaseCheck } from './modules/health/health.routes.js';

/** Things the app needs from outside, passed in so tests can replace them. */
export interface AppDependencies {
  checkDatabase: DatabaseCheck;
}

/** Builds the Express app without starting a server, so tests can call it directly. */
export function createApp(config: AppConfig, deps: AppDependencies): Express {
  const app = express();

  app.use(helmet());
  app.use(cors({ origin: config.corsOrigins }));
  app.use(express.json({ limit: '100kb' }));

  app.use('/api/v1/health', healthRouter(config, deps.checkDatabase));

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
