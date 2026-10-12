import { createApp } from '../app.js';
import type { AppConfig } from '../config/env.js';

export const testConfig: AppConfig = {
  nodeEnv: 'test',
  port: 0,
  corsOrigins: ['http://localhost:8080'],
  // Never connected to: unit tests replace the database check.
  databaseUrl: 'postgres://unused:unused@localhost:5432/unused',
};

/** The app with a fake database check, for tests that do not need PostgreSQL. */
export function createTestApp({ databaseUp = true } = {}) {
  return createApp(testConfig, { checkDatabase: async () => databaseUp });
}
