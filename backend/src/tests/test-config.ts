import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import { createApp } from '../app.js';
import type { AppConfig } from '../config/env.js';

export const testConfig: AppConfig = {
  nodeEnv: 'test',
  port: 0,
  corsOrigins: ['http://localhost:8080'],
  // Never connected to by unit tests.
  databaseUrl: 'postgres://unused:unused@localhost:5432/unused',
  businessTimezone: 'Africa/Harare',
  billingWeekStartsOn: 1,
  baseCurrency: 'USD',
  paymentTermsDays: 7,
  business: { name: 'Snackify Test Foods', contact: '12 Example Road, Harare' },
  webAppDir: null,
  trustProxyHops: 0,
  receipts: { stockAvailableBeforeVerification: true, documentRequired: true },
  attachments: {
    storageDir: join(tmpdir(), 'snackify-test-attachments'),
    maxBytes: 64 * 1024,
  },
};

/**
 * The app with a fake database check, for tests that do not need PostgreSQL.
 * The pool is never used by those tests (creating a pool does not connect).
 */
export function createTestApp({ databaseUp = true } = {}) {
  return createApp(testConfig, {
    db: new pg.Pool({ connectionString: testConfig.databaseUrl }),
    checkDatabase: async () => databaseUp,
  });
}
