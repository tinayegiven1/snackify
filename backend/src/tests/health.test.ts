import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { createTestApp } from './test-config.js';

describe('GET /api/v1/health', () => {
  const app = createTestApp({ databaseUp: true });

  it('returns 200 when the database is up', async () => {
    const response = await request(app).get('/api/v1/health');

    expect(response.status).toBe(200);
    expect(response.headers['content-type']).toMatch(/application\/json/);
    expect(response.headers['cache-control']).toBe('no-store');
    expect(response.body).toMatchObject({
      status: 'ok',
      service: 'snackify-api',
      environment: 'test',
      checks: { database: 'up' },
    });
    expect(Number.isNaN(Date.parse(response.body.timestamp))).toBe(false);
    expect(response.body.uptimeSeconds).toBeGreaterThanOrEqual(0);
  });

  it('returns 503 when the database is down', async () => {
    const response = await request(createTestApp({ databaseUp: false })).get('/api/v1/health');

    expect(response.status).toBe(503);
    expect(response.body).toMatchObject({ status: 'unavailable', checks: { database: 'down' } });
  });

  it('sets security headers and hides the framework', async () => {
    const response = await request(app).get('/api/v1/health');

    expect(response.headers['x-powered-by']).toBeUndefined();
    expect(response.headers['x-content-type-options']).toBe('nosniff');
  });

  it('allows a configured browser origin', async () => {
    const response = await request(app)
      .get('/api/v1/health')
      .set('Origin', 'http://localhost:8080');

    expect(response.headers['access-control-allow-origin']).toBe('http://localhost:8080');
  });

  it('does not allow an unknown browser origin', async () => {
    const response = await request(app).get('/api/v1/health').set('Origin', 'https://evil.example');

    expect(response.headers['access-control-allow-origin']).toBeUndefined();
  });
});
