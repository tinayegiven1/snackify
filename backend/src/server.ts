import { existsSync } from 'node:fs';
import { createApp } from './app.js';
import { loadConfig, type AppConfig } from './config/env.js';
import { logger } from './utils/logger.js';

// Load backend/.env for local development. Real environment variables take precedence.
if (existsSync('.env')) {
  process.loadEnvFile('.env');
}

let config: AppConfig;
try {
  config = loadConfig();
} catch (error) {
  logger.error('Server not started', { reason: (error as Error).message });
  process.exit(1);
}

const app = createApp(config);

const server = app.listen(config.port, (error?: Error) => {
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
});

function shutdown(signal: string): void {
  logger.info('Shutting down', { signal });
  server.close(() => process.exit(0));
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
