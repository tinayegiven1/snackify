import request from 'supertest';
import { afterAll, describe, expect, it, vi } from 'vitest';
import { createApp } from '../../app.js';
import { createPool, databaseHealthCheck } from '../../database/pool.js';
import { testConfig } from '../test-config.js';
import { appDatabaseUrl } from './db-test-helpers.js';

describe('database health check (real PostgreSQL)', () => {
  const pool = createPool(appDatabaseUrl);
  afterAll(() => pool.end());

  it('reports the database as up through GET /api/v1/health', async () => {
    const app = createApp(testConfig, { db: pool, checkDatabase: databaseHealthCheck(pool) });
    const response = await request(app).get('/api/v1/health');

    expect(response.status).toBe(200);
    expect(response.body.checks).toEqual({ database: 'up' });
  });

  it('reports false, without throwing, when PostgreSQL cannot be reached', async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    // Port 1 has nothing listening, so the connection is refused immediately.
    const unreachable = createPool('postgres://nobody:nothing@127.0.0.1:1/snackify_test');

    expect(await databaseHealthCheck(unreachable)()).toBe(false);

    await unreachable.end();
    vi.restoreAllMocks();
  });
});
