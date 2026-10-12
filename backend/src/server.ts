import { createApp } from './app.js';
import { loadConfig, loadDotEnv, type AppConfig } from './config/env.js';
import { createPool, databaseHealthCheck } from './database/pool.js';
import { logger } from './utils/logger.js';

loadDotEnv();

let config: AppConfig;
try {
  config = loadConfig();
} catch (error) {
  logger.error('Server not started', { reason: (error as Error).message });
  process.exit(1);
}

const pool = createPool(config.databaseUrl);
const checkDatabase = databaseHealthCheck(pool);
const app = createApp(config, { db: pool, checkDatabase });

const server = app.listen(config.port, async (error?: Error) => {
  if (error) {
    const hint =
      'code' in error && error.code === 'EADDRINUSE'
        ? `Port ${config.port} is already in use. Stop the other process or set PORT in backend/.env.`
        : undefined;
    logger.error('Server failed to start', { reason: error.message, hint });
    process.exit(1);
  }
  logger.info(`Snackify API listening on http://localhost:${config.port}`, {
    environment: config.nodeEnv,
    healthCheck: `http://localhost:${config.port}/api/v1/health`,
  });

  // Keep running if the database is down (health reports 503), but say so clearly.
  if (await checkDatabase()) {
    logger.info('Database connection OK');
  } else {
    logger.warn('Database is not reachable. Is PostgreSQL running and DATABASE_URL correct?');
  }
});

function shutdown(signal: string): void {
  logger.info('Shutting down', { signal });
  server.close(async () => {
    await pool.end();
    process.exit(0);
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
