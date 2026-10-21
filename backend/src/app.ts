import cors from 'cors';
import express, { type Express } from 'express';
import helmet from 'helmet';
import type pg from 'pg';
import type { AppConfig } from './config/env.js';
import { configurePgTypes } from './database/pg-types.js';
import { errorHandler } from './middleware/error-handler.js';
import { notFoundHandler } from './middleware/not-found.js';
import { auditRouter } from './modules/audit/audit.routes.js';
import { catalogueRouters } from './modules/catalogue/catalogue.routes.js';
import { authRouter } from './modules/auth/auth.routes.js';
import { customersRouter } from './modules/customers/customers.routes.js';
import { dispatchesRouter } from './modules/dispatches/dispatches.routes.js';
import { forecastsRouter } from './modules/forecasts/forecasts.routes.js';
import { healthRouter, type DatabaseCheck } from './modules/health/health.routes.js';
import { invoicesRouter } from './modules/invoices/invoices.routes.js';
import { organisationsRouter } from './modules/organisations/organisations.routes.js';
import { balancesRouter, paymentsRouter } from './modules/payments/payments.routes.js';
import { productsRouter } from './modules/products/products.routes.js';
import { receiptsRouter } from './modules/receipts/receipts.routes.js';
import { reportsRouter } from './modules/reports/reports.routes.js';
import { rolesRouter } from './modules/roles/roles.routes.js';
import { stockRouter } from './modules/stock/stock.routes.js';
import { usersRouter } from './modules/users/users.routes.js';
import { requestContextMiddleware } from './utils/request-context.js';
import { webAppRouter } from './web/web-app.js';

/** Things the app needs from outside, passed in so tests can replace them. */
export interface AppDependencies {
  db: pg.Pool;
  checkDatabase: DatabaseCheck;
}

/** Builds the Express app without starting a server, so tests can call it directly. */
export function createApp(config: AppConfig, deps: AppDependencies): Express {
  configurePgTypes();
  const app = express();
  if (config.trustProxyHops > 0) app.set('trust proxy', config.trustProxyHops);

  // The API only returns JSON, so its responses may load nothing at all. The web app replaces
  // this with a policy that fits Flutter (see web/web-app.ts).
  app.use(
    helmet({
      contentSecurityPolicy: {
        useDefaults: false,
        directives: { defaultSrc: ["'none'"], frameAncestors: ["'none'"] },
      },
    }),
  );
  app.use(cors({ origin: config.corsOrigins }));
  app.use(express.json({ limit: '100kb' }));
  // Remembers the client's address (and later the organisation) for the audit log.
  app.use(requestContextMiddleware);

  app.use('/api/v1/health', healthRouter(config, deps.checkDatabase));
  app.use('/api/v1/auth', authRouter(deps.db));
  app.use('/api/v1/users', usersRouter(deps.db));
  app.use('/api/v1/organisations', organisationsRouter(deps.db));
  app.use('/api/v1/roles', rolesRouter(deps.db));
  app.use('/api/v1/audit-logs', auditRouter(deps.db));
  app.use('/api/v1/products', productsRouter(deps.db));
  for (const [path, router] of Object.entries(catalogueRouters(deps.db))) {
    app.use(`/api/v1/${path}`, router);
  }
  app.use('/api/v1/stock', stockRouter(deps.db, config.businessTimezone));
  app.use('/api/v1/receipts', receiptsRouter(deps.db, config));
  app.use('/api/v1/customers', customersRouter(deps.db));
  app.use('/api/v1/dispatches', dispatchesRouter(deps.db, config.businessTimezone));
  app.use('/api/v1/invoices', invoicesRouter(deps.db, config));
  app.use('/api/v1/payments', paymentsRouter(deps.db, config));
  app.use('/api/v1/balances', balancesRouter(deps.db, config));
  app.use('/api/v1/reports', reportsRouter(deps.db, config));
  app.use('/api/v1/forecasts', forecastsRouter(deps.db, config));
  if (config.webAppDir) app.use(webAppRouter(config.webAppDir));

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
